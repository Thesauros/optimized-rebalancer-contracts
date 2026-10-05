// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ICustodianProvider} from "./ICustodianProvider.sol";

interface IMeshCustodian {
    error Unauthorized();
    error UnknownSource();
    error InvalidConfiguration();
    error ZeroAmount();
    error Paused();
    error UnexpectedTokenAmount();

    event GovernanceUpdated(address indexed governance);
    event RolesUpdated(address indexed executor, address indexed guardian);
    event PauseUpdated(bool paused);
    event AdapterTrusted(address indexed adapter, bool trusted);
    event ProviderAllowed(address indexed provider, bool allowed);
    event BridgeInReceived(uint64 indexed srcChainId, uint256 amount, bytes32 indexed transferId);
    event DeployedToProvider(address indexed provider, uint256 amount);
    event WithdrawnFromProvider(address indexed provider, uint256 actual);
    event BridgeOutInitiated(uint64 indexed destChainId, uint256 spent, bytes32 indexed transferId);

    function onBridgeIn(uint64 srcChainId, uint256 amount, bytes32 transferId) external;
    function deployToProvider(ICustodianProvider provider, uint256 amount) external;
    function withdrawFromProvider(ICustodianProvider provider, uint256 amount) external returns (uint256 actual);
    function getProviderBalance(ICustodianProvider provider) external view returns (uint256);
    function getTotalValue() external view returns (uint256);
    function getLiquidValue() external view returns (uint256);
}
