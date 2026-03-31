# Administration

Admin privileges and their scope in nana-omnichain-deployers-v6.

## At A Glance

| Item | Details |
|------|---------|
| Scope | Omnichain project launch, hook composition, sucker deployment, and the deployer's data-hook proxy behavior. |
| Operators | Project owners and delegates, the `JBOmnichainDeployer`, and the configured `JBSuckerRegistry` with its wildcard token-mapping grant. |
| Highest-risk actions | Launching a project with the wrong hook composition, terminal configuration, or cross-chain setup, then assuming it can be rewritten later. |
| Recovery posture | The deployer's immutable dependencies cannot be edited in place. Project-level recovery usually means launching corrected rulesets or redeploying the broader project path. |

## Routine Operations

- Validate all deploy-time hook choices, 721 settings, and sucker configuration before using `launchProjectFor` or `launchRulesetsFor`.
- Keep the distinction clear between per-ruleset composed hooks and the deployer's permanent proxy role.
- Use the deployer when you want its tax-free sucker and mint-permission behavior; otherwise, do not assume it is a drop-in replacement for arbitrary hook wiring.

## One-Way Or High-Risk Actions

- Constructor-time wildcard permissions and immutable references on the deployer cannot be changed afterward.
- Launch-time hook composition choices determine how future pay and cash-out flows are merged for that ruleset.
- A bad omnichain deployment can leave a project with a cross-chain shape that is expensive to unwind operationally.

## Recovery Notes

- If the project is still administratively flexible, queue new rulesets or use project-level migration paths to move to corrected hook composition.
- If the deployer's own immutable assumptions are wrong, recovery means deploying a new deployer path rather than trying to hot-fix the existing one.

## Roles

| Role | How Assigned | Scope |
|------|-------------|-------|
| Project owner | Holds the project's ERC-721 (minted by `JBProjects`) | Per-project. Can delegate via `JBPermissions`. |
| Permitted operator | Granted specific permission IDs by the project owner through `JBPermissions` | Per-project, per-permission. ROOT (1) grants all. Wildcard projectId=0 grants across all projects. |
| Registered sucker | Deployed via `JBSuckerRegistry.deploySuckersFor` (requires DEPLOY_SUCKERS permission) | Per-project. Gets 0% cash-out tax and mint permission automatically. |
| JBSuckerRegistry | Set at construction, granted MAP_SUCKER_TOKEN for all projects (projectId=0 wildcard) | Protocol-wide. Maps tokens for sucker bridging. |

## Privileged Functions

### JBOmnichainDeployer

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `deploySuckersFor` | Project owner or operator | `DEPLOY_SUCKERS` | Per-project | Deploys new cross-chain suckers for an existing project via the sucker registry. |
| `launchRulesetsFor` | Project owner or operator | `LAUNCH_RULESETS` + `SET_TERMINALS` | Per-project | Deploys a 721 tiers hook, launches new rulesets with terminal configuration for an existing project. Has a simplified overload without `deploy721Config`. |
| `queueRulesetsOf` | Project owner or operator | `QUEUE_RULESETS` | Per-project | Queues new rulesets for an existing project. If tiers provided, deploys a new 721 hook. Otherwise, carries forward the 721 hook from the latest ruleset. Has a simplified overload without `deploy721Config`. |

### Permissionless Functions

