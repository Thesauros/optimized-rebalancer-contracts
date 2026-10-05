# Changes: 2026-09-15 — CCTP V2 Bridge Integration

**Branch:** `crosschain-sandbox`
**Date:** 2026-09-15
**Author:** cto-agent

## Summary

Full CCTP V2 (Circle Cross-Chain Transfer Protocol) bridge integration for
USDC transfers between Base and Arbitrum. Implements the authenticated bridge
adapter specified in the crosschain-liquidity-mesh spec.

## New Contracts

### `contracts/crosschain/bridges/ITokenMessengerV2.sol`
CCTP V2 interfaces:
- `ITokenMessengerV2` — burn side (`depositForBurn` V1 + V2 signatures)
- `IMessageTransmitterV2` — receive side (`receiveMessage`)

### `contracts/crosschain/bridges/CCTPMeshBridgeAdapter.sol`
Implements `IMeshBridgeAdapter` using CCTP V2:
- `send()` burns USDC via `TokenMessengerV2.depositForBurn`
- Returns `credited = amount` (CCTP standard transfers have no protocol fee)
- Stores `transferId -> nonce` mapping for relay tracking
- Emits `CCTPBurn` event for keeper monitoring
- Governance can update `relayPeer` (destination relay address)

### `contracts/crosschain/bridges/CCTPRelayReceiver.sol`
Receives minted USDC from CCTP and delivers to target:
- **MODE_CUSTODIAN (0)**: calls `MeshCustodian.onBridgeIn` (destination chain)
- **MODE_NODE (1)**: calls `MeshNode.receiveReturn` (source chain, return path)
- Only authorized keeper can call `deliver()`
- `deliver()` submits attestation to MessageTransmitter, then forwards minted USDC
- Governance can update keeper and rescue stuck tokens

## New Scripts

### `scripts/DeployCCTPBridge.s.sol`
Foundry deploy script for bridge infrastructure:
- Deploys `CCTPRelayReceiver` + `CCTPMeshBridgeAdapter` on each chain
- Uses CCTP V2 mainnet addresses (deterministic across all chains):
  - TokenMessenger: `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d`
  - MessageTransmitter: `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64`

### `scripts/cctp-relay-keeper.ts`
TypeScript keeper for attestation relay:
- Watches `CCTPBurn` events on source chain adapter
- Polls Circle's Iris attestation API (`https://iris-api.circle.com/v2`)
- Calls `relay.deliver()` on destination chain when attestation is available
- Configurable poll interval, domains, and API endpoint

## New Tests

### `test/crosschain/CCTPBridge.t.sol` — 9 tests
- `testAdapterBurnsViaCCTP` — adapter burns USDC, stores nonce
- `testAdapterRejectsZeroAmount` — zero amount reverts
- `testGovernanceCanUpdateRelayPeer` — governance updates relay peer
- `testNonGovernanceCannotUpdateRelayPeer` — access control
- `testRelayDeliversToCustodian` — relay delivers minted USDC to custodian
- `testRelayRejectsNonKeeper` — only keeper can deliver
- `testGovernanceCanUpdateKeeper` — governance updates keeper
- `testRelayRescue` — governance rescues stuck tokens
- `testFullCCTPCycle` — complete burn -> mint -> deliver -> bridgeBack cycle

## Architecture

```
Base (domain 6)                          Arbitrum (domain 3)
┌──────────────────────────┐             ┌──────────────────────────┐
│ MeshNode                 │             │ MeshCustodian            │
│   ↓ bridgeOut            │             │   ↑ onBridgeIn           │
│ CCTPMeshBridgeAdapter    │   CCTP V2   │ CCTPRelayReceiver        │
│   ↓ depositForBurn       │ ──────────> │   (MODE_CUSTODIAN)       │
│   (burns USDC)           │  burn/mint  │   ↑ receiveMessage       │
│                          │             │   (mints USDC to relay)  │
│ CCTPRelayReceiver        │   CCTP V2   │ CCTPMeshBridgeAdapter    │
│   (MODE_NODE)            │ <────────── │   ↓ depositForBurn       │
│   ↑ receiveMessage       │  burn/mint  │   (burns USDC)           │
│   (mints USDC to relay)  │             │   ↑ bridgeBack           │
│   ↓ receiveReturn        │             │ MeshCustodian            │
│ MeshNode                 │             │                          │
└──────────────────────────┘             └──────────────────────────┘
         ↑                                         ↑
    cctp-relay-keeper.ts                    cctp-relay-keeper.ts
    (polls attestation API)                 (polls attestation API)
```

## CCTP V2 Details

- **Domain IDs**: Base = 6, Arbitrum = 3 (NOT chain IDs)
- **Standard transfer**: no protocol fee, `credited = amount`
- **Attestation**: Circle's Iris service, ~1-3 min for Fast Transfer
- **MessageTransmitter.receiveMessage**: verifies attestation signatures, prevents replay
- **mintRecipient**: the CCTPRelayReceiver on the destination chain

## Deployment Order

1. Deploy MeshNode + MeshCustodian (existing `DeployCrosschainStand.s.sol`)
2. Deploy CCTPRelayReceiver on each chain (needs target contract address)
3. Deploy CCTPMeshBridgeAdapter on each chain (needs relay peer address)
4. Configure MeshNode: `addRoute(routeId, adapterAddr, destChainId, custodianPeer, maxInFlight, 0)`
5. Configure MeshCustodian: `trustAdapter(relayAddr, true)` + `trustAdapter(adapterAddr, true)`
6. Start relay keeper on both chains

## Test Results

```
CCTPBridge.t.sol: 9 passed, 0 failed
Full suite: 82 passed, 0 failed (73 existing + 9 new)
forge build: clean
```

## Security Notes

- Relay keeper is the only address that can call `deliver()` — compromise = stuck funds (not stolen)
- CCTP attestation is verified by MessageTransmitter (Circle's signature threshold)
- Replay protection: MessageTransmitter tracks used nonces per source domain
- Adapter stores transferId -> nonce mapping for audit trail
- Relay uses `forceApprove` + immediate clear to minimize approval window
- Governance can rescue stuck tokens from relay

## Next Steps

1. Deploy bridge infrastructure on mainnet (Base + Arbitrum)
2. Start relay keeper
3. Execute canary with $10 USDC
4. Verify full cycle accounting
5. Scale canary: $100 -> $1000 -> $10k
