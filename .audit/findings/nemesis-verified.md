# N E M E S I S -- Verified Findings

## Scope
- Language: Solidity 0.8.26
- Modules analyzed: `JBOmnichainDeployer.sol`, `IJBOmnichainDeployer.sol`, `JBDeployerHookConfig.sol`, `JBSuckerDeploymentConfig.sol`, `Deploy.s.sol`, `DeployersDeploymentLib.sol`
- Functions analyzed: 16 (12 in JBOmnichainDeployer + 4 in deploy scripts)
- Coupled state pairs mapped: 2 (predicted rulesetId <-> actual rulesetId, hook ownership <-> project ownership)
- Mutation paths traced: 18
- Nemesis loop iterations: 4 (Pass 1 Feynman + Pass 2 State + Pass 3 Feynman targeted + Pass 4 State targeted)

## Nemesis Map (Phase 1 Cross-Reference)

| Function | Deploys Hook | Stores Data Hooks | Transfers Hook to Project | Checks ID Predictability |
|----------|-------------|-------------------|--------------------------|-------------------------|
| `launchProjectFor` | -- | yes | N/A | N/A (new project) |
| `launch721ProjectFor` | yes | yes | **YES** (L401) | N/A (new project) |
| `launchRulesetsFor` | -- | yes | N/A | N/A (first rulesets) |
| `launch721RulesetsFor` | yes | yes | **YES** (L493) | N/A (first rulesets) |
| `queueRulesetsOf` | -- | yes | N/A | YES (L536) |
| `queue721RulesetsOf` | yes | yes | **MISSING** | YES (L574) |

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Original Severity | Verdict | Final Severity |
|----|--------|-------------|-------------|-------------------|---------|----------------|
| NM-001 | Cross-feed: Feynman Q3.2 -> State parallel path | Hook ownership <-> Project ownership | `queue721RulesetsOf` | HIGH | TRUE POSITIVE | HIGH |
| NM-002 | Feynman Q4.1 | N/A | All launch/queue functions | LOW | TRUE POSITIVE | LOW |
| NM-003 | Feynman Q6.1 | N/A | `launchProjectFor`, `launch721ProjectFor` | INFO | TRUE POSITIVE | INFO |

---

## Verified Findings (TRUE POSITIVES only)

### Finding NM-001: `queue721RulesetsOf` Missing Hook Ownership Transfer

**Severity:** HIGH
**Source:** Cross-feed Pass 1 (Feynman Q3.2 consistency) -> Pass 2 (State parallel path comparison)
**Verification:** Code trace (Method A) + external dependency analysis (JB721TiersHookDeployer)

**Coupled Pair:** Hook ownership (JBOwnable) <-> Project ownership (JBProjects)
**Invariant:** After a 721 hook is deployed for a project, hook ownership must be transferred to the project via `transferOwnershipToProject(projectId)` so the project owner can manage the hook.

**Feynman Question that exposed it:**
> Q3.2: If `launch721RulesetsFor` transfers hook ownership to the project, does `queue721RulesetsOf` (which does the same work) also transfer it?

**State Mapper gap that confirmed it:**
> Parallel path comparison of all three 721-deploying functions shows `queue721RulesetsOf` is the only path that does NOT call `transferOwnershipToProject`.

**Breaking Operation:** `queue721RulesetsOf()` at `JBOmnichainDeployer.sol:556-600`
- Deploys a new 721 hook via `HOOK_DEPLOYER.deployHookFor()` (L581-585)
- The hook deployer transfers ownership to `msg.sender` (the JBOmnichainDeployer) -- confirmed at `JB721TiersHookDeployer.sol:100`
- Does NOT call `JBOwnable(address(hook)).transferOwnershipToProject(projectId)`
- Hook ownership is permanently stuck with the JBOmnichainDeployer contract

**The vulnerable code (`JBOmnichainDeployer.sol:556-600`):**
```solidity
function queue721RulesetsOf(
    uint256 projectId,
    JBDeploy721TiersHookConfig memory deployTiersHookConfig,
    JBQueueRulesetsConfig calldata queueRulesetsConfig,
    IJBController controller,
    bytes32 salt
)
    external
    override
    returns (uint256 rulesetId, IJB721TiersHook hook)
{
    _requirePermissionFrom({
        account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.QUEUE_RULESETS
    });

    if (controller.RULESETS().latestRulesetIdOf(projectId) >= block.timestamp) {
        revert JBOmnichainDeployer_RulesetIdsUnpredictable();
    }

    hook = HOOK_DEPLOYER.deployHookFor({
        projectId: projectId,
        deployTiersHookConfig: deployTiersHookConfig,
        salt: salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), salt))
    });

    // >>> MISSING: JBOwnable(address(hook)).transferOwnershipToProject(projectId); <<<

    JBRulesetConfig[] memory rulesetConfigurations = _setup({
        projectId: projectId,
        rulesetConfigurations: _from721Config({
            launchProjectConfig: queueRulesetsConfig.rulesetConfigurations, dataHook: hook
        })
    });

    rulesetId = controller.queueRulesetsOf({
        projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: queueRulesetsConfig.memo
    });
}
```

