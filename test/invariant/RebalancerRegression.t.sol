// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {RebalancerBase} from "./RebalancerBase.t.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockProvider} from "../mocks/MockProvider.sol";
import "../../contracts/libraries/Constants.sol";

/**
 * @title RevertingGetSourceProvider
 * @notice Minimal standalone `IProvider` used only to exercise Finding 4's try/catch
 *         around a removed provider's `getSource()` reverting. `getSource()` reverts only
 *         once `setRevertOnGetSource(true)` has been called, so it can first be added to a
 *         vault's provider list normally (which itself calls `getSource()` to grant
 *         approval) and only later start failing, mimicking a provider that broke AFTER
 *         being integrated.
 */
contract RevertingGetSourceProvider is IProvider {
    address public constant DUMMY_SOURCE = address(0x1234);

    bool public revertOnGetSource;

    function setRevertOnGetSource(bool value) external {
        revertOnGetSource = value;
    }

    function deposit(uint256, IRebalancer) external pure override returns (bool) {
        return true;
    }

    function withdraw(uint256, IRebalancer) external pure override returns (bool) {
        return true;
    }

    function getDepositBalance(
        address,
        IRebalancer
    ) external pure override returns (uint256) {
        return 0;
    }

    function getDepositRate(IRebalancer) external pure override returns (uint256) {
        return 0;
    }

    function getSource(
        address,
        address,
        address
    ) external view override returns (address) {
        if (revertOnGetSource) revert("broken provider: getSource");
        return DUMMY_SOURCE;
    }

    function getIdentifier() external pure override returns (string memory) {
        return "Reverting_Provider";
    }
}

/**
 * @title RebalancerRegressionTest
 * @notice Non-invariant, targeted regression tests for Findings 3, 4, 5, 6, and 7, plus
 *         the classic ERC4626 donation/inflation-attack check. Companion to
 *         `RebalancerInvariants.t.sol`'s property-based coverage.
 */
