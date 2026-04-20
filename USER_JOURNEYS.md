# User Journeys

## Repo Purpose

This repo packages omnichain project launches and omnichain-aware ruleset evolution.
It owns deployment-time composition of core launch config, 721 hook config, sucker deployment, and wrapper behavior
that keeps later bridge paths safe. It does not own the lower-level bridge runtime once suckers are deployed.

## Primary Actors

- teams launching projects that should be cross-chain from day one
- deployers composing a 721 hook, suckers, and optional extra hooks
- operators evolving rulesets without breaking omnichain wrapper behavior

## Key Surfaces

- `JBOmnichainDeployer`: packaged omnichain launch and ruleset-evolution surface

## Journey 1: Launch A Project Across Chains In One Flow

**Actor:** launch team or deployer.

**Intent:** launch a project with its 721 hook, sucker package, and wrapper behavior already wired in.

**Preconditions**
- the team has base launch config, 721 config, and sucker deployment config ready
- the team wants omnichain packaging instead of separate post-launch setup

**Main Flow**
1. Call `JBOmnichainDeployer` with the project launch config, 721 config, sucker deployment config, and any extra hook composition.
2. The deployer launches the base Juicebox project and either deploys or wires the tiered 721 hook.
3. It wraps the hook composition so future rulesets can keep sucker-safe behavior while still preserving project-specific hook logic.
4. Deterministic salts are used so sibling-chain deployments can be coordinated with confidence.

**Failure Modes**
- deterministic inputs differ across chains and break address or wrapper expectations
- teams treat the wrapper as cosmetic and miss its effect on later bridge-safe ruleset evolution

**Postconditions**
- the project launches with its omnichain-capable shape already installed
- future bridge and ruleset questions should move to the wrapper, sucker, or 721 surfaces this deployer packaged

## Journey 2: Coordinate Deterministic Deployment Inputs Across Chains

**Actor:** deployment operator.

**Intent:** keep addresses, salts, and wrapper behavior predictable across chains.

**Preconditions**
- the deployment will happen on more than one chain
- the team can reuse the same structured inputs where determinism matters

**Main Flow**
1. Fix the deployer inputs that drive deterministic addresses for suckers and hook packaging.
2. Reuse those inputs consistently on each chain.
3. Validate that the controller, hook ownership, and sucker expectations still line up across the resulting deployments.

**Failure Modes**
- teams reuse similar but not identical inputs and assume deterministic outputs still match
- address prediction is checked for one chain only and not for the full deployment set

**Postconditions**
- teams can predict addresses, salts, and wrapper behavior before doing the live rollout

## Journey 3: Carry Forward An Existing 721 Hook While Queueing New Omnichain Rulesets

**Actor:** operator evolving a live project.

**Intent:** queue new omnichain-aware rulesets without dropping the existing 721 collection.

**Preconditions**
- the project already has a 721 hook
- the operator wants omnichain-aware future rulesets without replacing that hook

**Main Flow**
1. Queue the next ruleset through the deployer using the path that reuses the existing 721 hook (pass zero tiers).
2. The deployer selects the source hook: it first checks the latest queued ruleset (if approved or with no approval hook), then falls back to the current active ruleset. This prevents losing a recently queued hook config.
3. The `useDataHookForCashOut` flag is preserved from whichever source ruleset is selected.
4. Validate the controller and queued ruleset inputs before relying on the result.
5. Confirm the queued ruleset now points at the carried-forward hook rather than accidentally dropping the 721 layer.

**Failure Modes**
- a newly queued but not yet active hook configuration is accidentally ignored
- operators assume zero tiers means "no 721 behavior" rather than "reuse the existing hook"

**Postconditions**
- the existing 721 hook is carried forward, stored against the queued ruleset, and kept bridge-safe

## Journey 4: Compose A Tiered 721 Hook With A Custom Extra Hook

**Actor:** product team.

**Intent:** add extra hook behavior without breaking the omnichain wrapper or the standard 721 hook.

**Preconditions**
- the project needs both standard tiered NFTs and additional product logic
- the extra hook is understood well enough to evaluate its effect on bridge paths

**Main Flow**
1. Provide the extra-hook config when launching through `JBOmnichainDeployer`.
2. Let the deployer remember which composition belongs to each ruleset.
3. Make sure bridge flows still bypass or special-case the right tax and data-hook behavior.

**Failure Modes**
- the extra hook overrides or bypasses wrapper assumptions the bridge path depends on
- teams audit the extra hook in isolation and miss the composed behavior

**Postconditions**
- the extra logic composes with the 721 hook and sucker wrapper instead of overriding them unsafely

## Journey 5: Evolve The Project After Launch Without Breaking Bridge Paths

**Actor:** live-project operator.

**Intent:** change future project behavior without breaking the special wrapper assumptions suckers rely on.

**Preconditions**
- the project is already live
- future rulesets need new metadata, hook composition, or payout behavior

**Main Flow**
1. Queue the next ruleset through the omnichain-aware deployer surface.
2. Keep track of which hook stack should apply for that future ruleset.
3. Confirm that sucker flows still land on the mint-safe and tax-safe path the wrapper was designed to preserve.

**Failure Modes**
- operators queue rulesets through a non-omnichain path and silently lose wrapper guarantees
- teams change payout or hook assumptions without rechecking bridge-special-case behavior

**Postconditions**
- ruleset changes preserve the wrapper assumptions that let suckers bridge cleanly

## Trust Boundaries

- this repo is trusted for wrapper composition and hook carry-forward decisions across rulesets
- `JBSuckerRegistry` and deployed suckers remain trusted for the actual bridge runtime
- the underlying 721 hook and any extra hook still need to be audited as part of the composed product

## Hand-Offs

- Use [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) for the bridge mechanics after the project has been launched with suckers.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the standard tier and resolver behavior that this repo packages into the omnichain launch.
