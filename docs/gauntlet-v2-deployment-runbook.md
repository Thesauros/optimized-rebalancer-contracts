# Gauntlet V2 deployment package

Preparation only. No transaction is signed or sent by the preparation command.
The provider implementation is the version reviewed in `1b3f1ea`, on
`feat/gauntlet-v2-provider`, based on `feat/crosschain-tick-epoch`.

## Prepared targets

| Network | Morpho V2 source | Registration target | Profile |
| --- | --- | --- | --- |
| Base | `0x050cE30b927Da55177A4914EC73480238BAD56f0` | `0x3C7739173cca612B6394EE57131458185A5beC44` | Existing main USDC vault |
| Base | same source/provider | `0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33` | Crosschain Strategy, **stand** |
| Ethereum | `0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0` | `0xc3156Da39EeEa9De80F1d74b497C0E4A7030Aae3` | Existing main USDC vault |

One provider per chain can serve both Base registration targets. Review each
target independently; the stand is not a production deployment. IProvider
registration belongs to its Strategy Rebalancer, not to the EpochVault.

## 1. Refresh preparation without sending anything

Use the installed lockfile dependencies and the pinned Solidity 0.8.33 toolchain.
`BASE_RPC_URL`, `ETHEREUM_RPC_URL` and the future `ETHERSCAN_API_KEY` are already
supported by `.env`. Do not put credentials in the bundle or in Git.

```sh
FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile
npm run test:deploy
npx tsc --noEmit
npm run prepare:gauntlet-v2 -- --network all \
  --deployer 0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D
```

The command creates a new dated folder in `deployments/plans/`; `--out NEW_PATH`
selects an explicit unused path. Existing folders are never overwritten.
Exit 0 means preparation has no deployment blockers at its snapshot; exit 2
means a bundle exists with disclosed blockers; exit 1 means preparation failed.

The generator uses only a public deployer address. It does not read private keys,
create a signer, or import an executable deployment script. RPC methods are
allowlisted at both the provider and transport boundaries. Signing, transaction
sends, unlocked accounts and node state mutation methods are rejected.

Each bundle contains:

- `manifest.json`: generation time, Git/compiler settings, source/input hashes.
- `artifact.json`: ABI, creation bytecode and runtime template.
- `standard-json-input.json`: compiler input for reproducible verification.
- `base.json` / `mainnet.json`: block snapshot, source/adapter hashes, nonce,
  provisional CREATE address, immutable runtime hash, gas/funding data and an
  unsigned creation transaction. Each target has its own unsigned timelock plan.

Constructor simulation is an `eth_call` with creation data. Registration/APR
simulations temporarily supply the candidate runtime through the RPC's state
override parameter. Those overrides exist only for that call: no contract is
deployed and no approval or queue entry persists.

## 2. Resolve the recorded blockers before a future deployment

The prepared snapshots show insufficient deployer ETH on both networks. The
report's `funding.maxExecutionCostWei` includes a 25% gas-limit margin and the RPC
max-fee estimate **for the provider deployment only**. Base L1 data fees and
later governance/activation transactions need additional ETH. Fees change; refresh
the report after funding and immediately before an approved deployment.

Funding, deploying, queueing, executing and moving funds are separate actions
requiring the user's authorization. None is part of this preparation task.

Check that the deployer has no pending transaction and avoid concurrent use of
that EOA while deploying. CREATE addresses depend on the nonce. A predicted
address is provisional and must never be treated as an existing contract.
Inspect any existing `GauntletPrimeV2MorphoProvider` record before a repeat deploy.

## 3. Future provider deployment and verification

Only after explicit deployment authorization, use the isolated provider directory:

```sh
FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat deploy \
  --deploy-scripts deploy/providers --tags gauntlet-v2-provider --network base
# Ethereum uses --network mainnet
```

`DRY_RUN=1` deliberately refuses these live-network commands. Local rehearsal uses
the in-process `hardhat` network; it is not required to prepare this package.
Do not use the full `usdc-vault` deployment command for an existing initialized
vault. Do not omit `--deploy-scripts`: the general deploy tree also contains
self-executing crosschain operational scripts.

Read the actual address and receipt from the newly generated
`deployments/<network>/GauntletPrimeV2MorphoProvider.json`. Confirm receipt success
and deployed code. Explorer verification must succeed separately: the existing
shared verify helper logs errors instead of throwing. Each report includes an
exact `verificationCommand` with the constructor source address and fully
qualified contract name; substitute the actual deployed address.

## 4. Regenerate registration against the actual deployed address

This remains read-only and does not register anything:

```sh
npm run prepare:gauntlet-v2 -- --network base \
  --deployer 0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D \
  --provider ACTUAL_DEPLOYED_BASE_PROVIDER
# Repeat for --network mainnet with its actual provider address.
```

`--provider` requires exactly one network. It verifies the deployed runtime
against the compiled immutable candidate, then checks the provider identifier
and approval source. A missing/wrong contract is refused. This mode generates
registration proposals for that verified address, not a prediction for the next
nonce. Select only intended targets and require their gates/simulations to pass.

Each registration proposal preserves every current provider in its existing
order and appends V2. Timelock owner, delay, complete before/after arrays, operation
hash and unsigned `queue`, `execute`, `cancel` requests are in the target report.
The ETA includes the live delay plus one hour for queueing; regenerate if the
queueing window is missed. At the recorded snapshot, normal vaults have a one-hour
delay and the Base stand Strategy has a 24-hour delay; always use the live report.

Submit a queue only through the recorded timelock owner. Once queued, retain that
exact tuple, hash and ETA for execute/cancel; do not regenerate it to execute an
already queued operation. Before execution, re-read the provider list, entry,
gates and timelock ownership. If the current list differs from `proposal.before`,
cancel/reprepare rather than overwriting later governance changes.

## 5. Activation and rollback are separate decisions

Registration alone does not change the entry provider or move funds. The optional
`setEntryProvider` data requires an account with `ADMIN_ROLE` after registration;
the report checks the known treasury and timelock-owner candidates. Do not assume
the deployer, treasury and administrator are the same account.

Before an explicitly authorized activation, check current caps and ordinary exit
liquidity, then perform a chosen canary deposit/withdrawal and verify native
receipt ownership, NAV and provider health. No canary amount or bulk migration is
preauthorized here. Core V1 and Prime V2 have different strategy configurations;
review that change before moving a Core position.

For rollback before activation, retain the old entry and cancel an unwanted queue
with the original tuple. After funds are allocated, an authorized executor must
withdraw/rebalance within available liquidity before a provider is removed. Keep
all funded V1/V2 providers registered. The known partial-liquidity aggregation
limitation remains: a large exit can require smaller requests even when several
sources have enough liquidity in aggregate. Forced deallocation is not automatic.