contract RebalancerRegressionTest is RebalancerBase {
    using Math for uint256;
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                    FINDING 5 — ENTRY PROVIDER / LIST DESYNC
    //////////////////////////////////////////////////////////////*/

    /// @notice `initialize()`'s very first call to `_setProviders` runs while
    /// `$._entryProvider` is still `address(0)` (before `_setEntryProvider` has ever run).
    /// If the Finding 5 containment check didn't correctly skip itself in that bootstrap
    /// case, EVERY test in this whole suite would already have failed in `setUp()`; this
    /// test asserts the resulting state directly as an explicit, documented proof.
    function test_Initialize_BootstrapSucceedsDespiteEntryProviderCheck() public view {
        assertEq(address(vault.getEntryProvider()), address(providerA));
        IProvider[] memory providers = vault.getProviders();
        assertEq(providers.length, 3);
        assertEq(address(providers[0]), address(providerA));
    }

    function test_SetProviders_RevertsIfDroppingCurrentEntryProvider() public {
        IProvider[] memory newProviders = new IProvider[](2);
        newProviders[0] = providerB;
        newProviders[1] = providerC;
        // providerA — the current entry provider — is intentionally excluded.

        vm.expectRevert(IRebalancer.EntryProviderNotInProviders.selector);
        vault.setProviders(newProviders); // timelock == address(this) in RebalancerBase
    }

    function test_SetProviders_SucceedsIfEntryProviderRetained() public {
        MockYieldSource sourceD = new MockYieldSource(asset);
        MockProvider providerD = new MockProvider(sourceD);

        IProvider[] memory newProviders = new IProvider[](4);
        newProviders[0] = providerA; // entry provider retained
        newProviders[1] = providerB;
        newProviders[2] = providerC;
        newProviders[3] = providerD;

        vault.setProviders(newProviders);

        assertEq(vault.getProviders().length, 4);
        assertEq(address(vault.getEntryProvider()), address(providerA));
    }

    /// @notice Defense-in-depth re-validation inside `_deposit()` itself: even though
    /// `_setProviders` already prevents this state from being reached through normal
    /// admin/timelock paths, a deposit must still refuse to route to an entry provider
    /// that (somehow) is no longer in the provider list.
    function test_Deposit_RevertsIfEntryProviderNotInProviders() public {
        // Seed providerB with a real balance directly (bypassing the vault), so
        // totalAssets() stays nonzero once providerA is dropped below. Without this, all
        // value (from the dead-share deposit) sits at providerA alone, so removing it
        // would make totalAssets() legitimately 0 and _convertToSharesWithTotals would hit
        // an (expected, unrelated) division-by-zero before execution ever reaches
        // _deposit()'s own check — this seed isolates the specific property being tested.
        uint256 seedAmount = HUNDRED;
        asset.mint(address(this), seedAmount);
        asset.approve(address(sourceB), seedAmount);
        sourceB.creditDeposit(address(vault), seedAmount);

        // there is no ordinary path to reach this state post-init (that is the point of
        // the Finding 5 fix in _setProviders); we recreate the guarded precondition via
        // raw storage writes purely to exercise _deposit()'s own independent check in
        // isolation, bypassing _setProviders' guard entirely.
        IProvider[] memory shrunk = new IProvider[](2);
        shrunk[0] = providerB;
        shrunk[1] = providerC;

        vm.store(address(vault), _providersLengthSlot(), bytes32(uint256(0)));
        for (uint256 i; i < shrunk.length; i++) {
            vm.store(
                address(vault),
                bytes32(uint256(_providersArrayDataSlot()) + i),
                bytes32(uint256(uint160(address(shrunk[i]))))
            );
        }
        vm.store(address(vault), _providersLengthSlot(), bytes32(shrunk.length));

        assertEq(vault.getProviders().length, 2);
        assertEq(address(vault.getEntryProvider()), address(providerA));
        assertGt(vault.totalAssets(), 0);

        asset.mint(alice, HUNDRED);
        vm.startPrank(alice);
        asset.approve(address(vault), HUNDRED);
        vm.expectRevert(IRebalancer.InvalidProvider.selector);
        vault.deposit(HUNDRED, alice);
        vm.stopPrank();
    }

    /// @dev Slot of `RebalancerStorage._providers.length` — the array field is 3rd
    /// declared in the struct (`_asset`+`_underlyingDecimals` share slot 0, `_providers` is
    /// the very next field, so it occupies slot offset 1). Located via `stdstore`-style
    /// brute force would not work for array length directly through a getter, so this is
    /// derived the same way `_getRebalancerStorage()` derives its base slot.
    function _providersLengthSlot() internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00
                ) + 1
            );
    }

    function _providersArrayDataSlot() internal pure returns (bytes32) {
        return keccak256(abi.encode(_providersLengthSlot()));
    }

    /*//////////////////////////////////////////////////////////////
                    FINDING 4 — STALE APPROVAL REVOCATION
    //////////////////////////////////////////////////////////////*/

    function test_SetProviders_RevokesStaleApprovalOnRemoval() public {
        assertEq(
            asset.allowance(address(vault), address(sourceC)),
            type(uint256).max
        );

        IProvider[] memory newProviders = new IProvider[](2);
        newProviders[0] = providerA;
        newProviders[1] = providerB;
        // providerC is dropped.

        vault.setProviders(newProviders);

        assertEq(asset.allowance(address(vault), address(sourceC)), 0);
        // untouched providers keep their approval.
        assertEq(
            asset.allowance(address(vault), address(sourceA)),
            type(uint256).max
        );
        assertEq(
            asset.allowance(address(vault), address(sourceB)),
            type(uint256).max
        );
    }

    function test_SetProviders_EmitsStaleApprovalRevokeFailedOnBrokenProvider() public {
        RevertingGetSourceProvider brokenProvider = new RevertingGetSourceProvider();

        IProvider[] memory withBroken = new IProvider[](4);
        withBroken[0] = providerA;
        withBroken[1] = providerB;
        withBroken[2] = providerC;
        withBroken[3] = brokenProvider;
        // getSource() must still succeed here (revert flag not set yet) so it can be added.
        vault.setProviders(withBroken);

        brokenProvider.setRevertOnGetSource(true);

        IProvider[] memory withoutBroken = new IProvider[](3);
        withoutBroken[0] = providerA;
        withoutBroken[1] = providerB;
        withoutBroken[2] = providerC;

        vm.expectEmit(address(vault));
        emit IRebalancer.StaleApprovalRevokeFailed(address(brokenProvider));
        vault.setProviders(withoutBroken);

        // removal from the list succeeds regardless of the approval-revocation failure.
        assertEq(vault.getProviders().length, 3);
    }

    /*//////////////////////////////////////////////////////////////
        FINDINGS 3 & 6 — REENTRANCY-GUARD / HIGH-WATER-MARK MIGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The core ordering-trap proof for the combined initializeV2() migration: a
    /// vault that has been quietly accruing real, un-fee'd yield — exactly like an
    /// already-deployed, pre-Finding-6 proxy, whose high-water mark was never written and
    /// therefore still sits at the storage default of 0 — must NOT have that entire
    /// pre-existing NAV treated as fresh profit the moment fees are next applied.
    function test_InitializeV2_NoWindfallFeeFromPreExistingYield() public {
        // isolate the performance-fee behavior being tested from management-fee noise.
        vault.setManagementFee(0);
        vault.setPerformanceFee(0.1e18); // 10%

        // real position + real, pre-existing, never-fee'd profit — mirrors a live proxy
        // that has been accruing yield under the OLD implementation.
        _executeDeposit(vault, THOUSAND, alice);
        _simulateYield(sourceA, HUNDRED);

        // Force the mark back to the pre-fix storage default (0), simulating a proxy
        // whose old initialize() never wrote this newly-appended field.
        stdstore.target(address(vault)).sig("getHighWaterMark()").checked_write(
            uint256(0)
        );
        assertEq(vault.getHighWaterMark(), 0);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);

        // the migration itself must never mint anything...
        vault.initializeV2();
        assertEq(
            vault.balanceOf(treasury),
            treasurySharesBefore,
            "initializeV2() must not mint fee shares by itself"
        );

        // ...and must have bootstrapped the mark to the CURRENT (already-grown) price.
        uint256 expectedSharePrice = vault.totalAssets().mulDiv(
            SCALE,
            vault.totalSupply(),
            Math.Rounding.Floor
        );
        assertEq(vault.getHighWaterMark(), expectedSharePrice);
        assertGt(
            vault.getHighWaterMark(),
            SCALE,
            "sanity: price should have grown above the initial 1:1"
        );

        // the very next real fee accrual must not mint a windfall from the pre-existing yield.
        vault.applyFees();
        assertEq(
            vault.balanceOf(treasury),
            treasurySharesBefore,
            "applyFees() right after migration minted a windfall performance fee"
        );
    }

    /// @notice `initializeV2()` can only ever run once (OZ's `reinitializer(2)`), and the
    /// vault must remain fully functional (including `nonReentrant`-guarded entry points)
    /// afterward.
    function test_InitializeV2_CannotBeCalledTwiceAndVaultStaysFunctional() public {
        vault.initializeV2();

        vm.expectRevert();
        vault.initializeV2();

        // a nonReentrant-guarded function must still behave completely normally.
        uint256 shares = _executeDeposit(vault, HUNDRED, alice);
        assertGt(shares, 0);
    }

    /// @notice `testFuzz_HWM_NoFeeOnRecoveryToOldPeak` — the core behavioral proof of
    /// Finding 6: a loss followed by a recovery back to (but not above) the pre-loss peak
    /// must never be charged a performance fee twice on the same underlying value.
    function testFuzz_HWM_NoFeeOnRecoveryToOldPeak(
        uint256 growthAmount,
        uint256 lossSeed
    ) public {
        vault.setManagementFee(0);
        vault.setPerformanceFee(0.1e18); // 10%

        growthAmount = bound(growthAmount, ONE, 500_000e6);

        _executeDeposit(vault, THOUSAND, alice);
        _simulateYield(sourceA, growthAmount);

        vault.applyFees(); // charges perf fee on the growth, ratchets HWM up to price P1
        uint256 hwmAfterGrowth = vault.getHighWaterMark();
        uint256 treasuryAfterGrowth = vault.balanceOf(treasury);
        assertGt(hwmAfterGrowth, SCALE);

        // simulate a loss strictly less than the current balance at the source, so price
        // drops below (but the vault doesn't go to) zero.
        uint256 balAtSource = sourceA.balances(address(vault));
        uint256 lossAmount = bound(lossSeed, 1, balAtSource - 1 > 0 ? balAtSource - 1 : 1);
        sourceA.simulateLoss(address(vault), lossAmount);

        vault.applyFees();
        assertEq(
            vault.balanceOf(treasury),
            treasuryAfterGrowth,
            "performance fee charged on a loss"
        );
        assertEq(
            vault.getHighWaterMark(),
            hwmAfterGrowth,
            "high-water mark must not move down on a loss"
        );

        // recover EXACTLY back to the pre-loss peak (not above it).
        _simulateYield(sourceA, lossAmount);

        vault.applyFees();
        assertEq(
            vault.balanceOf(treasury),
            treasuryAfterGrowth,
            "performance fee charged on mere recovery to the old peak"
        );
        assertEq(vault.getHighWaterMark(), hwmAfterGrowth);
    }

    /*//////////////////////////////////////////////////////////////
                    FINDING 7 — SEQUENTIAL FEE CLAMP
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression test for the ~20-year-`dt` revert-lock: at the maximum
    /// management fee rate, a long-dormant vault's `applyFees()` (and therefore every
    /// deposit/withdraw/mint/redeem, which all call it first) must not permanently revert.
    /// @dev At exactly this magnitude (25 years * 5%/year = 125% unclamped), the clamp caps
    /// the management fee at exactly 100% of the pool, correctly leaving nothing over for a
    /// performance fee and minting 0 shares this period — by design (see `_accruedFees`'s
    /// `totalAssetsWithoutFees == 0` guard) — rather than reverting or dividing by zero. The
    /// sole point of this test is that the call itself survives; the complementary test
    /// below shows the clamp still charges a real, nonzero fee below that 100% threshold.
    function test_AccruedFees_SequentialClampPreventsRevertLockAfterLongDormancy()
        public
    {
        vault.setManagementFee(uint96(MAX_MANAGEMENT_FEE));
        _executeDeposit(vault, THOUSAND, alice);

        // ~25 years: comfortably past the ~20-year point at which, pre-fix,
        // managementFeeAssets could exceed totalManagedAssets and underflow
        // `totalManagedAssets - managementFeeAssets - performanceFeeAssets`.
        vm.warp(block.timestamp + 25 * 365 days);

        vault.applyFees(); // must not revert

        assertGt(vault.totalSupply(), 0, "vault must remain functional post-clamp");

        // the vault must remain otherwise usable after the clamp kicks in.
        uint256 shares = _executeDeposit(vault, ONE, bob);
        assertGt(shares, 0);
    }

    /// @notice Complementary sanity check: below the 100%-consumption threshold, the
    /// clamp is a defensive bound, not a fee-zeroing mechanism — a real, nonzero
    /// management fee is still charged.
    function test_AccruedFees_ManagementFeeStillChargedBelowClampThreshold() public {
        vault.setManagementFee(uint96(MAX_MANAGEMENT_FEE));
        _executeDeposit(vault, THOUSAND, alice);

        uint256 treasuryBefore = vault.balanceOf(treasury);

        // 10 years at the 5%/year max rate implies an unclamped management fee of ~50% of
        // the pool — comfortably below the 100% full-consumption threshold.
        vm.warp(block.timestamp + 10 * 365 days);

        vault.applyFees();

        assertGt(
            vault.balanceOf(treasury),
            treasuryBefore,
            "a below-threshold dormancy period should still charge a real management fee"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    DONATION / INFLATION-ATTACK REGRESSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Confirms the existing dead-share mitigation (the non-trivial `minAssets_`
    /// seed deposit permanently minted to the vault itself in `initialize()`) still holds:
    /// donating directly to a yield source on the vault's behalf (bypassing
    /// `Rebalancer.deposit()` entirely, exactly like calling Aave's `supply(asset, amount,
    /// onBehalfOf=vault, 0)` directly) inflates `totalAssets()` without minting any shares,
    /// but a subsequent, realistically-sized victim deposit must still receive a fair,
    /// non-zero number of shares.
    function test_DonationInflationAttack_VictimSharesNotRoundedToZero() public {
        address attacker = makeAddr("attacker");
        uint256 donation = THOUSAND;

        asset.mint(attacker, donation);
        vm.startPrank(attacker);
        asset.approve(address(sourceA), donation);
        sourceA.creditDeposit(address(vault), donation); // no vault shares minted
        vm.stopPrank();

        assertGe(vault.totalAssets(), initialTotalAssets + donation);
        assertEq(vault.totalSupply(), initialTotalSupply); // unchanged by the donation

        uint256 sharesBefore = vault.balanceOf(bob);
        uint256 shares = _executeDeposit(vault, HUNDRED, bob);

        assertGt(shares, 0, "victim's deposit was rounded down to zero shares");
        assertEq(vault.balanceOf(bob), sharesBefore + shares);
        assertGt(vault.convertToAssets(shares), 0);
    }
}
