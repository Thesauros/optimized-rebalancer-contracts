// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {ForkPins} from "./ForkPins.sol";

interface IHubAccountant {
    function getTimelock() external view returns (address);

    function maxChainExposure() external view returns (uint128);
}

/**
 * @title UpgradeAndGovernanceBaseTest
 * @notice Proves the two outstanding production actions against the contracts that are
 *         actually live on Base, so neither is attempted blind.
 *
 * @dev Both actions are governance transactions on real deployments; this file is the
 *      rehearsal, not the execution. Nothing here broadcasts.
 *
 *      1. The standalone Base vault still runs the pre-hardening implementation: it has no
 *         `getHighWaterMark`, no `providersHealthy` and no pinned provider sources, so it
 *         predates the whole security-accounting and provider-isolation pass. The upgrade
 *         path is `ProxyAdmin.upgradeAndCall` with `initializeSecurityAccounting` as the
 *         call, which is the one function written for exactly this migration.
 *
 *      2. The cross-chain hub's `maxChainExposure` is 0, i.e. the per-chain concentration
 *         cap is off. The registry comment says to set it "once a target allocation exists
 *         or a third chain is added". This proves the Timelock path works and documents
 *         what a cap does, without choosing the number: that is an allocation decision.
 *
 *      Addresses are the live ones, read from `deployments/base/*.json` and confirmed
 *      on-chain on 2026-11-11. Owners are read from the chain rather than hardcoded, so
 *      these tests keep working after the governance rotation the stand is waiting for.
 */
