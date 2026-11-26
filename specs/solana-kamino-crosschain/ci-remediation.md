---
title: Solana Kamino CI reproducibility remediation
date: 2026-11-09
status: active
project: optimized-rebalancer-contracts
author: cto-agent
---

# Change: solana-kamino-crosschain

## Scope and acceptance

Repair the reported root npm clean-install, dependency audit and Slither jobs
without weakening their high/critical gates or changing the financial design.
Keep the current branch and create a local follow-up commit; do not push.
Recheck native SBF status independently of the failing sibling job.

Acceptance: a clean install from the committed lockfile, contracts compile,
non-fork Foundry regression, deployment and ops tests, both root/ops dependency
audits with no high/critical findings, and Slither with no first-party high
findings. Analyze application code while filtering third-party library reports;
do not disable a detector globally to hide an application finding.

Opportunity research is not applicable to this defect correction: product
scope, users, custody model and R1–R11 remain unchanged. Existing SDD and
verification templates apply. Engineering reproduces each failure, QA runs
checks from clean dependencies, Security reviews actual findings and package
compatibility, and the repository owner reviews the local commit before push.

## Evidence before remediation

- GitHub native workflow run `42638576829`, commit `93adc9a`: `native-build`
  succeeds, including host tests and both locked SBF v2 builds.
- Its `contracts-and-ops` job fails at root `npm ci --ignore-scripts`.
  Local reproduction reports EUSAGE and missing `@colors/colors`, `source-map`,
  `uglify-js`, `@pkgjs/parseargs`, `amdefine` lockfile entries.
- Security run `42638576635` fails both jobs. Root audit reports 32 high and
  4 critical affected packages. Previous ops-only audit did not cover root.
- Local Slither 0.11.6 finds one application high: immutable `agent` as the
  `transferFrom` source. `onlyAgent` already restricts the caller; express that
  directly with `msg.sender`. Other high reports are inside OpenZeppelin
  modular-inverse arithmetic/proxy assembly/nonpayable utility code.

## Verification after remediation

Fresh source copy: `/private/tmp/thesauros-ci-clean.4dLAqu`, with no inherited
node_modules, artifacts or private environment file; Node 22.21.1/npm 10.
The locked OpenZeppelin 5.4.0 and Hardhat 2.28.1 versions remain unchanged.

| Check | Observed result |
|---|---|
| Root `npm ci --ignore-scripts` | Success: 656 packages installed |
| Ops `npm ci --ignore-scripts` | Success: 260 packages installed |
| `FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile` | 86 Solidity files compiled; 250 typings generated |
| `forge test --no-match-path 'test/forking/*' -q` | Exit 0; 188 tests/invariants independently counted with `--list --json` |
| `npm run test:deploy` | 23 passed |
| Ops `npm run typecheck` / `npm test` | Typecheck succeeds; 65 passed |
| Root `npm audit --audit-level=high` | Exit 0; 0 high, 0 critical; 21 low and 18 moderate remain visible |
| Ops `npm audit --audit-level=high` | Exit 0; zero vulnerabilities |
| Slither 0.11.6 on the clean installed tree | Exit 0; zero application high findings; no detector disabled |
| Security workflow YAML / `git diff --check` | Valid / pass |

Network retry flags were used for npm downloads after a temporary DNS failure;
no peer-resolution or omission flags were added to the root install. The first
ops test attempt was blocked by sandbox `listen EPERM`; the authorized rerun
with localhost socket access passes all 65 tests.

### Security review and compatibility

Regenerate the incomplete lockfile and apply patched transitive overrides.
Keep Axios 0.x/1.x, WebSocket 7.x/8.x and other parent API families separate.
Undici 6 and serialize-javascript 7 are required for the published security
fixes; minimatch 11 replaces the affected 9.x path. The clean compilation,
generated typings, deployment and ops regressions exercise the resulting tree.
Do not use `npm audit fix --force` to migrate Hardhat or deployment plugins.

Remaining root audit advisories originate in bn.js, cookie, elliptic, glob
and uuid and propagate to development tooling. They are not suppressed; the
existing high/critical gate is unchanged. Ops remains independently audited.

The adapter's source change is equivalent under `onlyAgent`:
`msg.sender == agent` is required before `transferFrom`. Its authorization,
amount/fee and route regression tests pass. Slither's third-party OpenZeppelin
modular-inverse, proxy-return and nonpayable-helper reports are excluded by
path, while all application detectors stay enabled. The native adapter's
medium locked-ether report is unreachable through `send`: any nonzero
`msg.value` is explicitly rejected. Medium/low/informational application
findings remain visible; this is not a zero-findings claim.

### Remote evidence and delivery boundary

[Native workflow run](https://github.com/Thesauros/optimized-rebalancer-contracts/actions/runs/42638576829)
already confirms both SBF v2 builds and native host tests on Linux for the
unchanged Rust source. No SBF workflow correction is required.

The corrected jobs are locally verified. A GitHub rerun of these changes is
not claimed: no push or workflow dispatch was performed. Existing production
activation limits in `verification.md` remain unchanged.

References: [npm clean-install contract](https://docs.npmjs.com/cli/v11/commands/npm-ci/),
[Slither path filtering and options](https://github.com/crytic/slither/wiki/Usage).
