// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {AccessManager} from "../access/AccessManager.sol";
import {PausableActions} from "./PausableActions.sol";

/**
 * @title Vault
 */
abstract contract Vault is ERC20Permit, AccessManager, PausableActions, ReentrancyGuard, IVault {
    using Math for uint256;
    using Address for address;
    using SafeERC20 for IERC20Metadata;

    /**
     * @dev Errors
     */
    error Vault__Unauthorized();
    error Vault__AddressZero();
    error Vault__InvalidInput();
    error Vault__DepositLessThanMin();
    error Vault__SetupAlreadyCompleted();
    error Vault__NotWhitelisted();

    uint256 internal constant PRECISION_FACTOR = 1e18;
    uint256 internal constant MAX_WITHDRAW_FEE_PERCENT = 0.05 * 1e18; // 5%
    uint256 internal constant MAX_REBALANCE_FEE_PERCENT = 0.2 * 1e18; // 20%

    IERC20Metadata internal immutable _asset;
    uint8 private immutable _underlyingDecimals;

    IProvider[] internal _providers;
    IProvider public activeProvider;

    uint256 public minAmount;
    uint256 public withdrawFeePercent;

    address public timelock;
    address public treasury;

    bool public setupCompleted;
    
    // Whitelist functionality using AccessManager roles
    bool public whitelistEnabled;

    /**
     * @dev Reverts if called by any account other than the timelock contract.
     */
    modifier onlyTimelock() {
        if (msg.sender != timelock) {
            revert Vault__Unauthorized();
        }
        _;
    }

    /**
     * @dev Initializes the Vault contract with the specified parameters.
     * @param asset_ The address of the underlying asset managed by the vault.
     * @param name_ The name of the tokenized vault.
     * @param symbol_ The symbol of the tokenized vault.
     * @param providers_ An array of providers serving as a liquidity source for lending and/or yield.
     * @param withdrawFeePercent_ The fee percentage applied to withdrawals.
     * @param timelock_ The address of the timelock contract.
     * @param treasury_ The address of the treasury.
     */
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        uint256 withdrawFeePercent_,
        address timelock_,
        address treasury_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (asset_ == address(0)) {
            revert Vault__AddressZero();
        }

        _asset = IERC20Metadata(asset_);
        _underlyingDecimals = IERC20Metadata(asset_).decimals();

        _setTimelock(timelock_);
        _setProviders(providers_);
        _setActiveProvider(providers_[0]);
        _setTreasury(treasury_);
        _setWithdrawFeePercent(withdrawFeePercent_);
        _setMinAmount(1e6);

        /// @dev pause deposit and mint actions until vault setup is completed.
        _pause(Actions.Deposit);
    }

    /*////////////////////
      ERC4626 Management
    ////////////////////*/

    /**
     * @notice Returns the number of decimals used to get number representation.
     */
    function decimals()
        public
        view
        override(IERC20Metadata, ERC20)
        returns (uint8)
    {
        return _underlyingDecimals;
    }

    /**
     * @inheritdoc IERC4626
     */
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /**
     * @inheritdoc IERC4626
     */
    function totalAssets() public view override returns (uint256 assets) {
        return _getBalanceAtProviders();
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

    /**
     * @inheritdoc IERC4626
     */
    function maxDeposit(address) public view override returns (uint256) {
        if (paused(Actions.Deposit)) {
            return 0;
        }
        return type(uint256).max;
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxMint(address) public view override returns (uint256) {
        if (paused(Actions.Deposit)) {
            return 0;
        }
        return type(uint256).max;
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused(Actions.Withdraw)) {
            return 0;
        }
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused(Actions.Withdraw)) {
            return 0;
        }
        return balanceOf(owner);
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
        uint256 shares = previewWithdraw(assets);
        (uint256 validatedAssets, uint256 validatedShares) = _validateWithdraw(
            assets,
            shares,
            msg.sender,
            receiver,
            owner
        );
        _withdraw(
            msg.sender,
            receiver,
            owner,
            validatedAssets,
            validatedShares
        );
        return validatedShares;
    }

    /**
     * @inheritdoc IERC4626
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        uint256 assets = previewRedeem(shares);
        (uint256 validatedAssets, uint256 validatedShares) = _validateWithdraw(
            assets,
            shares,
            msg.sender,
            receiver,
            owner
        );
        _withdraw(
            msg.sender,
            receiver,
            owner,
            validatedAssets,
            validatedShares
        );
        return validatedAssets;
    }

    /**
     * @dev Converts assets to shares equivalent, with support for rounding direction.
     *
     * @param assets The amount of assets to convert to shares.
     * @param rounding The direction of division remainder for conversion.
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        return
            (assets == 0 || supply == 0)
                ? assets
                : assets.mulDiv(supply, totalAssets(), rounding);
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
        uint256 supply = totalSupply();
        return
            (supply == 0)
                ? shares
                : shares.mulDiv(totalAssets(), supply, rounding);
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
        if (receiver == address(0)) {
            revert Vault__AddressZero();
        }
        if (assets == 0 || shares == 0) {
            revert Vault__InvalidInput();
        }
        if (assets < minAmount) {
            revert Vault__DepositLessThanMin();
        }
        if (whitelistEnabled && !hasRole(DEPOSITOR_ROLE, receiver)) {
            revert Vault__NotWhitelisted();
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
    ) internal nonReentrant {
        _asset.safeTransferFrom(caller, address(this), assets);
        _delegateActionToProvider(assets, "deposit", activeProvider);
        _mint(receiver, shares);

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
    )
        internal
        whenNotPaused(Actions.Withdraw)
        returns (uint256 validatedAssets, uint256 validatedShares)
    {
        if (receiver == address(0) || owner == address(0)) {
            revert Vault__AddressZero();
        }
        if (assets == 0 || shares == 0) {
            revert Vault__InvalidInput();
        }

        uint256 _maxWithdraw = maxWithdraw(owner);
        if (assets > _maxWithdraw) {
            validatedAssets = _maxWithdraw;
            // Use CEIL rounding to prevent validatedShares from rounding down to zero
            validatedShares = _convertToShares(validatedAssets, Math.Rounding.Ceil);
            
            // Safety checks to prevent zero values
            if (validatedShares == 0) {
                revert Vault__InvalidInput();
            }
            if (validatedAssets == 0) {
                revert Vault__InvalidInput();
            }
        } else {
            validatedAssets = assets;
            validatedShares = shares;
        }

        if (caller != owner) {
            _spendAllowance(owner, caller, validatedShares);
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
    ) internal nonReentrant {
        uint256 withdrawFee = assets.mulDiv(
            withdrawFeePercent,
            PRECISION_FACTOR
        );
        uint256 assetsToReceiver = assets - withdrawFee;

        _burn(owner, shares);

        uint256 count = _providers.length;
        for (uint256 i; i < count; i++) {
            IProvider provider = _providers[i];
            uint256 balanceAtProvider = provider.getDepositBalance(
                address(this),
                this
            );

            if (balanceAtProvider == 0) continue;

            uint256 amount = (balanceAtProvider >= assets)
                ? assets
                : balanceAtProvider;

            _delegateActionToProvider(amount, "withdraw", provider);

            assets -= amount;

            if (assets == 0) break;
        }

        address _treasury = treasury;

        _asset.safeTransfer(_treasury, withdrawFee);
        _asset.safeTransfer(receiver, assetsToReceiver);

        emit FeeCharged(_treasury, withdrawFee);
        emit Withdraw(caller, receiver, owner, assetsToReceiver, shares);
    }

    /*/////////////////////
      REBALANCE functions
    /////////////////////*/

    /**
     * @inheritdoc IVault
     */
    function setupVault(uint256 assets) external {
        if (setupCompleted) {
            revert Vault__SetupAlreadyCompleted();
        }
        if (assets < minAmount) {
            revert Vault__DepositLessThanMin();
        }

        _unpause(Actions.Deposit);

        _deposit(msg.sender, address(this), assets, assets);
        setupCompleted = true;

        emit SetupCompleted(msg.sender);
    }

    /**
     * @notice Pauses the specified action in the vault.
     *
     * @param action The action to pause.
     */
    function pause(Actions action) external onlyAdmin {
        _pause(action);
    }

    /**
     * @notice Unpauses the specified action in the vault.
     *
     * @param action The action to unpause.
     */
    function unpause(Actions action) external onlyAdmin {
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
    function setActiveProvider(IProvider _activeProvider) external onlyAdmin {
        _setActiveProvider(_activeProvider);
    }

    /**
     * @notice Sets the treasury address for this vault.
     * @param _treasury The new treasury address.
     */
    function setTreasury(address _treasury) external onlyAdmin {
        _setTreasury(_treasury);
    }

    /**
     * @notice Sets the withdrawal fee percentage for this vault.
     * @param _withdrawFeePercent The new withdrawal fee percentage.
     */
    function setWithdrawFeePercent(
        uint256 _withdrawFeePercent
    ) external onlyAdmin {
        _setWithdrawFeePercent(_withdrawFeePercent);
    }

    /**
     * @notice Sets the minimum amount required for deposit and mint actions.
     * @param _minAmount The new minimum amount.
     */
    function setMinAmount(uint256 _minAmount) external onlyAdmin {
        _setMinAmount(_minAmount);
    }

    /**
     * @dev Internal function to update the address of the timelock contract.
     * @param _timelock The address of the new timelock contract.
     */
    function _setTimelock(address _timelock) internal {
        if (_timelock == address(0)) {
            revert Vault__AddressZero();
        }
        timelock = _timelock;
        emit TimelockUpdated(_timelock);
    }

    /**
     * @dev Internal function to set the providers for this vault.
     * @param providers An array of provider contracts.
     */
    function _setProviders(IProvider[] memory providers) internal {
        for (uint256 i; i < providers.length; i++) {
            if (address(providers[i]) == address(0)) {
                revert Vault__AddressZero();
            }
            _asset.forceApprove(
                providers[i].getSource(asset(), address(this), address(0)),
                type(uint256).max
            );
        }
        _providers = providers;

        emit ProvidersUpdated(providers);
    }

    /**
     * @dev Internal function to set the active provider for this vault.
     * @param _activeProvider The contract of the new active provider.
     */
    function _setActiveProvider(IProvider _activeProvider) internal {
        if (!_validateProvider(address(_activeProvider))) {
            revert Vault__InvalidInput();
        }
        activeProvider = _activeProvider;
        emit ActiveProviderUpdated(_activeProvider);
    }

    /**
     * @dev Internal function to set the treasury address for this vault.
     * @param _treasury The new treasury address.
     */
    function _setTreasury(address _treasury) internal {
        if (_treasury == address(0)) {
            revert Vault__AddressZero();
        }
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @dev Internal function to set the withdrawal fee percentage for this vault.
     * @param _withdrawFeePercent The new withdrawal fee percentage.
     */
    function _setWithdrawFeePercent(uint256 _withdrawFeePercent) internal {
        if (_withdrawFeePercent > MAX_WITHDRAW_FEE_PERCENT) {
            revert Vault__InvalidInput();
        }
        withdrawFeePercent = _withdrawFeePercent;
        emit WithdrawFeePercentUpdated(_withdrawFeePercent);
    }

    /**
     * @dev Internal function to set the minimum amount required for deposit and mint actions.
     * @param _minAmount The new minimum amount.
     */
    function _setMinAmount(uint256 _minAmount) internal {
        minAmount = _minAmount;
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

    /**
     * @dev Returns the total balance of the asset held by this vault across all listed providers.
     */
    function _getBalanceAtProviders()
        internal
        view
        returns (uint256 totalBalance)
    {
        uint256 providerBalance;
        uint256 count = _providers.length;
        for (uint256 i; i < count; i++) {
            providerBalance = _providers[i].getDepositBalance(
                address(this),
                this
            );
            totalBalance += providerBalance;
        }
    }

    /**
     * @dev Returns true if the specified provider is in the list of providers.
     * @param provider The address of the provider to validate.
     */
    function _validateProvider(
        address provider
    ) internal view returns (bool valid) {
        uint256 count = _providers.length;
        for (uint256 i; i < count; i++) {
            if (provider == address(_providers[i])) {
                valid = true;
                break;
            }
        }
    }

    /**
     * @notice Returns the amount of assets owned by the specified address.
     * @param owner The address of the account whose asset balance is checked.
     */
    function getBalanceOfAsset(
        address owner
    ) public view returns (uint256 assets) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @notice Returns the array of providers of this vault.
     */
    function getProviders() public view returns (IProvider[] memory) {
        return _providers;
    }

    /**
     * @notice Toggles the whitelist functionality on or off.
     * @param enabled Whether to enable or disable the whitelist.
     */
    function toggleWhitelist(bool enabled) external onlyTimelock {
        whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    /**
     * @notice Grants DEPOSITOR_ROLE to an address (adds to whitelist).
     * @param account The address to add to the whitelist.
     */
    function addToWhitelist(address account) external onlyTimelock {
        if (account == address(0)) {
            revert Vault__AddressZero();
        }
        grantRole(DEPOSITOR_ROLE, account);
    }

    /**
     * @notice Revokes DEPOSITOR_ROLE from an address (removes from whitelist).
     * @param account The address to remove from the whitelist.
     */
    function removeFromWhitelist(address account) external onlyTimelock {
        if (account == address(0)) {
            revert Vault__AddressZero();
        }
        revokeRole(DEPOSITOR_ROLE, account);
    }

    /**
     * @notice Checks if an address is whitelisted (has DEPOSITOR_ROLE).
     * @param account The address to check.
     * @return Whether the address is whitelisted.
     */
    function isWhitelisted(address account) external view returns (bool) {
        return hasRole(DEPOSITOR_ROLE, account);
    }

    /**
     * @notice Checks if whitelist is enabled.
     * @return Whether whitelist is enabled.
     */
    function isWhitelistEnabled() external view returns (bool) {
        return whitelistEnabled;
    }
}
