// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {FeeCapAsset} from "./PerformanceFeeCap.t.sol";
import {RemediationSource, RemediationProvider} from "./SecurityRemediation.t.sol";
import "../../contracts/libraries/Constants.sol";

/**
 * What ops/src/strategy-value.ts relies on. While one provider's balance view
 * fails, every complete-NAV view of the strategy reverts, yet each input of the
 * readable lower bound stays readable. `_readable` below is that computation on
 * public getters only, as the ops code does it; with every provider readable it
 * equals `convertToAssets` (fuzzed), so the bound uses the contract's own fee
 * dilution and rounding. The golden vectors are repeated in
 * ops/test/strategy-value.test.ts.
 */
contract ReadableStrategyValueTest is Test {
    uint256 constant ONE = 1e6;
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");
    FeeCapAsset asset;
    RemediationSource sourceA;
    RemediationSource sourceB;
    RemediationProvider providerA;
    RemediationProvider providerB;
    Rebalancer vault;

    function setUp() public {
        asset = new FeeCapAsset();
        sourceA = new RemediationSource(IERC20(address(asset)));
        sourceB = new RemediationSource(IERC20(address(asset)));
        providerA = new RemediationProvider(sourceA);
        providerB = new RemediationProvider(sourceB);
        vault =
            Rebalancer(payable(address(new TransparentUpgradeableProxy(address(new Rebalancer()), address(this), ""))));
        IProvider[] memory ps = new IProvider[](2);
        ps[0] = providerA;
        ps[1] = providerB;
        asset.mint(address(this), ONE);
        asset.approve(address(vault), ONE);
        vault.initialize(address(this), address(this), address(asset), "readable", "RDB", ps, treasury, 0, 0, ONE);
        vault.grantRole(vault.EXECUTOR_ROLE(), address(this));

        asset.mint(alice, 1000 * ONE);
        vm.startPrank(alice);
        asset.approve(address(vault), 1000 * ONE);
        vault.deposit(1000 * ONE, alice);
        vm.stopPrank();
        _move(400 * ONE);
    }

    function _move(uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        IProvider[] memory from = new IProvider[](1);
        from[0] = providerA;
        IProvider[] memory to = new IProvider[](1);
        to[0] = providerB;
        vault.rebalance(amounts, from, to);
    }

    function _yield(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(sourceA), amount);
        sourceA.simulateYield(address(vault), amount);
    }

    /// The ops bound: idle asset plus every provider whose pinned source answers
    /// and whose balance view answers, each within the contract's stipend.
    function _readableTotal() internal view returns (uint256 total) {
        address a = vault.asset();
        total = IERC20(a).balanceOf(address(vault));
        IProvider[] memory ps = vault.getProviders();
        for (uint256 i; i < ps.length; i++) {
            address pinned = vault.getPinnedProviderSource(ps[i]);
            if (pinned == address(0)) continue;
            try ps[i].getSource{gas: 3_000_000}(a, address(vault), address(0)) returns (address s) {
                if (s != pinned) continue;
            } catch {
                continue;
            }
            try ps[i].getDepositBalance{gas: 3_000_000}(address(vault), vault) returns (uint256 b) {
                total += b;
            } catch {}
        }
    }

    /// Rebalancer._accruedFees on public getters.
    function _fees(uint256 t) internal view returns (uint256 performanceShares, uint256 managementShares) {
        uint256 hwm = vault.getHighWaterMark();
        require(hwm != 0, "SecurityAccountingNotInitialized");
        uint256 supply = vault.totalSupply();
        if (t == 0 || supply == 0) return (0, 0);
        uint256 dt = block.timestamp - vault.getLastTimestamp();
        uint256 m = Math.mulDiv(t, uint256(vault.getManagementFee()) * dt, 365 days * SCALE);
        if (m >= t) m = t - 1;
        uint256 highWaterAssets = Math.mulDiv(hwm, supply, SCALE, Math.Rounding.Ceil);
        uint256 p;
        if (t - m > highWaterAssets && vault.getPerformanceFee() != 0) {
            p = Math.mulDiv(t - m - highWaterAssets, vault.getPerformanceFee(), SCALE);
        }
        if (p >= t - m) p = t - m - 1;
        uint256 net = t - m - p;
        performanceShares = Math.mulDiv(p, supply, net);
        managementShares = Math.mulDiv(m, supply, net);
    }

    /// Rebalancer._convertToAssets over `t`.
    function _readableValue(uint256 shares, uint256 t) internal view returns (uint256) {
        (uint256 p, uint256 m) = _fees(t);
        uint256 supply = vault.totalSupply() + p + m;
        return supply == 0 ? shares : Math.mulDiv(shares, t, supply);
    }

    function testOneFailingViewRevertsCompleteNavButKeepsTheReadableInputs() public {
        uint256 shares = vault.balanceOf(alice);
        sourceB.configure(true, false, 0);
        assertFalse(vault.providersHealthy());
        // what the NAV service called first, and why it stopped every Tick
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.convertToAssets(shares);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.totalAssets();
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.getAccruedFees();

        // every input of the readable bound still answers
        assertEq(vault.getProviders().length, 2);
        assertEq(vault.getPinnedProviderSource(providerA), address(sourceA));
        assertEq(vault.getPinnedProviderSource(providerB), address(sourceB));
        assertEq(providerB.getSource(address(asset), address(vault), address(0)), address(sourceB));
        vm.expectRevert(bytes("view unavailable"));
        providerB.getDepositBalance(address(vault), vault);
        assertGt(vault.getHighWaterMark(), 0);
        vault.getLastTimestamp();
        vault.getManagementFee();
        vault.getPerformanceFee();

        // the bound counts A and idle, not B: 601 of 1001 USDC
        uint256 t = _readableTotal();
        assertEq(t, 601 * ONE);
        assertEq(_readableValue(shares, t), Math.mulDiv(shares, t, vault.totalSupply()));
    }

    function testRetargetedSourceIsLeftOutLikeTheContractDoes() public {
        // a provider answering for another source than the pinned one is not counted
        uint256 before = vault.totalAssets();
        providerB.setSource(new RemediationSource(IERC20(address(asset))));
        assertFalse(vault.providersHealthy());
        assertEq(_readableTotal(), before - 400 * ONE);
    }

    /// The bound is the contract's conversion whenever every provider answers.
    function testFuzzReadableValueEqualsConvertToAssets(
        uint96 managementFee,
        uint96 performanceFee,
        uint32 elapsed,
        uint64 gain,
        uint64 extraShares
    ) public {
        vault.setManagementFee(uint96(bound(managementFee, 0, MAX_MANAGEMENT_FEE)));
        vault.setPerformanceFee(uint96(bound(performanceFee, 0, MAX_PERFORMANCE_FEE)));
        skip(bound(elapsed, 0, 5 * 365 days));
        _yield(bound(gain, 0, 10_000 * ONE));
        uint256 t = _readableTotal();
        assertEq(t, vault.totalAssets());
        (uint256 p, uint256 m) = vault.getAccruedFees();
        (uint256 rp, uint256 rm) = _fees(t);
        assertEq(rp, p);
        assertEq(rm, m);
        uint256[3] memory amounts = [vault.balanceOf(alice), 1, bound(extraShares, 0, vault.totalSupply())];
        for (uint256 i; i < 3; i++) {
            assertEq(_readableValue(amounts[i], t), vault.convertToAssets(amounts[i]));
        }
    }

    /// Fixed scenario; the same numbers are the vectors of ops/test/strategy-value.test.ts.
    function testGoldenVectors() public {
        vault.setManagementFee(0.02e18);
        vault.setPerformanceFee(0.2e18);
        skip(30 days);
        _yield(50 * ONE);
        uint256 shares = vault.balanceOf(alice);
        assertEq(block.timestamp, 2_592_001);
        assertEq(vault.getLastTimestamp(), 1);
        assertEq(vault.getHighWaterMark(), 1e18);
        assertEq(vault.totalSupply(), 1_001_000_000);
        assertEq(shares, 1_000_000_000);

        // every provider answers: the contract's own numbers
        assertEq(vault.totalAssets(), 1_051_000_000);
        (uint256 p, uint256 m) = vault.getAccruedFees();
        assertEq(p, 9_295_838);
        assertEq(m, 1_663_494);
        assertEq(vault.convertToAssets(shares), 1_038_579_285);

        // provider B's view fails: the readable bound
        sourceB.configure(true, false, 0);
        uint256 t = _readableTotal();
        assertEq(t, 651_000_000);
        (uint256 rp, uint256 rm) = _fees(t);
        assertEq(rp, 0);
        assertEq(rm, 1_648_187);
        assertEq(_readableValue(shares, t), 649_280_583);
    }
}
