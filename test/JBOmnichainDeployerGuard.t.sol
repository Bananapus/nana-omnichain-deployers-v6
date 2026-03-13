// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "@bananapus/suckers-v6/src/structs/JBSuckersPair.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../src/structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

/// @notice Minimal mock implementing IJBSuckerRegistry — all calls return defaults.
contract MockSuckerRegistry is IJBSuckerRegistry {
    function DIRECTORY() external pure override returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    function PROJECTS() external pure override returns (IJBProjects) {
        return IJBProjects(address(0));
    }

    function isSuckerOf(uint256, address) external pure override returns (bool) {
        return false;
    }

    function suckerDeployerIsAllowed(address) external pure override returns (bool) {
        return false;
    }

    function suckerPairsOf(uint256) external pure override returns (JBSuckersPair[] memory) {
        return new JBSuckersPair[](0);
    }

    function suckersOf(uint256) external pure override returns (address[] memory) {
        return new address[](0);
    }

    function allowSuckerDeployer(address) external override {}
    function allowSuckerDeployers(address[] calldata) external override {}

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] memory
    )
        external
        pure
        override
        returns (address[] memory)
    {
        return new address[](0);
    }

    function removeDeprecatedSucker(uint256, address) external override {}
    function removeSuckerDeployer(address) external override {}
}

