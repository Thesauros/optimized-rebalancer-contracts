// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import "../../contracts/libraries/Constants.sol";

/*//////////////////////////////////////////////////////////////
                            TEST DOUBLES

    Fork-free doubles, in the spirit of `test/forking/ForkingBase.t.sol` but
    with no RPC dependency, so the fee-cap assertions run deterministically
    and in milliseconds.

    `FeeCapProvider.deposit`/`withdraw` are DELEGATECALLED by the vault (see
    `IProvider`'s NatSpec and `Rebalancer._delegateActionToProvider`), so while
    they execute `address(this) == vault`. The provider therefore holds no
    mutable storage of its own — any `SSTORE` here would land in the vault's
    storage layout and corrupt it. All mutable state lives on `FeeCapSource`,
    a plain contract reached through ordinary external `CALL`s, mirroring how
    the real adapters call out to Aave's Pool / Compound's Comet / MetaMorpho.
//////////////////////////////////////////////////////////////*/

/// @notice Freely-mintable 6-decimal asset standing in for USDC/USDT0.
contract FeeCapAsset is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands in for an external lending market. Never delegatecalled.
contract FeeCapSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    /// @dev vault => assets this source reports as deposited on that vault's behalf.
    mapping(address vault => uint256) public balances;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    /// @notice Pulls `amount` from the caller (the vault, under delegatecall) and
    /// credits `vault`'s ledger balance.
    function creditDeposit(address vault, uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[vault] += amount;
    }

    /// @notice Debits `vault`'s ledger balance and sends `amount` of asset to `to`.
    function debitAndSend(
        address vault,
        uint256 amount,
        address to
    ) external returns (uint256 sent) {
        balances[vault] -= amount;
        if (amount > 0) {
            asset.safeTransfer(to, amount);
        }
        sent = amount;
    }

    function balanceOf(address vault) external view returns (uint256) {
        return balances[vault];
    }

    /// @notice Test helper: yield accruing at the source for `vault`. Pulls the
    /// backing tokens from the caller so the source can always honor withdrawals.
    function simulateYield(address vault, uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[vault] += amount;
    }
}

/// @notice Stands in for `AaveV3Provider`/`CompoundV3Provider`/`MorphoProvider`.
contract FeeCapProvider is IProvider {
    FeeCapSource private immutable _source;

    constructor(FeeCapSource source_) {
        _source = source_;
    }

    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _source.creditDeposit(address(vault), amount);
        success = true;
    }

    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _source.debitAndSend(address(vault), amount, address(vault));
        success = true;
    }

    function getDepositBalance(
        address user,
        IRebalancer
    ) external view override returns (uint256 balance) {
        balance = _source.balanceOf(user);
    }

    function getDepositRate(IRebalancer) external pure override returns (uint256) {
        return 0;
    }

    function getSource(
        address,
        address,
        address
    ) external view override returns (address source) {
        source = address(_source);
    }

    function getIdentifier() public pure override returns (string memory) {
        return "Mock_Provider";
    }
}

/*//////////////////////////////////////////////////////////////
                                 TESTS
//////////////////////////////////////////////////////////////*/

/**
 * @title PerformanceFeeCapTest
 * @notice Covers the `MAX_PERFORMANCE_FEE` cap raise from 0.2e18 (20%) to 0.25e18 (25%)
 *         and the fee-accrual arithmetic at the new cap.
 *
 * @dev IMPORTANT — what "accrual" means in the live generation. `Rebalancer._accruedFees`
 *      charges performance fee on `totalManagedAssets - $._lastTotalAssets`, and
 *      `_applyFees` unconditionally resets `$._lastTotalAssets = totalManagedAssets`.
 *      The baseline therefore ratchets DOWN as well as up: it is a rolling
 *      last-applied-assets snapshot, not a high-water mark. A loss followed by a
 *      recovery is charged again on the recovery. (A real `_highWaterMark` only
 *      exists on the unreleased `crosschain-sandbox` branch, via `initializeV2`.)
 *      Every assertion below is written against the rolling-baseline math that is
 *      actually deployed, because that is the math the cap change ships with.
 */
