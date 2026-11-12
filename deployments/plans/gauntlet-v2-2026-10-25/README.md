# Gauntlet V2: prepared, not deployed

Generated 2026-10-25 at 13:37:27 UTC from clean source commit `7c2ec58`.
Provider source is the reviewed `1b3f1ea` implementation. No transaction was
signed, broadcast, deployed, queued or executed. All simulations used eth_call;
temporary code overrides were confined to those calls.

## Files

- [manifest.json](manifest.json): source/compiler provenance and artifact hashes.
- [base.json](base.json), [mainnet.json](mainnet.json): unsigned deployment data,
  source/gate checks, gas/funding estimates and unsigned registration proposals.
- [artifact.json](artifact.json): ABI and bytecode.
- [standard-json-input.json](standard-json-input.json): explorer verification input.
- [activation-authority.json](activation-authority.json): additional Base admin check.
- [Runbook](../../../docs/gauntlet-v2-deployment-runbook.md): refresh, future deployment,
  verification, registration, activation and rollback instructions.

## Deployment blockers

Deployer: `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D`.

| Network | Snapshot block | Estimated gas | ETH balance | Deployment budget, ETH | Shortfall, ETH |
| --- | --- | --- | --- | --- | --- |
| Base | 53073045 | 1,889,260 | 0.000002476665354051 | 0.000025977325 | 0.000023500659645949 |
| Ethereum | 26270036 | 1,915,331 | 0.000048229031434500 | 0.000202594871140872 | 0.000154365839706372 |

The budget uses a 25% gas-limit margin and the recorded RPC max-fee estimate.
Base L1 data fees and all later governance/activation transactions are additional.
Funding is not performed or authorized by this package. Refresh balances, gas
fees and nonce immediately before any subsequently approved deployment.

## Validated drafts

Constructor simulations and gas estimates passed on both networks. All four
Morpho action gates allow all three targets. Appending the candidate provider,
queueing the operation and reading its APR were simulated successfully.
The current five-provider list is preserved in each six-provider proposal.

| Network | Target | Timelock delay |
| --- | --- | --- |
| Base | Main vault `0x3C7739173cca612B6394EE57131458185A5beC44` | 1 hour |
| Base | Stand Strategy `0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33` | 24 hours |
| Ethereum | Main vault `0xc3156Da39EeEa9De80F1d74b497C0E4A7030Aae3` | 1 hour |

Provisional CREATE addresses (no code deployed):

- Base nonce 1395: `0x9D64bC96A2eD88c0CE273194f41441FebaBBcE1A`.
- Ethereum nonce 35: `0x7a5Ae7F0a2FE2F555b92C2e237381c04040F60Bc`.

These are predictions, not deployment records. The same deployer sending any
other transaction invalidates the prediction. After actual deployment, regenerate
each registration draft using `--provider ACTUAL_DEPLOYED_ADDRESS`; do not simply
reuse an old predicted-address proposal. The tool validates the actual immutable
runtime before preparing registration. Once an operation is queued, retain its
original tuple and ETA for execute/cancel and recheck that the provider list did
not change before execution.

Base main-vault activation authority was checked separately at block 53073177:
Safe `0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1` has `ADMIN_ROLE`; the deployer
does not. Its timelock owner is the deployer. Queue/execute and entry selection
therefore use different authorities. The Base stand Strategy and Ethereum main
vault report the deployer/treasury as an administrator. Recheck roles at activation.

Validation: 23 automated preparation/deployment tests, TypeScript and Hardhat
compilation passed. Bundle hashes, constructor encoding, CREATE predictions and
all three preserved provider lists were independently checked offline.
