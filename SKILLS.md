# Juicebox Omnichain Deployers

## Purpose

Single-transaction deployment of Juicebox projects with cross-chain suckers and 721 tiers hooks. Every project gets a 721 hook (even with 0 initial tiers), so projects can add NFT tiers later without reconfiguring. Wraps the project's data hooks to give suckers tax-free cash outs and mint permission without interfering with custom hooks. Stores the 721 hook per-ruleset in `_tiered721HookOf` and the optional custom hook per-ruleset in `_extraDataHookOf`, each with their own `useDataHookForCashOut` flag. Supports composing a 721 hook alongside a custom data hook (e.g., buyback hook) — both run on every payment.

## Contracts

| Contract | Role |
|----------|------|
| `JBOmnichainDeployer` | Deploys projects/rulesets/suckers, wraps data hooks for sucker tax exemption. Always deploys a 721 hook. Stores 721 hook per-ruleset in `_tiered721HookOf` and custom hook per-ruleset in `_extraDataHookOf`. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

## Key Functions

### Deployment

| Function | What it does |
|----------|-------------|
| `launchProjectFor(owner, projectUri, deploy721Config, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Creates a new project with a 721 tiers hook, rulesets, terminals, and suckers in one tx. Always deploys a 721 hook (even with 0 tiers). Temporarily holds the project NFT. Returns `(projectId, hook, suckers)`. |
| `launchRulesetsFor(projectId, deploy721Config, rulesetConfigs, terminalConfigs, memo, controller)` | Launches new rulesets + terminals with a new 721 tiers hook for an existing project. Requires `QUEUE_RULESETS` + `SET_TERMINALS`. Returns `(rulesetId, hook)`. |
| `queueRulesetsOf(projectId, deploy721Config, rulesetConfigs, memo, controller)` | Queues future rulesets. If tiers provided, deploys a new 721 hook. Otherwise, carries forward the 721 hook from the latest ruleset. Requires `QUEUE_RULESETS`. Reverts if rulesets were already queued in the same block. Returns `(rulesetId, hook)`. |
| `deploySuckersFor(projectId, suckerConfig)` | Deploys new suckers for an existing project. Requires `DEPLOY_SUCKERS`. |

### Data Hook (IJBRulesetDataHook)

| Function | What it does |
|----------|-------------|
| `beforePayRecordedWith(context)` | Calls the 721 hook first (via `_tiered721HookOf`) for its specs (including split amounts), then calls the custom hook from `_extraDataHookOf` (if `useDataHookForPay: true`) with a reduced amount context (payment minus split amount) for weight + specs. Adjusts the returned weight proportionally so the terminal only mints tokens for the amount entering the project (`weight = mulDiv(weight, amount - splitAmount, amount)`). Merges specs (721 hook specs first if any, then custom hook specs). If the 721 hook returns no specs (0 tiers), its slot is omitted from the output. |
| `beforeCashOutRecordedWith(context)` | If holder is a sucker: returns 0% tax immediately. Checks 721 hook first (if `useDataHookForCashOut: true`), then custom hook from `_extraDataHookOf`. The first with the flag set handles it. If the 721 hook has the flag set and reverts (e.g., fungible cashout), the revert propagates. If neither has the flag set, returns original values. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` for registered suckers, OR if the custom hook in `_extraDataHookOf` grants permission. Returns `false` only if it doesn't grant it. |

### Views

