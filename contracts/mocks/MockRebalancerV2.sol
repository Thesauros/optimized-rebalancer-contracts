// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Rebalancer} from "../Rebalancer.sol";

/**
 * @title MockRebalancerV2
 */
contract MockRebalancerV2 is Rebalancer {
    constructor() {
        // intentionally left blank
    }

    /// @dev Re-initializes the vault
    function initializeV2() external reinitializer(2) {
        // intentionally left blank
    }
}
