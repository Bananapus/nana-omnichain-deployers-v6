# N E M E S I S --- Raw Findings (Pre-Verification)

## Phase 0: Attacker Recon

**Language:** Solidity 0.8.26 (overflow-safe by default)

### Attack Goals (Q0.1)
1. Tax-free cash outs -- bypass cash out tax on any project by spoofing sucker status
2. Unauthorized minting -- get free project tokens by spoofing sucker identity
3. Steal project ownership -- intercept project NFT during the launch flow (minted to deployer, then transferred)
4. Corrupt data hook mapping -- cause incorrect rulesetId -> data hook mapping, making payments/cashouts bypass or use wrong hook
5. Lock 721 hook management -- cause hook ownership to be irrecoverable

### Novel Code (Q0.2)
- `JBOmnichainDeployer` is entirely novel -- data hook wrapper/proxy with predicted ruleset IDs
- `_setup()` ruleset ID prediction logic (`block.timestamp + i`) is fragile and novel
- Pattern of minting project NFT to `address(this)` then transferring to `owner`
- Constructor's wildcard `MAP_SUCKER_TOKEN` permission with `projectId: 0`

### Value Stores (Q0.3)
- `_dataHookOf[projectId][rulesetId]` controls which data hook is used for pay/cashout -- determines tax rates and token minting behavior
- `SUCKER_REGISTRY.isSuckerOf()` gates tax-free cash outs and mint permissions -- critical trust boundary
- Project ownership NFT -- temporarily held by this contract during launch

### Complex Paths (Q0.4)
- `launch721ProjectFor`: deploy hook -> predict ruleset IDs -> store data hook configs -> call controller -> transfer hook ownership -> deploy suckers -> transfer project NFT (7 steps, 5 external calls)
- `beforeCashOutRecordedWith`: check sucker registry -> look up data hook -> forward to data hook (critical cashout path)

### Coupled Value (Q0.5)
- `_dataHookOf[projectId][rulesetId]` must match actual ruleset IDs assigned by `JBRulesets` -- if prediction is wrong, data hook lookup returns empty/wrong hook
- Hook ownership must be transferred to project after deployment -- if missing, hook is permanently locked

### Priority Order
1. `queue721RulesetsOf` -- appears in attack goal #5, novel code, complex paths (missing ownership transfer)
2. `_setup()` ruleset ID prediction -- appears in attack goal #4, novel code, coupled value
3. `beforeCashOutRecordedWith` sucker bypass -- appears in attack goal #1, value stores
4. `launchProjectFor` / `launch721ProjectFor` race condition -- appears in attack goal #3, complex paths

---

## Phase 1: Dual Mapping

### 1A: Function-State Matrix

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `beforePayRecordedWith` | `_dataHookOf` | -- | view | `hook.dataHook.beforePayRecordedWith()` |
| `beforeCashOutRecordedWith` | `_dataHookOf` | -- | view | `SUCKER_REGISTRY.isSuckerOf()`, `hook.dataHook.beforeCashOutRecordedWith()` |
| `dataHookOf` | `_dataHookOf` | -- | view | -- |
| `hasMintPermissionFor` | `_dataHookOf` | -- | view | `SUCKER_REGISTRY.isSuckerOf()`, `hook.dataHook.hasMintPermissionFor()` |
| `supportsInterface` | -- | -- | view | -- |
| `deploySuckersFor` | -- | -- | DEPLOY_SUCKERS | `PROJECTS.ownerOf()`, `SUCKER_REGISTRY.deploySuckersFor()` |
| `launchProjectFor` | -- | `_dataHookOf` (via _setup) | none | `PROJECTS.count()`, `controller.launchProjectFor()`, `SUCKER_REGISTRY.deploySuckersFor()`, `PROJECTS.transferFrom()` |
| `launch721ProjectFor` | -- | `_dataHookOf` (via _setup) | none | `HOOK_DEPLOYER.deployHookFor()`, `controller.launchProjectFor()`, `JBOwnable.transferOwnershipToProject()`, `SUCKER_REGISTRY.deploySuckersFor()`, `PROJECTS.transferFrom()` |
| `launchRulesetsFor` | -- | `_dataHookOf` (via _setup) | QUEUE_RULESETS, SET_TERMINALS | `PROJECTS.ownerOf()`, `controller.launchRulesetsFor()` |
| `launch721RulesetsFor` | -- | `_dataHookOf` (via _setup) | QUEUE_RULESETS, SET_TERMINALS | `PROJECTS.ownerOf()`, `HOOK_DEPLOYER.deployHookFor()`, `JBOwnable.transferOwnershipToProject()`, `controller.launchRulesetsFor()` |
| `queueRulesetsOf` | -- | `_dataHookOf` (via _setup) | QUEUE_RULESETS | `PROJECTS.ownerOf()`, `controller.RULESETS().latestRulesetIdOf()`, `controller.queueRulesetsOf()` |
| `queue721RulesetsOf` | -- | `_dataHookOf` (via _setup) | QUEUE_RULESETS | `PROJECTS.ownerOf()`, `controller.RULESETS().latestRulesetIdOf()`, `HOOK_DEPLOYER.deployHookFor()`, `controller.queueRulesetsOf()` |
| `onERC721Received` | -- | -- | msg.sender == PROJECTS | -- |
| `_setup` (internal) | -- | `_dataHookOf` | -- | -- |
| `_from721Config` (internal) | -- | -- | pure | -- |
| constructor | -- | PROJECTS, SUCKER_REGISTRY, HOOK_DEPLOYER | -- | `PERMISSIONS.setPermissionsFor()` |

