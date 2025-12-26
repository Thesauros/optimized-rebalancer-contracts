// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IProvider} from "../interfaces/IProvider.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IProviderManager} from "../interfaces/IProviderManager.sol";
import {CometInterface} from "../interfaces/compoundV3/CometInterface.sol";

/**
 * @title CompoundV3Provider
 * @notice Provider implementation for Compound V3 (Comet) protocol integration
 * @dev This provider integrates with Compound V3's Comet lending protocol to provide
 *      yield generation through supply-side lending operations with enhanced efficiency.
 * 
 * @custom:integration The provider works with Compound V3 by:
 * - Supplying assets to the Comet lending market
 * - Earning interest from borrowers through supply APY
 * - Supporting multiple assets through ProviderManager configuration
 * - Leveraging Compound's efficient monolithic money market design
 * 
 * @custom:yield-mechanism Yield generation through:
 * - Supply APY from borrowers paying interest
 * - Compound's efficient interest rate models
 * - Automatic yield accrual through supply balances
 * - Optimized gas usage and capital efficiency
 * 
 * @custom:security Features:
 * - Uses Compound V3's audited Comet protocol
 * - Integrates with ProviderManager for asset configuration
 * - Implements proper access controls through IProvider interface
 * - Supports emergency pause mechanisms
 * 
 * @custom:usage Example:
 * ```solidity
 * // Deploy with ProviderManager address
 * CompoundV3Provider provider = new CompoundV3Provider(providerManager);
 * 
 * // Configure assets in ProviderManager first
 * providerManager.setYieldToken("CompoundV3_Provider", usdc, comet);
 * 
 * // The vault can now deposit/withdraw through this provider
 * provider.deposit(amount, vault);
 * uint256 balance = provider.getDepositBalance(user, vault);
 * uint256 apy = provider.getDepositRate(vault);
 * ```
 */
contract CompoundV3Provider is IProvider {
    /**
     * @dev Errors
     */
    error CompoundV3Provider__AddressZero();

    IProviderManager private immutable _providerManager;

    constructor(address providerManager_) {
        if (providerManager_ == address(0)) {
            revert CompoundV3Provider__AddressZero();
        }
        _providerManager = IProviderManager(providerManager_);
    }

    /**
     * @inheritdoc IProvider
     */
    function deposit(
        uint256 amount,
        IVault vault
    ) external returns (bool success) {
        CometInterface comet = _getComet(vault);
        comet.supply(vault.asset(), amount);
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IVault vault
    ) external returns (bool success) {
        CometInterface comet = _getComet(vault);
        comet.withdraw(vault.asset(), amount);
        success = true;
    }

    /**
     * @dev Returns the Comet contract of Compound V3 for the specified vault.
     * @param vault The vault for which to get the Comet contract.
     */
    function _getComet(IVault vault) internal view returns (CometInterface) {
        // From Compound docs: Earn interest by supplying the base asset.
        address comet = _providerManager.getYieldToken(
            getIdentifier(),
            vault.asset()
        );
        return CometInterface(comet);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositBalance(
        address user,
        IVault vault
    ) external view returns (uint256 balance) {
        CometInterface comet = _getComet(vault);
        balance = comet.balanceOf(user);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(IVault vault) external view returns (uint256 rate) {
        CometInterface comet = _getComet(vault);
        uint256 utilization = comet.getUtilization();
        // Scaled by 1e9 to return ray(1e27) per IProvider specs, Compound uses base 1e18 number.
        uint256 ratePerSecond = comet.getSupplyRate(utilization) * 10 ** 9;
        // 31536000 seconds in a `year` = 60 * 60 * 24 * 365.
        rate = ratePerSecond * 31536000;
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address asset,
        address,
        address
    ) external view returns (address source) {
        source = _providerManager.getYieldToken(getIdentifier(), asset);
    }

    /**
     * @notice Returns the ProviderManager contract applicable to this provider.
     */
    function getProviderManager() public view returns (IProviderManager) {
        return _providerManager;
    }

    /**
     * @inheritdoc IProvider
     */
    function getIdentifier() public pure override returns (string memory) {
        return "Compound_V3_Provider";
    }
}