contract PerformanceFeeCapTest is Test {
    uint256 internal constant MIN_ASSETS = 1e6; // 1 USDC seed / dead shares
    uint256 internal constant ONE = 1e6;

    /// @dev The cap this change introduces, written out so a wrong `Constants.sol`
    ///      cannot make the suite pass by moving the goalposts with it.
    uint256 internal constant EXPECTED_MAX_PERFORMANCE_FEE = 250_000_000_000_000_000; // 0.25e18
    /// @dev The cap being replaced; kept as a regression/compat reference.
    uint256 internal constant OLD_MAX_PERFORMANCE_FEE = 200_000_000_000_000_000; // 0.2e18

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");

    struct Stack {
        FeeCapAsset asset;
        FeeCapSource source;
        FeeCapProvider provider;
        Rebalancer vault;
    }

    Stack internal s;

    function setUp() public {
        s = _newStack(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              FIXTURES
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys an independent implementation + transparent proxy + provider stack.
    ///      The test contract is `admin_` (so it holds ADMIN_ROLE) and `timelock_`.
    function _newStack(
        uint96 managementFee,
        uint96 performanceFee
    ) internal returns (Stack memory out) {
        out.asset = new FeeCapAsset();
        out.source = new FeeCapSource(IERC20(address(out.asset)));
        out.provider = new FeeCapProvider(out.source);

        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(this), // owner of the ProxyAdmin the proxy constructor creates
            ""
        );
        out.vault = Rebalancer(payable(address(proxy)));

        out.asset.mint(address(this), MIN_ASSETS);
        out.asset.approve(address(out.vault), MIN_ASSETS);

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = out.provider;

        out.vault.initialize(
            address(this), // admin for testing
            address(this), // timelock for testing
            address(out.asset),
            "Mock Rebalancer",
            "mrTOK",
            providers,
            treasury,
            managementFee,
            performanceFee,
            MIN_ASSETS
        );
    }

    function _deposit(Stack memory st, address who, uint256 amount) internal {
        st.asset.mint(who, amount);
        vm.startPrank(who);
        st.asset.approve(address(st.vault), amount);
        st.vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Credits `amount` of yield to the vault's provider balance without any
    ///      deposit/withdraw, so `_lastTotalAssets` is left untouched.
    function _simulateYield(Stack memory st, uint256 amount) internal {
        st.asset.mint(address(this), amount);
        st.asset.approve(address(st.source), amount);
        st.source.simulateYield(address(st.vault), amount);
    }

    /// @dev Mirrors `Rebalancer._accruedFees` for the performance leg with the
    ///      management fee at zero and no elapsed time.
    function _expectedPerformanceFeeShares(
        uint256 yield,
        uint256 performanceFee,
        uint256 totalSupplyBefore,
        uint256 totalAssetsAfter
    ) internal pure returns (uint256 feeAssets, uint256 feeShares) {
        feeAssets = (yield * performanceFee) / SCALE;
        feeShares =
            (feeAssets * totalSupplyBefore) /
            (totalAssetsAfter - feeAssets);
    }

    /*//////////////////////////////////////////////////////////////
                       1. THE CONSTANT ITSELF
    //////////////////////////////////////////////////////////////*/

    function testMaxPerformanceFeeIs25Percent() public view {
        assertEq(
            MAX_PERFORMANCE_FEE,
            EXPECTED_MAX_PERFORMANCE_FEE,
            "MAX_PERFORMANCE_FEE must be 0.25e18"
        );
        // 25% == 20% * 1.25, i.e. exactly one quarter of scale, not a rounding artefact
        assertEq(MAX_PERFORMANCE_FEE, SCALE / 4, "cap must be SCALE/4");
    }

    function testMaxPerformanceFeeFitsTheUint96StorageField() public pure {
        // `_performanceFee` is stored as uint96; the cap must be representable.
        assertTrue(
            MAX_PERFORMANCE_FEE <= type(uint96).max,
            "cap must fit uint96"
        );
    }

    function testMaxManagementFeeCapIsUnchanged() public view {
        // Guard: this change must touch the performance cap only.
        assertEq(MAX_MANAGEMENT_FEE, 0.05e18, "management cap must stay 5%");
        assertEq(SCALE, 1e18, "SCALE must stay 1e18");
        assertTrue(
            MAX_PERFORMANCE_FEE > MAX_MANAGEMENT_FEE,
            "performance cap must exceed management cap"
        );
    }

    /*//////////////////////////////////////////////////////////////
                 2. setPerformanceFee AT / ABOVE THE CAP
    //////////////////////////////////////////////////////////////*/

    function testSetPerformanceFeeAtCapSucceedsFromAdminRole() public {
        assertTrue(
            s.vault.hasRole(bytes32(0), address(this)),
            "fixture must hold ADMIN_ROLE"
        );

        vm.expectEmit(true, true, true, true);
        emit IRebalancer.PerformanceFeeUpdated(MAX_PERFORMANCE_FEE);

        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));

        assertEq(
            uint256(s.vault.getPerformanceFee()),
            MAX_PERFORMANCE_FEE,
            "cap value must be accepted and stored"
        );
    }

    function testSetPerformanceFeeOneAboveCapRevertsInvalidInput() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE) + 1);

        // the rejected call must leave the stored fee untouched
        assertEq(s.vault.getPerformanceFee(), 0, "fee must be unchanged");
    }

    function testSetPerformanceFeeAtUint96MaxRevertsInvalidInput() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        s.vault.setPerformanceFee(type(uint96).max);

        assertEq(s.vault.getPerformanceFee(), 0, "fee must be unchanged");
    }

    /// @dev The pre-change cap stays a legal configuration: vaults already running at
    ///      20% must not be broken by raising the ceiling.
    function testSetPerformanceFeeAtOldCapStillSucceeds() public {
        s.vault.setPerformanceFee(uint96(OLD_MAX_PERFORMANCE_FEE));
        assertEq(
            uint256(s.vault.getPerformanceFee()),
            OLD_MAX_PERFORMANCE_FEE,
            "0.2e18 must remain accepted"
        );

        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));
        assertEq(uint256(s.vault.getPerformanceFee()), MAX_PERFORMANCE_FEE);
    }

    function testSetPerformanceFeeWithoutAdminRoleReverts() public {
        vm.prank(mallory);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));

        assertEq(s.vault.getPerformanceFee(), 0, "fee must be unchanged");
    }

    /// @dev The cap is enforced in `_setPerformanceFee`, which `initialize` also routes
    ///      through, so a vault cannot be born above 25%.
    function testInitializeAtCapSucceeds() public {
        Stack memory atCap = _newStack(0, uint96(MAX_PERFORMANCE_FEE));
        assertEq(
            uint256(atCap.vault.getPerformanceFee()),
            MAX_PERFORMANCE_FEE,
            "initialize must accept the cap"
        );
    }

    function testInitializeOneAboveCapReverts() public {
        // `initialize` reverts inside the proxy call; assert on the raw call so the
        // bubbled-up custom error is what we check.
        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(this),
            ""
        );

        FeeCapAsset asset = new FeeCapAsset();
        FeeCapSource source = new FeeCapSource(IERC20(address(asset)));
        FeeCapProvider provider = new FeeCapProvider(source);

        asset.mint(address(this), MIN_ASSETS);
        asset.approve(address(proxy), MIN_ASSETS);

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = provider;

        vm.expectRevert(IRebalancer.InvalidInput.selector);
        Rebalancer(payable(address(proxy))).initialize(
            address(this),
            address(this),
            address(asset),
            "Mock Rebalancer",
            "mrTOK",
            providers,
            treasury,
            0,
            uint96(MAX_PERFORMANCE_FEE) + 1,
            MIN_ASSETS
        );
    }

    /*//////////////////////////////////////////////////////////////
              3. MANAGEMENT-FEE CAP BEHAVIOUR IS UNTOUCHED
    //////////////////////////////////////////////////////////////*/

    function testSetManagementFeeAtCapStillSucceeds() public {
        s.vault.setManagementFee(uint96(MAX_MANAGEMENT_FEE));
        assertEq(uint256(s.vault.getManagementFee()), MAX_MANAGEMENT_FEE);
    }

    function testSetManagementFeeOneAboveCapStillReverts() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        s.vault.setManagementFee(uint96(MAX_MANAGEMENT_FEE) + 1);
        assertEq(s.vault.getManagementFee(), 0, "fee must be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                 4. ACCRUAL AT 25% — WORKED EXAMPLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fixed, hand-checkable numbers.
     *
     *      seed (dead shares held by the vault)      1_000_000
     *      alice deposits                        1_000_000_000
     *      => totalSupply before yield           1_001_000_000
     *      => _lastTotalAssets                   1_001_000_000
     *      yield credited                          100_000_000
     *      => totalAssets after yield            1_101_000_000
     *
     *      performanceFeeAssets = 100_000_000 * 0.25e18 / 1e18 = 25_000_000
     *      totalAssetsWithoutFees = 1_101_000_000 - 25_000_000 = 1_076_000_000
     *      performanceFeeShares = 25_000_000 * 1_001_000_000 / 1_076_000_000
     *                           = 23_257_434  (floor, remainder 1_016)
     */
    function testPerformanceFeeAccrualAtCapWorkedExample() public {
        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));

        _deposit(s, alice, 1_000 * ONE);

        uint256 supplyBefore = s.vault.totalSupply();
        assertEq(supplyBefore, 1_001_000_000, "fixture: seed + alice shares");
        assertEq(
            s.vault.getLastTotalAssets(),
            1_001_000_000,
            "fixture: baseline equals assets"
        );
        uint256 aliceShares = s.vault.balanceOf(alice);
        assertEq(aliceShares, 1_000_000_000, "fixture: 1:1 price on deposit");

        uint256 yield = 100 * ONE;
        _simulateYield(s, yield);

        uint256 totalAssetsAfter = s.vault.totalAssets();
        assertEq(totalAssetsAfter, 1_101_000_000, "fixture: yield is visible");

        // preview before applying, so we check the contract's own view of the accrual
        (uint256 previewPerf, uint256 previewMgmt) = s.vault.getAccruedFees();
        assertEq(previewMgmt, 0, "no management fee configured");
        assertEq(previewPerf, 23_257_434, "previewed performance fee shares");

        // alice's claim before the fee is applied
        uint256 aliceClaimBefore = (aliceShares * totalAssetsAfter) / supplyBefore;

        vm.expectEmit(true, true, true, true);
        emit IRebalancer.FeesApplied(
            1_001_000_000,
            1_101_000_000,
            23_257_434,
            0
        );
        s.vault.applyFees();

        uint256 treasuryShares = s.vault.balanceOf(treasury);
        assertEq(treasuryShares, 23_257_434, "treasury fee shares");

        // shares were minted, no assets moved
        assertEq(
            s.vault.totalAssets(),
            1_101_000_000,
            "fee application must not move assets"
        );
        assertEq(
            s.vault.totalSupply(),
            1_001_000_000 + 23_257_434,
            "supply grows by exactly the fee shares"
        );
        assertEq(
            s.vault.getLastTotalAssets(),
            1_101_000_000,
            "baseline ratchets to post-yield assets"
        );
        assertEq(s.vault.balanceOf(alice), aliceShares, "alice is not diluted in shares");

        // economic effect: the treasury's redeemable value is 25% of the yield,
        // less at most one unit of floor rounding
        uint256 treasuryClaim = s.vault.convertToAssets(treasuryShares);
        assertLe(treasuryClaim, 25_000_000, "treasury must not over-charge");
        assertGe(treasuryClaim, 25_000_000 - 2, "treasury must take the full 25%");
        assertEq(treasuryClaim, 24_999_999, "exact post-rounding treasury value");

        // and that value is taken pro-rata from the pre-existing shareholders
        uint256 aliceClaimAfter = s.vault.convertToAssets(aliceShares);
        uint256 aliceBurden = aliceClaimBefore - aliceClaimAfter;
        uint256 expectedAliceBurden = (25_000_000 * aliceShares) / supplyBefore;
        assertApproxEqAbs(
            aliceBurden,
            expectedAliceBurden,
            2,
            "alice must bear her pro-rata share of the 25% fee"
        );

        // conservation: every share class's claim sums back to totalAssets
        uint256 deadShares = s.vault.balanceOf(address(s.vault));
        uint256 sum = aliceClaimAfter +
            treasuryClaim +
            s.vault.convertToAssets(deadShares);
        assertApproxEqAbs(sum, 1_101_000_000, 4, "claims must sum to totalAssets");
    }

    /// @dev The 0.25e18 cap is not merely accepted — it actually charges more than the
    ///      0.2e18 cap it replaces, on identical inputs.
    function testAccrualAtNewCapExceedsOldCapOnIdenticalInputs() public {
        Stack memory at25 = _newStack(0, uint96(MAX_PERFORMANCE_FEE));
        Stack memory at20 = _newStack(0, uint96(OLD_MAX_PERFORMANCE_FEE));

        for (uint256 i; i < 2; i++) {
            Stack memory st = i == 0 ? at25 : at20;
            _deposit(st, alice, 1_000 * ONE);
            _simulateYield(st, 100 * ONE);
            st.vault.applyFees();
        }

        uint256 feeAssets25 = (100 * ONE) / 4; // 25_000_000
        uint256 feeAssets20 = (100 * ONE) / 5; // 20_000_000

        uint256 claim25 = at25.vault.convertToAssets(at25.vault.balanceOf(treasury));
        uint256 claim20 = at20.vault.convertToAssets(at20.vault.balanceOf(treasury));

        assertEq(feeAssets25, 25_000_000);
        assertEq(feeAssets20, 20_000_000);
        assertApproxEqAbs(claim25, feeAssets25, 2, "25% leg");
        assertApproxEqAbs(claim20, feeAssets20, 2, "20% leg");
        assertGt(claim25, claim20, "the raised cap must charge strictly more");
        assertApproxEqAbs(claim25 - claim20, 5_000_000, 4, "delta is the extra 5%");

        assertGt(
            at25.vault.balanceOf(treasury),
            at20.vault.balanceOf(treasury),
            "more fee shares at 25%"
        );
    }

    /*//////////////////////////////////////////////////////////////
                   5. ACCRUAL AT 25% — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @param yield_ Assets credited to the provider between two fee applications.
    /// @param deposit_ Third-party deposit that sets the pre-yield share supply.
    function testFuzzPerformanceFeeAccrualAtCap(
        uint256 yield_,
        uint256 deposit_
    ) public {
        // Lower bound keeps the fee shares far above the floor-rounding noise the
        // dedicated small-yield test below pins; upper bound stays realistic for a
        // USDC vault and keeps mulDiv far from overflow.
        yield_ = bound(yield_, 1_000 * ONE, 10_000_000 * ONE);
        deposit_ = bound(deposit_, 10 * ONE, 10_000_000 * ONE);

        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));
        _deposit(s, alice, deposit_);

        uint256 supplyBefore = s.vault.totalSupply();
        _simulateYield(s, yield_);
        uint256 totalAssetsAfter = s.vault.totalAssets();
        assertEq(
            totalAssetsAfter,
            supplyBefore + yield_,
            "fixture: 1:1 price, so assets == supply + yield"
        );

        // floor(yield * 0.25e18 / 1e18) == yield / 4 exactly, for every yield
        uint256 feeAssets = yield_ / 4;
        assertEq(feeAssets, (yield_ * MAX_PERFORMANCE_FEE) / SCALE, "25% == /4");

        (uint256 expectedFeeAssets, uint256 expectedShares) = _expectedPerformanceFeeShares(
            yield_,
            MAX_PERFORMANCE_FEE,
            supplyBefore,
            totalAssetsAfter
        );
        assertEq(expectedFeeAssets, feeAssets);

        (uint256 previewPerf, ) = s.vault.getAccruedFees();
        assertEq(previewPerf, expectedShares, "getAccruedFees must match the formula");

        s.vault.applyFees();

        uint256 treasuryShares = s.vault.balanceOf(treasury);
        assertEq(treasuryShares, expectedShares, "minted fee shares");
        assertEq(
            s.vault.totalSupply(),
            supplyBefore + expectedShares,
            "supply grows by the fee shares only"
        );
        assertEq(
            s.vault.totalAssets(),
            totalAssetsAfter,
            "fee application must not move assets"
        );
        assertEq(
            s.vault.getLastTotalAssets(),
            totalAssetsAfter,
            "baseline ratchets to post-yield assets"
        );

        // the treasury's redeemable value never exceeds its 25% entitlement and
        // never loses more than floor-rounding to it
        uint256 treasuryClaim = s.vault.convertToAssets(treasuryShares);
        assertLe(treasuryClaim, feeAssets, "must not over-charge");
        assertApproxEqRel(treasuryClaim, feeAssets, 1e15, "0.1% of the entitlement");
    }

    /// @dev For a 6-decimal asset `yield * 0.25e18 / 1e18 == yield / 4`, so a yield of
    ///      1..3 units floors to a zero fee. Unchanged by the cap raise (at 20% the
    ///      threshold was 5 units); pinned so the reviewer can see the rounding edge
    ///      moved in the protocol's favour, not against it.
    function testPerformanceFeeAtCapFloorsToZeroBelowFourUnits() public {
        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));
        _deposit(s, alice, 1_000 * ONE);

        _simulateYield(s, 3);
        assertEq(s.vault.totalAssets(), 1_001_000_003, "3 units of yield visible");

        (uint256 previewPerf, uint256 previewMgmt) = s.vault.getAccruedFees();
        assertEq(previewPerf, 0, "yield of 3 floors to a zero 25% fee");
        assertEq(previewMgmt, 0);

        s.vault.applyFees();
        assertEq(s.vault.balanceOf(treasury), 0, "nothing minted");
        assertEq(
            s.vault.getLastTotalAssets(),
            1_001_000_003,
            "baseline still ratchets, so the dust is not re-charged later"
        );
    }

    /// @dev Rolling-baseline semantics: `_applyFees` resets `_lastTotalAssets` to the
    ///      post-loss figure, so a recovery back to the old peak is charged again.
    ///      Pinned here because it is the behaviour the 25% cap now amplifies.
    function testPerformanceFeeAtCapUsesRollingBaselineNotHighWaterMark() public {
        s.vault.setPerformanceFee(uint96(MAX_PERFORMANCE_FEE));
        _deposit(s, alice, 1_000 * ONE);

        // +100 yield, fee taken
        _simulateYield(s, 100 * ONE);
        s.vault.applyFees();
        uint256 firstFee = s.vault.balanceOf(treasury);
        assertEq(firstFee, 23_257_434, "first accrual");

        uint256 peakAssets = s.vault.totalAssets();

        // -100 loss. `FeeCapSource` has no loss hook, so model it by withdrawing the
        // assets back out of the source through the vault's own accounting: read the
        // baseline before and after an explicit `applyFees`, which ratchets it down.
        s.source.debitAndSend(address(s.vault), 100 * ONE, address(this));
        assertEq(s.vault.totalAssets(), peakAssets - 100 * ONE, "loss visible");

        s.vault.applyFees();
        assertEq(
            s.vault.getLastTotalAssets(),
            peakAssets - 100 * ONE,
            "baseline ratchets DOWN on a loss - not a high-water mark"
        );
        assertEq(
            s.vault.balanceOf(treasury),
            firstFee,
            "no fee is charged on the loss itself"
        );

        // +100 recovery back to the previous peak: charged again at 25%.
        _simulateYield(s, 100 * ONE);
        s.vault.applyFees();
        assertGt(
            s.vault.balanceOf(treasury),
            firstFee,
            "recovery to the same peak is fee'd a second time"
        );
    }
}
