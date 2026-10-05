// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20PermitUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessManager} from "./access/AccessManager.sol";
import {PausableActions} from "./utils/PausableActions.sol";
import {IPausableActions} from "./interfaces/IPausableActions.sol";
import {IProvider} from "./interfaces/IProvider.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IRebalancer} from "./interfaces/IRebalancer.sol";
import "./libraries/Constants.sol";

/**
 * @title Rebalancer
 */
contract Rebalancer is
    ERC20PermitUpgradeable,
    AccessManager,
    PausableActions,
    ReentrancyGuardUpgradeable,
    IRebalancer
{
    using Math for uint256;
    using Address for address;
    using SafeCast for uint256;
    using SafeERC20 for IERC20Metadata;

    /// @custom:storage-location erc7201:thesauros.storage.Rebalancer
    struct RebalancerStorage {
        // core
        IERC20Metadata _asset;
        uint8 _underlyingDecimals;
        // providers
        IProvider[] _providers;
        IProvider _entryProvider;
        // access
        address _timelock;
        // fees
        address _treasury;
        uint96 _managementFee;
        uint96 _performanceFee;
        // accounting
        uint256 _lastTotalAssets;
        uint64 _lastTimestamp;
        // operational
        uint256 _minAssets;
        // fees (added by initializeV2 — appended at the end so existing field offsets
        // under this ERC-7201 namespaced struct are preserved for already-deployed proxies)
        uint256 _highWaterMark;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.Rebalancer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RebalancerStorageLocation =
        0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;

    /**
     * @dev Gas stipend forwarded to `IProvider.getDepositBalance()` when called through
     *      `_safeGetDepositBalance`, so a single broken/malicious provider cannot consume
     *      unbounded gas or otherwise DoS `totalAssets()`/`_withdraw()`/`rebalance()` for
     *      every other (healthy) provider in the list.
     *
     *      Sized from real measurements: `forge test --gas-report` against a Base-mainnet
     *      fork (2026-08-13) across all integrated provider types shows
     *      `AaveV3Provider.getDepositBalance` maxing at ~56,864 gas,
     *      `CompoundV3Provider.getDepositBalance` at ~32,937 gas, and
     *      `MorphoProvider.getDepositBalance` — which is NOT O(1); it loops over the
     *      MetaMorpho withdraw queue via `_totalRealAssets()` — at up to ~1,109,765 gas
     *      (the Steakhouse High Yield vault, the longest withdraw queue among the three
     *      Morpho vaults profiled). This constant is set to ~2.7x that observed worst case,
     *      leaving headroom for withdraw queues to grow before this becomes a limiting
     *      factor again.
     */
    uint256 internal constant PROVIDER_VIEW_CALL_GAS = 3_000_000;

    function _getRebalancerStorage()
        private
        pure
        returns (RebalancerStorage storage $)
    {
        assembly {
            $.slot := RebalancerStorageLocation
        }
    }

    /**
     * @dev Reverts if called by any account other than the timelock contract.
     */
    modifier onlyTimelock() {
        _onlyTimelock();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /**
     * @dev Initializes the Rebalancer contract with the specified parameters.
     */
    function initialize(
        address admin_,
        address timelock_,
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        address treasury_,
        uint96 managementFee_,
        uint96 performanceFee_,
        uint256 minAssets_
    ) external initializer {
        if (admin_ == address(0)) {
            revert AddressZero();
        }
        if (asset_ == address(0)) {
            revert AddressZero();
        }
        if (minAssets_ == 0) {
            revert InvalidInput();
        }

        __AccessManager_init(admin_);
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ReentrancyGuard_init();

        RebalancerStorage storage $ = _getRebalancerStorage();
        $._asset = IERC20Metadata(asset_);
        $._underlyingDecimals = IERC20Metadata(asset_).decimals();

        _setProviders(providers_);
        _setEntryProvider(providers_[0]);
        _setTimelock(timelock_);
        _setTreasury(treasury_);
        _setManagementFee(managementFee_);
        _setPerformanceFee(performanceFee_);
        _setMinAssets(minAssets_);

        $._lastTimestamp = block.timestamp.toUint64();
        // a freshly-initialized vault's share price is exactly 1:1 (SCALE); starting the
        // high-water mark here (rather than leaving it at the storage default of 0) means
        // new deployments never depend on `initializeV2()` also being called before the
        // first real `applyFees()` — see Finding 6.
        $._highWaterMark = SCALE;

        // requires a non-trivial initial deposit to mitigate inflation attacks.
        // the appropriate amount depends on the underlying asset’s decimals.
        _deposit(_msgSender(), address(this), minAssets_, minAssets_);
    }

    /**
     * @notice Migration entrypoint for vaults deployed under the pre-Finding-3/6
     *         implementation. Bundles the two upgrades that must land together:
     *         (1) initializing `ReentrancyGuardUpgradeable`'s own storage, and
     *         (2) bootstrapping the performance-fee high-water mark.
     *
     * @dev Ordering is deliberate and load-bearing: this function sets `$._highWaterMark`
     *      directly from the vault's CURRENT share price and never calls
     *      `_applyFees()`/`applyFees()`. If the mark were left at its pre-migration default
     *      (0), or if fees were applied before the mark is set, the very next real fee
     *      accrual would treat the vault's entire pre-upgrade NAV as brand-new profit and
     *      mint a one-time windfall performance fee to treasury. This function is intended
     *      to be invoked atomically with the implementation upgrade itself (e.g. via
     *      `ProxyAdmin.upgradeAndCall`), so no intervening call to `applyFees()` (or
     *      `deposit`/`mint`/`withdraw`/`redeem`, which all call it first) can observe the
     *      vault between "upgraded" and "migrated". Wiring this into an actual upgrade
     *      transaction against a live proxy is a separate operational step for a human to
     *      review and execute — this function only contains the migration logic itself.
     */
    function initializeV2() external reinitializer(2) {
        __ReentrancyGuard_init();

        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 supply = totalSupply();
        $._highWaterMark = supply == 0
            ? SCALE
            : totalAssets().mulDiv(SCALE, supply, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC4626
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the number of decimals used to get number representation.
     */
    function decimals() public view override(ERC20Upgradeable) returns (uint8) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._underlyingDecimals;
    }

    /**
     * @inheritdoc IERC4626
     */
    function asset() public view override returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return address($._asset);
    }

    /**
     * @inheritdoc IERC4626
     */
    function totalAssets() public view override returns (uint256) {
        return _totalAssetsAtProviders();
    }

    /**
     * @inheritdoc IERC4626
     */
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        uint256 totalManagedAssets = _applyFees();

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            totalManagedAssets,
            Math.Rounding.Floor
        );
        _validateDeposit(receiver, assets, shares);

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        uint256 totalManagedAssets = _applyFees();

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            totalManagedAssets,
            Math.Rounding.Ceil
        );
        _validateDeposit(receiver, assets, shares);

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        uint256 totalManagedAssets = _applyFees();

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            totalManagedAssets,
            Math.Rounding.Ceil
        );
        _validateWithdraw(assets, shares, _msgSender(), receiver, owner);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        uint256 totalManagedAssets = _applyFees();

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            totalManagedAssets,
            Math.Rounding.Floor
        );
        _validateWithdraw(assets, shares, _msgSender(), receiver, owner);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @dev Converts assets to shares equivalent, with support for rounding direction.
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view returns (uint256 shares) {
        uint256 totalManagedAssets = totalAssets();
        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _accruedFees(totalManagedAssets);

        return
            _convertToSharesWithTotals(
                assets,
                totalSupply() + performanceFeeShares + managementFeeShares,
                totalManagedAssets,
                rounding
            );
    }

    /// @dev Converts shares to assets equivalent, with support for rounding direction.
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (uint256 assets) {
        uint256 totalManagedAssets = totalAssets();
        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _accruedFees(totalManagedAssets);

        return
            _convertToAssetsWithTotals(
                shares,
                totalSupply() + performanceFeeShares + managementFeeShares,
                totalManagedAssets,
                rounding
            );
    }

    /// @dev Converts assets to shares equivalent using provided total supply and total assets, with support for rounding direction.
    /// @dev Will revert if assets > 0, totalSupply > 0 and totalAssets = 0. That corresponds to a case where any asset would represent an infinite amount of shares.
    function _convertToSharesWithTotals(
        uint256 assets,
        uint256 totalSupply,
        uint256 totalManagedAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256 shares) {
        return
            (assets == 0 || totalSupply == 0)
                ? assets
                : assets.mulDiv(totalSupply, totalManagedAssets, rounding);
    }

    /// @dev Converts shares to assets equivalent using provided total supply and total assets, with support for rounding direction.
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 totalSupply,
        uint256 totalManagedAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256 assets) {
        return
            (totalSupply == 0)
                ? shares
                : shares.mulDiv(totalManagedAssets, totalSupply, rounding);
    }

    /**
     * @dev Executes a deposit at the active provider.
     * @param caller The address that initiated the deposit.
     * @param receiver The address to which shares are minted.
     * @param assets The amount transferred during this deposit.
     * @param shares The amount minted to receiver.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        IProvider entryProvider = $._entryProvider;

        // Cheap defense-in-depth (Finding 5): `_setProviders` already rejects a new
        // provider list that would drop the current entry provider, but re-validating
        // membership here as well means a future code path that mutates `$._providers` or
        // `$._entryProvider` inconsistently can never silently route new deposits to a
        // delisted provider.
        if (!_validateProvider(address(entryProvider))) {
            revert InvalidProvider();
        }

        $._asset.safeTransferFrom(caller, address(this), assets);
        _delegateActionToProvider(assets, "deposit", entryProvider);
        _mint(receiver, shares);
        $._lastTotalAssets += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Executes a withdraw at the active provider.
     * @param caller The address that initiated the withdrawal.
     * @param receiver The address to which the assets will be transferred.
     * @param owner The address whose shares will be burned during this withdrawal.
     * @param assets The amount of assets being withdrawn from the vault.
     * @param shares The amount of shares being burned during this withdrawal.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal {
        _burn(owner, shares);

        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 assetsLeft = assets;
        uint256 count = $._providers.length;
        for (uint256 i; i < count && assetsLeft > 0; i++) {
            IProvider provider = $._providers[i];
            (uint256 assetsAtProvider, bool ok) = _safeGetDepositBalance(
                provider
            );

            // a provider whose view call fails is skipped exactly like one reporting a
            // zero balance — its funds (if any) are simply not counted as available for
            // this withdrawal, instead of reverting the whole loop for every provider.
            if (!ok || assetsAtProvider == 0) continue;

            uint256 amount = (assetsAtProvider >= assetsLeft)
                ? assetsLeft
                : assetsAtProvider;

            // continue to next provider instead of reverting the entire tx.
            uint256 balBefore = $._asset.balanceOf(address(this));
            (bool success, ) = address(provider).delegatecall(
                abi.encodeWithSignature(
                    "withdraw(uint256,address)",
                    amount,
                    address(this)
                )
            );
            if (success) {
                uint256 received = $._asset.balanceOf(address(this)) - balBefore;
                assetsLeft -= received;
            }
        }

        if (assetsLeft > 0) revert InsufficientLiquidity();

        $._lastTotalAssets -= assets;
        $._asset.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Runs checks for all deposit or mint actions in this vault.
     * @param receiver The address receiving the deposit.
     * @param assets The amount of assets being deposited.
     * @param shares The amount of shares being minted for the receiver.
     */
    function _validateDeposit(
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal view whenNotPaused(Actions.Deposit) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        if (receiver == address(0)) {
            revert AddressZero();
        }
        if (assets == 0 || shares == 0) {
            revert InvalidInput();
        }
        if (assets < $._minAssets) {
            revert AssetsBelowMin();
        }
    }

    /**
     * @dev Runs checks for all withdraw or redeem actions in this vault.
     * @param assets The amount of assets being withdrawn.
     * @param shares The amount of shares being burned during this withdrawal.
     * @param caller The address that initiated the withdrawal.
     * @param receiver The address to which the assets will be transferred.
     * @param owner The address whose shares will be burned.
     */
    function _validateWithdraw(
        uint256 assets,
        uint256 shares,
        address caller,
        address receiver,
        address owner
    ) internal whenNotPaused(Actions.Withdraw) {
        if (receiver == address(0) || owner == address(0)) {
            revert AddressZero();
        }
        if (assets == 0 || shares == 0) {
            revert InvalidInput();
        }
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              REBALANCING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebalancer
    function rebalance(
        uint256[] memory amounts,
        IProvider[] memory sources,
        IProvider[] memory destinations
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (bool) {
        uint256 count = amounts.length;
        if (count == 0) {
            revert InvalidCount();
        }
        if (count != sources.length || count != destinations.length) {
            revert ArrayMismatch();
        }

        for (uint256 i; i < count; i++) {
            uint256 assets = amounts[i];
            IProvider from = sources[i];
            IProvider to = destinations[i];

            if (
                !_validateProvider(address(from)) ||
                !_validateProvider(address(to))
            ) {
                revert InvalidProvider();
            }

            (uint256 assetsAtFrom, bool ok) = _safeGetDepositBalance(from);
            if (!ok) revert InvalidProvider();

            if (assets == type(uint256).max) {
                assets = assetsAtFrom;
            }
            if (assets == 0 || assets > assetsAtFrom) {
                revert InvalidInput();
            }

            _delegateActionToProvider(assets, "withdraw", from);
            _delegateActionToProvider(assets, "deposit", to);

            emit RebalanceExecuted(assets, address(from), address(to));
        }

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints accrued fee shares and updates fee snapshots.
    function applyFees() external {
        _applyFees();
    }

    /// @dev Internal function for fee application.
    function _applyFees() internal returns (uint256 totalManagedAssets) {
        totalManagedAssets = totalAssets();

        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _accruedFees(totalManagedAssets);

        RebalancerStorage storage $ = _getRebalancerStorage();

        emit FeesApplied(
            $._lastTotalAssets,
            totalManagedAssets,
            performanceFeeShares,
            managementFeeShares
        );

        $._lastTotalAssets = totalManagedAssets;

        // Ratchet the high-water mark using the share price BEFORE any fee shares are
        // minted below (i.e. from totalManagedAssets and the pre-mint totalSupply()).
        // Minting new shares to treasury dilutes totalAssets()/totalSupply() without
        // moving any assets out of the vault, so computing the price after minting would
        // record an artificially-lowered mark and let the next recovery back up to the
        // PRE-mint price be taxed again as if it were fresh profit. The mark only ever
        // moves up (see Finding 6 / `_accruedFees`).
        uint256 supplyBeforeMint = totalSupply();
        if (supplyBeforeMint > 0) {
            uint256 sharePrice = totalManagedAssets.mulDiv(
                SCALE,
                supplyBeforeMint,
                Math.Rounding.Floor
            );
            if (sharePrice > $._highWaterMark) {
                $._highWaterMark = sharePrice;
            }
        }

        address treasury = $._treasury;
        if (performanceFeeShares != 0) {
            _mint(treasury, performanceFeeShares);
        }
        if (managementFeeShares != 0) {
            _mint(treasury, managementFeeShares);
        }

        $._lastTimestamp = block.timestamp.toUint64();
    }

    /// @dev Computes accrued fee shares.
    /// @dev The management fee is not tied to yield (profits or losses) and may reduce share price.
    /// @dev The performance fee is charged only on the excess of the CURRENT share price over
    ///      the all-time high-water mark (`$._highWaterMark`), not merely on growth since the
    ///      last snapshot — this is what prevents charging a performance fee twice on the same
    ///      value when the vault takes a loss and later merely recovers back toward (not above)
    ///      its previous peak (see Finding 6).
    /// @dev Both fees are rounded down, so treasury could receive less than expected.
    /// @dev `managementFeeAssets` and `performanceFeeAssets` are clamped SEQUENTIALLY against
    ///      `totalManagedAssets` (management first, then performance against whatever remains)
    ///      rather than independently, so their sum can never exceed `totalManagedAssets` and
    ///      underflow the subtraction below — this is what actually closes the pathological
    ///      ~20-year-`dt` revert-lock at the maximum management fee rate (see Finding 7).
    ///      Clamping each independently against the full `totalManagedAssets` would not be
    ///      sufficient: their sum could still exceed it.
    function _accruedFees(
        uint256 totalManagedAssets
    )
        internal
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();

        uint96 managementFee = $._managementFee;
        uint96 performanceFee = $._performanceFee;

        uint256 dt = block.timestamp - $._lastTimestamp;
        uint256 supply = totalSupply();

        uint256 performanceFeeAssets;
        if (performanceFee > 0 && supply > 0) {
            uint256 sharePrice = totalManagedAssets.mulDiv(
                SCALE,
                supply,
                Math.Rounding.Floor
            );
            uint256 highWaterMark = $._highWaterMark;
            if (sharePrice > highWaterMark) {
                // profit per share, converted back to an asset amount over the full supply
                uint256 profitAssets = (sharePrice - highWaterMark).mulDiv(
                    supply,
                    SCALE,
                    Math.Rounding.Floor
                );
                // may be rounded down to 0 if profitAssets * fee < SCALE.
                performanceFeeAssets = profitAssets.mulDiv(
                    performanceFee,
                    SCALE,
                    Math.Rounding.Floor
                );
            }
        }

        uint256 managementFeeAssets = dt > 0 && managementFee > 0
            ? (totalManagedAssets * dt).mulDiv(
                managementFee,
                365 days * SCALE,
                Math.Rounding.Floor
            )
            : 0;

        // Sequential clamp (Finding 7): management fee is capped against the full pool
        // first, then performance fee is capped against whatever remains. Clamping each
        // independently against totalManagedAssets would still let managementFeeAssets +
        // performanceFeeAssets exceed totalManagedAssets and underflow the subtraction
        // below under pathological (e.g. ~20+ year) `dt` values at the maximum fee rate.
        managementFeeAssets = managementFeeAssets > totalManagedAssets
            ? totalManagedAssets
            : managementFeeAssets;
        performanceFeeAssets = performanceFeeAssets >
            totalManagedAssets - managementFeeAssets
            ? totalManagedAssets - managementFeeAssets
            : performanceFeeAssets;

        // assumes the vault should be interacted with periodically; fees must remain < total assets
        uint256 totalAssetsWithoutFees = totalManagedAssets -
            managementFeeAssets -
            performanceFeeAssets;

        // totalAssetsWithoutFees can only be 0 in the pathological all-fees-consumed-the-pool
        // edge case above; Math.mulDiv reverts on a zero denominator, so both fee-share
        // conversions are skipped (0 shares minted this period) rather than reverting.
        if (totalAssetsWithoutFees > 0) {
            performanceFeeShares = performanceFeeAssets.mulDiv(
                supply,
                totalAssetsWithoutFees,
                Math.Rounding.Floor
            );
            managementFeeShares = managementFeeAssets.mulDiv(
                supply,
                totalAssetsWithoutFees,
                Math.Rounding.Floor
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN & TIMELOCK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPausableActions
    function pause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _pause(action);
    }

    /// @inheritdoc IPausableActions
    function unpause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _unpause(action);
    }

    /**
     * @notice Sets the list of providers for this vault.
     * @param providers An array of provider contracts.
     */
    function setProviders(IProvider[] memory providers) external onlyTimelock {
        _setProviders(providers);
    }

    /**
     * @notice Sets the active provider for this vault.
     * @param entryProvider The contract of the new entry provider.
     *
     */
    function setEntryProvider(
        IProvider entryProvider
    ) external onlyRole(ADMIN_ROLE) {
        _setEntryProvider(entryProvider);
    }

    /**
     * @notice Sets the address of the timelock contract.
     * @param timelock The address of the new timelock contract.
     */
    function setTimelock(address timelock) external onlyTimelock {
        _setTimelock(timelock);
    }

    /**
     * @notice Sets the treasury address for this vault.
     * @param treasury The new treasury address.
     */
    function setTreasury(address treasury) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setTreasury(treasury);
    }

    /**
     * @notice Sets the management fee percentage for this vault.
     * @param managementFee The new management fee percentage.
     */
    function setManagementFee(
        uint96 managementFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setManagementFee(managementFee);
    }

    /**
     * @notice Sets the performance fee percentage for this vault.
     * @param performanceFee The new performance fee percentage.
     */
    function setPerformanceFee(
        uint96 performanceFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setPerformanceFee(performanceFee);
    }

    /**
     * @notice Sets the minimum amount required for deposit and mint actions.
     * @param minAssets The new minimum amount.
     */
    function setMinAssets(uint256 minAssets) external onlyRole(ADMIN_ROLE) {
        _setMinAssets(minAssets);
    }

    /**
     * @dev Internal function to set the providers for this vault.
     * @param providers An array of provider contracts.
     * @dev Finding 5: reverts if `providers` would drop the CURRENT `$._entryProvider`,
     *      which would otherwise silently misprice the vault (new deposits keep flowing to
     *      a provider that is no longer tracked by `totalAssets()`/`_withdraw()`) and make
     *      those new deposits unwithdrawable through the normal `_withdraw()` loop (which
     *      only ever iterates `$._providers`). This check is skipped while
     *      `$._entryProvider` is still `address(0)` — i.e. during `initialize()`'s very
     *      first call to `_setProviders`, before `_setEntryProvider` has ever run — so
     *      bootstrapping a brand-new vault is unaffected.
     * @dev Finding 4: revokes this vault's approval for any provider that is leaving the
     *      list (diffing old vs. new), so a removed provider's `source` address never keeps
     *      a stale unlimited allowance. Each revocation is isolated in its own try/catch
     *      (via `_revokeStaleApproval`) so a broken removed provider's own revert (e.g. in
     *      `getSource`) cannot block its removal from the list; a failure only emits
     *      `StaleApprovalRevokeFailed` for that provider instead.
     */
    function _setProviders(IProvider[] memory providers) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();

        address currentEntryProvider = address($._entryProvider);
        if (
            currentEntryProvider != address(0) &&
            !_isProviderInList(currentEntryProvider, providers)
        ) {
            revert EntryProviderNotInProviders();
        }

        IProvider[] memory oldProviders = $._providers;

        for (uint256 i; i < providers.length; i++) {
            if (address(providers[i]) == address(0)) {
                revert AddressZero();
            }
            $._asset.forceApprove(
                providers[i].getSource(asset(), address(this), address(0)),
                type(uint256).max
            );
        }

        for (uint256 i; i < oldProviders.length; i++) {
            address oldProviderAddr = address(oldProviders[i]);
            if (_isProviderInList(oldProviderAddr, providers)) continue;

            try this._revokeStaleApproval(oldProviders[i]) {} catch {
                emit StaleApprovalRevokeFailed(oldProviderAddr);
            }
        }

        $._providers = providers;

        emit ProvidersUpdated(providers);
    }

    /**
     * @dev Revokes this vault's approval for a provider that `_setProviders` is removing
     *      from the list. Declared `external` (rather than `internal`/`private`) solely so
     *      that `_setProviders` can wrap the call in `try/catch` — Solidity only allows
     *      try/catch around external calls / contract creation, and a broken removed
     *      provider's `getSource()` (or the token's `approve`) reverting here must not
     *      block the provider's removal. Restricted to self-calls: it must never be usable
     *      by a third party to grief an ACTIVE provider's approval down to 0.
     */
    function _revokeStaleApproval(IProvider provider) external {
        if (_msgSender() != address(this)) {
            revert Unauthorized();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        address source = provider.getSource(asset(), address(this), address(0));
        $._asset.forceApprove(source, 0);
    }

    /// @dev Returns true if `provider` is present in the given in-memory `list`.
    function _isProviderInList(
        address provider,
        IProvider[] memory list
    ) private pure returns (bool found) {
        uint256 count = list.length;
        for (uint256 i; i < count; i++) {
            if (address(list[i]) == provider) {
                return true;
            }
        }
    }

    /**
     * @dev Internal function to set the active provider for this vault.
     * @param entryProvider The contract of the new active provider.
     */
    function _setEntryProvider(IProvider entryProvider) internal {
        if (!_validateProvider(address(entryProvider))) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._entryProvider = entryProvider;
        emit EntryProviderUpdated(entryProvider);
    }

    /**
     * @dev Internal function to update the address of the timelock contract.
     * @param timelock The address of the new timelock contract.
     */
    function _setTimelock(address timelock) internal {
        if (timelock == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._timelock = timelock;
        emit TimelockUpdated(timelock);
    }

    /**
     * @dev Internal function to set the treasury address for this vault.
     * @param treasury The new treasury address.
     */
    function _setTreasury(address treasury) internal {
        if (treasury == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._treasury = treasury;
        emit TreasuryUpdated(treasury);
    }

    /**
     * @dev Internal function to set the management fee percentage for this vault.
     * @param managementFee The new management fee percentage.
     */
    function _setManagementFee(uint96 managementFee) internal {
        if (managementFee > MAX_MANAGEMENT_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._managementFee = managementFee;
        emit ManagementFeeUpdated(managementFee);
    }

    /**
     * @dev Internal function to set the performance fee percentage for this vault.
     * @param performanceFee The new performance fee percentage.
     */
    function _setPerformanceFee(uint96 performanceFee) internal {
        if (performanceFee > MAX_PERFORMANCE_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._performanceFee = performanceFee;
        emit PerformanceFeeUpdated(performanceFee);
    }

    /**
     * @dev Internal function to set the minimum amount required for deposit and mint actions.
     * @param minAssets The new minimum amount.
     */
    function _setMinAssets(uint256 minAssets) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._minAssets = minAssets;
        emit MinAssetsUpdated(minAssets);
    }

    /// @dev Reverts if the caller is not the timelock.
    function _onlyTimelock() internal view {
        RebalancerStorage storage $ = _getRebalancerStorage();
        if (_msgSender() != $._timelock) {
            revert Unauthorized();
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PROVIDER INTERNALS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Delegates an action to a provider.
     * @param assets The amount of assets involved in the action.
     * @param actionName The identifier of the method to call.
     * @param provider The provider contract to which the action is delegated.
     */
    function _delegateActionToProvider(
        uint256 assets,
        string memory actionName,
        IProvider provider
    ) internal {
        bytes memory data = abi.encodeWithSignature(
            string(abi.encodePacked(actionName, "(uint256,address)")),
            assets,
            address(this)
        );
        address(provider).functionDelegateCall(data);
    }

    /**
     * @dev Returns the total assets of this vault across all listed providers.
     * @dev A provider whose `getDepositBalance` view call fails (reverts or runs out of
     *      the bounded gas stipend) contributes 0 to the total instead of reverting this
     *      whole aggregation for every other, healthy provider.
     */
    function _totalAssetsAtProviders() internal view returns (uint256 total) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 count = $._providers.length;
        for (uint256 i; i < count; i++) {
            (uint256 assetsAtProvider, bool ok) = _safeGetDepositBalance(
                $._providers[i]
            );
            if (ok) {
                total += assetsAtProvider;
            }
        }
    }

    /**
     * @dev Calls `IProvider.getDepositBalance` under a bounded gas stipend
     *      (`PROVIDER_VIEW_CALL_GAS`) and never reverts: a broken or adversarial provider
     *      can only ever cause its own contribution to be treated as unknown/zero, never
     *      block visibility into, or withdrawals from, every other provider.
     * @dev `IProvider.getDepositBalance` is declared `external view`, so every call site is
     *      already a `STATICCALL` under the hood — `try/catch` on the interface call below
     *      is sufficient; no separate low-level-call wrapper is needed.
     * @param provider The provider to query.
     * @return balance The provider's reported deposit balance, or 0 if the call failed.
     * @return ok True if the call succeeded, false if it reverted or ran out of gas.
     */
    function _safeGetDepositBalance(
        IProvider provider
    ) internal view returns (uint256 balance, bool ok) {
        try
            provider.getDepositBalance{gas: PROVIDER_VIEW_CALL_GAS}(
                address(this),
                this
            )
        returns (uint256 bal) {
            return (bal, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @dev Returns true if the specified provider is in the list of providers.
     * @param provider The address of the provider to validate.
     */
    function _validateProvider(
        address provider
    ) internal view returns (bool valid) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 count = $._providers.length;
        for (uint256 i; i < count; i++) {
            if (provider == address($._providers[i])) {
                valid = true;
                break;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns, for every listed provider, its address, its currently reported
    /// deposit balance, and whether that provider's `getDepositBalance` view call
    /// succeeded. A `false` entry in `oks` means that provider's contribution to
    /// `totalAssets()`/withdrawals is currently being treated as 0 (see
    /// `_safeGetDepositBalance`), which off-chain monitoring can use as a signal of a
    /// degraded provider — `totalAssets()`/`_withdraw()` themselves are `view`/internal and
    /// cannot emit an event to surface this on their own.
    function getProviderBalances()
        public
        view
        returns (
            address[] memory providers,
            uint256[] memory balances,
            bool[] memory oks
        )
    {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 count = $._providers.length;
        providers = new address[](count);
        balances = new uint256[](count);
        oks = new bool[](count);
        for (uint256 i; i < count; i++) {
            IProvider provider = $._providers[i];
            providers[i] = address(provider);
            (balances[i], oks[i]) = _safeGetDepositBalance(provider);
        }
    }

    /// @notice Returns accrued fee shares
    function getAccruedFees() public view returns (uint256, uint256) {
        uint256 totalManagedAssets = totalAssets();
        return _accruedFees(totalManagedAssets);
    }

    /// @notice Returns the list of providers used by the vault.
    function getProviders() public view returns (IProvider[] memory) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._providers;
    }

    /// @notice Returns the entry provider
    function getEntryProvider() public view returns (IProvider) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._entryProvider;
    }

    /// @notice Returns the timelock address
    function getTimelock() public view returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._timelock;
    }

    /// @notice Returns the treasury address
    function getTreasury() public view returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._treasury;
    }

    /// @notice Returns the management fee rate (scaled)
    function getManagementFee() public view returns (uint96) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._managementFee;
    }

    /// @notice Returns the performance fee rate (scaled)
    function getPerformanceFee() public view returns (uint96) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._performanceFee;
    }

    /// @notice Returns the last recorded total managed assets
    function getLastTotalAssets() public view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._lastTotalAssets;
    }

    /// @notice Returns the last recorded timestamp
    function getLastTimestamp() public view returns (uint64) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._lastTimestamp;
    }

    /// @notice Returns the minimum asset amount for deposit and mint actions
    function getMinAssets() public view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._minAssets;
    }

    /// @notice Returns the all-time performance-fee high-water mark (share price, scaled
    /// by `SCALE`). Only ever ratchets upward, in `_applyFees()` — see Finding 6.
    function getHighWaterMark() public view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._highWaterMark;
    }
}
