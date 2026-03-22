# nana-omnichain-deployers-v6 -- Audit Instructions

## Previous Audit Findings

No prior formal audit with finding IDs has been conducted on this repository. Known risks and design trade-offs are documented in [`RISKS.md`](./RISKS.md).

## Compiler and Version Info

Settings from `foundry.toml`:

| Setting | Value |
|---------|-------|
| Solidity version | `0.8.26` |
| EVM target | `cancun` |
| Intermediate representation | `via_ir = true` |
| Optimizer runs | `200` |
| Dependency paths | `node_modules`, `lib` |
| Fuzz runs | `4,096` |
| Invariant runs | `1,024` (depth: `100`, `fail_on_revert: false`) |

## Scope

One contract, 872 lines, four structs. This repo wraps Juicebox V6 project deployment to automatically configure cross-chain suckers and a 721 tiers hook. The deployer itself acts as a data hook proxy, composing a 721 hook with an optional custom hook (e.g. buyback) while granting registered suckers 0% cash-out tax and mint permission.

## Architecture

| File | Lines | Role |
|------|------:|------|
| `src/JBOmnichainDeployer.sol` | 872 | Main contract. Deploys projects, queues rulesets, proxies data hook calls. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `JBPermissioned`, `ERC2771Context`. |
| `src/interfaces/IJBOmnichainDeployer.sol` | 171 | Public interface. |
| `src/structs/JBDeployerHookConfig.sol` | 11 | Stores custom data hook address + pay/cashout flags per ruleset. |
| `src/structs/JBOmnichain721Config.sol` | 16 | 721 hook deployment config: tiers config + cashout flag + salt. |
| `src/structs/JBSuckerDeploymentConfig.sol` | 12 | Sucker deployer configs + salt for deterministic addresses. |
| `src/structs/JBTiered721HookConfig.sol` | 10 | Stores 721 hook address + `useDataHookForCashOut` flag per ruleset. |

**Total source**: ~1,092 lines.

## External Dependencies

| Dependency | What the deployer calls |
|------------|------------------------|
| `IJBController` | `launchProjectFor`, `launchRulesetsFor`, `queueRulesetsOf`, `DIRECTORY()`, `RULESETS()` |
| `IJBProjects` | `count()`, `ownerOf()`, `transferFrom()` |
| `IJBPermissions` | `setPermissionsFor()` (constructor), `hasPermission()` (via `_requirePermissionFrom`) |
| `IJB721TiersHookDeployer` | `deployHookFor()` |
| `IJBSuckerRegistry` | `isSuckerOf()`, `deploySuckersFor()` |
| `JBOwnable` | `transferOwnershipToProject()` on deployed 721 hooks |
| `IJBRulesetDataHook` | `beforePayRecordedWith()`, `beforeCashOutRecordedWith()`, `hasMintPermissionFor()` on stored hooks |
| `@prb/math` | `mulDiv()` for weight scaling |

## Storage Layout

Two mappings, both `internal`:

```solidity
// Slot 0 (after inherited storage)
mapping(uint256 projectId => mapping(uint256 rulesetId => JBDeployerHookConfig)) internal _extraDataHookOf;

// Slot 1
mapping(uint256 projectId => mapping(uint256 rulesetId => JBTiered721HookConfig)) internal _tiered721HookOf;
```

Both are keyed by `(projectId, rulesetId)` where `rulesetId` is predicted as `block.timestamp + i` during setup.

## Key Constants

- Constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` for `projectId = 0` (wildcard -- all projects).
- Salt for 721 hook deployment: `keccak256(abi.encode(_msgSender(), config.salt))` -- includes sender for cross-chain replay protection. `bytes32(0)` salt bypasses determinism.
- Salt for sucker deployment: `keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender()))`.
- Sucker deployment skipped when `suckerDeploymentConfiguration.salt == bytes32(0)`.

## Key Flows

### 1. `launchProjectFor` (two overloads)

```
launchProjectFor(owner, projectUri, [deploy721Config], rulesetConfigurations, terminalConfigurations, memo, suckerDeploymentConfiguration, controller)
```

**Full signature (with explicit 721 config)**:
```solidity
function launchProjectFor(
    address owner,
    string calldata projectUri,
    JBOmnichain721Config calldata deploy721Config,
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
    IJBController controller
) external returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
```

**Simplified overload** (omits `deploy721Config`, derives default from first ruleset's `baseCurrency`):
```solidity
function launchProjectFor(
    address owner,
    string calldata projectUri,
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
    IJBController controller
) external returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
```

**Execution order**:
1. `projectId = PROJECTS.count() + 1` -- predicted before creation.
2. `_deploy721Hook(projectId, config)` -- deploys 721 hook via `HOOK_DEPLOYER.deployHookFor()`.
3. `_setup721(projectId, rulesetConfigurations, hook, use721ForCashOut)` -- stores hook mappings, replaces `metadata.dataHook` with `address(this)`.
4. `controller.launchProjectFor(address(this), ...)` -- project NFT minted to deployer.
5. Reverts with `JBOmnichainDeployer_ProjectIdMismatch` if returned ID does not match prediction.
6. `JBOwnable(hook).transferOwnershipToProject(projectId)` -- transfers hook ownership.
7. `SUCKER_REGISTRY.deploySuckersFor(...)` -- if salt is non-zero.
8. `PROJECTS.transferFrom(address(this), owner, projectId)` -- transfers project NFT to intended owner.

**No permission checks**: Anyone can call `launchProjectFor`. The caller-supplied `controller` is trusted because the project does not exist yet (no controller to validate against).

### 2. `launchRulesetsFor` (two overloads)

```solidity
function launchRulesetsFor(
    uint256 projectId,
    JBOmnichain721Config memory deploy721Config,
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    IJBController controller
) external returns (uint256 rulesetId, IJB721TiersHook hook)
```

**Permission checks**: Requires both `LAUNCH_RULESETS` and `SET_TERMINALS` from project owner.

**Controller validation**: `_validateController(projectId, controller)` checks `controller.DIRECTORY().controllerOf(projectId) == controller`.

**Execution**: Always deploys a new 721 hook, transfers ownership, then calls `controller.launchRulesetsFor()`.

### 3. `queueRulesetsOf` (two overloads)

```solidity
function queueRulesetsOf(
    uint256 projectId,
    JBOmnichain721Config memory deploy721Config,
    JBRulesetConfig[] memory rulesetConfigurations,
    string calldata memo,
    IJBController controller
) external returns (uint256 rulesetId, IJB721TiersHook hook)
```

**Permission checks**: Requires `QUEUE_RULESETS` from project owner.

**Controller validation**: Same as `launchRulesetsFor`.

**Ruleset ID prediction guard**:
```solidity
uint256 latestRulesetId = controller.RULESETS().latestRulesetIdOf(projectId);
if (latestRulesetId >= block.timestamp) {
    revert JBOmnichainDeployer_RulesetIdsUnpredictable();
}
```

**721 hook handling**:
- If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`: deploy new hook, transfer ownership.
- Otherwise: carry forward `_tiered721HookOf[projectId][latestRulesetId].hook`.

### 4. `deploySuckersFor`

```solidity
function deploySuckersFor(
    uint256 projectId,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
) external returns (address[] memory suckers)
```

**Permission checks**: Requires `DEPLOY_SUCKERS` from project owner.

### 5. `beforePayRecordedWith` (data hook proxy -- view)

```solidity
function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
    external view returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
```

