// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20PermitUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
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
/// @custom:note consider dead vault case where totalAssets < 0 but totalSupply > 0, what will happen
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
        IERC20Metadata _asset;
        uint8 _underlyingDecimals;
        IProvider[] _providers;
        IProvider activeProvider; // to-do: better to change naming, all the providers are active when optimized
        uint256 lastTotalBalance;
        uint64 lastTimestamp;
        uint96 managementFee;
        address treasury;
        uint96 performanceFee;
        address timelock;
        uint256 minAmount; /// to-do: better to change naming
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.Rebalancer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RebalancerStorageLocation =
        0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;

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
        RebalancerStorage storage $ = _getRebalancerStorage();
        if (msg.sender != $.timelock) {
            revert Unauthorized();
        }
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
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        uint256 initialDeposit_,
        uint96 managementFee_,
        uint96 performanceFee_,
        address treasury_,
        address timelock_
    ) public initializer {
        __AccessManager_init();
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        if (asset_ == address(0)) {
            revert AddressZero();
        }

        RebalancerStorage storage $ = _getRebalancerStorage();

        $._asset = IERC20Metadata(asset_);
        // note: think about also adding virtual shares and decimals offset
        $._underlyingDecimals = IERC20Metadata(asset_).decimals();

        _setTimelock(timelock_);
        _setProviders(providers_);
        _setActiveProvider(providers_[0]);
        // note: 1 token for most stablecoins, depends on the decimals of underlying
        _setMinAmount(1e6);

        $.lastTimestamp = block.timestamp.toUint64();

        // note: care should be taken for the initial deposit to be a non-trivial amount, depends on the decimals of underlying
        if (initialDeposit_ < $.minAmount) {
            revert DepositLessThanMin();
        }

        // may need an approve to the precomputed address before deployment
        _deposit(msg.sender, address(this), initialDeposit_, initialDeposit_);

        _setTreasury(treasury_);
        _setManagementFee(managementFee_);
        _setPerformanceFee(performanceFee_);
    }

    /*////////////////////
      ERC4626 Management
    ////////////////////*/

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
    function totalAssets()
        public
        view
        override
        returns (uint256 totalManagedAssets)
    {
        /// @custom:note think about idle funds possibility
        totalManagedAssets = _getBalanceAtProviders();
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
    ) public override returns (uint256) {
        _applyFees();

        uint256 shares = previewDeposit(assets);
        _validateDeposit(receiver, assets, shares);

        _deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    /**
     * @inheritdoc IERC4626
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        _applyFees();

        uint256 assets = previewMint(shares);
        _validateDeposit(receiver, assets, shares);

        _deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    /**
     * @inheritdoc IERC4626
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        _applyFees();

        uint256 shares = previewWithdraw(assets);
        _validateWithdraw(assets, shares, msg.sender, receiver, owner);

        _withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    /**
     * @inheritdoc IERC4626
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        _applyFees();

        uint256 assets = previewRedeem(shares);
        _validateWithdraw(assets, shares, msg.sender, receiver, owner);

        _withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }

    /**
     * @dev Converts assets to shares equivalent, with support for rounding direction.
     *
     * @param assets The amount of assets to convert to shares.
     * @param rounding The direction of division remainder for conversion.
     */
    /// @custom:note Will revert if assets > 0, totalSupply > 0 and totalAssets = 0. That corresponds to a case where any asset would
    /// represent an infinite amout of shares (dead vault)
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view returns (uint256 shares) {
        uint256 totalBalance = _getBalanceAtProviders();
        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _getAccruedFees(totalBalance);

        uint256 supply = totalSupply() +
            performanceFeeShares +
            managementFeeShares;

        return
            (assets == 0 || supply == 0)
                ? assets
                : assets.mulDiv(supply, totalBalance, rounding);
    }

    /**
     * @dev Converts shares to assets equivalent, with support for rounding direction.
     *
     * @param shares The amount of shares to convert to assets.
     * @param rounding The direction of division remainder for conversion.
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (uint256 assets) {
        uint256 totalBalance = _getBalanceAtProviders();
        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _getAccruedFees(totalBalance);

        uint256 supply = totalSupply() +
            performanceFeeShares +
            managementFeeShares;

        return
            (supply == 0)
                ? shares
                : shares.mulDiv(totalBalance, supply, rounding);
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
        if (assets < $.minAmount) {
            revert DepositLessThanMin();
        }
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
        $._asset.safeTransferFrom(caller, address(this), assets);
        _delegateActionToProvider(assets, "deposit", $.activeProvider);
        _mint(receiver, shares);
        $.lastTotalBalance += assets;

        emit Deposit(caller, receiver, assets, shares);
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
        RebalancerStorage storage $ = _getRebalancerStorage();
        _burn(owner, shares);

        uint256 assetsToWithdraw = assets;
        uint256 count = $._providers.length;
        for (uint256 i; i < count; i++) {
            IProvider provider = $._providers[i];
            uint256 balanceAtProvider = provider.getDepositBalance(
                address(this),
                this
            );

            if (balanceAtProvider == 0) continue;

            uint256 amount = (balanceAtProvider >= assetsToWithdraw)
                ? assetsToWithdraw
                : balanceAtProvider;

            _delegateActionToProvider(amount, "withdraw", provider);

            assetsToWithdraw -= amount;

            if (assetsToWithdraw == 0) break;
        }

        $.lastTotalBalance -= assets;
        $._asset.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /*/////////////////////
      REBALANCE functions
    /////////////////////*/

    /**
     *
     */
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

            // to-do: think about from == to check

            uint256 assetsAtFrom = from.getDepositBalance(address(this), this);

            if (assets == type(uint256).max) {
                assets = assetsAtFrom;
            }
            if (assets == 0 || assets > assetsAtFrom) {
                revert InvalidAssetAmount();
            }

            _delegateActionToProvider(assets, "withdraw", from);
            _delegateActionToProvider(assets, "deposit", to);

            emit RebalanceExecuted(assets, address(from), address(to));
        }

        return true;
    }

    function applyFees() external {
        _applyFees();
    }

    /// @inheritdoc IPausableActions
    function pause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _pause(action);
    }

    /// @inheritdoc IPausableActions
    function unpause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _unpause(action);
    }

    /**
     * @notice Sets the address of the timelock contract.
     * @param _timelock The address of the new timelock contract.
     */
    function setTimelock(address _timelock) external onlyTimelock {
        _setTimelock(_timelock);
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
     * @param _activeProvider The contract of the new active provider.
     *
     */
    function setActiveProvider(
        IProvider _activeProvider
    ) external onlyRole(ADMIN_ROLE) {
        _setActiveProvider(_activeProvider);
    }

    /**
     * @notice Sets the treasury address for this vault.
     * @param _treasury The new treasury address.
     */
    function setTreasury(address _treasury) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setTreasury(_treasury);
    }

    /**
     * @notice Sets the performance fee percentage for this vault.
     * @param _performanceFee The new performance fee percentage.
     */
    function setPerformanceFee(
        uint96 _performanceFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setPerformanceFee(_performanceFee);
    }

    /**
     * @notice Sets the management fee percentage for this vault.
     * @param _managementFee The new management fee percentage.
     */
    function setManagementFee(
        uint96 _managementFee
    ) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setManagementFee(_managementFee);
    }

    /**
     * @notice Sets the minimum amount required for deposit and mint actions.
     * @param _minAmount The new minimum amount.
     */
    function setMinAmount(uint256 _minAmount) external onlyRole(ADMIN_ROLE) {
        _setMinAmount(_minAmount);
    }

    /**
     * @dev Internal function to update the address of the timelock contract.
     * @param _timelock The address of the new timelock contract.
     */
    function _setTimelock(address _timelock) internal {
        if (_timelock == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.timelock = _timelock;
        emit TimelockUpdated(_timelock);
    }

    /**
     * @dev Internal function to set the providers for this vault.
     * @param providers An array of provider contracts.
     */
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

    /**
     * @dev Internal function to set the active provider for this vault.
     * @param _activeProvider The contract of the new active provider.
     */
    function _setActiveProvider(IProvider _activeProvider) internal {
        if (!_validateProvider(address(_activeProvider))) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.activeProvider = _activeProvider;
        emit ActiveProviderUpdated(_activeProvider);
    }

    /**
     * @dev Internal function to set the treasury address for this vault.
     * @param _treasury The new treasury address.
     */
    function _setTreasury(address _treasury) internal {
        if (_treasury == address(0)) {
            revert AddressZero();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @dev Internal function to set the performance fee percentage for this vault.
     * @param _performanceFee The new performance fee percentage.
     */
    function _setPerformanceFee(uint96 _performanceFee) internal {
        if (_performanceFee > MAX_PERFORMANCE_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.performanceFee = _performanceFee;
        emit PerformanceFeeUpdated(_performanceFee);
    }

    /**
     * @dev Internal function to set the management fee percentage for this vault.
     * @param _managementFee The new management fee percentage.
     */
    function _setManagementFee(uint96 _managementFee) internal {
        if (_managementFee > MAX_MANAGEMENT_FEE) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.managementFee = _managementFee;
        emit ManagementFeeUpdated(_managementFee);
    }

    /**
     * @dev Internal function to set the minimum amount required for deposit and mint actions.
     * @param _minAmount The new minimum amount.
     */
    function _setMinAmount(uint256 _minAmount) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        $.minAmount = _minAmount;
        emit MinAmountUpdated(_minAmount);
    }

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

    function _applyFees() internal {
        uint256 totalBalance = _getBalanceAtProviders();

        (
            uint256 performanceFeeShares,
            uint256 managementFeeShares
        ) = _getAccruedFees(totalBalance);

        RebalancerStorage storage $ = _getRebalancerStorage();

        emit FeesApplied(
            $.lastTotalBalance,
            totalBalance,
            performanceFeeShares,
            managementFeeShares
        );

        $.lastTotalBalance = totalBalance;
        address _treasury = $.treasury;

        if (performanceFeeShares != 0) {
            _mint(_treasury, performanceFeeShares);
        }
        if (managementFeeShares != 0) {
            _mint(_treasury, managementFeeShares);
        }

        $.lastTimestamp = block.timestamp.toUint64();
    }

    /**
     * @dev Returns the total balance of the asset held by this vault across all listed providers.
     */
    function _getBalanceAtProviders()
        internal
        view
        returns (uint256 totalBalance)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 providerBalance;
        uint256 count = $._providers.length;
        for (uint256 i; i < count; i++) {
            providerBalance = $._providers[i].getDepositBalance(
                address(this),
                this
            );
            totalBalance += providerBalance;
        }
    }

    function _getAccruedFees(
        uint256 totalBalance // actual balance at providers at the moment
    )
        internal
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 dt = block.timestamp - $.lastTimestamp;

        uint256 yield = totalBalance > $.lastTotalBalance
            ? totalBalance - $.lastTotalBalance
            : 0;

        uint256 performanceFeeAssets = yield > 0 && $.performanceFee > 0
            ? yield.mulDiv($.performanceFee, SCALE, Math.Rounding.Floor)
            : 0;

        uint256 managementFeeAssets = dt > 0 && $.managementFee > 0
            ? (totalBalance * dt).mulDiv(
                $.managementFee,
                365 days * SCALE,
                Math.Rounding.Floor
            )
            : 0;

        /// @custom:note assumes the vault should be interacted with periodically and fees never exceed balance
        uint256 totalBalanceWithoutFees = totalBalance -
            managementFeeAssets -
            performanceFeeAssets;

        /// @custom:note convert to shares logic, assumes no zero values
        performanceFeeShares = performanceFeeAssets.mulDiv(
            totalSupply(),
            totalBalanceWithoutFees,
            Math.Rounding.Floor
        );
        managementFeeShares = managementFeeAssets.mulDiv(
            totalSupply(),
            totalBalanceWithoutFees,
            Math.Rounding.Floor
        );
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

    function getAccruedFees() public view returns (uint256, uint256) {
        uint256 totalBalance = _getBalanceAtProviders();
        return _getAccruedFees(totalBalance);
    }

    /**
     * @notice Returns the array of providers of this vault.
     */
    function getProviders() public view returns (IProvider[] memory) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._providers;
    }
}
