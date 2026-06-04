# Architecture

## Purpose

`nana-omnichain-deployers-v6` packages a Juicebox project, a 721 hook, and sucker deployment into one omnichain launch surface.

## System overview

`JBOmnichainDeployer` launches the project, stores per-ruleset hook composition, and wraps sucker behavior so bridge-triggered flows can bypass project-specific logic where intended.

## Core invariants

- launch wiring must match the intended omnichain project shape
- hook composition must stay consistent with the created ruleset IDs
- sucker-specific privileged paths must remain limited to trusted suckers
- project NFT ownership and hook ownership must end in the intended place

## Trust boundaries

- bridge runtime trust lives in `nana-suckers-v6`
- 721 runtime trust lives in `nana-721-hook-v6`
- this repo mainly owns orchestration and wrapper semantics

## Security model

- the main risks are hook composition, ruleset ID prediction, and registry-trusted sucker bypasses
- this repo is not the source of underlying bridge or 721 behavior, but it can wire them together incorrectly

## Source map

- `src/JBOmnichainDeployer.sol` — the single runtime contract.
- `src/interfaces/IJBOmnichainDeployer.sol` — external interface.
- `src/structs/` — `JBOmnichain721Config`, `JBTiered721HookConfig`, `JBDeployerHookConfig` config shapes.

For per-function caller / effect / invariant detail, see [`INVARIANTS.md`](./INVARIANTS.md).
