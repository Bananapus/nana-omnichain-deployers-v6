# Juicebox Omnichain Deployers

## Purpose

Single-transaction deployment of Juicebox projects with cross-chain suckers and optional 721 tiers hooks. Wraps the project's data hooks to give suckers tax-free cash outs and mint permission without interfering with custom hooks. Stores hooks in an ordered array with per-hook `useDataHookForPay`/`useDataHookForCashOut` flags. Supports composing a 721 hook alongside a custom data hook (e.g., buyback hook) — both run on every payment.

## Contracts

| Contract | Role |
|----------|------|
| `JBOmnichainDeployer` | Deploys projects/rulesets/suckers, wraps data hooks for sucker tax exemption. Stores hooks in ordered array (`_dataHooksOf`) with per-hook flags. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

## Key Functions

### Deployment

| Function | What it does |
|----------|-------------|
| `launchProjectFor(owner, projectUri, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Creates a new project with rulesets, terminals, and suckers in one tx. Temporarily holds the project NFT. Returns `(projectId, suckers)`. |
| `launch721ProjectFor(owner, deployTiersHookConfig, launchProjectConfig, suckerConfig, controller, dataHookConfig, salt)` | Same as above but also deploys a 721 tiers hook. Pass a `JBDeployerHookConfig` with a custom data hook (e.g., buyback hook) to compose alongside the 721 hook, or `dataHook: address(0)` for none. Each hook gets its own `useDataHookForPay`/`useDataHookForCashOut` flags. Returns `(projectId, hook, suckers)`. |
| `launchRulesetsFor(projectId, rulesetConfigs, terminalConfigs, memo, controller)` | Launches new rulesets + terminals for an existing project. Requires `QUEUE_RULESETS` + `SET_TERMINALS`. |
| `launch721RulesetsFor(projectId, deployTiersHookConfig, launchRulesetsConfig, controller, dataHookConfig, salt)` | Launches rulesets with a new 721 tiers hook + optional custom data hook config. Requires `QUEUE_RULESETS` + `SET_TERMINALS`. |
| `queueRulesetsOf(projectId, rulesetConfigs, memo, controller)` | Queues future rulesets. Requires `QUEUE_RULESETS`. Reverts if rulesets were already queued in the same block. |
| `queue721RulesetsOf(projectId, deployTiersHookConfig, queueRulesetsConfig, controller, dataHookConfig, salt)` | Queues rulesets with a new 721 tiers hook + optional custom data hook config. Same same-block guard. |
| `deploySuckersFor(projectId, suckerConfig)` | Deploys new suckers for an existing project. Requires `DEPLOY_SUCKERS`. |

### Data Hook (IJBRulesetDataHook)

| Function | What it does |
|----------|-------------|
| `beforePayRecordedWith(context)` | Calls the 721 hook first (via `tiered721HookOf`) for its specs (including split amounts), then iterates hooks in `_dataHooksOf` with `useDataHookForPay: true` (skipping the 721 hook) with a reduced amount context (payment minus split amount) for weight + specs. Adjusts the returned weight proportionally so the terminal only mints tokens for the amount entering the project (`weight = mulDiv(weight, amount - splitAmount, amount)`). Merges both (721 hook specs first, then custom hook specs). |
| `beforeCashOutRecordedWith(context)` | If holder is a sucker: returns 0% tax immediately. Iterates hooks in `_dataHooksOf` — the first hook with `useDataHookForCashOut: true` handles it. If the 721 hook has this flag set and reverts (e.g., fungible cashout), the revert propagates. If no hook has the flag set, returns original values. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` for registered suckers, OR if any hook in `_dataHooksOf` (excluding the 721 hook) grants permission. Returns `false` only if none grant it. |

### Views

