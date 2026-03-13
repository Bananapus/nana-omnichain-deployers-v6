# nana-omnichain-deployers-v6 — Architecture

## Purpose

Omnichain project deployer for Juicebox V6. Wraps the project deployment flow to automatically configure cross-chain suckers, acting as a data hook that gives suckers 0% cash-out tax (bridging privilege) and mint permission.

## Contract Map

```
src/
├── JBOmnichainDeployer.sol       — Deploys projects with sucker integration, acts as data hook wrapper
├── interfaces/
│   └── IJBOmnichainDeployer.sol  — Interface
└── structs/
    ├── JBDeployerHookConfig.sol      — Custom hook configuration for deployment
    ├── JBTiered721HookConfig.sol     — Per-ruleset 721 hook configuration
    └── JBSuckerDeploymentConfig.sol  — Sucker deployment parameters
```

## Key Data Flows

### Omnichain Project Deployment
```
Deployer → JBOmnichainDeployer.deployProjectFor()
  → Launch JB project via JB721TiersHookProjectDeployer
  → Set JBOmnichainDeployer as data hook
  → Deploy suckers via JBSuckerRegistry
  → Configure sucker permissions (mint, 0% cashout tax)
  → Transfer project ownership back to deployer
```

### Data Hook Behavior
```
Payment → JBOmnichainDeployer.beforePayRecordedWith()
  → Calls 721 hook first (from _tiered721HookOf) for specs/split amounts
  → Calls custom hook from _extraDataHookOf (if useDataHookForPay=true)
  → Custom hook receives reduced amount (payment - splitAmount)
  → Adjusts weight proportionally for splits
  → Merges both hook specs (721 first, then custom)

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
  → Queue new rulesets via JBController
  → Maintains deployer as data hook
  → Supports adding/removing suckers

Owner → JBOmnichainDeployer.launchRulesetsFor()
  → Launch rulesets for an existing project
  → Configure sucker integration
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook (pay) | `IJBRulesetDataHook.beforePayRecordedWith` | Pass-through for payments |
| Data hook (cashout) | `IJBRulesetDataHook.beforeCashOutRecordedWith` | 0% tax for suckers |
| Sucker registry | `IJBSuckerRegistry` | Sucker deployment and discovery |
| 721 hook deployer | `IJB721TiersHookDeployer` | Optional NFT tier deployment |

## Dependencies
- `@bananapus/core-v6` — Core protocol (controller, directory, permissions)
- `@bananapus/721-hook-v6` — NFT tier deployment
- `@bananapus/ownable-v6` — JB-aware ownership
- `@bananapus/permission-ids-v6` — Permission constants
- `@bananapus/suckers-v6` — Cross-chain sucker registry
- `@openzeppelin/contracts` — ERC2771, ERC721Receiver
