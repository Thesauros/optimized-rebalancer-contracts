// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {MockProtocol} from "./MockProtocol.sol";

/**
 * @title MockProvider
 */
contract MockProvider is IProvider {
    MockProtocol private immutable _protocol;

    constructor(MockProtocol protocol_) {
        _protocol = protocol_;
    }

    /**
     * @inheritdoc IProvider
     */

    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _protocol.supply(amount, address(vault));
        return true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _protocol.withdraw(amount, address(vault));
        return true;
    }

    function getDepositBalance(
        address user,
        IRebalancer
    ) external view override returns (uint256 balance) {
        return _protocol.balances(user);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(
        IRebalancer
    ) external pure override returns (uint256 rate) {
        rate = 1e27;
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address,
        address,
        address
    ) external view override returns (address source) {
        return address(_protocol);
    }

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
        return "Mock_Provider";
    }
}
