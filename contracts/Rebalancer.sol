// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20PermitUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessManager} from "./access/AccessManager.sol";
import {PausableActions} from "./utils/PausableActions.sol";
import {IPausableActions} from "./interfaces/IPausableActions.sol";
import {IProvider} from "./interfaces/IProvider.sol";
import {IRebalancer} from "./interfaces/IRebalancer.sol";
import "./libraries/Constants.sol";

/// @title Rebalancer
/// @notice ERC-4626 and ERC-2612 compliant vault that allocates assets across external providers and supports rebalancing.
///
/// @dev The vault does not hold idle underlying; deposits are forwarded to the entry provider.
/// @dev maxDeposit, maxMint, maxWithdraw, and maxRedeem always return zero.
/// @dev totalSupply does not include accrued fee shares until fees are applied.
/// @dev Initialization includes an initial deposit that is locked and treated as normal liquidity.
///
/// @dev Deposits and mints require a minimum asset amount.
///
/// @dev Fees are charged by minting shares to the treasury.
/// @dev Fees accrue over time and are applied on vault interactions; periodic interaction is required.
/// @dev The performance fee is yield-based; the management fee is time-based and may reduce share price.
/// @dev Fee rates are expressed in WAD.
///
/// @dev Providers are timelock-controlled; other vault configs are admin-controlled.
///
/// @dev The vault relies on external providers remaining operational.
contract Rebalancer is
    ERC20PermitUpgradeable,
    AccessManager,
    PausableActions,
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
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.Rebalancer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RebalancerStorageLocation =
        0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;

    /// @dev Returns the ERC-7201 namespaced storage pointer.
    function _getRebalancerStorage()
        private
        pure
        returns (RebalancerStorage storage $)
    {
        assembly {
            $.slot := RebalancerStorageLocation
        }
    }

    /// @dev Checks that the caller is the timelock.
    modifier onlyTimelock() {
        _onlyTimelock();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @dev Initializes the Rebalancer with the specified parameters.
    /// @param admin_ The address of the initial admin.
    /// @param timelock_ The address of the initial timelock.
    /// @param asset_ The address of the underlying asset.
    /// @param name_ The name of the share token.
    /// @param symbol_ The symbol of the share token.
    /// @param providers_ The initial listed providers.
    /// @param treasury_ The address of the initial treasury.
    /// @param managementFee_ The initial management fee rate.
    /// @param performanceFee_ The initial performance fee rate.
    /// @param minAssets_ The initial minimum asset amount.
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

        // requires an initial deposit to mitigate inflation attacks.
        // the appropriate amount depends on the underlying asset’s decimals.
        _deposit(_msgSender(), address(this), minAssets_, minAssets_);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC4626
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20Metadata
    function decimals()
        public
        view
        override(ERC20Upgradeable, IERC20Metadata)
        returns (uint8)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._underlyingDecimals;
    }

    /// @inheritdoc IERC4626
    function asset() public view returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return address($._asset);
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view returns (uint256) {
        return _totalAssetsAtProviders();
    }

    /// @notice Converts assets to shares.
    /// @param assets The amount of assets.
    /// @return shares The amount of shares.
    function convertToShares(
        uint256 assets
    ) public view returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Converts shares to assets.
    /// @param shares The amount of shares.
    /// @return assets The amount of assets.
    function convertToAssets(
        uint256 shares
    ) public view returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxDeposit(address) public pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxMint(address) public pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxWithdraw(address) public pure returns (uint256) {
        return 0;
    }

    /// @dev Unconventional underestimation: limits depend on external providers, so we return 0 to avoid over-promising.
    function maxRedeem(address) public pure returns (uint256) {
        return 0;
    }

    /// @notice Previews the amount of shares minted in a deposit.
    /// @param assets The amount of assets to deposit.
    /// @return The previewed amount of shares.
    function previewDeposit(
        uint256 assets
    ) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Previews the amount of assets required for a mint.
    /// @param shares The amount of shares to mint.
    /// @return The previewed amount of assets.
    function previewMint(
        uint256 shares
    ) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @notice Previews the amount of shares burned in a withdraw.
    /// @param assets The amount of assets to withdraw.
    /// @return The previewed amount of shares.
    function previewWithdraw(
        uint256 assets
    ) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @notice Previews the amount of assets received for a redeem.
    /// @param shares The amount of shares to redeem.
    /// @return The previewed amount of assets.
    function previewRedeem(
        uint256 shares
    ) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function deposit(
        uint256 assets,
        address receiver
    ) public returns (uint256 shares) {
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

    /// @inheritdoc IERC4626
    function mint(
        uint256 shares,
        address receiver
    ) public returns (uint256 assets) {
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

    /// @inheritdoc IERC4626
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
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

    /// @inheritdoc IERC4626
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
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

    /// @dev Converts assets to shares with support for rounding direction.
    /// @dev Includes accrued fee shares in total supply during conversion.
    /// @param assets The amount of assets.
    /// @param rounding The rounding direction.
    /// @return shares The amount of shares.
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

    /// @dev Converts shares to assets with support for rounding direction.
    /// @dev Includes accrued fee shares in total supply during conversion.
    /// @param shares The amount of shares.
    /// @param rounding The rounding direction.
    /// @return assets The amount of assets.
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

    /// @dev Converts assets to shares using totals, with support for rounding direction.
    /// @dev Reverts if assets > 0, totalSupply > 0 and totalManagedAssets = 0. That corresponds to a case where any asset would represent an infinite amount of shares.
    /// @param assets The amount of assets.
    /// @param totalSupply The total supply used for the conversion.
    /// @param totalManagedAssets The total assets used for the conversion.
    /// @param rounding The rounding direction.
    /// @return shares The amount of shares.
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

    /// @dev Converts shares to assets using totals, with support for rounding direction.
    /// @param shares The amount of shares.
    /// @param totalSupply The total supply used for the conversion.
    /// @param totalManagedAssets The total assets used for the conversion.
    /// @param rounding The rounding direction.
    /// @return assets The amount of assets.
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

    /// @dev Deposits assets via the entry provider and mints shares to the receiver.
    /// @param caller The address initiating the action.
    /// @param receiver The address receiving the shares.
    /// @param assets The amount of assets.
    /// @param shares The amount of shares.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._asset.safeTransferFrom(caller, address(this), assets);
        _delegateActionToProvider(assets, "deposit", $._entryProvider);
        _mint(receiver, shares);
        $._lastTotalAssets += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Burns shares and withdraws assets from providers.
    /// @param caller The address initiating the action.
    /// @param receiver The address receiving the assets.
    /// @param owner The owner of the shares being burned.
    /// @param assets The amount of assets.
    /// @param shares The amount of shares.
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
            uint256 assetsAtProvider = provider.getDepositBalance(
                address(this),
                this
            );

            if (assetsAtProvider == 0) continue;

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

    /// @dev Validates a deposit or mint.
    /// @param receiver The address receiving the shares.
    /// @param assets The amount of assets to deposit.
    /// @param shares The amount of shares to mint.
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

    /// @dev Validates a withdraw or redeem.
    /// @param assets The amount of assets to withdraw.
    /// @param shares The amount of shares to burn.
    /// @param caller The address initiating the action.
    /// @param receiver The address receiving the assets.
    /// @param owner The owner of the shares being burned.
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
    ) external onlyRole(EXECUTOR_ROLE) returns (bool) {
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

            uint256 assetsAtFrom = from.getDepositBalance(address(this), this);

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

    /// @inheritdoc IRebalancer
    function applyFees() external {
        _applyFees();
    }

    /// @dev Applies accrued fees.
    /// @return totalManagedAssets The current total managed assets.
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

        address treasury = $._treasury;
        if (performanceFeeShares != 0) {
            _mint(treasury, performanceFeeShares);
        }
        if (managementFeeShares != 0) {
            _mint(treasury, managementFeeShares);
        }

        $._lastTimestamp = block.timestamp.toUint64();
    }

    /// @dev Calculates accrued fee shares.
    /// @dev Both fees are rounded down, so the treasury may receive less than expected.
    /// @param totalManagedAssets The current total managed assets.
    /// @return performanceFeeShares The accrued performance fee shares.
    /// @return managementFeeShares The accrued management fee shares.
    function _accruedFees(
        uint256 totalManagedAssets
    )
        internal
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();

        uint256 lastTotalAssets = $._lastTotalAssets;
        uint96 managementFee = $._managementFee;
        uint96 performanceFee = $._performanceFee;

        uint256 dt = block.timestamp - $._lastTimestamp;

        uint256 yield = totalManagedAssets > lastTotalAssets
            ? totalManagedAssets - lastTotalAssets
            : 0;

        // may be rounded down to 0 if yield * fee < SCALE.
        uint256 performanceFeeAssets = yield > 0 && performanceFee > 0
            ? yield.mulDiv(performanceFee, SCALE, Math.Rounding.Floor)
            : 0;

        uint256 managementFeeAssets = dt > 0 && managementFee > 0
            ? (totalManagedAssets * dt).mulDiv(
                managementFee,
                365 days * SCALE,
                Math.Rounding.Floor
            )
            : 0;

        // assumes the vault should be interacted with periodically; fees must remain < total assets.
        uint256 totalAssetsWithoutFees = totalManagedAssets -
            managementFeeAssets -
            performanceFeeAssets;

        performanceFeeShares = performanceFeeAssets.mulDiv(
            totalSupply(),
            totalAssetsWithoutFees,
            Math.Rounding.Floor
        );
        managementFeeShares = managementFeeAssets.mulDiv(
            totalSupply(),
            totalAssetsWithoutFees,
            Math.Rounding.Floor
        );
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

    /// @inheritdoc IRebalancer
    function setProviders(IProvider[] memory providers) external onlyTimelock {
        _setProviders(providers);
    }

    /// @inheritdoc IRebalancer
    function setEntryProvider(
        IProvider entryProvider
    ) external onlyRole(ADMIN_ROLE) {
        _setEntryProvider(entryProvider);
    }

    /// @inheritdoc IRebalancer
    function setTimelock(address timelock) external onlyTimelock {
        _setTimelock(timelock);
    }

    /// @inheritdoc IRebalancer
    function setTreasury(address treasury) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setTreasury(treasury);
    }

    /// @inheritdoc IRebalancer
    function setManagementFee(
        uint96 managementFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setManagementFee(managementFee);
    }

    /// @inheritdoc IRebalancer
    function setPerformanceFee(
        uint96 performanceFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setPerformanceFee(performanceFee);
    }

    /// @inheritdoc IRebalancer
    function setMinAssets(uint256 minAssets) external onlyRole(ADMIN_ROLE) {
        _setMinAssets(minAssets);
    }

    /// @dev Updates the listed providers.
    /// @param providers The new listed providers.
    function _setProviders(IProvider[] memory providers) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        for (uint256 i; i < providers.length; i++) {
            if (address(providers[i]) == address(0)) {
                revert AddressZero();
            }
            $._asset.forceApprove(
                providers[i].getSource(asset(), address(this), address(0)),
                type(uint256).max
            );
        }
        $._providers = providers;

        emit ProvidersUpdated(providers);
    }

    /// @dev Updates the entry provider.
    /// @param entryProvider The new entry provider.
    function _setEntryProvider(IProvider entryProvider) internal {
        if (!_validateProvider(address(entryProvider))) {
            revert InvalidProvider();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._entryProvider = entryProvider;
        emit EntryProviderUpdated(entryProvider);
    }

    /// @dev Updates the timelock address.
    /// @param timelock The new timelock address.
    function _setTimelock(address timelock) internal {
        if (timelock == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._timelock = timelock;
        emit TimelockUpdated(timelock);
    }

    /// @dev Updates the treasury address.
    /// @param treasury The new treasury address.
    function _setTreasury(address treasury) internal {
        if (treasury == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._treasury = treasury;
        emit TreasuryUpdated(treasury);
    }

    /// @dev Updates the management fee rate.
    /// @param managementFee The new management fee rate.
    function _setManagementFee(uint96 managementFee) internal {
        if (managementFee > MAX_MANAGEMENT_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._managementFee = managementFee;
        emit ManagementFeeUpdated(managementFee);
    }

    /// @dev Updates the performance fee rate.
    /// @param performanceFee The new performance fee rate.
    function _setPerformanceFee(uint96 performanceFee) internal {
        if (performanceFee > MAX_PERFORMANCE_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._performanceFee = performanceFee;
        emit PerformanceFeeUpdated(performanceFee);
    }

    /// @dev Updates the minimum asset amount.
    /// @param minAssets The new minimum asset amount.
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

    /// @dev Delegates an action to a provider.
    /// @param assets The amount of assets.
    /// @param actionName The name of the action.
    /// @param provider The provider contract.
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

    /// @dev Returns the total managed assets across all providers.
    /// @return total The sum of assets managed across all providers.
    function _totalAssetsAtProviders() internal view returns (uint256 total) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 assetsAtProvider;
        uint256 count = $._providers.length;
        for (uint256 i; i < count; i++) {
            assetsAtProvider = $._providers[i].getDepositBalance(
                address(this),
                this
            );
            total += assetsAtProvider;
        }
    }

    /// @dev Returns whether a provider is listed.
    /// @param provider The provider address.
    /// @return valid True if the provider is listed, false otherwise.
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

    /// @inheritdoc IRebalancer
    function getAccruedFees()
        external
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        uint256 totalManagedAssets = totalAssets();
        return _accruedFees(totalManagedAssets);
    }

    /// @inheritdoc IRebalancer
    function getProviders() external view returns (IProvider[] memory) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._providers;
    }

    /// @inheritdoc IRebalancer
    function getEntryProvider() external view returns (IProvider) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._entryProvider;
    }

    /// @inheritdoc IRebalancer
    function getTimelock() external view returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._timelock;
    }

    /// @inheritdoc IRebalancer
    function getTreasury() external view returns (address) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._treasury;
    }

    /// @inheritdoc IRebalancer
    function getManagementFee() external view returns (uint96) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._managementFee;
    }

    /// @inheritdoc IRebalancer
    function getPerformanceFee() external view returns (uint96) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._performanceFee;
    }

    /// @inheritdoc IRebalancer
    function getLastTotalAssets() external view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._lastTotalAssets;
    }

    /// @inheritdoc IRebalancer
    function getLastTimestamp() external view returns (uint64) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._lastTimestamp;
    }

    /// @inheritdoc IRebalancer
    function getMinAssets() external view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._minAssets;
    }
}
