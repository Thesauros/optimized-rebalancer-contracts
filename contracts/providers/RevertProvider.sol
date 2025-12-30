// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV3Vault} from "../interfaces/revert/IV3Vault.sol";
import {IInterestRateModel} from "../interfaces/revert/IInterestRateModel.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title RevertProvider
 */
contract RevertProvider is IProvider {
    /**
     * @inheritdoc IProvider
     */
    function deposit(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        IV3Vault v = _getV3Vault();
        v.deposit(amount, address(vault));
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        IV3Vault v = _getV3Vault();
        v.withdraw(amount, address(vault), address(vault));
        success = true;
    }

    /**
     * @dev Returns the V3Vault contract of Revert.
     */
    function _getV3Vault() internal pure returns (IV3Vault) {
        return IV3Vault(0x74E6AFeF5705BEb126C6d3Bf46f8fad8F3e07825);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositBalance(
        address user,
        IVault
    ) external view override returns (uint256 balance) {
        IV3Vault v = _getV3Vault();
        balance = v.lendInfo(user);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(
        IVault
    ) external view override returns (uint256 rate) {
        IV3Vault v = _getV3Vault();
        (uint256 debt, , uint256 balance, , , ) = v.vaultInfo();

        IInterestRateModel irm = v.interestRateModel();
        uint32 reserveFactorX32 = v.reserveFactorX32();

        (, uint256 supplyRateX64) = irm.getRatesPerSecondX64(balance, debt);

        uint256 q32 = 2 ** 32;
        uint256 q64 = 2 ** 64;
        supplyRateX64 = Math.mulDiv(supplyRateX64, q32 - reserveFactorX32, q32);

        // Scaled to return ray(1e27) per IProvider specs
        rate = (supplyRateX64 * irm.YEAR_SECS() * 1e27) / q64;
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address,
        address,
        address
    ) external pure override returns (address source) {
        source = address(_getV3Vault());
    }

    /**
     * @inheritdoc IProvider
     */
    function getIdentifier() public pure override returns (string memory) {
        return "Revert_Provider";
    }
}
