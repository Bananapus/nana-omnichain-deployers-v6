# nana-omnichain-deployers-v5

## Purpose

Convenience contract for deploying Juicebox projects with cross-chain suckers (and optionally 721 tiers hooks) in a single transaction, while wrapping the data hook to allow tax-free cash outs from suckers.

## Contracts

| Contract | Role |
|----------|------|
| `JBOmnichainDeployer` | Project/ruleset/sucker deployment + data hook wrapper for sucker tax exemption. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `launchProjectFor(...)` | `JBOmnichainDeployer` | Creates a new project with rulesets, terminals, and suckers. Temporarily holds project NFT. |
| `launch721ProjectFor(...)` | `JBOmnichainDeployer` | Same as above but also deploys a 721 tiers hook and transfers its ownership to the project. |
| `launchRulesetsFor(...)` | `JBOmnichainDeployer` | Launches new rulesets for an existing project. Requires `QUEUE_RULESETS` + `SET_TERMINALS` permissions. |
| `launch721RulesetsFor(...)` | `JBOmnichainDeployer` | Launches rulesets with a new 721 tiers hook attached. |
| `queueRulesetsOf(...)` | `JBOmnichainDeployer` | Queues future rulesets. Requires `QUEUE_RULESETS` permission. |
| `queue721RulesetsOf(...)` | `JBOmnichainDeployer` | Queues rulesets with a new 721 tiers hook. |
| `deploySuckersFor(...)` | `JBOmnichainDeployer` | Deploys new suckers for an existing project. Requires `DEPLOY_SUCKERS` permission. |
| `beforePayRecordedWith(...)` | `JBOmnichainDeployer` | Data hook: forwards to real data hook if set. |
| `beforeCashOutRecordedWith(...)` | `JBOmnichainDeployer` | Data hook: returns 0% tax for suckers, otherwise forwards to real hook. |
| `hasMintPermissionFor(...)` | `JBOmnichainDeployer` | Returns `true` for suckers, otherwise forwards to real hook. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBController`, `JBPermissioned`, `IJBProjects` | Launching projects, permission checks, project NFT transfers |
| `nana-721-hook-v6` | `IJB721TiersHookDeployer`, `JBDeploy721TiersHookConfig` | Deploying 721 tiers hooks for projects |
| `nana-suckers-v6` | `IJBSuckerRegistry` | Deploying suckers, checking `isSuckerOf` for tax-free cash outs |
| `nana-ownable-v6` | `JBOwnable` | Transferring 721 hook ownership to the project |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission constants (`DEPLOY_SUCKERS`, `QUEUE_RULESETS`, `SET_TERMINALS`, `MAP_SUCKER_TOKEN`) |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, receiving project NFTs |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBDeployerHookConfig` | `bool useDataHookForPay`, `bool useDataHookForCashOut`, `IJBRulesetDataHook dataHook` | `_dataHookOf` mapping keyed by `(projectId, rulesetId)` |
| `JBSuckerDeploymentConfig` | `JBSuckerDeployerConfig[] deployerConfigurations`, `bytes32 salt` | All launch/deploy functions |

## Gotchas

- The deployer inserts itself as the data hook via `_setup()`. Setting a ruleset's data hook to `address(this)` reverts with `JBOmnichainDeployer_InvalidHook` to prevent infinite forwarding loops.
- Ruleset IDs in `_dataHookOf` are keyed by `block.timestamp + i`, which must match the IDs assigned during controller launch.
- Sucker deployment salts are hashed with `_msgSender()` to prevent cross-deployer address collisions.
- Constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` with `projectId=0` (wildcard for all projects).
- Only accepts ERC-721 transfers from the `PROJECTS` contract (the `onERC721Received` callback reverts otherwise).

## Example Integration

```solidity
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";

// Launch a project with suckers in one transaction
(uint256 projectId, address[] memory suckers) = omnichainDeployer.launchProjectFor({
    owner: msg.sender,
    projectUri: "ipfs://...",
    rulesetConfigurations: rulesetConfigs,
    terminalConfigurations: terminalConfigs,
    memo: "Launching with suckers",
    suckerDeploymentConfiguration: suckerConfig,
    controller: controller
});
```
