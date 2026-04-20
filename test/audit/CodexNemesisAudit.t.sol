// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

contract CodexNemesisAudit is Test {
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer internal hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBSuckerRegistry internal mockSuckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJBController internal controller = IJBController(makeAddr("controller"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    address internal hookAddr = makeAddr("hook721");
    address internal projectOwner = makeAddr("projectOwner");
    address internal operator = makeAddr("operator");

    uint256 internal constant PROJECT_ID = 42;

    function setUp() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());
    }

    function test_poc_launchRulesetsFor_succeedsWhenProjectHasNoControllerYet() public {
        JBOmnichainDeployer deployer =
            new JBOmnichainDeployer(mockSuckerRegistry, hookDeployer, permissions, projects, address(0));

        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        // A freshly created project with no controller yet — the M-14 fix allows address(0) through.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, PROJECT_ID),
            abi.encode(IERC165(address(0)))
        );
        // Mock controller.launchRulesetsFor to return a rulesetId.
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchRulesetsFor.selector),
            abi.encode(uint256(1))
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig();

        vm.prank(projectOwner);
        (uint256 rulesetId,) =
            deployer.launchRulesetsFor(PROJECT_ID, configs, new JBTerminalConfig[](0), "memo", controller);

        // Verify the call succeeded and returned a valid rulesetId.
        assertGt(rulesetId, 0, "launchRulesetsFor should succeed for fresh project with no controller");
    }

    function test_poc_deploySuckersFor_requiresHiddenPermissionForDeployerItself() public {
        vm.mockCall(address(directory), abi.encodeWithSelector(IJBDirectory.PROJECTS.selector), abi.encode(projects));

        JBSuckerRegistry registry = new JBSuckerRegistry(directory, permissions, address(this), address(0));
        JBOmnichainDeployer deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(address(registry)), hookDeployer, permissions, projects, address(0)
        );

        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(
                IJBPermissions.hasPermission.selector,
                operator,
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.DEPLOY_SUCKERS,
                true,
                true
            ),
            abi.encode(true)
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(
                IJBPermissions.hasPermission.selector,
                address(deployer),
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.DEPLOY_SUCKERS,
                true,
                true
            ),
            abi.encode(false)
        );

        JBSuckerDeploymentConfig memory config = JBSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32("SUCKER_SALT")
        });

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                address(deployer),
                PROJECT_ID,
                JBPermissionIds.DEPLOY_SUCKERS
            )
        );
        deployer.deploySuckersFor(PROJECT_ID, config);
    }

    function _makeRulesetConfig() internal pure returns (JBRulesetConfig memory config) {
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
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
}
