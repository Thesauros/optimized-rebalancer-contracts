// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITickAccountant} from "./interfaces/ITickAccountant.sol";
import {IEpochVault} from "./interfaces/IEpochVault.sol";
import {IEpochVaultAccounting} from "./interfaces/IEpochVaultAccounting.sol";

/**
 * @title EpochVaultStorage
 * @notice The EpochVault's ERC-7201 layout, shared by the vault and by the
 *         `EpochVaultLogic` library that operates on it under delegatecall.
 * @dev Append-only. Field order is part of the upgrade contract of the vault.
 */
library EpochVaultStorage {
    /// @custom:storage-location erc7201:thesauros.storage.EpochVault
    struct Layout {
        IERC20Metadata asset;
        uint8 decimals;
        ITickAccountant accountant;
        address hubAgent;
        address timelock;
        uint256 paused;
        // accounting
        uint256 cash;
        uint256 pendingDeposits;
        uint256 liabilities;
        uint256 reserved;
        uint256 escrowRedeemShares;
        uint256 unclaimedDepositShares;
        IEpochVaultAccounting.Checkpoint[] checkpoints;
        // epochs
        uint64 currentEpoch;
        uint64 nextDepositClear;
        uint64 nextRedeemClear;
        uint64 nextFund;
        IEpochVault.EpochConfig epochConfig;
        mapping(uint64 epoch => IEpochVault.Epoch) epochs;
        // requests
        uint256 nextRequestId;
        mapping(uint256 requestId => IEpochVault.Request) requests;
        // limits
        IEpochVault.Limits limits;
        uint128 instantLevel;
        uint64 instantUpdatedAt;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.EpochVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x7b80b62495198692ae2748b2cdafbaec6bff4d8db0d1e8fb8ff543cac4ce2f00;

    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := LOCATION
        }
    }
}
