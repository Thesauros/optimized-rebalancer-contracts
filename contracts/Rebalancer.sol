// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
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
contract Rebalancer is ERC20PermitUpgradeable, AccessManager, PausableActions, ReentrancyGuardUpgradeable, IRebalancer {
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
        // risk (appended; existing field offsets unchanged for deployed proxies)
        // provider => max share of totalAssets in bps; 0 means uncapped
        mapping(address provider => uint256) _providerCapBps;
        // Append-only security accounting; never insert before legacy fields.
        uint256 _highWaterMark;
        mapping(address provider => address source) _providerSources;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.Rebalancer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RebalancerStorageLocation =
        0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;

    uint256 internal constant BPS = 10_000;

    /**
     * @dev Gas forwarded to `IProvider.getDepositBalance` from `_safeGetDepositBalance`,
     *      to bound health-check gas. Unknown NAV blocks financial settlement;
     *      action illiquidity is isolated when NAV is known. `MorphoProvider` was measured at up
     *      to ~1.1M gas on a Base fork (crosschain-sandbox, 2026-08-13); this is ~2.7x that.
     */
    uint256 internal constant PROVIDER_VIEW_CALL_GAS = 3_000_000;

    function _getRebalancerStorage() private pure returns (RebalancerStorage storage $) {
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

        // also sets the entry provider to providers_[0]
        _setProviders(providers_);
        _setTimelock(timelock_);
        _setTreasury(treasury_);
        _setManagementFee(managementFee_);
        _setPerformanceFee(performanceFee_);
        _setMinAssets(minAssets_);

        $._lastTimestamp = block.timestamp.toUint64();

        // requires a non-trivial initial deposit to mitigate inflation attacks.
        // the appropriate amount depends on the underlying asset’s decimals.
        _deposit(_msgSender(), address(this), minAssets_, minAssets_);
        $._highWaterMark = SCALE;
    }

    /// @notice Bootstrap an upgraded legacy proxy in the upgrade transaction.
    /// @dev Governance must attest historic PPS and the currently configured
    /// sources. Unsettled legacy fees are waived; no historic peak is guessed.
    function initializeSecurityAccounting(uint256 historicalHighWaterMark) external reinitializer(2) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        // upgradeAndCall preserves ProxyAdmin as msg.sender. Its owner already
        // controls implementation upgrades; accepting that actual admin permits
        // atomic migration without opening a public initialization window.
        if (_msgSender() != $._timelock && _msgSender() != ERC1967Utils.getAdmin()) revert Unauthorized();
        if ($._highWaterMark != 0) revert InvalidInput();
        _setProviders($._providers);
        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        if (
            supply == 0 || historicalHighWaterMark == 0
                || historicalHighWaterMark < assets.mulDiv(SCALE, supply, Math.Rounding.Ceil)
        ) {
            revert InvalidInput();
        }
        $._highWaterMark = historicalHighWaterMark;
        $._lastTotalAssets = assets;
        $._lastTimestamp = block.timestamp.toUint64();
        emit SecurityAccountingInitialized(historicalHighWaterMark);
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
    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
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
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        uint256 totalManagedAssets = _applyFeesRequiringHealthyProviders();

        shares = _convertToSharesWithTotals(assets, totalSupply(), totalManagedAssets, Math.Rounding.Floor);
        _validateDeposit(receiver, assets, shares);

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        uint256 totalManagedAssets = _applyFeesRequiringHealthyProviders();

        assets = _convertToAssetsWithTotals(shares, totalSupply(), totalManagedAssets, Math.Rounding.Ceil);
        _validateDeposit(receiver, assets, shares);

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        uint256 totalManagedAssets = _applyFees();

        shares = _convertToSharesWithTotals(assets, totalSupply(), totalManagedAssets, Math.Rounding.Ceil);
        _validateWithdraw(assets, shares, _msgSender(), receiver, owner);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        uint256 totalManagedAssets = _applyFees();

        assets = _convertToAssetsWithTotals(shares, totalSupply(), totalManagedAssets, Math.Rounding.Floor);
        _validateWithdraw(assets, shares, _msgSender(), receiver, owner);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @dev Converts assets to shares equivalent, with support for rounding direction.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256 shares) {
        uint256 totalManagedAssets = totalAssets();
        (uint256 performanceFeeShares, uint256 managementFeeShares) = _accruedFees(totalManagedAssets);

        return _convertToSharesWithTotals(
            assets, totalSupply() + performanceFeeShares + managementFeeShares, totalManagedAssets, rounding
        );
    }

    /// @dev Converts shares to assets equivalent, with support for rounding direction.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256 assets) {
        uint256 totalManagedAssets = totalAssets();
        (uint256 performanceFeeShares, uint256 managementFeeShares) = _accruedFees(totalManagedAssets);

        return _convertToAssetsWithTotals(
            shares, totalSupply() + performanceFeeShares + managementFeeShares, totalManagedAssets, rounding
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
        return (assets == 0 || totalSupply == 0) ? assets : assets.mulDiv(totalSupply, totalManagedAssets, rounding);
    }

    /// @dev Converts shares to assets equivalent using provided total supply and total assets, with support for rounding direction.
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 totalSupply,
        uint256 totalManagedAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256 assets) {
        return (totalSupply == 0) ? shares : shares.mulDiv(totalManagedAssets, totalSupply, rounding);
    }

    /**
     * @dev Executes a deposit at the active provider.
     * @param caller The address that initiated the deposit.
     * @param receiver The address to which shares are minted.
     * @param assets The amount transferred during this deposit.
     * @param shares The amount minted to receiver.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        IProvider entryProvider = $._entryProvider;
        // defense in depth: never route deposits to a provider NAV does not track
        if (!_validateProvider(address(entryProvider))) {
            revert InvalidProvider();
        }
        $._asset.safeTransferFrom(caller, address(this), assets);
        _delegateActionToProvider(assets, "deposit", entryProvider);
        _mint(receiver, shares);
        $._lastTotalAssets += assets;
        _enforceProviderCap(entryProvider);

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
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        _burn(owner, shares);

        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 assetsLeft = assets;
        uint256 count = $._providers.length;
        for (uint256 i; i < count && assetsLeft > 0; i++) {
            IProvider provider = $._providers[i];
            (uint256 assetsAtProvider, bool ok) = _safeGetDepositBalance(provider);

            // Unknown value must never be confused with an empty position.
            if (!ok) revert ProviderUnavailable();
            if (assetsAtProvider == 0) continue;

            uint256 amount = (assetsAtProvider >= assetsLeft) ? assetsLeft : assetsAtProvider;

            // continue to next provider instead of reverting the entire tx.
            uint256 balBefore = $._asset.balanceOf(address(this));
            (bool success,) = address(provider)
                .delegatecall(abi.encodeWithSignature("withdraw(uint256,address)", amount, address(this)));
            if (success) {
                // Same measured-amount idiom as ChainAgent: the delta across the provider
                // call is the value that actually arrived, under `nonReentrant`.
                // slither-disable-next-line reentrancy-balance
                uint256 received = $._asset.balanceOf(address(this)) - balBefore;
                assetsLeft = received >= assetsLeft ? 0 : assetsLeft - received;
            }
        }

        // `assetsLeft` accumulates the measured shortfalls of the loop above; under
        // `nonReentrant` no caller can change the balance between the reads.
        // slither-disable-next-line reentrancy-balance
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
    function _validateDeposit(address receiver, uint256 assets, uint256 shares)
        internal
        view
        whenNotPaused(Actions.Deposit)
    {
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
    function _validateWithdraw(uint256 assets, uint256 shares, address caller, address receiver, address owner)
        internal
        whenNotPaused(Actions.Withdraw)
    {
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
    function rebalance(uint256[] memory amounts, IProvider[] memory sources, IProvider[] memory destinations)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
        returns (bool)
    {
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

            if (!_validateProvider(address(from)) || !_validateProvider(address(to))) {
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

            // move exactly what the source released, never idle vault balance
            RebalancerStorage storage $ = _getRebalancerStorage();
            uint256 balanceBefore = $._asset.balanceOf(address(this));
            _delegateActionToProvider(assets, "withdraw", from);
            // slither-disable-start reentrancy-balance
            uint256 received = $._asset.balanceOf(address(this)) - balanceBefore;
            if (received == 0) revert InvalidInput();
            _delegateActionToProvider(received, "deposit", to);
            // slither-disable-end reentrancy-balance

            _enforceProviderCap(to);

            emit RebalanceExecuted(received, address(from), address(to));
        }

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints accrued fee shares and updates fee snapshots.
    function applyFees() external nonReentrant {
        _applyFees();
    }

    /// @dev Internal function for fee application.
    function _applyFees() internal returns (uint256 totalManagedAssets) {
        bool healthy;
        (totalManagedAssets, healthy) = _totalAssetsWithHealth();
        if (!healthy) revert ProviderUnavailable();
        _settleFees(totalManagedAssets);
    }

    /**
     * @dev Entry paths use this variant. When a provider's balance view fails it
     *      cannot be priced safely. Both entry and exit settlement require the
     *      complete NAV; no holder forfeits an unknown position on redemption.
     */
    function _applyFeesRequiringHealthyProviders() internal returns (uint256 totalManagedAssets) {
        bool healthy;
        (totalManagedAssets, healthy) = _totalAssetsWithHealth();
        if (!healthy) revert ProviderUnavailable();
        _settleFees(totalManagedAssets);
    }

    function _settleFees(uint256 totalManagedAssets) internal {
        (uint256 performanceFeeShares, uint256 managementFeeShares) = _accruedFees(totalManagedAssets);

        RebalancerStorage storage $ = _getRebalancerStorage();

        emit FeesApplied($._lastTotalAssets, totalManagedAssets, performanceFeeShares, managementFeeShares);

        $._lastTotalAssets = totalManagedAssets;

        address treasury = $._treasury;
        if (performanceFeeShares != 0) {
            _mint(treasury, performanceFeeShares);
        }
        if (managementFeeShares != 0) {
            _mint(treasury, managementFeeShares);
        }

        uint256 supply = totalSupply();
        if (supply != 0) {
            uint256 netPrice = totalManagedAssets.mulDiv(SCALE, supply, Math.Rounding.Ceil);
            if (netPrice > $._highWaterMark) $._highWaterMark = netPrice;
        }

        $._lastTimestamp = block.timestamp.toUint64();
    }

    /// @dev Computes accrued fee shares.
    /// @dev The management fee is not tied to yield (profits or losses) and may reduce share price.
    /// @dev Both fees are rounded down, so treasury could receive less than expected.
    function _accruedFees(uint256 totalManagedAssets)
        internal
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        RebalancerStorage storage $ = _getRebalancerStorage();

        if ($._highWaterMark == 0) revert SecurityAccountingNotInitialized();
        uint96 managementFee = $._managementFee;
        uint96 performanceFee = $._performanceFee;
        uint256 supply = totalSupply();
        if (totalManagedAssets == 0 || supply == 0) return (0, 0);
        uint256 dt = block.timestamp - $._lastTimestamp;
        uint256 managementFeeAssets = totalManagedAssets.mulDiv(uint256(managementFee) * dt, 365 days * SCALE);
        if (managementFeeAssets >= totalManagedAssets) managementFeeAssets = totalManagedAssets - 1;
        uint256 highWaterAssets = $._highWaterMark.mulDiv(supply, SCALE, Math.Rounding.Ceil);
        uint256 performanceFeeAssets;
        if (totalManagedAssets - managementFeeAssets > highWaterAssets && performanceFee != 0) {
            uint256 gain = totalManagedAssets - managementFeeAssets - highWaterAssets;
            performanceFeeAssets = gain.mulDiv(performanceFee, SCALE);
        }
        uint256 remaining = totalManagedAssets - managementFeeAssets;
        if (performanceFeeAssets >= remaining) performanceFeeAssets = remaining - 1;
        uint256 totalAssetsWithoutFees = totalManagedAssets - managementFeeAssets - performanceFeeAssets;

        performanceFeeShares = performanceFeeAssets.mulDiv(supply, totalAssetsWithoutFees, Math.Rounding.Floor);
        managementFeeShares = managementFeeAssets.mulDiv(supply, totalAssetsWithoutFees, Math.Rounding.Floor);
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
     * @dev Change the entry explicitly before removing it. Every removed position
     * must be provably empty; unknown value and accounting aliases are rejected.
     * @param providers A non-empty array of provider contracts.
     */
    function setProviders(IProvider[] memory providers) external onlyTimelock {
        _setProviders(providers);
    }

    /**
     * @notice Sets the provider that receives new deposits.
     * @dev Callable by ADMIN_ROLE or EXECUTOR_ROLE. Both paths accept only a provider
     * present in the current providers list (`_validateProvider`), so the executor can
     * route deposits only where `rebalance` could already move funds.
     * @param entryProvider The contract of the new entry provider.
     */
    function setEntryProvider(IProvider entryProvider) external {
        address sender = _msgSender();
        if (!hasRole(ADMIN_ROLE, sender) && !hasRole(EXECUTOR_ROLE, sender)) {
            revert Unauthorized();
        }
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
    function setManagementFee(uint96 managementFee) external onlyRole(ADMIN_ROLE) {
        _applyFees();
        _setManagementFee(managementFee);
    }

    /**
     * @notice Sets the performance fee percentage for this vault.
     * @param performanceFee The new performance fee percentage.
     */
    function setPerformanceFee(uint96 performanceFee) external onlyRole(ADMIN_ROLE) {
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
     * During initialization entry defaults to providers[0]. Subsequent updates
     * retain the current entry and require known-empty removed positions.
     * @param providers A non-empty array of provider contracts.
     */
    function _setProviders(IProvider[] memory providers) internal {
        if (providers.length == 0) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();

        // the current entry provider must stay listed (skipped during initialize)
        address currentEntry = address($._entryProvider);
        if (currentEntry != address(0) && !_isInList(currentEntry, providers)) {
            revert EntryProviderNotInProviders();
        }

        IProvider[] memory oldProviders = $._providers;
        address[] memory sources = new address[](providers.length);
        // Validate every source and alias before any approval/state mutation.
        for (uint256 i; i < providers.length; i++) {
            address provider = address(providers[i]);
            if (provider.code.length == 0) revert InvalidProvider();
            address source = providers[i].getSource(asset(), address(this), address(0));
            if (source.code.length == 0) revert InvalidProvider();
            address pinned = $._providerSources[provider];
            if (pinned != address(0) && pinned != source) revert ProviderSourceChanged();
            for (uint256 j; j < i; j++) {
                if (providers[j] == providers[i] || sources[j] == source) revert DuplicateProviderSource();
            }
            sources[i] = source;
        }
        for (uint256 i; i < oldProviders.length; i++) {
            if (_isInList(address(oldProviders[i]), providers)) continue;
            (uint256 assets, bool ok) = _safeGetDepositBalance(oldProviders[i]);
            if (!ok) revert ProviderUnavailable();
            if (assets != 0) revert ProviderHasAssets(address(oldProviders[i]), assets);
        }
        for (uint256 i; i < oldProviders.length; i++) {
            address provider = address(oldProviders[i]);
            if (_isInList(provider, providers)) continue;
            $._asset.forceApprove($._providerSources[provider], 0);
            delete $._providerSources[provider];
        }
        for (uint256 i; i < providers.length; i++) {
            $._providerSources[address(providers[i])] = sources[i];
            $._asset.forceApprove(sources[i], type(uint256).max);
        }
        $._providers = providers;

        emit ProvidersUpdated(providers);

        if (!_validateProvider(address($._entryProvider))) {
            _setEntryProvider(providers[0]);
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

    /**
     * @notice Sets the maximum share of total assets a provider may hold, in bps.
     * @dev 0 means uncapped (the pre-existing behaviour). Lowering a cap reduces
     *      risk and is open to ADMIN_ROLE for fast response; raising or removing a
     *      cap goes through the timelock. Enforced after every deposit into the
     *      entry provider and after every rebalance into a provider.
     */
    function setProviderCap(IProvider provider, uint256 capBps) external {
        if (!_validateProvider(address(provider)) || capBps > BPS) {
            revert InvalidInput();
        }
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 current = $._providerCapBps[address(provider)];
        bool lowering = capBps != 0 && (current == 0 || capBps <= current);
        if (_msgSender() != $._timelock) {
            if (!lowering || !hasRole(ADMIN_ROLE, _msgSender())) {
                revert Unauthorized();
            }
        }
        $._providerCapBps[address(provider)] = capBps;
        emit ProviderCapUpdated(address(provider), capBps);
    }

    /**
     * @dev Legacy ABI-compatible self-call target; revokes the saved source rather
     *      than resolving a possibly retargeted registry. Removal now fails closed.
     */
    function revokeStaleApproval(IProvider provider) external {
        if (_msgSender() != address(this)) revert Unauthorized();
        RebalancerStorage storage $ = _getRebalancerStorage();
        $._asset.forceApprove($._providerSources[address(provider)], 0);
    }

    /// @dev Reverts if `provider` holds more than its cap of total assets.
    function _enforceProviderCap(IProvider provider) internal view {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 capBps = $._providerCapBps[address(provider)];
        if (capBps == 0) return;
        (uint256 atProvider,) = _safeGetDepositBalance(provider);
        if (atProvider * BPS > totalAssets() * capBps) {
            revert ProviderCapExceeded(address(provider));
        }
    }

    function _isInList(address provider, IProvider[] memory list) private pure returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (address(list[i]) == provider) return true;
        }
        return false;
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
    function _delegateActionToProvider(uint256 assets, string memory actionName, IProvider provider) internal {
        RebalancerStorage storage $ = _getRebalancerStorage();
        if (provider.getSource(asset(), address(this), address(0)) != $._providerSources[address(provider)]) {
            revert ProviderSourceChanged();
        }
        bytes memory data =
            abi.encodeWithSignature(string(abi.encodePacked(actionName, "(uint256,address)")), assets, address(this));
        address(provider).functionDelegateCall(data);
    }

    /**
     * @dev Returns the total assets of this vault across all listed providers.
     */
    function _totalAssetsAtProviders() internal view returns (uint256 total) {
        bool healthy;
        (total, healthy) = _totalAssetsWithHealth();
        if (!healthy) revert ProviderUnavailable();
    }

    /// @dev Sum of provider balances; `healthy` is false if any view failed.
    function _totalAssetsWithHealth() internal view returns (uint256 total, bool healthy) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        uint256 count = $._providers.length;
        healthy = true;
        for (uint256 i; i < count; i++) {
            (uint256 assetsAtProvider, bool ok) = _safeGetDepositBalance($._providers[i]);
            if (ok) {
                total += assetsAtProvider;
            } else {
                healthy = false;
            }
        }
    }

    /**
     * @dev `getDepositBalance` under a bounded gas stipend; never reverts. A failing
     *      provider reads as (0, false): its funds are temporarily not counted.
     *      The false health bit is mandatory: settlement and public NAV readers
     *      reject incomplete totals rather than irreversibly pricing from zero.
     */
    function _safeGetDepositBalance(IProvider provider) internal view returns (uint256 balance, bool ok) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        address pinned = $._providerSources[address(provider)];
        if (pinned == address(0)) return (0, false);
        try provider.getSource{gas: PROVIDER_VIEW_CALL_GAS}(asset(), address(this), address(0)) returns (
            address current
        ) {
            if (current != pinned) return (0, false);
        } catch {
            return (0, false);
        }
        try provider.getDepositBalance{gas: PROVIDER_VIEW_CALL_GAS}(address(this), this) returns (uint256 bal) {
            return (bal, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @dev Returns true if the specified provider is in the list of providers.
     * @param provider The address of the provider to validate.
     */
    function _validateProvider(address provider) internal view returns (bool valid) {
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

    /// @notice False while any listed provider's balance view fails. Deposits are
    ///         refused and NAV readers must not treat `totalAssets` as complete.
    function providersHealthy() public view returns (bool healthy) {
        (, healthy) = _totalAssetsWithHealth();
    }

    /// @notice Returns a provider's cap as a share of total assets in bps (0 = uncapped)
    function getProviderCap(IProvider provider) public view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._providerCapBps[address(provider)];
    }

    /// @notice Returns the minimum asset amount for deposit and mint actions
    function getMinAssets() public view returns (uint256) {
        RebalancerStorage storage $ = _getRebalancerStorage();
        return $._minAssets;
    }

    function getHighWaterMark() external view returns (uint256) {
        return _getRebalancerStorage()._highWaterMark;
    }

    function getPinnedProviderSource(IProvider provider) external view returns (address) {
        return _getRebalancerStorage()._providerSources[address(provider)];
    }
}
