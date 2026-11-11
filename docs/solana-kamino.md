# Solana / Kamino USDC spoke

Change: `solana-kamino-crosschain`. Specification and architecture decision:
[`spec.md`](../specs/solana-kamino-crosschain/spec.md),
[`design.md`](../specs/solana-kamino-crosschain/design.md).

## Capital and authority

Users continue to request deposits/redemptions and receive USDC from the Base
EpochVault. The capital path is:

```text
Base EpochVault → Base ChainAgent → CctpSolanaAdapter
    → Circle CCTP V2 → Solana agent PDA / idle USDC token account
    → Kamino reserve → agent-owned collateral token account
    → redeem collateral → idle USDC → CCTP → Base ChainAgent → EpochVault
```

No user vault, user share token, obligation, loan or leverage is created on
Solana. The executor pays SOL transaction fees; it never owns the strategy's
USDC or cTokens. The agent signs CPIs using its PDA seeds. Strategy accounts,
program, liquidity mint/supply, market authority and destinations are fixed by
governance. Receives and redemptions remain available during an allocation/send
pause. New agents start paused.

The native registry is `deploy/crosschain/native-registry.ts`; EVM entries in
`registry.ts` have `family: 'evm'`. Native RPC, addresses and signing keys never
enter ethers/Hardhat network configuration. Mainnet is CAIP-2
`solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp`; the **full** genesis hash is separately
verified. `0x8000000000000005` is an internal uint64 accounting identifier, not
an EVM chain ID. CCTP uses Solana domain 5 and Base domain 6, finalized at 2000.

The existing hub's v1 snapshot and ChainAgent ABI stay unchanged. The hub uses
`last20(keccak256("thesauros.solana.identity.v1:" || full_public_key))` as a
registered accounting alias. The native bridge authenticates the full public
key before returning its alias. A Solana address is never truncated into an EVM
address or used as an ethers contract target.

## Deployment preparation

The repository contains source and tests, **no live Solana deployment manifest**.
The source program ID identifies this build; before first deployment, generate
the deployment keypair securely, update `declare_id!`, rebuild and rerun the VM
tests with the intended ID. Put program upgrade authority and native governance
under the reviewed timelocked multisig PDA. EOAs in the local VM tests are test
identities, not a production governance recommendation.

1. Prepare a native manifest matching the `SolanaManifest` interface. Include
   `family`, `network`, reviewed program ID, bytes32 seed, derived agent/idle PDAs,
   Base hub agent and new native adapter addresses, checkpoint freshness limit,
   `programDataSha256`, and explicit `{ protocol: 'kamino-lending', reserve, market }` definitions.
   The digest covers deployed ProgramData bytes after the 45-byte upgradeable
   loader header, including reserved zero padding; verify it against the reviewed
   build. Native readers check that digest at startup and periodically.
   Start with the main-market USDC reserve in the native registry or a separately
   reviewed USDC reserve. Check owner, mint, market and native token program.
2. Prepare a public JSON configuration for `prepare`/`plan`: `governance`,
   `executor`, `guardian`, `maxPerTransfer`, `capacity`, `refillPerSecond`,
   `maxFeeBps`, `strategyCaps` keyed by reserve. Amounts/caps are integer strings
   in **USDC micro-units**; identities are public keys, never private keys.
3. `npm run solana -- prepare public-config.json` prints unsigned native
   initialization, collateral ATA and strategy registration instructions. It
   also prepares the address lookup table needed for atomic CCTP receipt plus
   checkpoint. Lookup table creation uses a recent slot: regenerate immediately
   before execution, execute extension batches in order, then wait for activation
   and finalization. Set `SOLANA_LOOKUP_TABLES` to the resulting table address.
4. `npm run solana -- plan public-config.json` prints the EVM native adapter's
   constructor parameters and unsigned Base Timelock calldata for adapter, peer,
   route and accountant registration. Deploy/verify the adapter, native agent,
   strategies and first checkpoint before activating the hub chain set. The
   native adapter's endpoints are immutable: a different endpoint needs a new
   adapter/route and a reviewed migration.
5. Verify full remote keys, runtime code, native governance/upgrade authority,
   route limits, aliases, RPC genesis, lookup table, funded gas accounts, source
   index and observer/relayer readiness. Activate the native chain in the Base
   accountant, then unpause the native agent through its governance. Run a
   separately authorized capped round trip and full unwind before raising limits.