**Comparison with correct code (`launch721RulesetsFor`, L463-511):**
```solidity
function launch721RulesetsFor(...) external override returns (uint256 rulesetId, IJB721TiersHook hook) {
    // ... permissions ...
    hook = HOOK_DEPLOYER.deployHookFor({...});
    JBOwnable(address(hook)).transferOwnershipToProject(projectId); // <-- PRESENT HERE
    JBRulesetConfig[] memory rulesetConfigurations = _setup({...});
    rulesetId = controller.launchRulesetsFor({...});
}
```

**Trigger Sequence:**
1. Project owner calls `queue721RulesetsOf` to queue new rulesets with a 721 hook
2. Hook is deployed and initialized with tiers, hook ownership goes to JBOmnichainDeployer
3. Rulesets are queued with the hook as data source (wrapped by deployer)
4. The queued ruleset becomes active
5. Project owner attempts to manage the hook (add tier, change URI resolver, etc.)
6. Transaction reverts -- only JBOmnichainDeployer (which has no management functions) can call owner-restricted functions

**Consequence:**
- The 721 hook deployed via `queue721RulesetsOf` is permanently unmanageable
- The project owner cannot add, remove, or adjust NFT tiers
- The project owner cannot set a new token URI resolver
- The project owner cannot change hook flags
- No recovery mechanism exists -- JBOmnichainDeployer has no function to call `transferOwnershipToProject` on previously deployed hooks
- This affects ANY project that uses `queue721RulesetsOf`, which is the primary function for adding 721 hooks to existing rulesets

**Verification Evidence:**
- Code trace confirmed: `transferOwnershipToProject` appears at L401 (`launch721ProjectFor`) and L493 (`launch721RulesetsFor`) but NOT in `queue721RulesetsOf` (L556-600)
- External dependency confirmed: `JB721TiersHookDeployer.deployHookFor()` (L99-100) calls `JBOwnable(address(newHook)).transferOwnership(_msgSender())`, setting the deployer as owner
- No internal call, modifier, or hook in `queue721RulesetsOf` performs the transfer
- JBOmnichainDeployer has no function to manage or transfer ownership of deployed hooks

**Fix:**
```solidity
// In queue721RulesetsOf, after deploying the hook:
hook = HOOK_DEPLOYER.deployHookFor({
    projectId: projectId,
    deployTiersHookConfig: deployTiersHookConfig,
    salt: salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), salt))
});

// ADD THIS LINE:
JBOwnable(address(hook)).transferOwnershipToProject(projectId);

JBRulesetConfig[] memory rulesetConfigurations = _setup({...});
```

---

### Finding NM-002: User-Supplied Controller Parameter (Trust Assumption)

**Severity:** LOW
**Source:** Feynman Q4.1 (assumptions about caller)
**Verification:** Code trace (Method A)

All external functions (`launchProjectFor`, `launch721ProjectFor`, `launchRulesetsFor`, `launch721RulesetsFor`, `queueRulesetsOf`, `queue721RulesetsOf`) accept a user-supplied `controller` parameter of type `IJBController`. This is not validated against the project's actual controller (e.g., via `JBDirectory`).

A malicious controller could:
- Accept calls but not create proper rulesets (making stored `_dataHookOf` entries point to non-existent ruleset IDs)
- Return fake values from `RULESETS().latestRulesetIdOf()` to bypass the predictability check in `queueRulesetsOf`/`queue721RulesetsOf`

