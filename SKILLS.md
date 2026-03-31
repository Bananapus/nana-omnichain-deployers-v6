# Juicebox Omnichain Deployers

## Use This File For

- Use this file when the task involves deploying core projects with suckers and optional 721 or custom data-hook composition in one flow.
- Start here, then open the deployer or composition-focused tests depending on whether the question is about setup, permissions, hook wrapping, or runtime delegation.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and launch model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Deployment implementation | [`src/JBOmnichainDeployer.sol`](./src/JBOmnichainDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Input and output types | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Guard rails, attacks, or hook composition behavior | [`test/JBOmnichainDeployerGuard.t.sol`](./test/JBOmnichainDeployerGuard.t.sol), [`test/OmnichainDeployerAttacks.t.sol`](./test/OmnichainDeployerAttacks.t.sol), [`test/Tiered721HookComposition.t.sol`](./test/Tiered721HookComposition.t.sol), [`test/regression/`](./test/regression/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contract | [`src/JBOmnichainDeployer.sol`](./src/JBOmnichainDeployer.sol) |
| Types | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Single-transaction deployment and wrapper layer for Juicebox projects that need a 721 hook, cross-chain sucker support, and optional extra data-hook composition from day one.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need hook-composition order, sucker exemptions, per-ruleset storage behavior, or the main runtime invariants.
- Open [`references/operations.md`](./references/operations.md) when you need launch and queue behavior, permission and salt assumptions, test breadcrumbs, or the common stale-data traps.

## Working Rules

- Start in [`src/JBOmnichainDeployer.sol`](./src/JBOmnichainDeployer.sol) for both deployment and runtime wrapping behavior. This repo is orchestration plus a live data-hook wrapper, not a pure deploy script package.
- Treat ruleset ID prediction, hook-carry-forward logic, and salt derivation as high-risk. Small changes there can orphan config or break deterministic deployment.
- When a bug mentions suckers, tax-free cash outs, or mint permission, verify whether the early-return wrapper behavior is the real cause before changing downstream hooks.
- If a task mentions 721 or custom-hook behavior, confirm whether the issue lives here or in the composed repo before patching wrapper logic.
