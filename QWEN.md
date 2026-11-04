# Optimized Rebalancer Contracts — Project Instructions

## Project Overview

Thesauros Meridian Vault — DeFi protocol for automated yield optimization. ERC4626 vault that rebalances stablecoin deposits across lending providers (Aave V3, Compound V3, Morpho) to maximize yield.

## Tech Stack

- **Solidity** 0.8.23
- **Hardhat** 2.28.1 + **Foundry** (dual toolchain)
- **OpenZeppelin** 5.4 (contracts + upgradeable)
- **Network:** Base (branch `base-dev`)
- **Audit:** Hexens (see `audit/`)

## Key Commands

```bash
npx hardhat compile          # Compile contracts
npx hardhat test             # Run tests
npx hardhat test test/forking/  # Fork tests
npx hardhat coverage         # Coverage
forge build                  # Foundry build
forge test                   # Foundry tests
```

## Repository Layout

- `contracts/Rebalancer.sol` — core rebalancing logic
- `contracts/providers/` — AaveV3, CompoundV3, Morpho providers
- `contracts/access/` — AccessManager, Timelock
- `contracts/interfaces/` — IProvider, IRebalancer, IERC4626, etc.
- `contracts/libraries/Constants.sol`
- `test/forking/` — fork tests against live chains
- `deploy/` — deployment scripts
- `deployments/` — deployment artifacts
- `audit/` — Hexens audit reports

## Conventions

- Solidity 0.8.23, OpenZeppelin 5.x patterns
- Role-based access: Admin, Operator, Executor, RootUpdater, Timelock
- Fee limits: max 5% withdrawal, max 20% rebalancing
- ERC4626 standard compliance
- Inflation attack protection via `setupVault()`

## CTO Skill

This project uses the CTO skill at `.cto-skill/`.

- On session start: read `.cto-skill/SKILL.md` for CTO persona and workflows.
- Load relevant context from `.cto-skill/data/` (lazy — only what's needed).
- Follow `.cto-skill/AGENT_INSTRUCTIONS.md` for full operating rules.
- Use templates from `.cto-skill/templates/` for documents.
- Write durable decisions/context to `.cto-skill/data/`.
- Before ending: `cd .cto-skill && git add data/ && git commit -m "Update CTO context" && git push`

## Permissions & Autonomy

Full autonomy granted:
- Read, write, edit any file in this repo
- Run build, test, compile commands
- Create branches, commit changes
- No need to ask permission for routine dev operations

## Language

User communicates in informal Russian. Respond in Russian unless asked otherwise. Keep code, paths, commands in English.

## Orchestrator Skill

This project uses the Orchestrator skill at `.orchestrator-skill/`.

- On session start: read `.orchestrator-skill/SKILL.md` for orchestrator persona and workflows.
- ALWAYS read `.orchestrator-skill/data/state/` first to understand current project position.
- Follow `.orchestrator-skill/AGENT_INSTRUCTIONS.md` for full operating rules.
- Use templates from `.orchestrator-skill/templates/` for documents.
- Update state in `.orchestrator-skill/data/state/` after every significant event.
- Before ending: `cd .orchestrator-skill && git add data/ && git commit -m "[<change-name>] Update orchestration state" -m "Change: <change-name>" && git push`

## Product Squad Skill

This project uses the Product Squad skill at `.product-squad-skill/`.

- On session start: read `.product-squad-skill/SKILL.md` for product persona and workflows.
- Load relevant context from `.product-squad-skill/data/` (lazy — only what's needed).
- Follow `.product-squad-skill/AGENT_INSTRUCTIONS.md` for full operating rules.
- Run the mandatory SDD Opportunity Research Subcycle before a material task enters sprint planning or CTO implementation.
- Use templates from `.product-squad-skill/templates/` for documents.
- Write durable decisions/context to `.product-squad-skill/data/`.
- Before ending: `cd .product-squad-skill && git add data/ && git commit -m "[<change-name>] Update product context" -m "Change: <change-name>" && git push`

## Security Engineer Skill

This project uses the Security Engineer skill at `.security-engineer-skill/`.

- On session start: read `.security-engineer-skill/SKILL.md` for security persona and workflows.
- Load relevant context from `.security-engineer-skill/data/` (lazy — only what's needed).
- Follow `.security-engineer-skill/AGENT_INSTRUCTIONS.md` for full operating rules.
- Use templates from `.security-engineer-skill/templates/` for documents.
- Write findings/reviews to `.security-engineer-skill/data/`.
- Before ending: `cd .security-engineer-skill && git add data/ && git commit -m "[<change-name>] Update security context" -m "Change: <change-name>" && git push`
