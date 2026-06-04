# Invariants of `nana-omnichain-deployers-v6`

Scope: the single contract `JBOmnichainDeployer` (and its `IJBOmnichainDeployer` interface + config structs) that launches a multi-chain Juicebox V6 project — 721 hook + rulesets + terminals + suckers — in one transaction, then permanently wires itself as the project's ruleset data hook so it can mediate pay/cash-out across the 721 hook, an optional extra data hook (e.g. buyback), and the sucker registry. Package: `@bananapus/omnichain-deployers-v6`.

Trust model in one sentence: a **permissionless one-shot launcher** mints a fresh `JBProjects` NFT, deploys a 721 hook, queues the operator-supplied rulesets (with this contract spliced in as the data hook), deploys suckers, and hands the project NFT to the named owner — with `msg.sender` mixed into every deterministic salt so an attacker cannot bind a victim's project ID to a hostile launcher on another chain. After hand-over the deployer holds **no Ownable role and no project-scoped permissions over the launched project**; only the configuration boundary (`launchRulesetsFor`, `queueRulesetsOf`, `deploySuckersFor`) can be invoked by the project owner / authorized operators.

This file documents the invariants enforced by the **runtime contract in this repo**. The OMNICHAIN_RULESET_OPERATOR bypass exists *inside* `JBController` (`nana-core-v6/src/JBController.sol:475, 651`); this deployer is the address that operator role is bound to, and the back-stop that makes the bypass safe is the per-call permission check this contract performs against `PROJECTS.ownerOf(projectId)`. Cross-chain economic divergence (the arbitrage model) lives in the canonical `INVARIANTS.md` at `../INVARIANTS.md` Section D2. Sucker mechanics live in `nana-suckers-v6/INVARIANTS.md`. 721-hook mechanics live in `nana-721-hook-v6/INVARIANTS.md`.

---

## Section A — Guarantees to project creators / paying users

## A.1 Permissionless launch — deterministic project ID, hostile-launcher-resistant

- `launchProjectFor` is **permissionless** (`JBOmnichainDeployer.sol:204-227`, 240-262): anyone can call it, paying the `JBProjects.createFor` creation fee via `msg.value`. There is no allowlist, no Ownable gate.
- The contract reserves the project ID up front by calling `PROJECTS.createFor{value: msg.value}(address(this))` (`JBOmnichainDeployer.sol:781`) — `address(this)` is the temporary holder of the NFT during the launch, never the configured `owner`. This prevents permissionless project creations from interleaving and invalidating subsequent hook deployments under that ID.
- The project NFT is transferred to `owner` via `PROJECTS.safeTransferFrom(address(this), owner, projectId)` **at the end** of the launch (`JBOmnichainDeployer.sol:827`). Use of `safeTransferFrom` lets contract-recipient owners receive the `onERC721Received` callback before the launch transaction returns.
- The deployer's own `onERC721Received` (`JBOmnichainDeployer.sol:327-334`) accepts only mints (`from == address(0)`) sourced from `address(PROJECTS)`. Arbitrary `JBProjects.safeTransferFrom` into this contract reverts. **This is intentional one-way receipt**: NFTs that somehow land here are not recoverable (no rescue function exists, by design — the deployer is never supposed to hold a project NFT past the launch transaction).
- **Cross-chain replay defense.** The 721-hook salt is mixed with `_msgSender()` (`JBOmnichainDeployer.sol:763`): `salt: config.salt == 0 ? 0 : keccak256(abi.encode(_msgSender(), config.salt))`. The sucker-deployment salt is identical: `keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender()))` (`JBOmnichainDeployer.sol:186, 820`). A different `msg.sender` on a peer chain produces a different deterministic hook/sucker address — so cross-chain address parity requires the **same EOA** to call on every chain. An attacker calling on the destination chain with the victim's intended salt cannot front-run the legitimate launcher into a matching address.
- **Same-block ruleset-ID guard** (`JBOmnichainDeployer.sol:902-909`): `queueRulesetsOf` predicts ruleset IDs as `block.timestamp + i`. If `latestRulesetIdOf >= block.timestamp` (i.e. rulesets were queued earlier in this block — would shift the prediction by the collision-bump path in `JBRulesets`), the call reverts with `JBOmnichainDeployer_RulesetIdsUnpredictable`. Otherwise the deployer's in-memory `_tiered721HookOf`/`_extraDataHookOf` keys would mismatch the actual ruleset IDs `JBRulesets` assigned, silently desynchronizing pay/cash-out routing.

