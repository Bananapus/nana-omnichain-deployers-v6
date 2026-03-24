# nana-omnichain-deployers-v6 — Architecture

## Purpose

Omnichain project deployer for Juicebox V6. Wraps the project deployment flow to automatically configure cross-chain suckers and a 721 tiers hook, acting as a data hook that gives suckers 0% cash-out tax (bridging privilege) and mint permission. Every project gets a 721 hook (even with 0 initial tiers).

## Contract Map

```
src/
├── JBOmnichainDeployer.sol       — Deploys projects with sucker + 721 hook integration, acts as data hook wrapper
├── interfaces/
│   └── IJBOmnichainDeployer.sol  — Interface
└── structs/
    ├── JBDeployerHookConfig.sol      — Custom hook configuration for deployment
    ├── JBOmnichain721Config.sol      — 721 hook deployment config (tiers + cashout flag + salt)
    ├── JBTiered721HookConfig.sol     — Per-ruleset 721 hook configuration
    └── JBSuckerDeploymentConfig.sol  — Sucker deployment parameters
```

## Hook Storage Mappings

The deployer maintains two internal mappings, both keyed by `(projectId, rulesetId)`:

- **`_tiered721HookOf`** — Stores the project's `IJB721TiersHook` reference and a `useDataHookForCashOut` flag. Always populated for every ruleset (every project gets a 721 hook). The hook is always consulted for payments (it controls NFT tier minting), and optionally consulted for cash outs based on the flag.

- **`_extraDataHookOf`** — Stores an optional secondary data hook (e.g., a buyback hook) extracted from the ruleset's original `metadata.dataHook` field before the deployer overwrites it with itself. Includes separate `useDataHookForPay` and `useDataHookForCashOut` flags, preserved from the original ruleset metadata. Only populated when the caller's ruleset config specifies a non-zero `dataHook`.

During `_setup721`, the deployer extracts any user-specified data hook into `_extraDataHookOf`, then replaces `metadata.dataHook` with itself and forces both pay/cashout flags to `true`. At runtime, the deployer delegates to the 721 hook first, then the extra hook (if present), and merges their results.

## Key Data Flows

### Omnichain Project Deployment
```
Caller → JBOmnichainDeployer.launchProjectFor()
  → Deploy 721 hook via HOOK_DEPLOYER (always, even with 0 tiers)
  → _setup721(): store hooks, insert deployer as data hook
  → Launch JB project via controller.launchProjectFor
  → Transfer 721 hook ownership to project (after project NFT exists)
  → Deploy suckers via JBSuckerRegistry
  → Transfer project NFT to owner
```

### Data Hook Behavior
```
Payment → JBOmnichainDeployer.beforePayRecordedWith()
  → Calls 721 hook first (from _tiered721HookOf) for specs/split amounts
  → If 721 hook returned specs: include in merged output
  → Calls custom hook from _extraDataHookOf (if useDataHookForPay=true)
  → Custom hook receives reduced amount (payment - splitAmount)
  → Uses 721 hook's split-adjusted weight directly
  → Merges both hook specs (721 first if any, then custom)

Cash Out → JBOmnichainDeployer.beforeCashOutRecordedWith()
  → If caller is a registered sucker: return 0% cash-out tax (early return)
  → Calls 721 hook (from _tiered721HookOf, if useDataHookForCashOut=true)
    → Updates cashOutTaxRate, cashOutCount, totalSupply from 721 hook response
  → Calls custom hook (from _extraDataHookOf, if useDataHookForCashOut=true)
    → Receives already-updated values from 721 hook
    → Further updates cashOutTaxRate, cashOutCount, totalSupply
  → Merges both hooks' specifications (721 specs first, then custom hook specs)
  → If 721 hook has flag=true and reverts (fungible cashout): revert propagates
  → If neither hook has the flag set: return original values
```

### Ruleset Management
```
Owner → JBOmnichainDeployer.queueRulesetsOf()
  → If new tiers provided: deploy new 721 hook
  → If no new tiers: carry forward 721 hook from latest ruleset
  → _setup721(): store hooks, insert deployer as data hook
  → Queue new rulesets via JBController

Owner → JBOmnichainDeployer.launchRulesetsFor()
  → Deploy new 721 hook
  → Launch rulesets for an existing project
  → Configure terminal integration
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook (pay) | `IJBRulesetDataHook.beforePayRecordedWith` | Compose 721 + custom hook for payments |
| Data hook (cashout) | `IJBRulesetDataHook.beforeCashOutRecordedWith` | 0% tax for suckers, forward to hooks |
| Sucker registry | `IJBSuckerRegistry` | Sucker deployment and discovery |
| 721 hook deployer | `IJB721TiersHookDeployer` | 721 tiers hook deployment (always used) |

## Design Decisions

1. **Always deploy a 721 hook, even with 0 tiers.** Every project gets a 721 hook instance so that NFT tiers can be added later via `queueRulesetsOf` without changing the data hook architecture. The hook is also needed as the pay hook target for tier minting. Deploying with 0 tiers is a no-op at runtime (no specs returned) but keeps the infrastructure in place.

2. **Deployer acts as a data hook wrapper instead of direct hook assignment.** The core protocol only supports a single `dataHook` per ruleset. The deployer inserts itself as that hook so it can compose two hooks (721 + custom) behind a single interface, while also injecting sucker-specific logic (0% cash-out tax for suckers, mint permission for suckers). Without this wrapper, projects would have to choose between NFT tiers, a buyback hook, and sucker privileges.

3. **721 hook specs are merged first, custom hook specs second.** During payments, the 721 hook's split amount is subtracted from the payment before the custom hook sees it. This ordering ensures the 721 hook claims funds for tier mints at full price, and the custom hook (e.g., buyback) operates on the remaining amount. For cash outs, the 721 hook adjusts `cashOutTaxRate`/`cashOutCount`/`totalSupply` first, and the custom hook receives those already-updated values, allowing each hook to build on the previous hook's adjustments.

4. **721 hook's weight is used directly after tier splits.** The 721 hook's `beforePayRecordedWith` returns a weight that is already adjusted for tier-split deductions (via `JB721TiersHookLib.calculateWeight`). The deployer uses this weight directly instead of re-scaling with `mulDiv`. This prevents double-counting: the 721 hook mints its own NFTs for the split amount, and the terminal mints fungible tokens only for the remainder at the hook's pre-adjusted weight.

5. **Ruleset IDs are predicted as `block.timestamp + i`.** The deployer must store hook configs keyed by ruleset ID before the rulesets are actually created. It predicts IDs using the core protocol's convention (`block.timestamp` for the first, incrementing for subsequent rulesets in the same transaction). `queueRulesetsOf` explicitly reverts if `latestRulesetId >= block.timestamp`, which would mean rulesets were already queued in the same block and the prediction would be wrong.

## Dependencies
- `@bananapus/core-v6` — Core protocol (controller, directory, permissions)
- `@bananapus/721-hook-v6` — NFT tier deployment
- `@bananapus/ownable-v6` — JB-aware ownership
- `@bananapus/permission-ids-v6` — Permission constants
- `@bananapus/suckers-v6` — Cross-chain sucker registry
- `@openzeppelin/contracts` — ERC2771, ERC721Receiver