**Mitigating factors:**
- For `launchProjectFor`/`launch721ProjectFor`: the `assert` check + `PROJECTS.transferFrom` requirement make it infeasible to exploit with a malicious controller (the deployer must actually hold the correct project NFT)
- For permission-gated functions: the caller already has admin-level permissions for the project and could cause equivalent damage through the real controller
- The damage from a malicious controller is limited to self-harm (only affects the caller's own project)

**Impact:** An authorized caller could inadvertently or intentionally use a non-standard controller, causing stored data hook entries to be orphaned (pointing to non-existent rulesets). This results in the deployer being the data hook for rulesets but returning passthrough values (no actual hook forwarding), which means sucker tax bypass still works but custom pay/cashout hooks would be silently skipped.

**Fix consideration:** Validate the controller against the project's directory, e.g.:
```solidity
// Optional: validate controller matches the project's registered controller
// require(address(controller) == address(DIRECTORY.controllerOf(projectId)), "wrong controller");
```
This is a design decision -- the current approach provides flexibility for projects to use different controllers.

---

### Finding NM-003: `assert` Used for External Call Result Checking

**Severity:** INFORMATIONAL
**Source:** Feynman Q6.1 (return value handling)
**Verification:** Code inspection

`launchProjectFor` (L315-324) and `launch721ProjectFor` (L389-398) use `assert(projectId == controller.launchProjectFor(...))` to verify the returned project ID. In Solidity 0.8+, failed `assert` consumes all remaining gas. Since this validates the result of an external call (influenced by user-supplied `controller`), using `require` would be more gas-efficient on failure by refunding unused gas.

**Impact:** No security impact. Users pay more gas on failure (e.g., when racing with another project launch). The `assert` was likely chosen intentionally to signal "this should never fail" semantics.

---

## False Positives Eliminated

### FP-001: Reentrancy in launch flows
**Initial hypothesis:** Multiple external calls in `launchProjectFor` and `launch721ProjectFor` without a reentrancy guard could allow state manipulation.
**Why false positive:** Between external calls, the deployer holds no exploitable state. The project NFT is held transiently, but reentrant calls would operate on different project IDs (since `PROJECTS.count()` has been incremented). No function on the deployer allows extracting a held NFT except the launch flow itself, which requires a matching project ID prediction.

### FP-002: Sucker registry trust boundary bypass
**Initial hypothesis:** An attacker could spoof sucker status to get tax-free cash outs.
**Why false positive:** The `SUCKER_REGISTRY.isSuckerOf()` check delegates to the external registry. Spoofing requires compromising the registry itself, which is outside this contract's scope. The deployer correctly trusts the registry as designed.

### FP-003: Ruleset ID prediction mismatch for `launchRulesetsFor`
**Initial hypothesis:** `launchRulesetsFor` lacks the `latestRulesetIdOf >= block.timestamp` check that `queueRulesetsOf` has, potentially causing ID prediction mismatch.
**Why false positive:** `launchRulesetsFor` is for projects with no existing rulesets (first rulesets after project creation). In this case, `latestRulesetIdOf` is 0, so the JBRulesets contract assigns `block.timestamp` as the first ID, matching the prediction. The real controller's `launchRulesetsFor` reverts if rulesets already exist.

### FP-004: Wildcard `MAP_SUCKER_TOKEN` permission in constructor
**Initial hypothesis:** `projectId: 0` in the constructor's permission grant gives the sucker registry MAP_SUCKER_TOKEN for all projects, not just those deployed through this deployer.
**Why false positive:** This is by design. The deployer needs to grant this permission for all projects it will deploy in the future (project IDs are not known at construction time). The sucker registry is a trusted protocol component. The permission scope (MAP_SUCKER_TOKEN only) is narrow and appropriate.

### FP-005: `_setup()` forces `useDataHookForCashOut = true` regardless of original config
**Initial hypothesis:** Overriding `useDataHookForCashOut` could cause unexpected behavior for projects that don't want a cash out data hook.
**Why false positive:** This is intentional. The deployer MUST be the cash out data hook to enable the sucker tax bypass (0% tax for suckers). When no original cash out hook is configured, the deployer simply passes through original values for non-sucker holders. The sucker bypass is the core purpose of this contract.

---

## Feedback Loop Discoveries

NM-001 was initially surfaced by Feynman Q3.2 (consistency: why does `launch721RulesetsFor` have the ownership transfer but `queue721RulesetsOf` doesn't?). It was independently confirmed by the State Inconsistency parallel path comparison (Pass 2). The cross-feed between the two auditors increased confidence from SUSPECT to CONFIRMED without requiring a PoC test.

No findings were discovered that required more than 4 passes. The codebase converged quickly due to its focused scope (single contract with no complex state coupling).

---

## Deploy Script Analysis

### `Deploy.s.sol`
- Uses Sphinx framework for multi-chain deterministic deployment
- `NANA_OMNICHAIN_DEPLOYER_SALT = "JBOmnichainDeployerV6_"` -- static salt ensures same address on all chains
- `_isDeployed` check uses Arachnid CREATE2 proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) -- standard practice
- Constructor args read from deployment files at runtime -- no hardcoded addresses in the script itself
- No issues found

### `DeployersDeploymentLib.sol`
- Library named `SuckerDeploymentLib` but file is `DeployersDeploymentLib.sol` -- naming inconsistency (cosmetic)
- Reads deployment addresses from JSON files without zero-address validation -- acceptable for deployment tooling
- No security issues found

---

## Summary
- Total functions analyzed: 16
- Coupled state pairs mapped: 2
- Nemesis loop iterations: 4 (converged at Pass 4)
- Raw findings (pre-verification): 1 HIGH | 0 MEDIUM | 1 LOW | 1 INFO
- False positives eliminated: 5
- After verification: 3 TRUE POSITIVE | 5 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 0 CRITICAL | 1 HIGH | 0 MEDIUM | 1 LOW | 1 INFO**