## A.2 Controller pinning — canonical controller required

- The deployer pins one canonical `IJBController` at construction (`JBOmnichainDeployer.sol:84, 131`). All `launchProjectFor`/`launchRulesetsFor`/`queueRulesetsOf` paths route through it.
- `_requireController(projectId, allowUnset)` (`JBOmnichainDeployer.sol:1063-1071`) is called at every entry and exit:
  - `allowUnset = true` on pre-launch — a fresh project with no controller wired yet is accepted.
  - `allowUnset = false` on post-launch — `DIRECTORY.controllerOf(projectId)` must equal the pinned `CONTROLLER`. Reverts `JBOmnichainDeployer_ControllerMismatch` otherwise.
- This blocks a class of attack where a third party assigns a non-canonical controller to a project between this deployer reserving the ID and configuring rulesets. The pre/post checks bracket all state writes.

## A.3 Data-hook wrapping is total and irreversible-per-ruleset

- `_setup721` (`JBOmnichainDeployer.sol:977-1017`) iterates each `JBRulesetConfig` and:
  - rejects self-reference (`metadata.dataHook == address(this)`),
  - stores the 721 hook as `_tiered721HookOf[projectId][predictedRulesetId]`,
  - stores any operator-supplied extra data hook as `_extraDataHookOf[projectId][predictedRulesetId]`,
  - **overwrites** `metadata.dataHook = address(this)`, `useDataHookForPay = true`, `useDataHookForCashOut = true`.
- The terminal therefore ALWAYS routes pay/cash-out through this contract for any ruleset queued via this deployer. The 721 hook and extra hook see the per-ruleset stored entries only via this contract's mediation; their addresses never appear in `metadata.dataHook`.
- A ruleset's hook routing is **fixed at queue time** — once stored under `(projectId, rulesetId)`, the mappings are not exposed to any mutator. A different hook for a later ruleset requires queueing a new ruleset through `queueRulesetsOf` (which requires `QUEUE_RULESETS` against `PROJECTS.ownerOf(projectId)`).

## A.4 Sucker holders get 0% cash-out tax

- `beforeCashOutRecordedWith` (`JBOmnichainDeployer.sol:407-508`) short-circuits when `SUCKER_REGISTRY.isSuckerOf({projectId, addr: context.holder})` is true (`JBOmnichainDeployer.sol:422-424`). It returns `(0, context.cashOutCount, context.totalSupply, context.surplus.value, [])` — zero tax, local-only supply/surplus, no hook specs.
- This is the bridge-accounting primitive: the value moving out of this chain via a sucker must stay proportional to **local** backing. Adding remote supply/surplus here would let the bridge over-pull on chains with thin local liquidity.
- Suckers also always get `hasMintPermissionFor` granted (`JBOmnichainDeployer.sol:653`). Without this, claim-time minting on the destination chain would fail.

## A.5 Cross-chain bonding-curve aggregation for normal holders

- For non-sucker holders, `beforeCashOutRecordedWith` aggregates `remoteTotalSupplyOf` and `remoteSurplusOf` from the sucker registry into the bonding curve (`JBOmnichainDeployer.sol:434-442`), unless the ruleset opted into `scopeCashOutsToLocalBalances`.
- The 721 hook (if `useDataHookForCashOut`) is consulted first and its returned `totalSupply` / `effectiveSurplusValue` are **used as-is** (`JBOmnichainDeployer.sol:453-459`). Rationale: NFT cash-outs reclaim against local NFT supply, not omnichain ERC-20 supply — using aggregated denominators would systematically over-reclaim per NFT.
- The extra hook (e.g. buyback) is invoked **only if the 721 hook did not handle cash-out** (`JBOmnichainDeployer.sol:471`). Its returned `totalSupply` / `effectiveSurplusValue` are **discarded** — this contract is the single source of truth for cross-chain denominators on fungible cash-outs (`JBOmnichainDeployer.sol:480-484`).
- Hook specifications from both hooks are concatenated 721-first (`JBOmnichainDeployer.sol:491-505`). The terminal executes them in order.