Production activation is a distinct operation. These preparation commands sign
and send nothing.

## Environment and operators

The Solana integration is enabled only by setting `CROSSCHAIN_SOLANA_MANIFEST`.
An accountant tracking Solana without its configured native reader fails closed.

| Variable | Purpose |
|---|---|
| `CROSSCHAIN_SOLANA_MANIFEST` | Native manifest JSON path. |
| `RPC_SOLANA` | Solana RPC with finalized blocks and historical transaction support. |
| `RPC_SEND_SOLANA` | Optional native broadcast endpoint; genesis must match the read RPC. |
| `SOLANA_EXECUTOR_KEYPAIR` | JSON keypair **file path** for native allocation, redemption and burn. |
| `SOLANA_RELAYER_KEYPAIR` | Gas payer file for permissionless native receipt. |
| `SOLANA_CHECKPOINT_KEYPAIR` | Gas payer file for permissionless observation. |
| `SOLANA_LOOKUP_TABLES` | Comma-separated activated lookup tables. |
| `SOLANA_TX_JOURNAL_DIR` | Durable directory for signed transaction reconciliation. |
| `SOLANA_CHECKPOINT_DB` | Durable SQLite checkpoint cache, e.g. `/data/solana-checkpoints.sqlite`. |
| `SOLANA_RPC_TIMEOUT_MS` | Native RPC timeout; default 15,000 ms. |
| `SOLANA_OBSERVE_SECONDS` | Observer poll period; default 60 seconds. |
| `SOLANA_MIN_OBSERVE_INTERVAL_SECONDS` | Minimum observation spacing when a NAV is due; default min(180, freshness/2). |

EVM roles keep their existing `*_PRIVATE_KEY` variables. Native keys are separate
Ed25519 files. Mount public manifests to all accounting readers; mount key files
read-only only to services that need the corresponding signer. The Docker image
includes native runtime/dependencies; mount the native manifest and keys at the
paths named in the environment, and persist `/data`.

`ops/docker-compose.yml` carries that wiring. The native services live behind an
extra profile, so an EVM-only stand is unaffected:

```sh
docker compose -f ops/docker-compose.yml --profile stand --profile solana up -d --build
```

| Host path (variable, default) | Container path | Mounted into |
|---|---|---|
| `ops/config/solana` (`SOLANA_CONFIG_DIR`) | `/config/solana`, read-only | every service: `monitor` and `indexer` verify Ticks, so they are accounting readers too |
| `ops/keys/solana-checkpoint.json` (`SOLANA_KEYS_DIR`) | `/keys/solana-checkpoint.json`, read-only | `solana-observer`, `preflight`, `solana-cli` |
| `ops/keys/solana-relayer.json` | `/keys/solana-relayer.json`, read-only | `relayer`, `operators`, `preflight`, `solana-cli` |
| `ops/keys/solana-executor.json` | `/keys/solana-executor.json`, read-only | `preflight`, `solana-cli` |

Each keypair is mounted as its own file rather than as one `/keys` directory, so
a service cannot read a signer it does not use: `monitor` and `indexer` stay
keyless, `nav` and `keeper` read native state without a native key, and
`solana-observer` signs natively only — it receives the keypair *path* from
compose and not `.env.keys`, which also holds the EVM keys. The container paths
are fixed and are the ones `ops/.env.keys.example` names; only the host side is
configurable. Create `ops/keys` with the three JSON files (`chmod 600`) before
enabling the profile: Docker turns a missing bind source into an empty
directory, and preflight then fails on an unreadable keypair instead of a service
starting without one. `SOLANA_CHECKPOINT_DB`
and `SOLANA_TX_JOURNAL_DIR` belong under `/data`, the persisted `ops-data`
volume. The observer serves `/health` and `/status` on 127.0.0.1:8086
(`PORT_SOLANA_OBSERVER`), and it is unhealthy once no checkpoint has succeeded
within `maxCheckpointAgeSeconds` — the same window NAV enforces.

`solana-cli` is the operator CLI from the previous section, on demand:

```sh
docker compose -f ops/docker-compose.yml --profile tools run --rm solana-cli rates
docker compose -f ops/docker-compose.yml --profile tools run --rm solana-cli allocate 0 10 --yes
```

