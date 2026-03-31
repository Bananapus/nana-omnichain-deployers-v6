# User Journeys

## Who This Repo Serves

- founders launching a project across multiple chains from day one
- operators who want 721 tiers and suckers wired in during deployment
- integrators who need deterministic cross-chain deployment planning

## Journey 1: Launch A Project Across Chains In One Flow

**Starting state:** you know the project owner, the base Juicebox rulesets, accepted terminals, and whether the launch includes 721 tiers or custom data hooks.

**Success:** the project launches with the intended owner, rulesets, optional tiered NFTs, and optional sucker deployment support.

**Flow**
1. Prepare the controller, project metadata, rulesets, and terminal configs.
2. Add optional 721 hook configuration if the project should mint NFTs on payment.
3. Add optional custom data-hook configuration if another hook must compose with the 721 layer.
4. Add optional sucker deployment configuration for the chains you want bridged.
5. Call the omnichain deployer once and receive the final project ownership in the target owner account.

## Journey 2: Coordinate Deterministic Deployment Inputs Across Chains

**Starting state:** multiple chains or operators need to agree on what will be deployed before execution.

**Success:** you can keep sucker and hook deployments aligned across chains by keeping sender and salt inputs consistent.

**Flow**
1. Reuse the same sender and salt inputs on each chain where deterministic alignment matters.
2. Remember that the deployer mixes `msg.sender` into the salts it uses, so matching salts alone are not enough.
3. Treat ruleset-ID prediction as an implementation assumption the deployer depends on during launch and queue flows, not as a standalone public utility surface.

## Journey 3: Evolve The Project After Launch

**Starting state:** the project is live and the owner wants to keep operating it as a normal Juicebox project.

**Success:** post-launch administration happens through the standard owner-controlled protocol surfaces.

**Flow**
1. Queue rulesets through the core controller as needed.
2. Manage the 721 hook or sucker-connected contracts within the permissions granted during deployment.
3. Treat this repo as the bootstrap layer rather than the long-term operator surface.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for normal post-launch treasury operations.
- Use [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) for bridge-specific runtime behavior.