contract JBOmnichainDeployerGuardTest is TestBaseWorkflow {
    JBOmnichainDeployer deployer;
    MockSuckerRegistry suckerRegistry;

    address owner;

    function setUp() public override {
        super.setUp();

        owner = multisig();
        suckerRegistry = new MockSuckerRegistry();

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(address(suckerRegistry)),
            IJB721TiersHookDeployer(address(0)),
            IJBPermissions(address(jbPermissions())),
            IJBProjects(address(jbProjects())),
            trustedForwarder()
        );

        // Allow the deployer to set first controller.
        vm.prank(multisig());
        jbDirectory().setIsAllowedToSetFirstController(address(deployer), true);
    }

    // ──────────────────── Helpers
    // ────────────────────

    function _defaultMetadata() internal pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE))), // native
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function _makeRulesetConfigs(uint256 count) internal pure returns (JBRulesetConfig[] memory configs) {
        configs = new JBRulesetConfig[](count);
        for (uint256 i; i < count; i++) {
            configs[i] = JBRulesetConfig({
                mustStartAtOrAfter: uint48(0),
                duration: uint32(0),
                weight: uint112(1e18),
                weightCutPercent: uint32(0),
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: _defaultMetadata(),
                splitGroups: new JBSplitGroup[](0),
                fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
            });
        }
    }

    function _makeRulesetConfigsWithHook(
        uint256 count,
        address hook
    )
        internal
        pure
        returns (JBRulesetConfig[] memory configs)
    {
        configs = _makeRulesetConfigs(count);
        for (uint256 i; i < count; i++) {
            configs[i].metadata.dataHook = hook;
            configs[i].metadata.useDataHookForPay = true;
        }
    }

    function _makeTerminalConfigs() internal view returns (JBTerminalConfig[] memory configs) {
        configs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: address(0x000000000000000000000000000000000000EEEe), // JBConstants.NATIVE_TOKEN
            decimals: 18,
            currency: uint32(uint160(address(0x000000000000000000000000000000000000EEEe)))
        });
        configs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: contexts});
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory) {
        return JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
    }

    function _launchProject(uint256 rulesetCount) internal returns (uint256 projectId) {
        JBRulesetConfig[] memory rulesets = _makeRulesetConfigs(rulesetCount);
        JBTerminalConfig[] memory terminals = _makeTerminalConfigs();
        JBOmnichain721Config memory empty721Config;

        (projectId,,) = deployer.launchProjectFor(
            owner,
            "ipfs://test",
            empty721Config,
            rulesets,
            terminals,
            "launch",
            _emptySuckerConfig(),
            IJBController(address(jbController()))
        );
    }

    function _launchProjectWithHook(uint256 rulesetCount, address hook) internal returns (uint256 projectId) {
        JBRulesetConfig[] memory rulesets = _makeRulesetConfigsWithHook(rulesetCount, hook);
        JBTerminalConfig[] memory terminals = _makeTerminalConfigs();
        JBOmnichain721Config memory empty721Config;

        (projectId,,) = deployer.launchProjectFor(
            owner,
            "ipfs://test",
            empty721Config,
            rulesets,
            terminals,
            "launch",
            _emptySuckerConfig(),
            IJBController(address(jbController()))
        );
    }

    function _grantDeployerQueuePermission(uint256 projectId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.QUEUE_RULESETS;

        // The deployer checks that msg.sender (this test contract) has permission.
        vm.prank(owner);
        jbPermissions()
            .setPermissionsFor(
                owner,
                JBPermissionsData({operator: address(this), projectId: uint64(projectId), permissionIds: permissionIds})
            );

        // The controller checks that msg.sender (the deployer) has permission.
        vm.prank(owner);
        jbPermissions()
            .setPermissionsFor(
                owner,
                JBPermissionsData({
                    operator: address(deployer), projectId: uint64(projectId), permissionIds: permissionIds
                })
            );
    }

    // ──────────────────── Tests
    // ────────────────────

    /// @notice Verify that launchProjectFor stores data hooks at the correct predicted ruleset IDs.
    function test_launchProjectFor_storesDataHooks() public {
        address mockHook = address(0xBEEF);

        uint256 projectId = _launchProjectWithHook(2, mockHook);

        // Ruleset IDs are predicted as block.timestamp + i.
        uint256 rulesetId0 = block.timestamp;
        uint256 rulesetId1 = block.timestamp + 1;

        JBDeployerHookConfig memory hook0 = deployer.extraDataHookOf(projectId, rulesetId0);
        JBDeployerHookConfig memory hook1 = deployer.extraDataHookOf(projectId, rulesetId1);

        assertEq(address(hook0.dataHook), mockHook, "hook 0 mismatch");
        assertTrue(hook0.useDataHookForPay, "useDataHookForPay 0 should be true");
        assertEq(address(hook1.dataHook), mockHook, "hook 1 mismatch");
        assertTrue(hook1.useDataHookForPay, "useDataHookForPay 1 should be true");
    }

    /// @notice Queue rulesets succeeds when called in a different block than launch.
    function test_queueRulesetsOf_succeeds_noConflict() public {
        uint256 projectId = _launchProject(1);
        _grantDeployerQueuePermission(projectId);

        // Warp forward so latestRulesetIdOf < block.timestamp.
        vm.warp(block.timestamp + 1 days);

        JBRulesetConfig[] memory rulesets = _makeRulesetConfigs(1);

        // Should succeed without reverting.
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, rulesets, "queue", IJBController(address(jbController())));
    }

    /// @notice Queue rulesets reverts when called in the same block as launch
    ///         (latestRulesetIdOf >= block.timestamp).
    function test_queueRulesetsOf_reverts_sameBlock() public {
        uint256 projectId = _launchProject(1);
        _grantDeployerQueuePermission(projectId);

        // Same block: latestRulesetIdOf == block.timestamp, so >= holds.
        JBRulesetConfig[] memory rulesets = _makeRulesetConfigs(1);

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, rulesets, "queue", IJBController(address(jbController())));
    }

    /// @notice Queue via deployer reverts when someone already queued via the controller
    ///         directly in the same block.
    function test_queueRulesetsOf_reverts_afterDirectQueueInSameBlock() public {
        uint256 projectId = _launchProject(1);
        _grantDeployerQueuePermission(projectId);

        // Warp forward to clear the launch-block conflict.
        vm.warp(block.timestamp + 1 days);

        // Queue directly via the controller (as owner).
        JBRulesetConfig[] memory directRulesets = _makeRulesetConfigs(1);
        vm.prank(owner);
        jbController().queueRulesetsOf(projectId, directRulesets, "direct");

        // Now latestRulesetIdOf == block.timestamp (from the direct queue).
        // Deployer queue in the same block should revert.
        JBRulesetConfig[] memory deployerRulesets = _makeRulesetConfigs(1);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, deployerRulesets, "deployer-queue", IJBController(address(jbController())));
    }

    /// @notice Queue succeeds after warping past the latestRulesetIdOf from a multi-ruleset launch.
    function test_queueRulesetsOf_succeeds_afterWarpPastConflict() public {
        // Launch with 2 rulesets: latestRulesetIdOf = block.timestamp + 1.
        uint256 projectId = _launchProject(2);
        _grantDeployerQueuePermission(projectId);

        // Verify we can't queue in the same block (latestRulesetIdOf = block.timestamp + 1 >= block.timestamp).
        JBRulesetConfig[] memory rulesets = _makeRulesetConfigs(1);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, rulesets, "too-early", IJBController(address(jbController())));

        // Warp past latestRulesetIdOf so the guard passes.
        vm.warp(block.timestamp + 2);

        // Now should succeed.
        JBOmnichain721Config memory empty721b;
        deployer.queueRulesetsOf(projectId, empty721b, rulesets, "ok-now", IJBController(address(jbController())));
    }
}