It takes `.env.keys` because `bridge-in` also signs on Base as the executor.
`docs/crosschain-server.md` describes the EVM-only stack and predates this
profile; its container table does not list the two native services yet.

From `ops/`:

```sh
npm run solana -- rates
npm run solana -- status
npm run solana -- observe
npm run solana -- bridge-in 10
npm run solana -- allocate 0 10
npm run solana -- withdraw 0 5
npm run solana -- redeem-all 0
npm run solana -- bridge 10
npm run solana -- receive attestation.json
npm run solana:observer
```

Operator writes simulate by default; append `--yes` to explicitly broadcast.
The observer and existing relayer are continuous signing services, enabled only
after configuration and operational authorization. The relayer handles both
Base→Solana and Solana→Base using Circle Iris. Local EVM attestation mode is
rejected for native routes. Public `rates` discovery needs only `RPC_SOLANA`.

`bridge-in` and `bridge` optionally take a second USDC amount for minimum
receive. Full principal is the conservative default; a nonzero protocol fee
requires an explicit lower minimum within the reviewed route fee cap. Partial
withdrawal rounds required cToken units up and enforces received USDC. Full
redemption sells all actual cToken units with a 10-bps quoted output tolerance.
Available lending liquidity is read and checked before redemption.

An ambiguous broadcast retains the exact signed bytes and signature in the
journal. Retrying that operation resends the same transaction. Expired,
unresolved records require reconciliation with the chain and checkpoint before
replacement; never initiate another burn to repair a receive failure. Permanent
on-chain transfer IDs/receipts remain the accounting source of truth.

Governance can append a bounded write-down history using `write_down`, referencing
the original outbound checkpoint. Total loss cannot exceed sent principal.
Historical snapshots apply only entries at or before their cut. A later bridge
receipt books actual recovered USDC under the original transfer ID.

## Valuation, history and scaling

Current position and APR/APY use actual reserve, market and token-account data.
SDK reserve math reads utilization, rate curve, fees, reward budget and market
reward cap. Farm rewards are not reported as earned: this strategy holds reserve
cTokens without staking an obligation in farms. Borrow-interest APY and reserve
reward APR are reported separately. No position, exchange rate or yield is
configured as a constant.

Historical NAV uses immutable on-chain checkpoints created **inside every capital
movement**, after refresh and measured token deltas. Standard Solana RPC cannot
read historical accounts; it is not given a fictitious EVM `blockTag`. Native
checkpoints, transfer receipts and finalized block hashes participate in the
existing consistent-cut algorithm. A receipt with an unconfirmed/unreferenced
source remains in flight. Missing/stale observations stop a new Tick; there is
no zero-value fallback. Independent Tick verification reconstructs the native
positions at the committed slots.

The observer creates checkpoints when the hub's NAV cadence or closed-epoch
settlement requires one, with spacing to avoid paying rent for unused idle
minute-by-minute snapshots. Checkpoint allocation is exactly `133 + 49*N` bytes
for N strategies; gas payers fund account rent. Budget rent against expected
movement/NAV frequency before activation. Checkpoints are permanent in this
version; the SQLite cache avoids replaying the growing RPC history at every
restart. Do not delete on-chain checkpoints or use a cache from another genesis,
program or agent. CCTP event-account rent reclamation can be handled separately
through Circle's supported operator flow.

A checkpoint position carries an `observation_failed` flag. Receive and Observe
tolerate a reserve that cannot be refreshed or valued, so a dead Kamino reserve
cannot strand an inbound transfer, and record `value: 0` with that flag set. Zero
then means unknown, not free: NAV refuses to price the cut while any position with
units carries the flag, and the spoke halts rather than under-reports. Retire the
strategy once its collateral is empty to clear it. A reserve passed read-only is
rejected up front rather than tolerated, so a permissionless Receive or Observe
cannot set that flag on a checkpoint by handing it accounts the refresh CPI cannot
write.

The cache is a trusted accounting input, so it is protected like one. The reader
creates the file `0600` and its directory `0700`, tightens an existing
world-readable file in place, and applies the same mode to the WAL sidecars,
which hold the same rows. Cached amounts are what a NAV hash prices, and nothing
in the checkpoint format authenticates them: the discriminator, agent binding,
sequence contiguity, slot and timestamp monotonicity and the strategy set all
survive an edit of `idle` or of a position value. On startup the reader re-reads
the newest eight checkpoints from finalized chain and compares every field,
amounts included; the first disagreement drops that row and everything after it,
in memory and in the file, and re-fetches them from chain. Rows older than that
tail stay trusted, because re-reading all of them is the cold-start replay the
cache exists to avoid — so keep `SOLANA_CHECKPOINT_DB` owner-only and on a volume
no other workload can write. Receipts are unaffected: transfer IDs are
re-derived from the checkpoints on every sync, and a send's source transaction is
always looked up in its finalized block.

