// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IBridgeAdapter
 * @notice Transport boundary between ChainAgents. Core accounting sees only
 *         transfer ids and balance deltas the agent measures itself.
 *
 * @dev Requirements on every implementation:
 *      - `send` and `finalize` are callable only by the adapter's own agent;
 *      - `send` pulls exactly `amount` of the asset from the agent and binds
 *        `transferId` and the source agent to the message;
 *      - `finalize` authenticates the message (origin chain, origin adapter),
 *        delivers the minted/unlocked asset to the agent, and returns the ids
 *        carried by the message. Nobody else may be able to deliver a message to
 *        the agent, otherwise funds could arrive without being recorded and be
 *        counted twice (in flight on the source and idle on the destination).
 */
interface IBridgeAdapter {
    function asset() external view returns (address);

    function send(
        bytes32 transferId,
        uint256 amount,
        uint64 dstChainId,
        address dstAgent,
        uint256 minReceive
    ) external payable;

    function finalize(
        bytes calldata payload
    ) external returns (bytes32 transferId, uint64 srcChainId, address srcAgent);
}