## A.6 Pay-time weight composition without split-credit erasure

- `beforePayRecordedWith` (`JBOmnichainDeployer.sol:522-617`) calls the 721 hook first; it returns a weight already scaled for tier splits and (in its single hook spec's metadata field 4) the `splitCreditWeight` that represents tokens owed to tier-split beneficiaries.
- The extra hook (e.g. buyback) is then called with `amount.value` reduced to `projectAmount = context.amount.value - totalSplitAmount` — it only sees funds actually entering the project (`JBOmnichainDeployer.sol:566, 576`). The extra hook is passed the **original** `context.weight`, not the 721's split-adjusted weight, so it does not double-discount (`JBOmnichainDeployer.sol:577-580`).
- After the extra hook returns its weight, the deployer rescales it by the 721 hook's split ratio: `weight = mulDiv(weight, tiered721Weight, context.weight)` (`JBOmnichainDeployer.sol:587-589`). The terminal therefore mints at most as many tokens as the funds actually entering the project warrant.
- **Split-credit guard** (`JBOmnichainDeployer.sol:595-597`): if the extra hook returns `weight == 0` (buyback found no profitable swap) but `splitCreditWeight > 0`, weight is restored to `splitCreditWeight` so the split share still mints. Without this, an unprofitable buyback would erase the issuance for tier splits even though those funds were forwarded to split beneficiaries.

## A.7 Peer-chain account forwarding

- `peerChainAdjustedAccountsOf` (`JBOmnichainDeployer.sol:696-723`) staticcalls the extra data hook's `peerChainAdjustedAccountsOf` (if it implements `IJBPeerChainAdjustedAccounts`) and returns its `(supply, surplus, balance)`.
- Without this forwarding, an extra hook (e.g. REVLoans-aware data hook) that contributes off-balance-sheet supply/surplus would be silently masked once this deployer wraps the ruleset — the sucker's cross-chain snapshot would only see the bonded curve's local view and over-reclaim on peer chains.
- The call is `staticcall` + length-check — extra hooks that do not implement the interface return `(0,0,0)` cleanly.

---

## Section B — Guarantees to project owners / operators

## B.1 What this deployer back-stops about `OMNICHAIN_RULESET_OPERATOR`

The pinned `JBController` grants `JBOmnichainDeployer` a bypass: when `_msgSender() == OMNICHAIN_RULESET_OPERATOR`, `LAUNCH_RULESETS` / `SET_TERMINALS` / `QUEUE_RULESETS` permission checks against the project owner are skipped inside the controller (`nana-core-v6/src/JBController.sol:475, 651`). This bypass exists so the deployer can ergonomically launch and queue across chains without each chain's project owner pre-granting it permissions.

The back-stop that keeps this safe lives **in this contract**:

- `launchRulesetsFor` (`JBOmnichainDeployer.sol:842-854`) explicitly calls `_requirePermissionFrom(owner, projectId, LAUNCH_RULESETS)` AND `SET_TERMINALS` (and `SET_PROJECT_URI` if a URI is supplied) **before** invoking the controller. The controller will then waive its own check — but only after this contract has already enforced it.
- `queueRulesetsOf` (`JBOmnichainDeployer.sol:893-895`) calls `_requirePermissionFrom(owner, projectId, QUEUE_RULESETS)` before invoking the controller.
- `deploySuckersFor` (`JBOmnichainDeployer.sol:173-179`) calls `_requirePermissionFrom(owner, projectId, DEPLOY_SUCKERS)` + `_requireExplicitSuckerPeerPermissionFrom` (which mirrors `SET_SUCKER_PEER` against the owner for any non-default peer).

Without these per-call checks, the controller bypass would be a wildcard — anyone could queue rulesets / set terminals on any project that had been launched through this deployer. The bypass is therefore safe **iff** this contract continues to gate every external entrypoint by the corresponding permission ID against `PROJECTS.ownerOf(projectId)`.

## B.2 Sucker-peer permission mirroring

- `_requireExplicitSuckerPeerPermissionFrom` (`JBOmnichainDeployer.sol:1079-1109`) scans every `deployerConfigurations[i].peer`. If any peer is non-zero (i.e. an explicit non-default peer was supplied), the caller is additionally required to hold `SET_SUCKER_PEER` against the original project authority — `owner = PROJECTS.ownerOf(projectId)`.
- At launch time, `_launchProjectFor` checks the **intended** `owner` (not `address(this)`, which still owns the NFT at that point) before invoking the registry (`JBOmnichainDeployer.sol:814-816`). This prevents `DEPLOY_SUCKERS` alone from smuggling in an arbitrary remote peer through the wrapper.
- The registry itself also enforces the same rule against its direct caller; this wrapper merely matches that behavior so the wrapper-vs-direct authorization model is symmetric.

## B.3 What this contract cannot do to a launched project (post hand-over)

After `safeTransferFrom(address(this), owner, projectId)` completes, this contract:

- **Holds no ROOT.** It is not the project NFT owner and holds no project-scoped permissions on the launched project. The only permission this contract ever holds is a wildcard `MAP_SUCKER_TOKEN` granted to `SUCKER_REGISTRY` on its own account (see B.4).
- **Cannot queue or launch rulesets on its own.** Every `launchRulesetsFor` / `queueRulesetsOf` call still requires `LAUNCH_RULESETS` / `QUEUE_RULESETS` against `PROJECTS.ownerOf(projectId)` (Section B.1).
- **Cannot transfer the project NFT.** No `safeTransferFrom` or approval flow exposes the project NFT after hand-over. The deployer is not on `JBProjects.isApprovedForAll` for `owner`.
- **Cannot rotate hooks.** `_tiered721HookOf` / `_extraDataHookOf` mappings are write-only via `_setup721`, which only runs during launch/queue paths gated by Section B.1.

## B.4 The constructor-time `MAP_SUCKER_TOKEN` grant is inert

- Constructor (`JBOmnichainDeployer.sol:138-145`) grants `SUCKER_REGISTRY` a wildcard (`projectId: 0`) `MAP_SUCKER_TOKEN` permission **on this deployer's own account**: `PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: …})`.
- This permission only authorizes the registry to map sucker tokens **on behalf of the deployer**. The deployer is never a project owner post-hand-over, so the registry can never use this grant to map tokens on a real project.
- The grant exists so that during the launch transaction itself — while `address(this)` is the transient holder of the project NFT — the registry can run `mapToken` inside `deploySuckersFor` without a project-scoped permission round-trip.
- The grant cannot be revoked by an external party (only `account == address(this)` or a ROOT-on-self can mutate it). There is no `setPermissionsFor` call elsewhere in the deployer that revokes or extends it.

---

## Section C — Per-function operation inventory

All file:line references are to `src/JBOmnichainDeployer.sol` unless otherwise noted.

## C.1 Permissionless project launch

- **`launchProjectFor(owner, projectUri, JBOmnichain721Config, JBRulesetConfig[], JBTerminalConfig[], memo, JBSuckerDeploymentConfig) payable → (projectId, hook, suckers)`** — `:204-227, 768-828`.
  - **Caller:** anyone. Pays `JBProjects.createFor` creation fee via `msg.value`.
  - **Effect:** mints fresh `JBProjects` NFT to `address(this)`; deploys a 721 tiers hook via `HOOK_DEPLOYER` with `salt = keccak256(abi.encode(_msgSender(), config.salt))`; wraps each ruleset's data-hook metadata to point at this contract and stores the underlying 721 + extra hook per ruleset; calls `CONTROLLER.launchRulesetsFor` (which configures terminals + accounting contexts + initial rulesets); transfers the 721 hook's `JBOwnable` ownership to the project; deploys suckers (if `suckerDeploymentConfiguration.salt != 0`) with salt mixed with `_msgSender()`; `safeTransferFrom`s the project NFT to `owner`.
  - **Invariant:** project ID is deterministic *given the same `JBProjects` state on each chain*; cross-chain hook/sucker address parity requires the same `_msgSender()`; controller is canonical before and after (`_requireController` brackets the launch); explicit non-default sucker peers require `SET_SUCKER_PEER` against `owner` (`:814-816`).
  - **Cannot:** install itself as data hook (rejected at `:991`); accept transferred NFTs from non-`JBProjects` sources; complete without leaving the canonical controller pinned.

- **`launchProjectFor(owner, projectUri, JBRulesetConfig[], JBTerminalConfig[], memo, JBSuckerDeploymentConfig) payable → (projectId, hook, suckers)`** — `:240-262`.
  - Convenience overload: derives a default `JBOmnichain721Config` (empty tiers, `currency = rulesetConfigurations[0].metadata.baseCurrency`, `decimals = 18`) and delegates to `_launchProjectFor`.
  - **Invariant:** reverts `JBOmnichainDeployer_NoRulesetConfigurations` if `rulesetConfigurations.length == 0` (`:1037-1041`).

## C.2 Owner / operator gated re-launch and queue

- **`launchRulesetsFor(projectId, projectUri, JBOmnichain721Config, JBRulesetConfig[], JBTerminalConfig[], memo) → (rulesetId, hook)`** — `:274-294, 831-880`.
  - **Caller:** `PROJECTS.ownerOf(projectId)` OR operator with `LAUNCH_RULESETS` + `SET_TERMINALS` (+ `SET_PROJECT_URI` if URI supplied). Permissions checked against the project owner (`:846-854`).
  - **Effect:** deploys a fresh 721 hook, transfers its `JBOwnable` to the project, re-wraps each ruleset's data hook through this contract, calls `CONTROLLER.launchRulesetsFor`.
  - **Invariant:** controller stays canonical (`_requireController` brackets the call); the OMNICHAIN_RULESET_OPERATOR bypass inside the controller is back-stopped by this contract's explicit permission check; rulesets cannot self-reference this contract as data hook (`:991`).
  - **Cannot:** be called by an address lacking `LAUNCH_RULESETS + SET_TERMINALS` against the project owner; complete if a non-canonical controller is in place.

- **`launchRulesetsFor(projectId, projectUri, JBRulesetConfig[], JBTerminalConfig[], memo) → (rulesetId, hook)`** — `:305-324`. Convenience overload with default empty-tier 721 config.

- **`queueRulesetsOf(projectId, JBOmnichain721Config, JBRulesetConfig[], memo) → (rulesetId, hook)`** — `:345-361, 883-965`.
  - **Caller:** `PROJECTS.ownerOf(projectId)` OR operator with `QUEUE_RULESETS`. Permission checked at `:893-895`.
  - **Effect:** if `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, deploys a fresh 721 hook and transfers its `JBOwnable` to the project; else carries forward the previous ruleset's 721 hook (preferring the latest queued ruleset's hook iff its `JBApprovalStatus` is `Approved` or `Empty`, falling back to the current active ruleset's). Re-wraps the new rulesets' data hooks. Calls `CONTROLLER.queueRulesetsOf`.
  - **Invariant:** reverts `JBOmnichainDeployer_RulesetIdsUnpredictable` if any ruleset was queued earlier in this block (`:902-909`); reverts `JBOmnichainDeployer_InvalidHook` if no tiers supplied AND no prior hook exists to carry forward (`:945-949`); preserves the previous ruleset's `useDataHookForCashOut` flag when carrying forward (`:951`); ApprovalExpected is explicitly excluded from "approved" status so a hook isn't locked in from a ruleset that may later be rejected (`:925-928`).
  - **Cannot:** be called by an address lacking `QUEUE_RULESETS` against the project owner; complete if the canonical controller has been swapped out.

- **`queueRulesetsOf(projectId, JBRulesetConfig[], memo) → (rulesetId, hook)`** — `:372-387`. Convenience overload; uses default empty-tier config which forces the carry-forward branch.

## C.3 Owner / operator gated sucker deployment

- **`deploySuckersFor(projectId, JBSuckerDeploymentConfig) → address[]`** — `:160-189`.
  - **Caller:** `PROJECTS.ownerOf(projectId)` OR operator with `DEPLOY_SUCKERS`. Permission checked at `:173`.
  - **Effect:** calls `SUCKER_REGISTRY.deploySuckersFor` with `salt = keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender()))`. The registry consumes this contract's constructor-time wildcard `MAP_SUCKER_TOKEN` grant to apply token mappings.
  - **Invariant:** any non-default peer in `deployerConfigurations[i].peer` triggers a second permission check requiring `SET_SUCKER_PEER` against the project owner (`:177-179, 1079-1109`); salt-mixed-with-msg.sender preserves cross-chain replay defense.
  - **Cannot:** ship a non-default peer without `SET_SUCKER_PEER`; produce the same sucker address as a different `_msgSender()` did with the same nominal salt.

## C.4 Data-hook callbacks (terminal-driven, view)

- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view → (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications[])`** — `:407-508`.
  - **Caller:** any terminal during `cashOutTokensOf`; callable view-side by anyone for preview.
  - **Invariant:** suckers always get `(0, cashOutCount, localSupply, localSurplus, [])`; non-suckers get cross-chain-aggregated denominators unless `scopeCashOutsToLocalBalances`; 721 hook denominators win when it handles cash-out (NFT-local); extra hook denominators are always discarded; hook specs are concatenated 721-first.