### 1B: Coupled State Dependency Map

Only one mutable state variable: `_dataHookOf[projectId][rulesetId]`

**PAIR 1:** `_dataHookOf[projectId][predicted_rulesetId]` <-> actual ruleset IDs assigned by JBRulesets
- Invariant: predicted IDs (`block.timestamp + i`) must match actual IDs
- Mutation points: `_setup()` (called from all launch/queue functions)

**PAIR 2 (External):** Hook ownership (in JBOwnable) <-> project ownership (in JBProjects)
- Invariant: After deployment, hook should be owned by the project (transferOwnershipToProject)
- Mutation points: `launch721ProjectFor`, `launch721RulesetsFor`, `queue721RulesetsOf`

### 1C: Cross-Reference (Nemesis Map)

| Function | Writes _dataHookOf | Transfers Hook Ownership | Checks Ruleset ID Predictability | Status |
|----------|-------------------|-------------------------|----------------------------------|--------|
| `launchProjectFor` | yes (via _setup) | N/A (no hook) | N/A (new project) | OK |
| `launch721ProjectFor` | yes (via _setup) | YES (L401) | N/A (new project) | OK |
| `launchRulesetsFor` | yes (via _setup) | N/A (no hook) | N/A (first rulesets) | OK |
| `launch721RulesetsFor` | yes (via _setup) | YES (L493) | N/A (first rulesets) | OK |
| `queueRulesetsOf` | yes (via _setup) | N/A (no hook) | YES (L536) | OK |
| `queue721RulesetsOf` | yes (via _setup) | **MISSING** | YES (L574) | **GAP** |

---

## Pass 1: Feynman Interrogation

### Finding FF-001: `queue721RulesetsOf` missing `transferOwnershipToProject` [RAW: HIGH]

**Source:** Category 3 (Consistency) -- Q3.2: If `launch721RulesetsFor` transfers hook ownership, does `queue721RulesetsOf` also do it?

**The code (`JBOmnichainDeployer.sol:556-600`):**
```solidity
function queue721RulesetsOf(...) external override returns (uint256 rulesetId, IJB721TiersHook hook) {
    _requirePermissionFrom({...});
    if (controller.RULESETS().latestRulesetIdOf(projectId) >= block.timestamp) {
        revert JBOmnichainDeployer_RulesetIdsUnpredictable();
    }
    hook = HOOK_DEPLOYER.deployHookFor({...});
    // MISSING: JBOwnable(address(hook)).transferOwnershipToProject(projectId);
    JBRulesetConfig[] memory rulesetConfigurations = _setup({...});
    rulesetId = controller.queueRulesetsOf({...});
}
```

**Comparison with `launch721RulesetsFor` (L463-511):**
```solidity
function launch721RulesetsFor(...) external override returns (uint256 rulesetId, IJB721TiersHook hook) {
    _requirePermissionFrom({...});
    _requirePermissionFrom({...});
    hook = HOOK_DEPLOYER.deployHookFor({...});
    JBOwnable(address(hook)).transferOwnershipToProject(projectId); // <-- PRESENT
    JBRulesetConfig[] memory rulesetConfigurations = _setup({...});
    rulesetId = controller.launchRulesetsFor({...});
}
```

**Why this is wrong:**
`HOOK_DEPLOYER.deployHookFor()` deploys a new hook and transfers ownership to `msg.sender` (the JBOmnichainDeployer contract). Both `launch721ProjectFor` (L401) and `launch721RulesetsFor` (L493) then transfer this ownership to the project via `JBOwnable(address(hook)).transferOwnershipToProject(projectId)`. The `queue721RulesetsOf` function does NOT make this call, leaving the hook permanently owned by the JBOmnichainDeployer contract, which has no mechanism to manage or transfer hook ownership.

**Impact:**
- The 721 hook deployed via `queue721RulesetsOf` is permanently locked
- The project owner cannot: add/remove/adjust NFT tiers, set token URI resolver, change hook flags, or perform any owner-only operations
- No recovery mechanism exists on JBOmnichainDeployer to transfer ownership of stranded hooks

---

### Finding FF-002: User-Supplied `controller` Parameter [RAW: LOW]

