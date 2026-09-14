// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../../interfaces/IProvider.sol";

interface IMeshCustodian {
    error Unauthorized();
    error UnknownSource();
    error DeployFailed();
    error ZeroAmount();

    event BridgeInReceived(uint64 indexed srcChainId, uint256 amount, bytes32 transferId);
    event DeployedToProvider(address indexed provider, uint256 amount);
    event WithdrawnFromProvider(address indexed provider, uint256 amount);
    event BridgeOutInitiated(uint64 indexed destChainId, uint256 amount, bytes32 transferId);

    function onBridgeIn(uint64 srcChainId, uint256 amount, bytes32 transferId) external;
    function deployToProvider(IProvider provider, uint256 amount) external;
    function withdrawFromProvider(IProvider provider, uint256 amount) external returns (uint256 actual);
    function getProviderBalance(IProvider provider) external view returns (uint256);
    function getTotalValue() external view returns (uint256);
}
