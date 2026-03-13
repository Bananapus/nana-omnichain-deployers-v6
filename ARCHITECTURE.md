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
  → Adjusts weight proportionally for splits
  → Merges both hook specs (721 first if any, then custom)

Cash Out → JBOmnichainDeployer.beforeCashOutRecordedWith()
  → If caller is a registered sucker: return 0% cash-out tax (early return)
  → Checks 721 hook (from _tiered721HookOf, if useDataHookForCashOut=true)
  → Then checks custom hook (from _extraDataHookOf, if useDataHookForCashOut=true)
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

## Dependencies
- `@bananapus/core-v6` — Core protocol (controller, directory, permissions)
- `@bananapus/721-hook-v6` — NFT tier deployment
- `@bananapus/ownable-v6` — JB-aware ownership
- `@bananapus/permission-ids-v6` — Permission constants
- `@bananapus/suckers-v6` — Cross-chain sucker registry
- `@openzeppelin/contracts` — ERC2771, ERC721Receiver
