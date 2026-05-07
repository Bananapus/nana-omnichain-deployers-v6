# User Journeys

## Repo Purpose

This repo launches projects that are omnichain from the start.

## Primary Actors

- operators launching omnichain projects
- teams composing 721 hooks with extra data hooks
- reviewers checking bridge-wrapper behavior

## Journey 1: Launch An Omnichain Project

**Actor:** deployer.

**Intent:** launch a project with a 721 hook and suckers already wired in.

**Main Flow**
1. Build the intended ruleset and hook composition.
2. Launch the project through `JBOmnichainDeployer`.
3. Deploy or wire the sucker pair and transfer control to the intended owner.

**Failure Modes**
- wrong hook composition
- cross-chain deployment drift
- wrong sucker peer wiring

## Journey 2: Deploying Suckers for an Existing Project

**Actor:** project owner who wants to add cross-chain sucker bridges to an already-launched project.

**Intent:** deploy suckers via `JBOmnichainDeployer.deploySuckersFor()` for a project that was not originally launched through the omnichain deployer (or needs additional suckers after launch).

**Background**

When a project is freshly launched through the omnichain deployer, the deployer contract temporarily holds the project NFT. This means it automatically satisfies the `DEPLOY_SUCKERS` permission check because it is the project owner at that moment. After sucker deployment, it transfers the NFT to the intended owner.

For projects that already exist and are owned by someone else, the deployer no longer holds the project NFT. The permission check in `deploySuckersFor()` requires that the caller has `DEPLOY_SUCKERS` permission from the project owner. Since the omnichain deployer enforces this check internally via `_requirePermissionFrom`, the project owner must explicitly grant this permission before calling the function.

**Main Flow**
1. The project owner calls `JBPermissions.setPermissionsFor()` to grant the `DEPLOY_SUCKERS` permission (from `JBPermissionIds`) to the `JBOmnichainDeployer` contract address, scoped to their project ID.
2. The project owner (or any caller with the appropriate permission) calls `JBOmnichainDeployer.deploySuckersFor()` with the project ID and sucker deployment configuration.
3. The deployer verifies that the caller has `DEPLOY_SUCKERS` permission from the project owner.
4. The deployer deploys the suckers via the sucker registry and returns their addresses.

**Failure Modes**
- Calling `deploySuckersFor()` without first granting the deployer `DEPLOY_SUCKERS` permission will revert with a permission error.
- Granting the permission to the wrong address (e.g., the caller's EOA instead of the deployer contract) will not satisfy the check, since the deployer enforces permission on behalf of the project owner against its own address.
- Forgetting to scope the permission to the correct project ID will cause the call to fail.

**Key Difference from Journey 1**

In Journey 1 (fresh launch), permission is implicit because the deployer owns the project NFT during deployment. In Journey 2 (existing project), permission must be explicitly granted via `JBPermissions` before sucker deployment can proceed.

## Trust Boundaries

- this repo wraps runtime behavior but does not replace the underlying 721 or sucker repos

## Hand-Offs

- Use `nana-suckers-v6` for bridge runtime behavior.
- Use `nana-721-hook-v6` for tiered NFT runtime behavior.
