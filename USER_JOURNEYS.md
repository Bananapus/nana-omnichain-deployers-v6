# User Journeys

## Who This Repo Serves

- teams launching Juicebox projects that should be cross-chain from day one
- deployers composing a tiered 721 hook with sucker support and optional extra hooks
- operators evolving rulesets without breaking sucker-safe wrapper behavior

## Journey 1: Launch A Project Across Chains In One Flow

**Starting state:** the project wants an initial Juicebox launch plus 721 hook plus sucker package instead of separate setup steps.

**Success:** the project launches with its omnichain-capable shape already installed.

**Flow**
1. Call `JBOmnichainDeployer` with the project launch config, 721 config, sucker deployment config, and any extra hook composition.
2. The deployer launches the base Juicebox project and either deploys or wires the tiered 721 hook.
3. It wraps the hook composition so future rulesets can keep sucker-safe behavior while still preserving project-specific hook logic.
4. Deterministic salts are used so sibling-chain deployments can be coordinated with confidence.

## Journey 2: Coordinate Deterministic Deployment Inputs Across Chains

**Starting state:** multiple chain deployments need to line up so the same project shape exists everywhere.

**Success:** teams can predict addresses, salts, and wrapper behavior before doing the live rollout.

**Flow**
1. Fix the deployer inputs that drive deterministic addresses for suckers and hook packaging.
2. Reuse those inputs consistently on each chain.
3. Validate that the controller, hook ownership, and sucker expectations still line up across the resulting deployments.

## Journey 3: Carry Forward An Existing 721 Hook While Queueing New Omnichain Rulesets

**Starting state:** the project already has a 721 hook and wants future omnichain-aware rulesets without replacing that collection.

**Success:** the deployer carries the existing hook forward, stores it against the queued ruleset, and preserves the ownership and wrapper assumptions bridge flows need.

**Flow**
1. Queue the next ruleset through the deployer using the path that reuses the existing 721 hook.
2. Validate the controller and queued ruleset inputs before relying on the result.
3. Let the deployer transfer or confirm hook ownership as needed so future project-controlled behavior still resolves correctly.
4. Confirm the queued ruleset now points at the carried-forward hook rather than accidentally dropping the 721 layer.

## Journey 4: Compose A Tiered 721 Hook With A Custom Extra Hook

**Starting state:** the project wants standard tiered NFTs plus some extra product logic.

**Success:** the extra logic composes with the 721 hook and sucker wrapper instead of overriding them unsafely.

**Flow**
1. Provide the extra-hook config when launching through `JBOmnichainDeployer`.
2. Let the deployer remember which composition belongs to each ruleset.
3. Make sure bridge flows still bypass or special-case the right tax and data-hook behavior.

## Journey 5: Evolve The Project After Launch Without Breaking Bridge Paths

**Starting state:** the project is live and future rulesets need new metadata, hook composition, or payout behavior.

**Success:** ruleset changes preserve the special wrapper assumptions that let suckers bridge cleanly.

**Flow**
1. Queue the next ruleset through the omnichain-aware deployer surface.
2. Keep track of which hook stack should apply for that future ruleset.
3. Confirm that sucker flows still land on the mint-safe and tax-safe path the wrapper was designed to preserve.

## Hand-Offs

- Use [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) for the bridge mechanics after the project has been launched with suckers.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the standard tier and resolver behavior that this repo packages into the omnichain launch.