| Function | What it does |
|----------|-------------|
| `extraDataHookOf(projectId, rulesetId)` | Returns the stored `JBDeployerHookConfig` for a given project and ruleset. Contains the custom data hook (e.g., buyback hook) with its per-hook flags. Returns empty struct if none configured. |
| `tiered721HookOf(projectId, rulesetId)` | Returns the 721 tiers hook and its `useDataHookForCashOut` flag for a given project and ruleset. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`, `IERC165`. |
| `onERC721Received(...)` | Accepts project NFTs from `PROJECTS` only. Reverts for any other NFT contract. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBController`, `JBPermissioned`, `IJBProjects`, `IJBRulesetDataHook` | Launching projects, permission checks, project NFT transfers, data hook interface |
| `nana-721-hook-v6` | `IJB721TiersHookDeployer`, `JBDeploy721TiersHookConfig` | Deploying 721 tiers hooks |
| `nana-suckers-v6` | `IJBSuckerRegistry` | Deploying suckers, checking `isSuckerOf()` for tax-free cash outs |
| `nana-ownable-v6` | `JBOwnable` | Transferring 721 hook ownership to the project |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission constants |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, receiving project NFTs |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBOmnichain721Config` | `JBDeploy721TiersHookConfig deployTiersHookConfig`, `bool useDataHookForCashOut`, `bytes32 salt` | All deploy/launch/queue functions — 721 hook deployment config. |
| `JBDeployerHookConfig` | `IJBRulesetDataHook dataHook`, `bool useDataHookForPay`, `bool useDataHookForCashOut` | `_extraDataHookOf` mapping keyed by `(projectId, rulesetId)` → single custom hook config. |
| `JBTiered721HookConfig` | `IJB721TiersHook hook`, `bool useDataHookForCashOut` | `_tiered721HookOf` mapping keyed by `(projectId, rulesetId)` → per-ruleset 721 hook config. |
| `JBSuckerDeploymentConfig` | `JBSuckerDeployerConfig[] deployerConfigurations`, `bytes32 salt` | All launch and deploy functions |

## Permission IDs

| Permission | Used By |
|------------|---------|
| `DEPLOY_SUCKERS` | `deploySuckersFor` -- deploy new suckers for a project |
| `QUEUE_RULESETS` | `launchRulesetsFor`, `queueRulesetsOf` -- modify project rulesets |
| `SET_TERMINALS` | `launchRulesetsFor` -- set terminal configurations |
| `MAP_SUCKER_TOKEN` | Granted to `SUCKER_REGISTRY` at construction with `projectId=0` (all projects) |

## Errors

| Error | When |
|-------|------|
| `JBOmnichainDeployer_InvalidHook` | `_setup721()` detects the hook is `address(this)` -- prevents infinite forwarding loops |
| `JBOmnichainDeployer_UnexpectedNFTReceived` | `onERC721Received` called by a contract other than `PROJECTS` |
| `JBOmnichainDeployer_RulesetIdsUnpredictable` | `queueRulesetsOf` called when `latestRulesetIdOf(projectId) >= block.timestamp` -- ruleset ID prediction would fail |
| `JBOmnichainDeployer_ProjectIdMismatch` | `launchProjectFor` -- the project ID returned by the controller does not match the predicted `PROJECTS.count() + 1` |
| `JBOmnichainDeployer_ControllerMismatch` | `launchRulesetsFor`/`queueRulesetsOf` -- the provided controller does not match the project's controller in `JBDirectory` |

## Gotchas

1. `launchProjectFor` requires **no permissions** -- anyone can launch a project to any owner address.
2. `queueRulesetsOf` **reverts if called in the same block** as a previous ruleset queue (whether via deployer or directly). The `launchProjectFor` function doesn't have this guard because it predicts IDs from `PROJECTS.count()`, which is always 0 for a new project.
3. Ruleset IDs in `_extraDataHookOf` are keyed by `block.timestamp + i`. If the controller assigns different IDs than predicted, the stored hook configs will be orphaned and the deployer will behave as if no hooks were set (returning default values).
4. Sucker deployment salts are hashed with `_msgSender()`: `keccak256(abi.encode(salt, _msgSender()))`. Cross-chain deterministic addresses require using the **same sender** on each chain. The 721 hook salt uses `keccak256(abi.encode(_msgSender(), salt))` (reversed order).
5. `salt = bytes32(0)` **skips sucker deployment entirely**. Use a nonzero salt to deploy suckers.
6. The deployer **always forces `useDataHookForCashOut = true`** at the protocol level so it can intercept cash outs for sucker tax exemption. However, the 721 hook's `useDataHookForCashOut` flag (stored in `_tiered721HookOf`) and the custom hook's flag (stored in `_extraDataHookOf`) each control whether that hook processes cash outs. Set `useDataHookForCashOut: false` on the 721 config to skip it for fungible cashouts (it reverts with `JB721Hook_UnexpectedTokenCashedOut` otherwise).
7. Suckers get an **early return** in `beforeCashOutRecordedWith` -- they bypass all stored hooks entirely. This means suckers can cash out even if any hook would revert.
8. If no custom hook is stored or it doesn't grant permission, `hasMintPermissionFor` returns `false` for non-suckers. Only the custom hook in `_extraDataHookOf` is checked — the 721 hook is not consulted.
9. 721 ruleset config conversion enforces `useDataHookForPay = true` and `allowSetCustomToken = false`. These cannot be overridden.
10. Hook ownership is transferred to the **project** (not the owner) via `JBOwnable.transferOwnershipToProject(projectId)`. This happens **after** the project NFT is minted — in `launchProjectFor`, the hook is deployed before `controller.launchProjectFor`, and ownership is transferred after the project exists.
11. The deployer holds the project NFT temporarily during launch. If the controller's `launchProjectFor` reverts, the entire transaction reverts -- no stuck NFTs.
12. The constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` with `projectId=0`, meaning the registry can map tokens for **any project** deployed through this deployer.
13. All data hook functions (`beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`) are `view`. If the project's real hook needs to modify state in these functions, it will fail.
14. Setting a hook's `dataHook` to `address(this)` (the deployer itself) reverts with `JBOmnichainDeployer_InvalidHook` in `_setup721()`. This prevents infinite forwarding loops.
15. `onERC721Received` only accepts NFTs from the `PROJECTS` contract. Sending any other ERC-721 to the deployer will revert.
16. ERC2771 meta-transaction support allows gasless deployments via a trusted forwarder. Salt hashing uses `_msgSender()` (not `msg.sender`), so forwarder-relayed transactions use the original sender's address for deterministic sucker addresses.
17. Every project always gets a 721 hook, even with an empty tiers array. This wires up the 721 hook from the start, so the project owner can add and sell NFTs later without needing to reconfigure the data hook in a new ruleset.
18. The 721 hook is stored per-ruleset in `_tiered721HookOf[projectId][rulesetId]` with its `useDataHookForCashOut` flag. The custom data hook (if any) is stored separately in `_extraDataHookOf[projectId][rulesetId]`. They are never in the same array.
19. For payments, `beforePayRecordedWith` calls the 721 hook first (via `_tiered721HookOf`) to get its specs (including split fund amounts and tier metadata), then calls the custom hook from `_extraDataHookOf` (if `useDataHookForPay: true`) with a reduced amount context (payment minus split amount) so the buyback hook only considers the available amount. The deployer then adjusts the weight proportionally for splits (`weight = mulDiv(weight, amount - splitAmount, amount)`). The 721 hook's specs come first in the merged result, but only if the hook returned specs (0-tier hooks produce no specs).
20. For cash outs, `beforeCashOutRecordedWith` checks the 721 hook first (from `_tiered721HookOf`, if `useDataHookForCashOut: true`), then the custom hook (from `_extraDataHookOf`). If the 721 hook has the flag set and reverts (e.g., `JB721Hook_UnexpectedTokenCashedOut` for fungible cashouts), the revert propagates. Set `useDataHookForCashOut: false` on the 721 config to skip it and let the custom hook handle cashouts.
21. The `JBOmnichain721Config` parameter bundles the 721 hook deployment config (`deployTiersHookConfig`), the `useDataHookForCashOut` flag, and the `salt`. Custom data hooks are read from each ruleset's `metadata.dataHook` field.
22. For `queueRulesetsOf`, if no new tiers are provided (`deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length == 0`), the 721 hook from the **latest ruleset** is carried forward instead of deploying a new one. This is looked up from `_tiered721HookOf[projectId][latestRulesetId]`.