| Function | What it does |
|----------|-------------|
| `dataHooksOf(projectId, rulesetId)` | Returns the stored `JBDeployerHookConfig[]` array for a given project and ruleset. For 721 projects, the 721 hook is the first element; the custom hook (if any) follows. |
| `tiered721HookOf(projectId)` | Returns the project's 721 tiers hook (convenience view). Returns `address(0)` if no 721 hook was deployed. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`, `IERC165`. |
| `onERC721Received(...)` | Accepts project NFTs from `PROJECTS` only. Reverts for any other NFT contract. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBController`, `JBPermissioned`, `IJBProjects`, `IJBRulesetDataHook` | Launching projects, permission checks, project NFT transfers, data hook interface |
| `nana-721-hook-v6` | `IJB721TiersHookDeployer`, `JBDeploy721TiersHookConfig`, `JBLaunchProjectConfig`, `JBPayDataHookRulesetConfig` | Deploying 721 tiers hooks, converting 721 configs to standard configs |
| `nana-suckers-v6` | `IJBSuckerRegistry` | Deploying suckers, checking `isSuckerOf()` for tax-free cash outs |
| `nana-ownable-v6` | `JBOwnable` | Transferring 721 hook ownership to the project |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission constants |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, receiving project NFTs |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBDeployerHookConfig` | `IJBRulesetDataHook dataHook`, `bool useDataHookForPay`, `bool useDataHookForCashOut` | `_dataHooksOf` mapping keyed by `(projectId, rulesetId)` → ordered array. For 721 projects, the 721 hook is the first element with per-hook flags. |
| `JBSuckerDeploymentConfig` | `JBSuckerDeployerConfig[] deployerConfigurations`, `bytes32 salt` | All launch and deploy functions |

## Permission IDs

| Permission | Used By |
|------------|---------|
| `DEPLOY_SUCKERS` | `deploySuckersFor` -- deploy new suckers for a project |
| `QUEUE_RULESETS` | `launchRulesetsFor`, `launch721RulesetsFor`, `queueRulesetsOf`, `queue721RulesetsOf` -- modify project rulesets |
| `SET_TERMINALS` | `launchRulesetsFor`, `launch721RulesetsFor` -- set terminal configurations |
| `MAP_SUCKER_TOKEN` | Granted to `SUCKER_REGISTRY` at construction with `projectId=0` (all projects) |

## Errors

| Error | When |
|-------|------|
| `JBOmnichainDeployer_InvalidHook` | `_setup()` or `_setup721()` detects the hook is `address(this)` -- prevents infinite forwarding loops |
| `JBOmnichainDeployer_UnexpectedNFTReceived` | `onERC721Received` called by a contract other than `PROJECTS` |
| `JBOmnichainDeployer_RulesetIdsUnpredictable` | `queueRulesetsOf`/`queue721RulesetsOf` called when `latestRulesetIdOf(projectId) >= block.timestamp` -- ruleset ID prediction would fail |
| `JBOmnichainDeployer_ProjectIdMismatch` | `launchProjectFor`/`launch721ProjectFor` -- the project ID returned by the controller does not match the predicted `PROJECTS.count() + 1` |
| `JBOmnichainDeployer_ControllerMismatch` | `launchRulesetsFor`/`launch721RulesetsFor`/`queueRulesetsOf`/`queue721RulesetsOf` -- the provided controller does not match the project's controller in `JBDirectory` |

## Gotchas

