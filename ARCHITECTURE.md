# Architecture

## Purpose

`nana-omnichain-deployers-v6` packages a Juicebox project, a 721 hook, and sucker deployment into one omnichain launch surface.

## System Overview

`JBOmnichainDeployer` launches the project, stores per-ruleset hook composition, and wraps sucker behavior so bridge-triggered flows can bypass project-specific logic where intended.

## Core Invariants

- launch wiring must match the intended omnichain project shape
- hook composition must stay consistent with the created ruleset IDs
- sucker-specific privileged paths must remain limited to trusted suckers
- project NFT ownership and hook ownership must end in the intended place

## Trust Boundaries

- bridge runtime trust lives in `nana-suckers-v6`
- 721 runtime trust lives in `nana-721-hook-v6`
- this repo mainly owns orchestration and wrapper semantics

## Security Model

- the main risks are hook composition, ruleset ID prediction, and registry-trusted sucker bypasses
- this repo is not the source of underlying bridge or 721 behavior, but it can wire them together incorrectly

## Source Map

- `src/JBOmnichainDeployer.sol`