## Example Integration

```solidity
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "@bananapus/omnichain-deployers-v6/src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "@bananapus/omnichain-deployers-v6/src/structs/JBSuckerDeploymentConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

// --- Launch a project with suckers ---

// Configure sucker deployment (use a nonzero salt to deploy suckers).
JBSuckerDeploymentConfig memory suckerConfig = JBSuckerDeploymentConfig({
    deployerConfigurations: suckerDeployerConfigs, // per-chain sucker configs
    salt: bytes32("my-project-salt")               // deterministic addresses
});

// Configure 721 hook (even with 0 tiers, every project gets a hook).
JBOmnichain721Config memory deploy721Config = JBOmnichain721Config({
    deployTiersHookConfig: tiersHookConfig, // tier configuration (can be empty)
    useDataHookForCashOut: false,           // set true for NFT-based cashouts
    salt: bytes32("my-hook-salt")           // deterministic 721 hook address
});

// Launch in one transaction.
(uint256 projectId, IJB721TiersHook hook, address[] memory suckers) = omnichainDeployer.launchProjectFor({
    owner: msg.sender,
    projectUri: "ipfs://project-metadata",
    deploy721Config: deploy721Config,
    rulesetConfigurations: rulesetConfigs,
    terminalConfigurations: terminalConfigs,
    memo: "Launching omnichain project",
    suckerDeploymentConfiguration: suckerConfig,
    controller: controller
});

// --- Add suckers to an existing project ---

// Requires DEPLOY_SUCKERS permission on the project.
address[] memory newSuckers = omnichainDeployer.deploySuckersFor({
    projectId: projectId,
    suckerDeploymentConfiguration: suckerConfig
});

// --- Queue new rulesets (carries forward existing 721 hook if no new tiers) ---

// Requires QUEUE_RULESETS permission. Must be called in a different block
// than any previous ruleset queue for this project.
// Custom data hooks are read from each ruleset's metadata.dataHook field.
JBOmnichain721Config memory queue721Config = JBOmnichain721Config({
    deployTiersHookConfig: emptyTiersConfig, // no new tiers = carry forward existing hook
    useDataHookForCashOut: false,
    salt: bytes32(0)                         // no salt needed when carrying forward
});

(uint256 rulesetId, IJB721TiersHook queuedHook) = omnichainDeployer.queueRulesetsOf({
    projectId: projectId,
    deploy721Config: queue721Config,
    rulesetConfigurations: queueConfig,
    memo: "Queue new rulesets",
    controller: controller
});
```