1. `launchProjectFor` and `launch721ProjectFor` require **no permissions** -- anyone can launch a project to any owner address.
2. `queueRulesetsOf` and `queue721RulesetsOf` **revert if called in the same block** as a previous ruleset queue (whether via deployer or directly). The `launch*` functions don't have this guard because they predict IDs from `PROJECTS.count()`, which is always 0 for a new project.
3. Ruleset IDs in `_dataHooksOf` are keyed by `block.timestamp + i`. If the controller assigns different IDs than predicted, the stored hook configs will be orphaned and the deployer will behave as if no hooks were set (returning default values).
4. Sucker deployment salts are hashed with `_msgSender()`: `keccak256(abi.encode(salt, _msgSender()))`. Cross-chain deterministic addresses require using the **same sender** on each chain. For `launch721ProjectFor`, the 721 hook salt uses `keccak256(abi.encode(_msgSender(), salt))` (reversed order).
5. `salt = bytes32(0)` **skips sucker deployment entirely**. Use a nonzero salt to deploy suckers.
6. The deployer **always forces `useDataHookForCashOut = true`** at the protocol level so it can intercept cash outs for sucker tax exemption. However, each hook's **individual** `useDataHookForCashOut` flag (stored in `_dataHooksOf`) controls whether that hook processes cash outs. Set `useDataHookForCashOut: false` on the 721 metadata to skip it for fungible cashouts (it reverts with `JB721Hook_UnexpectedTokenCashedOut` otherwise).
7. Suckers get an **early return** in `beforeCashOutRecordedWith` -- they bypass all stored hooks entirely. This means suckers can cash out even if any hook would revert.
8. If no hooks are stored or none have the relevant flag set, `hasMintPermissionFor` returns `false` for non-suckers. The 721 hook is **skipped** in `hasMintPermissionFor` iteration — only custom hooks are checked.
9. 721 ruleset config conversion enforces `useDataHookForPay = true` and `allowSetCustomToken = false`. These cannot be overridden.
10. Hook ownership is transferred to the **project** (not the owner) via `JBOwnable.transferOwnershipToProject(projectId)`. The project owner controls the hook through project ownership.
11. The deployer holds the project NFT temporarily during launch. If the controller's `launchProjectFor` reverts, the entire transaction reverts -- no stuck NFTs.
12. The constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` with `projectId=0`, meaning the registry can map tokens for **any project** deployed through this deployer.
13. All data hook functions (`beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`) are `view`. If the project's real hook needs to modify state in these functions, it will fail.
14. Setting a hook's `dataHook` to `address(this)` (the deployer itself) reverts with `JBOmnichainDeployer_InvalidHook` in both `_setup()` and `_setup721()`. This prevents infinite forwarding loops.
15. `onERC721Received` only accepts NFTs from the `PROJECTS` contract. Sending any other ERC-721 to the deployer will revert.
16. ERC2771 meta-transaction support allows gasless deployments via a trusted forwarder. Salt hashing uses `_msgSender()` (not `msg.sender`), so forwarder-relayed transactions use the original sender's address for deterministic sucker addresses.
17. **Prefer `launch721ProjectFor` over `launchProjectFor` even with empty tiers.** Using `launch721ProjectFor` with an empty tiers array wires up the 721 hook from the start, so the project owner can add and sell NFTs later without needing to reconfigure the data hook in a new ruleset. `launchProjectFor` skips hook deployment entirely.
18. The 721 hook is stored both in `tiered721HookOf[projectId]` (convenience view, per-project) and as the first element of `_dataHooksOf[projectId][rulesetId]` (per-ruleset, with flags). The custom data hook (if any) is the second element.
19. For payments, `beforePayRecordedWith` calls the 721 hook first (via `tiered721HookOf`) to get its specs (including split fund amounts and tier metadata), then iterates custom hooks from `_dataHooksOf` with `useDataHookForPay: true` with a reduced amount context (payment minus split amount) so the buyback hook only considers the available amount. The deployer then adjusts the weight proportionally for splits (`weight = mulDiv(weight, amount - splitAmount, amount)`). The 721 hook's specs come first in the merged result.
20. For cash outs, `beforeCashOutRecordedWith` iterates `_dataHooksOf` and the first hook with `useDataHookForCashOut: true` handles it. If the 721 hook has this flag set and reverts (e.g., `JB721Hook_UnexpectedTokenCashedOut` for fungible cashouts), the revert propagates. Set `useDataHookForCashOut: false` on the 721 metadata to skip it and let the custom hook handle cashouts.
21. The `launch721*` and `queue721*` functions accept a `dataHookConfig` parameter (type `JBDeployerHookConfig`) for the custom data hook to compose alongside the 721 hook. Each hook gets its own `useDataHookForPay`/`useDataHookForCashOut` flags. Pass `dataHook: address(0)` for no custom hook.

## Example Integration

```solidity
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
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

// Launch in one transaction.
(uint256 projectId, address[] memory suckers) = omnichainDeployer.launchProjectFor({
    owner: msg.sender,
    projectUri: "ipfs://project-metadata",
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

// --- Queue new rulesets with a 721 hook + buyback hook ---

// Requires QUEUE_RULESETS permission. Must be called in a different block
// than any previous ruleset queue for this project.
// Pass the buyback hook as the custom data hook to compose alongside the 721 hook.
(uint256 rulesetId, IJB721TiersHook hook) = omnichainDeployer.queue721RulesetsOf({
    projectId: projectId,
    deployTiersHookConfig: tiersHookConfig,
    queueRulesetsConfig: queueConfig,
    controller: controller,
    dataHookConfig: JBDeployerHookConfig({
        dataHook: IJBRulesetDataHook(address(buybackHook)),
        useDataHookForPay: true,
        useDataHookForCashOut: false
    }),
    salt: bytes32("my-hook-salt")
});
```