**Composition logic**:
1. Call 721 hook's `beforePayRecordedWith` (always, if hook exists). Extract `tiered721HookSpec` and `totalSplitAmount`.
2. Compute `projectAmount = context.amount.value - totalSplitAmount` (clamped to 0).
3. Call custom hook's `beforePayRecordedWith` with `hookContext.amount.value = projectAmount` (if `useDataHookForPay == true`).
4. If custom hook not called, `weight = context.weight`.
5. Scale weight: if `projectAmount == 0`, `weight = 0`. If `projectAmount < context.amount.value`, `weight = mulDiv(weight, projectAmount, context.amount.value)`.
6. Merge specs: 721 spec first, then custom hook specs.

### 6. `beforeCashOutRecordedWith` (data hook proxy -- view)

```solidity
function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
    external view returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
```

**Sequential composition**:
1. **Sucker check** (early return): If `SUCKER_REGISTRY.isSuckerOf(projectId, holder)` returns true, return `(0, cashOutCount, totalSupply, empty)`.
2. **Initialize**: Set `cashOutTaxRate`, `cashOutCount`, `totalSupply` from context.
3. **721 hook**: If stored and `useDataHookForCashOut == true`, call its `beforeCashOutRecordedWith` with current values. Updates `cashOutTaxRate`, `cashOutCount`, `totalSupply`, and stores returned specs (always 0 or 1).
4. **Custom hook**: If stored and `useDataHookForCashOut == true`, call its `beforeCashOutRecordedWith` with the already-updated values from the 721 hook. Further updates values and stores returned specs.
5. **Merge specs**: If either hook returned specs, merge them (721 first, then custom) into a single array.
6. **Fallback**: If neither returned specs, return adjusted `(cashOutTaxRate, cashOutCount, totalSupply, empty)`.

Note: Both hooks are called if both have the flag set. The 721 hook's output feeds into the custom hook's input. The sucker check always takes priority.

### 7. `hasMintPermissionFor` (data hook proxy -- view)

```solidity
function hasMintPermissionFor(uint256 projectId, JBRuleset memory ruleset, address addr)
    external view returns (bool)
```

1. If `SUCKER_REGISTRY.isSuckerOf(projectId, addr)` returns true, return `true`.
2. If custom hook exists and its `hasMintPermissionFor` returns true, return `true`.
3. The 721 hook is NOT checked for mint permission.
4. Otherwise return `false`.

## The `_setup721` Pattern (Critical)

```solidity
function _setup721(
    uint256 projectId,
    JBRulesetConfig[] memory rulesetConfigurations,
    IJB721TiersHook hook721,
    bool use721ForCashOut
) internal returns (JBRulesetConfig[] memory)
```

For each ruleset config at index `i`:
1. **Self-reference guard**: Reverts with `JBOmnichainDeployer_InvalidHook` if `metadata.dataHook == address(this)`.
2. **Store 721 hook**: `_tiered721HookOf[projectId][block.timestamp + i] = JBTiered721HookConfig(hook721, use721ForCashOut)`.
3. **Store custom hook**: If `metadata.dataHook != address(0)`, stores as `_extraDataHookOf[projectId][block.timestamp + i]`.
4. **Replace metadata**: Sets `metadata.dataHook = address(this)`, forces `useDataHookForPay = true`, `useDataHookForCashOut = true`.

**Ruleset ID prediction**: Keys are `block.timestamp + i`. This MUST match the IDs assigned by `JBRulesets` when the controller processes the configs. This is validated by:
- `launchProjectFor`: The project ID prediction (`PROJECTS.count() + 1`) is validated post-hoc via the `ProjectIdMismatch` revert.
- `queueRulesetsOf`: The `latestRulesetId >= block.timestamp` guard prevents same-block conflicts.
- `launchRulesetsFor`: No explicit guard on the ruleset ID prediction. This is safe because `launchRulesetsFor` is called on the controller which assigns IDs starting from `block.timestamp`.

## Gotchas for Auditors

1. **Ruleset ID prediction is fragile**: The deployer predicts ruleset IDs as `block.timestamp + i`. If the core protocol changes how IDs are assigned (e.g. incrementing differently), stored hooks will be keyed to the wrong rulesets. The `queueRulesetsOf` guard (`latestRulesetId >= block.timestamp`) catches same-block conflicts but does NOT protect against multi-tx-in-block race conditions on `launchRulesetsFor`.

