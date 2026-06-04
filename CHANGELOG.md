# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `nana-omnichain-deployers-v5` in `../../v5/evm` with the current `nana-omnichain-deployers-v6` repo.

## Current V6 Surface

- `JBOmnichainDeployer`
- `IJBOmnichainDeployer`
- `JBDeployerHookConfig`
- `JBOmnichain721Config`
- `JBSuckerDeploymentConfig`
- `JBTiered721HookConfig`

## Summary

- V6 folds 721-hook deployment into the normal omnichain launch/queue flows instead of keeping separate `*721*` entry points.
- Hook composition is explicit. V6 exposes one view for the extra data hook and another for the tiered 721 hook.
- The deployer participates in V6 data-hook behavior for pay and cash-out paths, including peer-chain adjusted accounting.
- Sucker deployment config follows the V6 `bytes32` remote-peer model and explicit-peer permission boundary.
- Permission checks distinguish launching rulesets from queueing rulesets.

## ABI, Event, and Error Changes

- Removed V5 functions:
  - `dataHookOf(...)`
  - `launch721ProjectFor(...)`
  - `launch721RulesetsFor(...)`
  - `queue721RulesetsOf(...)`
- Added or changed functions:
  - `extraDataHookOf(...)`
  - `tiered721HookOf(...)`
  - `launchProjectFor(...)` overloads using `JBOmnichain721Config`
  - `launchRulesetsFor(...)` overloads using `JBOmnichain721Config`
  - `queueRulesetsOf(...)` overloads using `JBOmnichain721Config`
  - `peerChainAdjustedAccountsOf(uint256)`
- Changed structs:
  - `JBOmnichain721Config` is new and carries the 721 hook setup through the normal launch/queue flow.
  - `JBTiered721HookConfig` is new.
  - `JBSuckerDeploymentConfig` follows the V6 sucker schema.
- Indexer impact:
  - Deployment indexing should look for the tiered 721 hook as part of the normal V6 launch path.
  - Hook-derived activity may be split between the deployer, extra data hook, and tiered 721 hook.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-omnichain-deployers-v5`.
- Own-source ABI artifacts compared: V6 `6`, V5 `4`.
- Contract/interface coverage: `2` added, `0` removed, `2` shared names with ABI changes, `2` shared names ABI-identical.
- Shared-name ABI item deltas: `29` added, `19` removed, `1` modified.

Added V6 ABI artifacts:
- `JBOmnichain721Config` from `src/structs/JBOmnichain721Config.sol`: `0` functions, `0` events, `0` errors.
- `JBTiered721HookConfig` from `src/structs/JBTiered721HookConfig.sol`: `0` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `IJBOmnichainDeployer`: `10` added, `8` removed, `0` modified ABI items.
- `JBOmnichainDeployer`: `19` added, `11` removed, `1` modified ABI items.

Generated event/error name deltas:
- Error names added:
  - `JBOmnichainDeployer_ControllerMismatch`, `JBOmnichainDeployer_InvalidHook`, `JBOmnichainDeployer_NoRulesetConfigurations`, `JBOmnichainDeployer_RulesetIdsUnpredictable`, `JBOmnichainDeployer_UnexpectedNFTReceived`, `PRBMath_MulDiv_Overflow`.
- Error names removed or replaced:
  - `JBOmnichainDeployer_InvalidHook`, `JBOmnichainDeployer_UnexpectedNFT`.

Shared ABI artifacts checked with no ABI item changes:
- `JBDeployerHookConfig`, `JBSuckerDeploymentConfig`.

## Migration Notes

- Replace `launch721*` / `queue721*` calls with the V6 overloads that include `JBOmnichain721Config`.
- Update off-chain code that treated `dataHookOf(...)` as the only hook lookup.
- Rebuild sucker deployment config encoders for the V6 `bytes32` peer model.
