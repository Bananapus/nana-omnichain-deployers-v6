// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";

/// @title HookOwnershipTransfer
/// @notice Regression test: queue721RulesetsOf must transfer hook ownership to the project.
///         Before this fix, the hook's ownership was stuck with JBOmnichainDeployer permanently.
contract HookOwnershipTransfer is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets rulesetsContract = IJBRulesets(makeAddr("rulesets"));
    address hookAddr = makeAddr("hook721");

    address projectOwner = makeAddr("projectOwner");

    uint256 projectId = 42;

    function setUp() public {
        // Mock permissions.setPermissionsFor in constructor.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, address(0));

        // Default mocks: permissions always pass.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Mock RULESETS on controller.
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesetsContract)
        );
        vm.mockCall(
            address(rulesetsContract),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, projectId),
            abi.encode(uint256(0)) // no conflict
        );

        // Mock DIRECTORY on controller and controllerOf on directory.
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(IERC165(address(controller)))
        );

        // Mock the hook deployer to return our hook address.
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );

        // Mock transferOwnershipToProject on the hook.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Mock controller.queueRulesetsOf to succeed.
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.queueRulesetsOf.selector), abi.encode(uint256(1))
        );
    }

    /// @notice Verify that queueRulesetsOf (721 path) calls transferOwnershipToProject on the hook.
    function test_queue721RulesetsOf_transfersHookOwnership() public {
        // Create minimal ruleset config.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: uint112(1e18),
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetController: false,
                allowSetTerminals: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBDeploy721TiersHookConfig memory hookConfig;
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        tiers[0].price = 0.01 ether;
        tiers[0].initialSupply = 100;
        hookConfig.tiersConfig.tiers = tiers;

        // Expect the transferOwnershipToProject call on the hook.
        vm.expectCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector, projectId));

        deployer.queueRulesetsOf({
            projectId: projectId,
            deploy721Config: JBOmnichain721Config({
                deployTiersHookConfig: hookConfig,
                useDataHookForCashOut: false,
                salt: bytes32(0)
            }),
            rulesetConfigurations: rulesetConfigs,
            memo: "test",
            controller: controller
        });
    }
}