2. **No reentrancy guard**: The contract does not use `ReentrancyGuard`. The `launchProjectFor` flow holds the project NFT temporarily. If `controller.launchProjectFor` calls back into the deployer, the project NFT is still held by the deployer. However, the entire tx would revert if the returned project ID doesn't match, so exploitation would require a cooperating controller.

3. **721 hook always deployed**: Even with 0 tiers, a 721 hook is deployed for every project/ruleset launch. This is intentional -- it ensures the hook exists for future tier additions.

4. **Cash-out hooks are now composed**: Like pay hooks, cash-out handling calls both hooks sequentially (721 hook first, then custom hook) and merges their specifications. The 721 hook's output values feed into the custom hook's input context.

5. **Carry-forward can yield zero-address hook**: In `queueRulesetsOf` with 0 tiers, the hook is carried from `_tiered721HookOf[projectId][latestRulesetId]`. If no hook was stored for that ruleset (e.g. the project was created outside the deployer), this returns `address(0)`.

6. **Custom hook receives reduced amount**: In `beforePayRecordedWith`, the custom data hook sees `amount.value = projectAmount` (original minus 721 splits). This is a modified `memory` copy of the original calldata context. The custom hook cannot see the original payment amount.

7. **Weight can overflow from custom hooks**: The deployer passes whatever weight the custom hook returns through `mulDiv`. If a custom hook returns `type(uint256).max`, the `mulDiv` still works correctly (PRB math handles this), but the resulting token mint amount could be extremely large.

8. **Constructor grants wildcard permission**: The deployer grants `MAP_SUCKER_TOKEN` to the `SUCKER_REGISTRY` for `projectId = 0` (wildcard). This means the sucker registry can map tokens for ANY project the deployer is associated with.

