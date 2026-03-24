# RISKS.md -- nana-omnichain-deployers-v6

## 1. Trust Assumptions

- **Trusted forwarder.** ERC-2771 `_msgSender()` is trusted to append the real sender. A compromised forwarder can impersonate any address for `deploySuckersFor`, `launchProjectFor`, `queueRulesetsOf`, and `launchRulesetsFor`.
- **Sucker registry.** `SUCKER_REGISTRY.isSuckerOf()` is the sole gatekeeper for 0% cashout tax and mint permission. A compromised or malicious registry lets any address bypass cashout taxes and mint tokens freely.
- **Controller trust.** The deployer passes an arbitrary `IJBController controller` parameter. `_validateController` checks `controller.DIRECTORY().controllerOf(projectId)` (a reflexive lookup through the controller's own directory reference), but during `launchProjectFor` the project does not yet exist -- validation is skipped, relying on the controller returning the correct project ID.
- **Extra data hooks.** Arbitrary `IJBRulesetDataHook` addresses from ruleset metadata are stored and delegated to with `staticcall`. A malicious hook can return arbitrary weight, cashout tax rate, or hook specifications.

## 2. Economic / Manipulation Risks

- **Sucker cashout bypass.** Any address registered as a sucker for a project gets 0% cashout tax rate and full reclaim. If a malicious sucker is registered (via compromised `SUCKER_REGISTRY`), it can drain the project's surplus.
- **Weight manipulation via extra data hook.** `beforePayRecordedWith` forwards to the extra data hook, which can return any `weight`. A malicious hook can inflate token minting or set weight=0 to block minting.
- **721 hook amount splitting.** The deployer computes `projectAmount = context.amount.value - totalSplitAmount`. The 721 hook's returned weight (already adjusted for splits via `JB721TiersHookLib.calculateWeight`) is used directly -- no proportional scaling is applied. If the 721 hook returns a `totalSplitAmount >= context.amount.value`, `projectAmount` is set to 0 and weight becomes 0 -- no tokens are minted for the payment.

## 3. Access Control

- **Wildcard MAP_SUCKER_TOKEN permission.** Constructor grants `SUCKER_REGISTRY` the `MAP_SUCKER_TOKEN` permission with `projectId=0` (wildcard). This grants the registry token-mapping rights across all projects ever deployed through this deployer.
- **Permission checks on `launchRulesetsFor`.** Requires both `LAUNCH_RULESETS` and `SET_TERMINALS` from the project owner. If an operator has one but not the other, the call reverts. No combined permission ID exists.
- **No permission check on `launchProjectFor`.** Anyone can call it because a new project is being created. The `owner` parameter receives the project NFT -- verify frontends do not allow this to be set to unexpected addresses.

## 4. DoS Vectors

- **Ruleset ID collision.** `_setup721` stores hook configs at `block.timestamp + i`. If `latestRulesetIdOf >= block.timestamp` (rulesets already queued this block), `queueRulesetsOf` reverts with `RulesetIdsUnpredictable`. An attacker who queues rulesets in the same block as the legitimate owner can front-run and block their queue attempt. Gas impact: `queueRulesetsOf` costs ~200-400k gas per ruleset queued. The collision only occurs when two transactions queue rulesets in the same block for the same project — race condition window is one block (~12 seconds on L1, 2 seconds on L2).
- **External hook revert.** `beforePayRecordedWith` and `beforeCashOutRecordedWith` call external hooks without try-catch. A reverting hook blocks all payments or cashouts for that project/ruleset. For cash-outs, if the 721 hook reverts, the custom hook is never reached (the revert propagates before it). Gas impact: the `staticcall` to the extra data hook has no gas limit — a gas-griefing hook can consume the entire transaction gas. The 721 hook call is similarly unbounded.
- **721 hook deployment revert.** `HOOK_DEPLOYER.deployHookFor` is called without try-catch. A failing deployment blocks the entire project launch.

## 5. Reentrancy Surface

- **`launchProjectFor` external call chain.** The function makes external calls to: (1) `_deploy721Hook()` via `HOOK_DEPLOYER.deployHookFor()` (deploys 721 hook clone), (2) `controller.launchProjectFor()` (creates project, deploys rulesets), (3) `JBOwnable(hook).transferOwnershipToProject()` (transfers hook ownership to the new project), (4) `SUCKER_REGISTRY.deploySuckersFor()` (deploys suckers if configured), (5) `PROJECTS.transferFrom()` (transfers the project NFT to the owner). None of these calls are try-catch wrapped — a revert in any of them fails the entire launch. Reentrancy from the controller callback during project creation could call back into `launchProjectFor`, but the new project would get a different ID (monotonically incrementing), so state corruption is not possible.
- **`beforePayRecordedWith` delegates to external hooks.** Calls `IJBRulesetDataHook(tiered721Hook).beforePayRecordedWith(context)` (not try-caught) and optionally delegates to the extra data hook via `staticcall`. The 721 hook call can execute arbitrary code. At callback time, no deployer state has been modified (the deployer is stateless during payments — it only routes). Reentrancy through the pay path processes as an independent payment.
- **`beforeCashOutRecordedWith` delegates to external hooks.** Same pattern as pay: calls the 721 hook (not try-caught), then optionally the extra data hook. Sucker check via `SUCKER_REGISTRY.isSuckerOf` is a view call. No deployer state is modified during cashouts.
- **No `ReentrancyGuard`.** Safe because the deployer is effectively stateless during pay/cashout operations — it reads `_tiered721HookOf` and `_extraDataHookOf` mappings but never writes them outside of deployment functions.

## 6. Integration Risks

- **Hook config keyed by predicted rulesetId.** Configs stored at `block.timestamp + i` must match the actual rulesetId assigned by the controller. If the controller assigns different IDs (e.g., due to approval hook delays), the stored configs become unreachable -- payments/cashouts fall through to default behavior (no 721 handling, no extra hook).
- **Carried-forward 721 hook on queue.** When `tiers.length == 0`, `queueRulesetsOf` carries forward the hook from `_tiered721HookOf[projectId][latestRulesetId]`. If the latest ruleset was not deployed through this deployer, the mapping is empty and the call reverts with `JBOmnichainDeployer_InvalidHook`.
- **ERC721Receiver restriction.** `onERC721Received` only accepts from `PROJECTS`. Any other NFTs sent to this contract are permanently lost.
- **Cross-reference: sucker registration.** The deployer grants `MAP_SUCKER_TOKEN` to `SUCKER_REGISTRY` with `projectId=0` (wildcard). This means the registry can map tokens for ALL projects deployed through this deployer. See [nana-suckers-v6 RISKS.md](../nana-suckers-v6/RISKS.md) for the full sucker lifecycle risks.
- **Cross-reference: core reentrancy.** The deployer delegates to `JBController` and `JBMultiTerminal` for all fund operations. See [nana-core-v6 RISKS.md](../nana-core-v6/RISKS.md) section 3 for the reentrancy surface of these contracts.

## 7. Invariants to Verify

- For any project launched through this deployer, `DIRECTORY.controllerOf(projectId)` matches the controller used during launch.
- `_tiered721HookOf[projectId][rulesetId]` is non-zero for every rulesetId created through this deployer.
- Sucker cashouts always receive 0% tax rate (no path where `isSuckerOf` returns true but tax > 0).
- `beforePayRecordedWith` uses the 721 hook's weight directly (already split-adjusted by `JB721TiersHookLib.calculateWeight`), so no additional scaling is applied.
- Self-reference prevention: `rulesetConfigurations[i].metadata.dataHook` cannot be `address(this)` after `_setup721`.
- Project NFT ownership: after `_launchProjectFor`, the project NFT is owned by `owner`, not the deployer.

## 8. Accepted Behaviors

### 8.1 Controller validation skipped during `launchProjectFor` (by design)

`_validateController` checks `controller.DIRECTORY().controllerOf(projectId)` to verify the provided controller matches the project's registered controller. During `launchProjectFor`, the project does not yet exist, so no directory entry exists. Validation is skipped, relying on `controller.launchProjectFor()` to return the correct project ID. This is accepted because: (1) the project is created atomically within the same transaction, (2) the caller provides the controller address, so they choose their own trust boundary, and (3) validating against a non-existent project would always fail, making the check useless.

### 8.2 Suckers receive 0% cashout tax (shared with revnet-core)

`beforeCashOutRecordedWith` returns `cashOutTaxRate = 0` for addresses registered in `SUCKER_REGISTRY`. This is the same trust model as REVDeployer. The security boundary is the sucker registry — only addresses deployed through authorized deployers receive this privilege. See [revnet-core-v6 RISKS.md](../revnet-core-v6/RISKS.md) section 4 for the full sucker bypass analysis.
