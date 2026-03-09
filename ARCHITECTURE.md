# nana-omnichain-deployers-v6 — Architecture

## Purpose

Omnichain project deployer for Juicebox V6. Wraps the project deployment flow to automatically configure cross-chain suckers, acting as a data hook that gives suckers 0% cash-out tax (bridging privilege) and mint permission.

## Contract Map

```
src/
├── JBOmnichainDeployer.sol       — Deploys projects with sucker integration, acts as data hook
├── interfaces/
│   └── IJBOmnichainDeployer.sol  — Interface
└── structs/
    ├── JBDeployerHookConfig.sol      — Hook configuration for deployment
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
  → Pass through (no modification to pay behavior)
  → Return empty pay hook specifications

Cash Out → JBOmnichainDeployer.beforeCashOutRecordedWith()
  → If caller is a registered sucker: return 0% cash-out tax
  → Otherwise: return configured cash-out tax rate
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
