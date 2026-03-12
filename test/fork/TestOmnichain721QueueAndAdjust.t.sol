// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./OmnichainForkTestBase.sol";

import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {JBQueueRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBQueueRulesetsConfig.sol";
import {JBLaunchRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchRulesetsConfig.sol";
import {JBPayDataHookRulesetConfig} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetConfig.sol";
import {JBPayDataHookRulesetMetadata} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetMetadata.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";

/// @notice Tests that queueing rulesets with a 721 hook properly transfers hook ownership
///         to the project, enabling the project owner to later adjust tiers.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestOmnichain721QueueAndAdjust -vvv
contract TestOmnichain721QueueAndAdjust is OmnichainForkTestBase {
    /// @notice Launch a plain project, then queue 721 rulesets, then verify the project owner can adjustTiers.
    function test_fork_queue721Rulesets_thenOwnerCanAdjustTiers() public {
        // Step 1: Launch a plain project (no 721 hook initially).
        uint256 projectId = _deployPlain(5000);

        // Step 2: Grant the deployer permission to queue rulesets and set terminals.
        _grantDeployerPermissions(projectId);

        // Step 3: Warp forward to avoid ruleset ID collision.
        vm.warp(block.timestamp + 1 days);

        // Step 4: Queue 721 rulesets via the deployer.
        JBDeploy721TiersHookConfig memory hookConfig = _build721Config();

        JBPayDataHookRulesetConfig[] memory rulesetConfigs = new JBPayDataHookRulesetConfig[](1);
        rulesetConfigs[0] = JBPayDataHookRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBPayDataHookRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 5000,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowTerminalMigration: false,
                allowSetController: false,
                allowSetTerminals: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForCashOut: false,
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBQueueRulesetsConfig memory queueConfig = JBQueueRulesetsConfig({
            projectId: uint56(projectId), rulesetConfigurations: rulesetConfigs, memo: "add 721 hook"
        });

        (, IJB721TiersHook hook) = DEPLOYER.queue721RulesetsOf({
            projectId: projectId,
            deployTiersHookConfig: hookConfig,
            queueRulesetsConfig: queueConfig,
            controller: IJBController(address(jbController())),
            dataHookConfig: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(0)), useDataHookForPay: false, useDataHookForCashOut: false
            }),
            salt: bytes32("Q721")
        });

        // Step 5: Verify hook ownership was transferred to the project.
        IJBOwnable ownableHook = IJBOwnable(address(hook));
        (, uint88 hookProjectId,) = ownableHook.jbOwner();
        assertEq(hookProjectId, uint88(projectId), "Hook should be owned by the project");

        // Step 6: Verify the hook is stored.
        assertEq(address(DEPLOYER.tiered721HookOf(projectId)), address(hook), "Deployer should store the new 721 hook");

        // Step 7: The project owner (multisig) should be able to add tiers.
        JB721TierConfig[] memory newTiers = new JB721TierConfig[](1);
        newTiers[0] = JB721TierConfig({
            price: 0.5 ether,
            initialSupply: 50,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: bytes32("tier2"),
            category: 2,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Owner of the project NFT should be able to call adjustTiers.
        vm.prank(multisig());
        hook.adjustTiers(newTiers, new uint256[](0));

        // Verify the new tier was added (tier ID 2 should exist now).
        // If this doesn't revert, the tier was successfully added.
    }

    /// @notice Launch a project with 721 hook, then queue new 721 rulesets (replace hook).
    ///         Verify the new hook is owned by the project and adjustable.
    function test_fork_launch721_thenQueue721_ownerCanAdjustNewHook() public {
        // Step 1: Launch project with initial 721 hook.
        (uint256 projectId, IJB721TiersHook originalHook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        // Step 2: Grant deployer permissions.
        _grantDeployerPermissions(projectId);

        // Step 3: Warp forward.
        vm.warp(block.timestamp + 1 days);

        // Step 4: Queue new 721 rulesets with a fresh hook.
        JBDeploy721TiersHookConfig memory newHookConfig = _build721Config();

        JBPayDataHookRulesetConfig[] memory rulesetConfigs = new JBPayDataHookRulesetConfig[](1);
        rulesetConfigs[0] = JBPayDataHookRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBPayDataHookRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 3000,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowTerminalMigration: false,
                allowSetController: false,
                allowSetTerminals: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForCashOut: false,
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBQueueRulesetsConfig memory queueConfig = JBQueueRulesetsConfig({
            projectId: uint56(projectId), rulesetConfigurations: rulesetConfigs, memo: "replace hook"
        });

        (, IJB721TiersHook newHook) = DEPLOYER.queue721RulesetsOf({
            projectId: projectId,
            deployTiersHookConfig: newHookConfig,
            queueRulesetsConfig: queueConfig,
            controller: IJBController(address(jbController())),
            dataHookConfig: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(BUYBACK_HOOK)),
                useDataHookForPay: true,
                useDataHookForCashOut: false
            }),
            salt: bytes32("REPLACE")
        });

        // The new hook should be different from the original.
        assertFalse(address(newHook) == address(originalHook), "New hook should be a different address");

        // The deployer should store the new hook (overwriting the old one).
        assertEq(address(DEPLOYER.tiered721HookOf(projectId)), address(newHook), "Deployer should store the new hook");

        // The new hook should be owned by the project.
        IJBOwnable ownableNewHook = IJBOwnable(address(newHook));
        (, uint88 newHookProjectId,) = ownableNewHook.jbOwner();
        assertEq(newHookProjectId, uint88(projectId), "New hook should be owned by the project");

        // Owner should be able to adjust tiers on the new hook.
        JB721TierConfig[] memory newTiers = new JB721TierConfig[](1);
        newTiers[0] = JB721TierConfig({
            price: 2 ether,
            initialSupply: 25,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: bytes32("tier3"),
            category: 3,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(multisig());
        newHook.adjustTiers(newTiers, new uint256[](0));
    }

    /// @notice Verify that a non-owner cannot adjust tiers on a queued 721 hook.
    function test_fork_queue721_nonOwnerCannotAdjustTiers() public {
        uint256 projectId = _deployPlain(5000);
        _grantDeployerPermissions(projectId);
        vm.warp(block.timestamp + 1 days);

        JBDeploy721TiersHookConfig memory hookConfig = _build721Config();

        JBPayDataHookRulesetConfig[] memory rulesetConfigs = new JBPayDataHookRulesetConfig[](1);
        rulesetConfigs[0] = JBPayDataHookRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBPayDataHookRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 5000,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowTerminalMigration: false,
                allowSetController: false,
                allowSetTerminals: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForCashOut: false,
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBQueueRulesetsConfig memory queueConfig = JBQueueRulesetsConfig({
            projectId: uint56(projectId), rulesetConfigurations: rulesetConfigs, memo: "test perms"
        });

        (, IJB721TiersHook hook) = DEPLOYER.queue721RulesetsOf({
            projectId: projectId,
            deployTiersHookConfig: hookConfig,
            queueRulesetsConfig: queueConfig,
            controller: IJBController(address(jbController())),
            dataHookConfig: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(0)), useDataHookForPay: false, useDataHookForCashOut: false
            }),
            salt: bytes32("PERMS")
        });

        // A random address should NOT be able to adjust tiers.
        address rando = makeAddr("rando");
        JB721TierConfig[] memory newTiers = new JB721TierConfig[](1);
        newTiers[0] = JB721TierConfig({
            price: 0.1 ether,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: bytes32("bad"),
            category: 4,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(rando);
        vm.expectRevert();
        hook.adjustTiers(newTiers, new uint256[](0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _grantDeployerPermissions(uint256 projectId) internal {
        // Grant QUEUE_RULESETS to test contract (caller of deployer methods).
        uint8[] memory queuePerms = new uint8[](2);
        queuePerms[0] = JBPermissionIds.QUEUE_RULESETS;
        queuePerms[1] = JBPermissionIds.SET_TERMINALS;

        vm.prank(multisig());
        jbPermissions()
            .setPermissionsFor(
                multisig(),
                JBPermissionsData({operator: address(this), projectId: uint64(projectId), permissionIds: queuePerms})
            );

        // Grant QUEUE_RULESETS to the deployer (it calls controller on behalf of the project).
        vm.prank(multisig());
        jbPermissions()
            .setPermissionsFor(
                multisig(),
                JBPermissionsData({
                    operator: address(DEPLOYER), projectId: uint64(projectId), permissionIds: queuePerms
                })
            );
    }
}