To add another Kamino reserve, prepare a reviewed USDC strategy definition and
cap, register its agent-owned collateral account, extend/finalize the lookup
table, append it to the native manifest, and create a checkpoint. Existing
endpoints are append-only; old observations keep their original position set.
The current capacity is eight strategies per agent. The freshness, account and
compute budget must be validated for the selected collection of reserves.

For a new Solana protocol, implement its native value/CPI adapter and off-chain
`SolanaStrategyAdapter`, assign an explicit protocol discriminator, and extend
the registry/manifest union and tests. Custody, Base vault, bridge transport,
limits, checkpoints, historical reconstruction, receipts and signing journal
remain shared. Arbitrary executable/data forwarding with the agent's signer
is deliberately excluded from the extension interface.

## Reproduce verification

```sh
FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile
forge test --no-match-path 'test/forking/*'
npm run test:deploy
npm --prefix ops ci --ignore-scripts
npm --prefix ops run typecheck
npm --prefix ops test
npm --prefix ops audit
cargo test --locked --manifest-path solana/Cargo.toml
cargo install cargo-build-sbf --version 4.5.0 --locked
cargo build-sbf --manifest-path solana/programs/chain-agent/Cargo.toml --arch v2 -- --locked
cargo build-sbf --manifest-path solana/tests/mock-kamino/Cargo.toml --arch v2 -- --locked
npm --prefix ops run test:solana-sbf
```

The local validator test uses real agent SBF, the real SPL token program and a
clearly named Kamino CPI double. Account order and instruction encodings are
independently compared to the official pinned SDK. Real-reserve ownership,
USDC mint, layout and current APR/APY are separately checked read-only on mainnet.

For the additional bridge VM test, download the public Circle mainnet program
bytecode with `solana program dump`, then provide both paths:

```sh
npm --prefix ops run test:solana-cctp -- \
  --token-messenger /path/to/token-messenger-v2.so \
  --message-transmitter /path/to/message-transmitter-v2.so
```

That test runs actual Circle bytecode with an isolated local test attester and
synthetic USDC, verifies burn/receive/replay/forgery, historical write-down,
finalized source indexing and SQLite restart recovery. It sends no transactions
to mainnet. Native validator compatibility was tested with SBPF v2; v3 build
compatibility is a separate check. Select the target cluster's enabled SBPF
version before deployment. See the dated verification report for exact evidence,
upstream versions and remaining activation work.

## What CI covers

`.github/workflows/solana.yml` runs on every pull request, on pushes to `main`
and `dev`, and on demand. `native-build` runs the host `cargo test` suite, builds
both programs with `cargo build-sbf --arch v2` and publishes the two `.so` files
as a workflow artifact. `native-e2e` downloads that artifact, installs the pinned
`solana-test-validator` release and runs `npm --prefix ops run test:solana-sbf`
against it, so the local-validator evidence above is reproduced automatically
instead of only on a workstation. A failure fails the job; nothing in it is
allowed to continue on error.

The bridge half stays a manual activation gate. Circle's two mainnet programs
are not artifacts of this repository, so CI does not fetch them by default: the
job prints which assertions it skipped (native PDA burn, secp256k1 attestation,
receive while paused, forged-sender and replay rejection, balance conservation,
governance write-down, finalized source indexing, historical values and SQLite
restart recovery). Setting the repository variable `CCTP_MAINNET_DUMP=true`
makes the job dump both programs at the addresses in
`deploy/crosschain/native-registry.ts` and run `test:solana-cctp`; that dump goes
through a public mainnet RPC, so a dump failure may be the RPC rather than this
code. Run it once before activation and keep the output with the dated
verification report.

The Solana checkpoint cache itself is covered without a validator by
`ops/test/solana-cache.test.ts`: file and directory permissions, the in-place
tightening of an existing world-readable file, and the startup re-read that
discards a cached amount the chain disagrees with.
