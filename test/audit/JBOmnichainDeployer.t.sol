// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
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

contract JBOmnichainDeployerTest is Test {
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer internal hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBController internal controller = IJBController(makeAddr("controller"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets internal rulesets = IJBRulesets(makeAddr("rulesets"));
    address internal hookAddr = makeAddr("hook721");
    address internal projectOwner = makeAddr("projectOwner");
    address internal operator = makeAddr("operator");

    uint256 internal constant PROJECT_ID = 42;

    function test_existingProjectSuckerDeployment_revertsWithoutRegistryPermission() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(address(directory), abi.encodeWithSelector(IJBDirectory.PROJECTS.selector), abi.encode(projects));
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(projectOwner)
        );

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
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            // forge-lint: disable-next-line(unsafe-typecast)
            salt: bytes32("SUCKER_SALT")
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

    function test_queueCarryForward_preserves721CashOutFlag() public {
        address suckerRegistry = makeAddr("suckerRegistry");

        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(PROJECT_ID - 1))
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(PROJECT_ID)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );
        vm.mockCall(suckerRegistry, abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false));

        JBOmnichainDeployer deployer =
            new JBOmnichainDeployer(IJBSuckerRegistry(suckerRegistry), hookDeployer, permissions, projects, address(0));

        JBCashOutHookSpecification[] memory emptySpecs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(1234), uint256(55), uint256(999), emptySpecs)
        );

        JBRulesetConfig[] memory launchConfigs = new JBRulesetConfig[](1);
        launchConfigs[0] = _rulesetConfig();

        deployer.launchProjectFor({
            owner: projectOwner,
            projectUri: "test",
            deploy721Config: JBOmnichain721Config({
                deployTiersHookConfig: _empty721HookConfig(), useDataHookForCashOut: true, salt: bytes32(0)
            }),
            rulesetConfigurations: launchConfigs,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: "",
            suckerDeploymentConfiguration: _emptySuckerConfig(),
            controller: controller
        });

        uint256 initialRulesetId = block.timestamp;
        (, bool initialUseForCashOut) = deployer.tiered721HookOf(PROJECT_ID, initialRulesetId);
        assertTrue(initialUseForCashOut, "launch should store the initial cash-out flag");

        JBBeforeCashOutRecordedContext memory initialContext = _cashOutContext(initialRulesetId);
        (uint256 initialTaxRate, uint256 initialCashOutCount, uint256 initialTotalSupply,) =
            deployer.beforeCashOutRecordedWith(initialContext);
        assertEq(initialTaxRate, 1234, "initial ruleset should forward cash-outs into the 721 hook");
        assertEq(initialCashOutCount, 55, "initial ruleset should use the 721 hook cash-out count");
        assertEq(initialTotalSupply, 999, "initial ruleset should use the 721 hook total supply");

        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, PROJECT_ID),
            abi.encode(IERC165(address(controller)))
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesets));
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, PROJECT_ID),
            abi.encode(initialRulesetId)
        );

        // Mock currentOf to return a JBRuleset with id = initialRulesetId so the carry-forward lookup succeeds.
        JBRuleset memory currentRuleset;
        currentRuleset.id = uint48(initialRulesetId);
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.currentOf.selector, PROJECT_ID),
            abi.encode(currentRuleset)
        );

        vm.warp(block.timestamp + 1);
        uint256 queuedRulesetId = block.timestamp;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(queuedRulesetId)
        );

        JBRulesetConfig[] memory queueConfigs = new JBRulesetConfig[](1);
        queueConfigs[0] = _rulesetConfig();

        vm.prank(projectOwner);
        deployer.queueRulesetsOf(PROJECT_ID, queueConfigs, "", controller);

        (IJB721TiersHook carriedHook, bool queuedUseForCashOut) = deployer.tiered721HookOf(PROJECT_ID, queuedRulesetId);
        assertEq(address(carriedHook), hookAddr, "queue should carry the existing 721 hook address forward");
        // The carry-forward preserves the cash-out flag from the previous ruleset.
        assertTrue(queuedUseForCashOut, "queue should preserve the existing 721 cash-out flag");

        JBBeforeCashOutRecordedContext memory queuedContext = _cashOutContext(queuedRulesetId);
        (uint256 queuedTaxRate, uint256 queuedCashOutCount, uint256 queuedTotalSupply,) =
            deployer.beforeCashOutRecordedWith(queuedContext);

        // The 721 hook is properly consulted for cash-outs in the queued ruleset.
        assertEq(queuedTaxRate, 1234, "queued ruleset should forward cash-outs into the 721 hook");
        assertEq(queuedCashOutCount, 55, "queued ruleset should use the 721 hook cash-out count");
        assertEq(queuedTotalSupply, 999, "queued ruleset should use the 721 hook total supply");
    }

    function _cashOutContext(uint256 rulesetId) internal pure returns (JBBeforeCashOutRecordedContext memory context) {
        context.terminal = _addr("terminal");
        context.holder = _addr("holder");
        context.projectId = PROJECT_ID;
        context.rulesetId = rulesetId;
        context.cashOutCount = 0;
        context.totalSupply = 777;
        context.surplus = JBTokenAmount({
            token: JBConstants.NATIVE_TOKEN,
            value: 1 ether,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        context.cashOutTaxRate = 5000;
    }

    function _addr(string memory seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(seed)))));
    }

    function _empty721HookConfig() internal pure returns (JBDeploy721TiersHookConfig memory config) {
        config.tiersConfig.currency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        config.tiersConfig.decimals = 18;
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
    }

    function _rulesetConfig() internal pure returns (JBRulesetConfig memory config) {
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000,
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
        config.splitGroups = new JBSplitGroup[](0);
        config.fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
    }
}