9. **`launchProjectFor` has no permission checks**: Anyone can call it. The project is created with the deployer as owner, then transferred. The caller-supplied controller is not validated (there's no existing project to validate against).

10. **`launchRulesetsFor` has no ruleset ID prediction guard**: Unlike `queueRulesetsOf`, `launchRulesetsFor` does not check `latestRulesetId >= block.timestamp`. This is acceptable because `launchRulesetsFor` is the first ruleset launch for an existing project, but could fail if called in the same block as another ruleset operation.

## Error Conditions

| Error | Trigger | Function |
|-------|---------|----------|
| `JBOmnichainDeployer_ControllerMismatch` | Provided controller does not match `directory.controllerOf(projectId)` | `queueRulesetsOf`, `launchRulesetsFor` |
| `JBOmnichainDeployer_InvalidHook` | Ruleset's `metadata.dataHook == address(this)` | `_setup721` (called by all launch/queue functions) |
| `JBOmnichainDeployer_ProjectIdMismatch` | `controller.launchProjectFor` returns unexpected project ID | `_launchProjectFor` |
| `JBOmnichainDeployer_RulesetIdsUnpredictable` | `latestRulesetIdOf(projectId) >= block.timestamp` | `_queueRulesetsOf` |
| `JBOmnichainDeployer_UnexpectedNFTReceived` | `onERC721Received` called by non-`PROJECTS` contract | `onERC721Received` |

## Priority Audit Areas

### P0 -- Critical

1. **Sucker privilege escalation**: Can a non-sucker address obtain 0% cash-out tax? The only gate is `SUCKER_REGISTRY.isSuckerOf()`. If the registry is compromised or returns incorrect values, all omnichain projects are affected. Verify the sucker registry's access control for `deploySuckersFor`.

2. **Ruleset ID prediction correctness**: Verify that `block.timestamp + i` matches the IDs assigned by `JBRulesets` in all scenarios. If the prediction is wrong, the deployer's stored hooks will never be consulted, and `beforePayRecordedWith` / `beforeCashOutRecordedWith` will return default values (no 721 integration, no sucker bypass).

3. **Ownership transfer ordering**: In `launchProjectFor`, the 721 hook is deployed BEFORE the project exists. Hook ownership is transferred after `controller.launchProjectFor` returns. If the controller reverts, the hook exists but is owned by the deployer with no project to transfer to. Verify this is a safe failure mode (entire tx reverts atomically).

### P1 -- High

4. **Data hook proxy composition**: Verify that the weight scaling in `beforePayRecordedWith` is correct when 721 splits consume part of the payment. Specifically verify: `mulDiv(weight, projectAmount, context.amount.value)` when `totalSplitAmount > 0`.

5. **Controller validation bypass**: `launchProjectFor` does not validate the controller because the project doesn't exist yet. Verify a malicious controller cannot exploit this (e.g. by returning a different project ID and tricking the deployer into configuring the wrong project).

6. **Permission escalation via deploySuckersFor**: The deployer grants `MAP_SUCKER_TOKEN` with `projectId = 0` (wildcard). Verify this cannot be abused to map tokens for projects not created through the deployer.

### P2 -- Medium

7. **Carry-forward stale hook**: When `queueRulesetsOf` carries forward a 721 hook from `latestRulesetId`, verify the carried hook is correct even after multiple queue operations.

8. **Custom hook isolation**: The custom hook receives a modified context (`amount.value = projectAmount`). Verify the hook cannot observe or manipulate the original amount. Verify the memory copy does not alias the original calldata.

9. **ERC2771 interaction**: The deployer uses `_msgSender()` for salt computation and permission checks. Verify the trusted forwarder cannot be used to spoof senders in permission-gated functions.

### P3 -- Low

10. **onERC721Received guard**: Only accepts NFTs from `PROJECTS`. Verify no other ERC721 can be sent to the deployer.

11. **supportsInterface completeness**: Verify the reported interfaces match actual implementations.

## Invariants to Verify

1. **Sucker always gets 0% tax**: For any `context` where `SUCKER_REGISTRY.isSuckerOf(projectId, holder)` returns true, `beforeCashOutRecordedWith` returns `cashOutTaxRate == 0`.

2. **Sucker always gets mint permission**: For any `(projectId, ruleset, addr)` where `SUCKER_REGISTRY.isSuckerOf(projectId, addr)` returns true, `hasMintPermissionFor` returns `true`.

3. **721 spec ordering**: In `beforePayRecordedWith`, if the 721 hook returns a spec, it is always the first element in the returned `hookSpecifications` array.

4. **Data hook replacement**: After `_setup721`, every ruleset config has `metadata.dataHook == address(this)`, `useDataHookForPay == true`, `useDataHookForCashOut == true`.

5. **Self-reference prevention**: `_setup721` reverts if any ruleset's `metadata.dataHook == address(this)`.

6. **Weight scaling correctness**: `weight = mulDiv(hookWeight, projectAmount, totalAmount)` where `projectAmount = totalAmount - splitAmount`. When `splitAmount >= totalAmount`, `weight == 0`.

7. **Controller validation**: `queueRulesetsOf` and `launchRulesetsFor` revert if the provided controller does not match `directory.controllerOf(projectId)`.

8. **Deployer never holds ETH**: The deployer has no `receive()` or `fallback()`, so it should never hold ETH.

9. **Hook storage consistency**: After `launchProjectFor` or `queueRulesetsOf`, `_tiered721HookOf[projectId][predictedRulesetId]` is non-zero for every queued ruleset.

10. **Ownership transfer completeness**: After `launchProjectFor`, the project NFT is owned by `owner` (not the deployer). After any 721 hook deployment, the hook's JBOwnable ownership is transferred to the project.

## Test Suite Overview

14 test files, ~5,000 lines of test code:

| Category | Files | Coverage |
|----------|-------|----------|
| Unit tests | `JBOmnichainDeployer.t.sol` | Constructor, `supportsInterface`, `onERC721Received`, `beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`, `deploySuckersFor`, simplified overloads |
| Guard tests | `JBOmnichainDeployerGuard.t.sol` | Ruleset ID prediction guard, same-block queue revert, multi-ruleset conflict |
| Attack tests | `OmnichainDeployerAttacks.t.sol` | Fake sucker bypass, reverting hook propagation, inflating hook weight, sucker bypass of reverting hooks |
| Edge cases | `OmnichainDeployerEdgeCases.t.sol` | `InvalidHook` self-reference, `ProjectIdMismatch`, weight=0 on full splits, `mulDiv` safety with `type(uint256).max`, `useDataHookForCashOut` flag routing, mint permission delegation |
| Composition | `Tiered721HookComposition.t.sol` | 721+buyback hook composition, split amount forwarding, weight adjustment, spec merging, cashout routing (721 vs custom vs fallback) |
| Reentrancy | `OmnichainDeployerReentrancy.t.sol` | Pay hook re-entering pay, cashout hook re-entering cashout, pay hook re-entering cashout (fork tests) |
| Invariants | `invariants/OmnichainDeployerInvariant.t.sol` + handler | Sucker 0% tax, 721 spec ordering, fund conservation, token supply consistency, deployer ETH balance, hook storage consistency |
| Regression | `regression/HookOwnershipTransfer.t.sol` | Hook ownership transfer in `queueRulesetsOf` |
| Regression | `regression/ValidateController.t.sol` | Controller validation rejects fake controllers |
| Fork | `fork/TestOmnichain*.t.sol` (5 files) | Real V4 PoolManager + buyback hook integration, 721 queue-and-adjust, cashout fork, stress, weight fork, sucker deployment fork |

## Testing Setup

```bash
# Install dependencies
npm install

# Run unit tests
forge test --match-path 'test/*.t.sol' -vvv

# Run fork tests (requires RPC)
RPC_ETHEREUM_MAINNET=<your_rpc> forge test --match-path 'test/fork/*.t.sol' -vvv

# Run invariant tests (requires RPC)
RPC_ETHEREUM_MAINNET=<your_rpc> forge test --match-contract OmnichainDeployerInvariant -vvv

# Compiler settings
# Solidity 0.8.26, EVM version: cancun, via_ir: true, optimizer: 200 runs
```

Foundry config is at `foundry.toml`. Fuzz runs: 4096. Invariant runs: 1024, depth: 100, `fail_on_revert: false`.

## How to Report Findings

Each finding should follow this 7-point structure:

1. **Title** -- A short, descriptive name (e.g. "Ruleset ID prediction fails on same-block queue").
2. **Affected contract(s)** -- File path(s) and line number(s).
3. **Description** -- What the issue is and why it matters. Include relevant code snippets.
4. **Trigger sequence** -- Step-by-step instructions to reproduce the issue (transactions, parameters, state preconditions).
5. **Impact** -- What can go wrong: fund loss, privilege escalation, denial of service, incorrect accounting, etc.
6. **Proof** -- A Foundry test, call trace, or formal argument demonstrating the issue. Runnable PoC strongly preferred.
7. **Fix** -- A concrete recommendation. Code diff preferred; otherwise a description of the required change.

### Severity Guide

| Severity | Criteria |
|----------|----------|
| **CRITICAL** | Direct loss or theft of funds, permanent freezing of funds, or unauthorized minting/burning of tokens. Exploitable without unusual preconditions. |
| **HIGH** | Significant fund loss under specific but realistic conditions, privilege escalation that bypasses access control, or corruption of core protocol state (e.g. wrong hook mappings that silently disable sucker bypass). |
| **MEDIUM** | Conditional issues requiring atypical state or timing (e.g. same-block race conditions), griefing attacks with bounded cost, or incorrect accounting that does not directly lose funds but violates documented invariants. |
| **LOW** | Code quality issues, gas inefficiencies, dead code, missing events, deviations from best practices, or edge cases with negligible economic impact. |