contract UpgradeAndGovernanceBaseTest is Test {
    /// Standalone `Thesauros USDC Vault` / tUSDC on Base (`deployments/base/USDCRebalancerProxy.json`).
    address internal constant VAULT = 0x3C7739173cca612B6394EE57131458185A5beC44;
    /// Cross-chain hub accountant on Base (`deployments/base/crosschain.json`).
    address internal constant ACCOUNTANT = 0xB45819B6844708915c5d7936A847186A6a078b27;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// ERC1967 admin slot: `bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)`.
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    /// ERC1967 implementation slot.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant SCALE = 1e18;

    bool internal forked;

    /// @dev Everything the upgrade must not disturb, captured in one shot.
    struct VaultState {
        uint256 assets;
        uint256 supply;
        uint96 managementFee;
        uint96 performanceFee;
        address treasury;
        address timelock;
        uint256 minAssets;
        address implementation;
    }

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        ForkPins.selectFork(vm, url, ForkPins.BASE_VAR, ForkPins.BASE);
        forked = true;
    }

    function _proxyAdmin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(VAULT, ADMIN_SLOT)))));
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(VAULT, IMPL_SLOT))));
    }

    function _snapshot(Rebalancer vault) internal view returns (VaultState memory s) {
        s.assets = vault.totalAssets();
        s.supply = vault.totalSupply();
        s.managementFee = vault.getManagementFee();
        s.performanceFee = vault.getPerformanceFee();
        s.treasury = vault.getTreasury();
        s.timelock = vault.getTimelock();
        s.minAssets = vault.getMinAssets();
        s.implementation = _implementation();
    }

    function _assertUnchanged(Rebalancer vault, VaultState memory b) internal view {
        assertEq(vault.totalAssets(), b.assets, "total assets changed");
        assertEq(vault.totalSupply(), b.supply, "total supply changed");
        assertEq(vault.getManagementFee(), b.managementFee, "management fee changed");
        assertEq(vault.getPerformanceFee(), b.performanceFee, "performance fee changed");
        assertEq(vault.getTreasury(), b.treasury, "treasury changed");
        assertEq(vault.getTimelock(), b.timelock, "timelock changed");
        assertEq(vault.getMinAssets(), b.minAssets, "min assets changed");
        assertTrue(_implementation() != b.implementation, "implementation unchanged");
    }

    function _assertProvidersIntact(Rebalancer vault, IProvider[] memory before) internal view {
        IProvider[] memory after_ = vault.getProviders();
        assertEq(after_.length, before.length, "provider count changed");
        for (uint256 i; i < before.length; i++) {
            assertEq(address(after_[i]), address(before[i]), "provider order changed");
            assertTrue(
                vault.getPinnedProviderSource(before[i]) != address(0),
                "source not pinned after upgrade"
            );
        }
    }

    /// @dev The old implementation has no selector for these, so the proxy reverts with no data.
    function _revertsOnCall(bytes memory data) internal view returns (bool) {
        (bool ok,) = VAULT.staticcall(data);
        return !ok;
    }

    /// @dev The hub's Timelock, read from the live accountant rather than hardcoded.
    function _hubTimelock() internal view returns (Timelock) {
        return Timelock(payable(IHubAccountant(ACCOUNTANT).getTimelock()));
    }

    /// @dev Upgrades the live proxy and bootstraps security accounting in the same call.
    function _upgrade() internal returns (Rebalancer vault, uint256 highWaterMark) {
        vault = Rebalancer(payable(VAULT));
        // no historic peak is guessed: governance attests the current price as the floor,
        // which is the minimum `initializeSecurityAccounting` accepts
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        highWaterMark = (assets * SCALE + supply - 1) / supply;

        ProxyAdmin proxyAdmin = _proxyAdmin();
        // both resolved before the prank: an external call or a contract creation between
        // `vm.prank` and the pranked call consumes the prank
        address governance = proxyAdmin.owner();
        Rebalancer implementation = new Rebalancer();
        bytes memory data = abi.encodeCall(Rebalancer.initializeSecurityAccounting, (highWaterMark));

        vm.prank(governance);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), address(implementation), data);
    }

    /*//////////////////////////////////////////////////////////////
                     C2 — THE OUTSTANDING VAULT UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev Establishes the starting point: the live vault is on the pre-hardening code.
    function testLiveVaultRunsThePreHardeningImplementation() public {
        if (!forked) return;

        assertTrue(_revertsOnCall(abi.encodeCall(Rebalancer.getHighWaterMark, ())), "has high-water mark");
        assertTrue(_revertsOnCall(abi.encodeCall(Rebalancer.providersHealthy, ())), "has health view");
        assertTrue(
            _revertsOnCall(abi.encodeCall(Rebalancer.getPinnedProviderSource, (IProvider(address(0))))),
            "has pinned sources"
        );

        // sanity: the vault itself is live and readable
        assertGt(Rebalancer(payable(VAULT)).totalSupply(), 0, "vault has no supply");
    }

    /**
     * @dev The migration itself. `upgradeAndCall` keeps the ProxyAdmin as `msg.sender` for
     *      the follow-up call, which is precisely the caller `initializeSecurityAccounting`
     *      accepts, so the upgrade and the security-accounting bootstrap are atomic — there
     *      is no window where the proxy runs new code with an unset high-water mark.
     *
     *      The state-preservation assertions are the point: `RebalancerStorage` grew since
     *      the deployed implementation, so this is what proves the new fields were appended
     *      rather than inserted, and that no live balance, fee, role or provider was moved.
     */
    function testUpgradeToHardenedImplementationPreservesState() public {
        if (!forked) return;

        Rebalancer vault = Rebalancer(payable(VAULT));
        VaultState memory before = _snapshot(vault);
        IProvider[] memory providersBefore = vault.getProviders();

        (, uint256 highWaterMark) = _upgrade();

        assertEq(vault.getHighWaterMark(), highWaterMark, "high-water mark");
        assertTrue(vault.providersHealthy(), "providers unhealthy after upgrade");
        _assertUnchanged(vault, before);
        _assertProvidersIntact(vault, providersBefore);
    }

    /// @dev The upgraded vault must still take money in and give it back. The live vault has
    ///      accrued yield, so the share price is above 1:1; the invariant checked is that the
    ///      mint matches the quoted preview and the redeem returns what was put in, not that
    ///      either is 1:1.
    function testUpgradedVaultStillDepositsAndWithdraws() public {
        if (!forked) return;

        (Rebalancer vault,) = _upgrade();

        address alice = makeAddr("alice");
        uint256 amount = 1_000e6;
        deal(USDC_BASE, alice, amount);

        uint256 quoted = vault.previewDeposit(amount);
        assertGt(quoted, 0, "preview quotes no shares");

        vm.startPrank(alice);
        IERC20Metadata(USDC_BASE).approve(VAULT, amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(shares, quoted, "mint disagrees with the preview");
        assertEq(vault.balanceOf(alice), shares, "shares not credited");

        uint256 assetsBeforeExit = vault.totalAssets();
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // a full round trip at an unchanged price returns principal, to the rounding of the
        // share price; the live vault's price sits just above 1, so allow two micro-units
        assertApproxEqAbs(assets, amount, 2, "redeem did not return principal");
        assertEq(IERC20Metadata(USDC_BASE).balanceOf(alice), assets, "alice not credited");
        // share<->asset conversion rounds down, so a full round trip can leave a wei of dust
        // behind in the vault; that is the correct direction, not a leak
        assertApproxEqAbs(vault.totalAssets(), assetsBeforeExit - assets, 1, "NAV not debited");
        assertEq(vault.balanceOf(alice), 0, "shares not burned");
        assertTrue(vault.providersHealthy(), "providers unhealthy after a round trip");
    }

    /*//////////////////////////////////////////////////////////////
                  C3 — THE OUTSTANDING GOVERNANCE ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Documents the starting point: the concentration cap is disabled on the live hub.
    function testMaxChainExposureIsCurrentlyDisabled() public {
        if (!forked) return;
        assertEq(IHubAccountant(ACCOUNTANT).maxChainExposure(), 0, "cap is not disabled");
    }

    /**
     * @dev Proves the Timelock path end to end against the hub's real Timelock and its real
     *      delay, so setting a cap later is a known-good transaction rather than a guess.
     *
     *      The ratio itself is deliberately a rehearsal parameter, not a decision:
     *      `_chainExposure` compares each chain's bid against `gross * cap`, so a cap below
     *      the current concentration flags `FLAG_CHAIN_EXPOSURE` on the next accepted Tick
     *      and blocks bridge sends into the over-exposed chains until capital is moved out.
     *      Pick the number from an allocation plan, not from this file.
     */
    function testTimelockCanSetMaxChainExposure() public {
        if (!forked) return;

        Timelock timelock = _hubTimelock();
        // resolved before expectRevert: `owner()` is itself an external call and would
        // otherwise be the "next call" the expectation attaches to
        address governance = timelock.owner();
        uint128 cap = 0.75e18; // rehearsal value only; see the NatSpec above
        uint256 delay = timelock.delay();
        assertGe(delay, timelock.MIN_DELAY(), "delay below the contract minimum");

        string memory signature = "setMaxChainExposure(uint128)";
        bytes memory data = abi.encode(cap);
        uint256 eta = block.timestamp + delay;

        vm.prank(governance);
        timelock.queue(ACCOUNTANT, 0, signature, data, eta);

        // not executable before the delay elapses
        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        vm.prank(governance);
        timelock.execute(ACCOUNTANT, 0, signature, data, eta);

        vm.warp(eta + 1);
        vm.prank(governance);
        timelock.execute(ACCOUNTANT, 0, signature, data, eta);

        assertEq(IHubAccountant(ACCOUNTANT).maxChainExposure(), cap, "cap not applied");
    }

    /// @dev A cap above 100% is rejected, so the setter cannot be misused; only an explicit
    ///      0 disables the check, and a failed execution leaves the stored value alone.
    function testMaxChainExposureRejectsAnImpossibleRatio() public {
        if (!forked) return;

        Timelock timelock = _hubTimelock();
        address governance = timelock.owner();
        uint256 eta = block.timestamp + timelock.delay();
        string memory signature = "setMaxChainExposure(uint128)";
        bytes memory data = abi.encode(uint128(1e18 + 1));

        vm.prank(governance);
        timelock.queue(ACCOUNTANT, 0, signature, data, eta);

        vm.warp(eta + 1);
        vm.expectRevert();
        vm.prank(governance);
        timelock.execute(ACCOUNTANT, 0, signature, data, eta);

        assertEq(IHubAccountant(ACCOUNTANT).maxChainExposure(), 0, "cap changed despite the revert");
    }
}