| Function | Who Can Call | What It Does |
|----------|-------------|--------------|
| `launchProjectFor` | Anyone | Creates a new project with a 721 tiers hook (even with 0 tiers) and suckers. The ERC-721 is minted to the specified `owner`. Returns `(projectId, hook, suckers)`. Has a simplified overload without `deploy721Config` that uses a default empty-tier 721 config. |
| `beforePayRecordedWith` | JBMultiTerminal (via controller) | View function: always calls the 721 hook (when its address is non-zero) for specs, then calls the custom hook (if configured and `useDataHookForPay` is set) with the reduced amount. Merges results. |
| `beforeCashOutRecordedWith` | JBMultiTerminal (via controller) | View function: returns 0% cash-out tax for registered suckers. Calls 721 hook first (from `_tiered721HookOf`, if `useDataHookForCashOut: true`), then calls custom hook (from `_extraDataHookOf`, if `useDataHookForCashOut: true`) with the updated values from the 721 hook. Both hooks' specifications are merged. If neither has the flag set, returns original values. |
| `hasMintPermissionFor` | JBController | View function: returns true for registered suckers, otherwise checks the custom hook in `_extraDataHookOf`. |
| `extraDataHookOf` | Anyone | View function: returns the stored `JBDeployerHookConfig` for a project/ruleset pair (the custom data hook). |
| `tiered721HookOf` | Anyone | View function: returns the stored 721 hook and `useDataHookForCashOut` flag for a project/ruleset pair. |

## Deployment Administration

**Who can deploy omnichain projects:** Anyone. The `launchProjectFor` function is permissionless. The caller specifies an `owner` address that receives the project ERC-721.

**Deployment flow:**
1. The deployer deploys a 721 tiers hook via `HOOK_DEPLOYER` (even with 0 tiers).
2. It configures rulesets via `_setup721()`, sets itself as the data hook wrapper.
3. It calls `controller.launchProjectFor`, which mints the project ERC-721 to `address(this)`.
4. It transfers 721 hook ownership to the project (requires project NFT to exist).
5. It optionally deploys suckers via the sucker registry.
6. It transfers the project ERC-721 to the specified `owner`.

**Configurable parameters at deployment:**
- Ruleset configurations (duration, weight, decay, approval hooks, splits, fund access limits, metadata flags).
- Terminal configurations (which terminals accept which tokens).
- 721 tiers hook configuration (tier pricing, supply, metadata, categories — can be empty for 0 tiers).
- Sucker deployment configuration (which chains, which deployers, token mappings).
- Salt for deterministic cross-chain address matching.

## Cross-Chain Controls

| Action | Who | Mechanism |
|--------|-----|-----------|
| Deploy suckers for existing project | Project owner or DEPLOY_SUCKERS operator | `deploySuckersFor` calls `SUCKER_REGISTRY.deploySuckersFor` |
| Deploy suckers during project launch | Project deployer (anyone) | Included in `launchProjectFor` if `salt != bytes32(0)` |
| Map sucker tokens | JBSuckerRegistry | Granted MAP_SUCKER_TOKEN at construction with projectId=0 wildcard |
| Grant 0% cash-out tax to suckers | Automatic | `beforeCashOutRecordedWith` checks `SUCKER_REGISTRY.isSuckerOf` |
| Grant mint permission to suckers | Automatic | `hasMintPermissionFor` checks `SUCKER_REGISTRY.isSuckerOf` |

**Cross-chain determinism:** The salt for sucker deployment is combined with `_msgSender()` (`keccak256(abi.encode(salt, _msgSender()))`). Deploying from the same sender address with the same salt on each chain produces matching sucker addresses.

## Data Hook Proxy Pattern

`JBOmnichainDeployer` acts as a data hook proxy. When set as a project's `dataHook` in ruleset metadata, it wraps up to two inner hooks:

1. **721 tiers hook** (`_tiered721HookOf[projectId][rulesetId]`): Handles NFT-based pay/cashout logic.
2. **Extra data hook** (`_extraDataHookOf[projectId][rulesetId]`): An optional custom hook for additional pay/cashout logic.

### Call flow for `beforePayRecordedWith`:

```
Terminal -> Controller -> JBOmnichainDeployer.beforePayRecordedWith()
  1. Call 721 hook's beforePayRecordedWith (always, when its address is non-zero)
     -> Get pay hook specifications and the total split amount
  2. Call extra hook's beforePayRecordedWith (if useDataHookForPay is set on extra hook config)
     -> Amount is reduced by what the 721 hook already allocated
  3. Scale the extra hook's weight proportionally to the project's share of the payment
  4. Merge both hooks' specifications and return
```