**Source:** Category 4 (Assumptions) -- Q4.1: What does this function assume about THE CALLER?

All launch/queue functions accept a user-supplied `controller` parameter. While permission checks use the real `PROJECTS` contract, the `controller` can be any address. A malicious controller could:
- Accept calls but not actually create rulesets (making stored data hooks point to non-existent rulesets)
- Return incorrect values from `RULESETS().latestRulesetIdOf()` to bypass the predictability check

**Mitigating factors:**
- `launchProjectFor`/`launch721ProjectFor`: The `assert` checks the returned projectId matches prediction, and `PROJECTS.transferFrom` requires the deployer to actually hold the NFT
- Permission-gated functions: The caller already has admin-level permissions for the project
- Self-harm only: A malicious controller can only affect the project the caller has permission for

---

### Finding FF-003: `assert` Used for External Result Validation [RAW: INFORMATIONAL]

**Source:** Category 6 (Return/Error) -- Q6.1

`launchProjectFor` (L315-324) and `launch721ProjectFor` (L389-398) use `assert(projectId == controller.launchProjectFor(...))`. In Solidity 0.8+, `assert` failures consume all remaining gas. Since this checks the result of an external call (user-influenced via `controller`), `require` would be more appropriate to refund unused gas on failure.

---

## Pass 2: State Inconsistency Audit

### Mutation Matrix

| State Variable | Mutating Function | Updates Coupled State? |
|---------------|-------------------|----------------------|
| `_dataHookOf[pid][ts+0]` | `_setup()` via `launchProjectFor` | N/A (single state) |
| `_dataHookOf[pid][ts+0]` | `_setup()` via `launch721ProjectFor` | N/A |
| `_dataHookOf[pid][ts+0]` | `_setup()` via `launchRulesetsFor` | N/A |
| `_dataHookOf[pid][ts+0]` | `_setup()` via `launch721RulesetsFor` | N/A |
| `_dataHookOf[pid][ts+0]` | `_setup()` via `queueRulesetsOf` | N/A |
| `_dataHookOf[pid][ts+0]` | `_setup()` via `queue721RulesetsOf` | N/A |
| Hook ownership (external) | `launch721ProjectFor` L401 | YES - transferred to project |
| Hook ownership (external) | `launch721RulesetsFor` L493 | YES - transferred to project |
| Hook ownership (external) | `queue721RulesetsOf` | **MISSING** - NOT transferred |

### Parallel Path Comparison

| Coupled State | `launch721ProjectFor` | `launch721RulesetsFor` | `queue721RulesetsOf` |
|--------------|----------------------|----------------------|---------------------|
| Deploy hook | YES | YES | YES |
| Store data hooks (_setup) | YES | YES | YES |
| Transfer hook ownership to project | YES (L401) | YES (L493) | **MISSING** |
| Queue/launch rulesets | YES | YES | YES |

**FINDING SI-001:** `queue721RulesetsOf` does not transfer hook ownership. This is the same finding as FF-001, discovered independently via parallel path comparison.

---

## Pass 3: Feynman Re-interrogation (targeted)

Re-interrogated `queue721RulesetsOf` based on Pass 2 gap:

**Q (Category 1):** WHY doesn't `queue721RulesetsOf` transfer hook ownership?
- Most likely: omission during development. The function was likely built by copying `queueRulesetsOf` (which has no hook) and adding hook deployment from `launch721RulesetsFor`, but the ownership transfer line was missed.

**Q (Category 5):** What happens if `queue721RulesetsOf` is called, and then the project owner tries to manage the hook?
- The hook's `owner()` returns the JBOmnichainDeployer contract address
- All `onlyOwner` functions on the hook revert when called by anyone other than JBOmnichainDeployer
- JBOmnichainDeployer has no function to call hook management functions
- The hook is permanently locked in its initial configuration

No new findings from Pass 3.

---

## Pass 4: State Re-analysis (targeted)

Checked if the root cause (missing ownership transfer) affects other coupled pairs or code paths. No additional gaps found. The finding is isolated to `queue721RulesetsOf`.

**Convergence:** No new findings in Pass 4. Loop terminates.

---

## Multi-Transaction Journey Tracing

### Sequence for FF-001/SI-001:
1. Project owner calls `queue721RulesetsOf` with a 721 hook config
2. Hook is deployed and initialized with tiers
3. Rulesets are queued with the hook as data source (wrapped by deployer)
4. Hook ownership remains with JBOmnichainDeployer
5. When the queued ruleset becomes active, payments trigger the hook correctly
6. Project owner tries to add a new tier to the hook -> **REVERTS** (only JBOmnichainDeployer can call)
7. Project owner tries to set a new token URI resolver -> **REVERTS**
8. No recovery path exists

### Adversarial Sequence Test:
- This is NOT an attacker exploit -- it's a functional bug affecting legitimate users
- Any project that queues 721 rulesets via this deployer will have a permanently locked hook
