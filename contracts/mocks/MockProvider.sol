// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IProvider} from "../interfaces/IProvider.sol";
import {IVault} from "../interfaces/IVault.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @title BaseMockProvider
 */
contract BaseMockProvider is IProvider {
    /**
     * @inheritdoc IProvider
     */
    function getIdentifier()
        public
        pure
        virtual
        override
        returns (string memory)
    {
        return "Base_Provider";
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address keyOne,
        address,
        address
    ) external pure override returns (address source) {
        source = keyOne;
    }

    /**
     * @inheritdoc IProvider
     */
    function deposit(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        MockERC20 token = MockERC20(vault.asset());
        try
            token.depositTokens(address(vault), amount, getIdentifier())
        returns (bool result) {
            success = result;
        } catch {}
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        MockERC20 token = MockERC20(vault.asset());
        try
            token.withdrawTokens(address(vault), amount, getIdentifier())
        returns (bool result) {
            success = result;
        } catch {}
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(
        IVault
    ) external pure override returns (uint256 rate) {
        rate = 1e27;
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositBalance(
        address user,
        IVault vault
    ) external view override returns (uint256 balance) {
        balance = MockERC20(vault.asset()).depositBalance(
            user,
            getIdentifier()
        );
    }
}

/**
 * @title MockProviderA
 */
contract MockProviderA is BaseMockProvider {
    function getIdentifier() public pure override returns (string memory) {
        return "Provider_A";
    }
}

/**
 * @title MockProviderB
 */
contract MockProviderB is BaseMockProvider {
    function getIdentifier() public pure override returns (string memory) {
        return "Provider_B";
    }
}

/**
 * @title MockProviderC
 */
contract MockProviderC is BaseMockProvider {
    function getIdentifier() public pure override returns (string memory) {
        return "Provider_C";
    }
}

/**
 * @title InvalidProvider
 */
contract InvalidProvider is BaseMockProvider {
    function getIdentifier() public pure override returns (string memory) {
        return "Invalid_Provider";
    }
}