- **`beforePayRecordedWith(JBBeforePayRecordedContext) view → (weight, hookSpecifications[])`** — `:522-617`.
  - **Caller:** any terminal during `pay`; callable view-side for preview.
  - **Invariant:** 721 hook's split-adjusted weight is preserved; extra hook receives `amount.value` reduced by tier splits; extra hook's returned weight is rescaled by the 721's split ratio (`mulDiv` at `:588`); zero-weight extra hook does not erase split-credit issuance.

- **`hasMintPermissionFor(projectId, JBRuleset, addr) view → bool`** — `:642-664`.
  - **Caller:** controller / project terminal during mint authorization.
  - **Invariant:** suckers always granted; otherwise delegates to extra hook's `hasMintPermissionFor` (the 721 hook never grants mint authority); never grants to arbitrary addresses.

- **`peerChainAdjustedAccountsOf(projectId, decimals, currency) view → (supply, surplus, balance)`** — `:696-723`.
  - **Caller:** suckers during peer-chain snapshot computation.
  - **Invariant:** staticcall to the project's extra hook for the *current* ruleset; returns `(0,0,0)` if no extra hook or the hook does not implement `IJBPeerChainAdjustedAccounts`.

## C.5 Lookups (views)

- `extraDataHookOf(projectId, rulesetId) → JBDeployerHookConfig` (`:623-633`).
- `tiered721HookOf(projectId, rulesetId) → (hook, useDataHookForCashOut)` (`:671-682`).
- `supportsInterface(bytes4) → bool` (`:733-738`) — declares `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IJBPeerChainAdjustedAccounts`, `IERC721Receiver`, `IERC165`.