### Call flow for `beforeCashOutRecordedWith`:

```
Terminal -> Controller -> JBOmnichainDeployer.beforeCashOutRecordedWith()
  1. Check if caller is a registered sucker -> return 0% cash-out tax (fee-free bridging)
  2. Call 721 hook's beforeCashOutRecordedWith (if useDataHookForCashOut is set on 721 config)
     -> Get cashout hook specifications and adjusted values
  3. Call extra hook's beforeCashOutRecordedWith (if useDataHookForCashOut is set on extra config)
     -> Receives updated values from 721 hook
  4. Merge both hooks' specifications and return
```

**`useDataHookForCashOut` / `useDataHookForPay` flags:** These flags control whether each hook participates in a given operation. For the **extra data hook**, the flags are stored per-ruleset in the `JBDeployerHookConfig` struct -- if the flag is `false`, that hook is skipped entirely and the original values are returned unchanged for that hook's portion. The **721 hook** behaves differently: it is **always** called during `beforePayRecordedWith` when its address is non-zero (no `useDataHookForPay` check), but for `beforeCashOutRecordedWith` it respects the `useDataHookForCashOut` flag stored in `JBTiered721HookConfig`.

**Write-once storage:** Both `_tiered721HookOf` and `_extraDataHookOf` mappings are written once during `_setup721()` and never updated. New rulesets can reference different hooks, but existing ruleset-to-hook mappings are permanent.

## Immutable Configuration

These values are set at deployment and cannot be changed:

| Property | Type | What It Is |
|----------|------|-----------|
| `PROJECTS` | `IJBProjects` | The ERC-721 contract for project ownership. |
| `HOOK_DEPLOYER` | `IJB721TiersHookDeployer` | The deployer for 721 tiers hooks. |
| `SUCKER_REGISTRY` | `IJBSuckerRegistry` | The registry for deploying and tracking suckers. |
| `PERMISSIONS` | `IJBPermissions` | The permissions contract (inherited from JBPermissioned). |
| Trusted forwarder | `address` | The ERC-2771 trusted forwarder for meta-transactions. |
| MAP_SUCKER_TOKEN grant | Permission | Granted to SUCKER_REGISTRY at construction for all projects (projectId=0). Cannot be revoked by this contract. |

**Data hook mappings** (`_tiered721HookOf[projectId][rulesetId]` and `_extraDataHookOf[projectId][rulesetId]`) are write-once per ruleset ID. They are set during `_setup721()` and never updated or deleted.

## Admin Boundaries

What admins **cannot** do:

- **Cannot upgrade the deployer.** JBOmnichainDeployer has no upgrade mechanism, proxy pattern, or self-destruct.
- **Cannot change immutable references.** PROJECTS, HOOK_DEPLOYER, SUCKER_REGISTRY, PERMISSIONS, and the trusted forwarder are all immutable.
- **Cannot modify stored data hooks.** Once a ruleset's hooks are stored in `_tiered721HookOf` and `_extraDataHookOf`, they cannot be changed. New rulesets can use different hooks, but existing mappings are permanent.
- **Cannot bypass permission checks.** All post-deployment admin functions require JBPermissions verification against the project owner.
- **Cannot revoke sucker privileges.** Once a sucker is registered in JBSuckerRegistry, it automatically gets 0% cash-out tax and mint permission for its project. Revocation must happen at the registry level.
- **Cannot set the deployer as its own data hook.** `_setup721()` explicitly reverts with `JBOmnichainDeployer_InvalidHook` if a hook is `address(this)`.
- **Cannot use a controller that doesn't match the project.** `_validateController` reverts with `JBOmnichainDeployer_ControllerMismatch` if the provided controller is not the project's actual controller in the directory.
- **Cannot steal project ownership during deployment.** The deployer holds the project ERC-721 only transiently and transfers it to the specified owner in the same transaction.
- **Cannot drain funds.** The deployer never holds or manages token balances. It only orchestrates configuration.