## C.6 ERC-721 receipt

- **`onERC721Received(_, from, tokenId, _) view → bytes4`** — `:327-334`.
  - Accepts only mints (`from == address(0)`) from `address(PROJECTS)`. Rejects everything else with `JBOmnichainDeployer_UnexpectedNFTReceived`.

## C.7 Public immutables

- `CONTROLLER` (canonical `IJBController`; `:84`).
- `DIRECTORY` (`IJBDirectory`, from `controller.DIRECTORY()`; `:87, 135`).
- `HOOK_DEPLOYER` (`IJB721TiersHookDeployer`; `:90`).
- `PROJECTS` (`IJBProjects`, from `controller.PROJECTS()`; `:93, 132`).
- `SUCKER_REGISTRY` (`IJBSuckerRegistry`; `:96`).

These are set once in the constructor (`:121-146`) and never mutated. There is no `setChainSpecificConstants`, no Ownable, no upgrade path.

---

## Section D — Cross-cutting invariants

1. **Permissionless launch is salt-bound to caller.** Every CREATE2-deterministic derivation that needs cross-chain parity — the 721 hook salt (`:763`), the sucker deployment salt (`:186, 820`) — incorporates `_msgSender()`. A different sender on a peer chain produces a different address, preventing a hostile launcher from binding a victim's intended project topology to attacker-controlled addresses on another chain.
2. **CREATE2 codehash defense via Sphinx deploy.** The `JBOmnichainDeployer` contract itself is deployed via Sphinx Safe with a fixed init-code hash (`script/Deploy.s.sol:60-75`). `_isDeployed` checks `vm.computeCreate2Address(salt, keccak256(creationCode || arguments), deployer)` — any pre-deploy bytecode squat at the predicted address would fail this check OR produce a different address. The deployer's address therefore matches across chains only if the same `(creationCode, constructor args, salt, deployer)` is used everywhere.
3. **Canonical controller pinning is bracketed.** `_requireController` is called both before and after every launch/queue, with `allowUnset` differentiating pre- vs post-state. A third party who races a non-canonical controller into the directory between the deployer's writes will cause the call to revert rather than complete in a corrupted state.
4. **OMNICHAIN_RULESET_OPERATOR bypass is back-stopped here.** The `JBController` waives permission checks when `_msgSender() == OMNICHAIN_RULESET_OPERATOR`; this contract performs the equivalent check itself first (`LAUNCH_RULESETS`/`SET_TERMINALS`/`QUEUE_RULESETS`/`DEPLOY_SUCKERS`/`SET_SUCKER_PEER` against `PROJECTS.ownerOf(projectId)`). Removing those checks would turn the bypass into an open wildcard for any project ever launched through this deployer.
5. **Suckers are first-class at the data-hook boundary.** Sucker holders get 0% cash-out tax (`:422-424`) and always receive mint permission (`:653`). This is structurally required for cross-chain accounting to be lossless: bridged tokens must mint at face value and exit at the local backing rate without paying the protocol fee.
6. **Cross-chain aggregation uses sucker-registry views.** The bonding curve sees `remoteTotalSupplyOf + remoteSurplusOf` as additive terms (`:436-441`). If a sucker is added/removed mid-lifetime, the registry's `isSuckerOf` / `remoteTotalSupplyOf` view is the single source of truth — this contract does not maintain its own sucker list.
7. **No Ownable, no upgrade, no mutable state outside hook mappings.** The only mutable storage is `_tiered721HookOf` and `_extraDataHookOf`, written only by `_setup721` which runs only under permission gates from Section B.1. There is no admin function, no fee setter, no implementation pointer.
8. **The constructor-time wildcard permission is inert post-hand-over.** The `MAP_SUCKER_TOKEN` grant to `SUCKER_REGISTRY` on `account: address(this)` (`:138-145`) only authorizes the registry to act *as this deployer*; since this deployer never owns a project NFT past launch, the grant has no exploitable scope.
9. **Project NFTs delivered to this contract are unrecoverable.** `onERC721Received` accepts only `JBProjects` mints; arbitrary transfers revert. There is no rescue function — by design, since the deployer should never end a transaction holding a project NFT. This documented one-way receipt is acceptable because no automated flow can route an NFT here.
10. **Ruleset-ID prediction is fragile and fail-closed.** `queueRulesetsOf` predicts `block.timestamp + i` and refuses to proceed if `latestRulesetIdOf >= block.timestamp`. Silently desyncing the in-memory mapping keys from the controller's assigned ruleset IDs would route subsequent pay/cash-out through stale 721/extra-hook bindings; the explicit revert closes that window.

---

## Section E — Known non-invariants / acceptable risks

- **Project NFTs sent here are lost.** Acknowledged in the contract NatSpec (`:42-44`). There is no rescue path.
- **`_requireController` cannot detect malicious controller swaps that occur *after* the launch transaction completes.** Once the project owner has the NFT, they (or anyone they grant `SET_CONTROLLER` to) can move the project off this deployer's canonical controller via the standard `JBDirectory` flow. Subsequent calls to `launchRulesetsFor`/`queueRulesetsOf` will revert `JBOmnichainDeployer_ControllerMismatch`. This is intentional: the deployer refuses to operate on projects it no longer canonically controls.
- **Same-`_msgSender()` cross-chain parity is required.** Two different EOAs cannot collaborate to produce the same hook/sucker address on different chains. This is a deliberate feature of the salt mixing.
- **ERC-2771 trusted forwarder is honored.** All `_msgSender()` callsites (`:1054-1056`) honor ERC-2771. A relayer can submit on behalf of an EOA; the salt mixing still pins to the EOA's address since the forwarder appends it to calldata.

---

## References

- Reference INVARIANTS template: `../INVARIANTS.md`
- Sister INVARIANTS: `../nana-suckers-v6/INVARIANTS.md`
- OMNICHAIN_RULESET_OPERATOR bypass: `nana-core-v6/src/JBController.sol:116, 475, 651`
- Sucker mechanics: `nana-suckers-v6/src/JBSucker.sol`, `nana-suckers-v6/src/JBSuckerRegistry.sol`
- 721 hook salt + ownership transfer: `nana-721-hook-v6/src/JB721TiersHookDeployer.sol`
