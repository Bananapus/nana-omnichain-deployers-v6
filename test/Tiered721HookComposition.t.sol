// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../src/structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @title Tiered721HookComposition
/// @notice Tests for the separated 721 hook storage and data hook composition.
contract Tiered721HookComposition is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets rulesetsContract = IJBRulesets(makeAddr("rulesets"));

    address hookAddr = makeAddr("hook721");
    address buybackHookAddr = makeAddr("buybackHook");
    address customHookAddr = makeAddr("customHook");
    address projectOwner = makeAddr("projectOwner");
    address sucker = makeAddr("sucker");
    address randomAddr = makeAddr("random");

    uint256 projectId = 42;

    function setUp() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, address(0));
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(IERC165(address(controller)))
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesetsContract)
        );
        vm.mockCall(
            address(rulesetsContract),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, projectId),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );
        JBPayHookSpecification[] memory default721Specs = new JBPayHookSpecification[](1);
        default721Specs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), default721Specs)
        );
        vm.mockCallRevert(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encodeWithSignature("JB721Hook_UnexpectedTokenCashedOut()")
        );
    }

    // ---------------------------------------------------------------
    // launchProjectFor (721 path): storage
    // ---------------------------------------------------------------

    function test_launch721ProjectFor_stores721HookSeparately() public {
        (uint256 pid, IJB721TiersHook hook,) = _launch721({
            dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false
        });
        (IJB721TiersHook storedHook,) = deployer.tiered721HookOf(pid, block.timestamp);
        assertEq(address(storedHook), hookAddr, "721 hook stored separately");
        assertEq(address(hook), hookAddr, "returned hook matches");
    }

    function test_launch721ProjectFor_storesUserDataHook() public {
        (uint256 pid,,) = _launch721({
            dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false
        });
        uint256 storedRulesetId = block.timestamp;
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(pid, storedRulesetId);
        assertEq(address(stored721), hookAddr, "721 hook should be stored per-ruleset");
        JBDeployerHookConfig memory extraHook = deployer.extraDataHookOf(pid, storedRulesetId);
        assertEq(address(extraHook.dataHook), buybackHookAddr, "extra hook should be custom");
        assertTrue(extraHook.useDataHookForPay, "custom useDataHookForPay should be true");
    }

    function test_launch721ProjectFor_noDataHook_stores721Only() public {
        (uint256 pid,,) = _launch721({
            dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false
        });
        uint256 storedRulesetId = block.timestamp;
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(pid, storedRulesetId);
        assertEq(address(stored721), hookAddr, "721 hook stored");
        JBDeployerHookConfig memory extraHook = deployer.extraDataHookOf(pid, storedRulesetId);
        assertEq(address(extraHook.dataHook), address(0), "no extra hook");
    }

    // ---------------------------------------------------------------
    // beforePayRecordedWith: composition
    // ---------------------------------------------------------------

    function test_beforePay_721Only_noDataHook() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, context.weight, "weight should be original (no user hook)");
        assertEq(specs.length, 1, "should have 1 spec (721 hook)");
        assertEq(address(specs[0].hook), hookAddr, "spec should point to 721 hook");
        assertEq(specs[0].amount, 0, "721 hook amount should be 0");
    }

    function test_beforePay_buybackPlus721_composesCorrectly() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        uint256 buybackWeight = 555;
        JBPayHookSpecification[] memory buybackSpecs = new JBPayHookSpecification[](1);
        buybackSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(buybackHookAddr), amount: 0.5 ether, metadata: bytes("buyback")});
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(buybackWeight, buybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, buybackWeight, "weight should come from buyback hook");
        assertEq(specs.length, 2, "should have 2 specs");
        assertEq(address(specs[0].hook), hookAddr, "first spec = 721 hook");
        assertEq(specs[0].amount, 0, "721 hook amount = 0");
        assertEq(address(specs[1].hook), buybackHookAddr, "second spec = buyback hook");
        assertEq(specs[1].amount, 0.5 ether, "buyback amount preserved");
        assertEq(specs[1].metadata, bytes("buyback"), "buyback metadata preserved");
    }

    function test_beforePay_userHookReturnsNoSpecs_only721Spec() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            customHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(777), emptySpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 777, "weight from custom hook");
        assertEq(specs.length, 1, "only 721 spec");
        assertEq(address(specs[0].hook), hookAddr, "721 hook");
    }

    function test_beforePay_userHookReturnsMultipleSpecs() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory userSpecs = new JBPayHookSpecification[](3);
        for (uint256 i; i < 3; i++) {
            userSpecs[i] = JBPayHookSpecification({
                hook: IJBPayHook(address(uint160(100 + i))), amount: (i + 1) * 0.1 ether, metadata: bytes("")
            });
        }
        vm.mockCall(
            customHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), userSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 1000);
        assertEq(specs.length, 4, "1 (721) + 3 (user)");
        assertEq(address(specs[0].hook), hookAddr, "first = 721");
        for (uint256 i; i < 3; i++) {
            assertEq(address(specs[i + 1].hook), address(uint160(100 + i)), "user spec position correct");
            assertEq(specs[i + 1].amount, (i + 1) * 0.1 ether);
        }
    }

    function test_beforePay_noHooksAtAll_returnsOriginalWeight() public {
        JBBeforePayRecordedContext memory context = _makePayContext(99, 999);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, context.weight, "original weight");
        assertEq(specs.length, 0, "no specs");
    }

    // ---------------------------------------------------------------
    // beforePayRecordedWith: split fund forwarding
    // ---------------------------------------------------------------

    function test_beforePay_721HookSplitAmountForwarded() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        uint256 splitAmount = 0.3 ether;
        bytes memory splitMetadata = abi.encode(uint256(1), uint256(2));
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: splitAmount, metadata: splitMetadata});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(specs.length, 1, "should have 1 spec (721 hook)");
        assertEq(address(specs[0].hook), hookAddr, "spec points to 721 hook");
        assertEq(specs[0].amount, splitAmount, "split amount must be forwarded, not hardcoded to 0");
        assertEq(specs[0].metadata, splitMetadata, "split metadata must be forwarded");
        assertEq(weight, 700, "weight adjusted for split ratio");
    }

    function test_beforePay_721SplitsComposedWithBuyback() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        uint256 splitAmount = 0.25 ether;
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: splitAmount, metadata: abi.encode(uint256(5))});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        uint256 buybackWeight = 555;
        JBPayHookSpecification[] memory buybackSpecs = new JBPayHookSpecification[](1);
        buybackSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(buybackHookAddr), amount: 0.5 ether, metadata: bytes("buyback")});
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(buybackWeight, buybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 416, "weight = buybackWeight * (amount - split) / amount");
        assertEq(specs.length, 2, "721 spec + buyback spec");
        assertEq(address(specs[0].hook), hookAddr, "first = 721 hook");
        assertEq(specs[0].amount, splitAmount, "721 split amount preserved");
        assertEq(address(specs[1].hook), buybackHookAddr, "second = buyback hook");
        assertEq(specs[1].amount, 0.5 ether, "buyback amount preserved");
    }

    function test_beforePay_721HookReturnsSingleSpec() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0.3 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(specs.length, 1, "single 721 spec forwarded");
        assertEq(specs[0].amount, 0.3 ether, "721 spec split amount");
    }

    // ---------------------------------------------------------------
    // beforeCashOutRecordedWith: routing
    // ---------------------------------------------------------------

    function test_beforeCashOut_suckerGetsZeroTax_regardless() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, block.timestamp, sucker);
        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);
        assertEq(taxRate, 0, "sucker gets 0 tax");
        assertEq(cashOutCount, context.cashOutCount);
        assertEq(totalSupply, context.totalSupply);
    }

    function test_beforeCashOut_721CashOutTrue_revertsForFungibleCashOut() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: true, use721ForCashOut: true});
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, block.timestamp, randomAddr);
        vm.expectRevert();
        deployer.beforeCashOutRecordedWith(context);
    }

    function test_beforeCashOut_721CashOutFalse_customHookHandlesCashOut() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: true, use721ForCashOut: false});
        JBCashOutHookSpecification[] memory cashOutSpecs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(3000), uint256(500), uint256(5000), cashOutSpecs)
        );
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, block.timestamp, randomAddr);
        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);
        assertEq(taxRate, 3000, "buyback hook's tax rate");
        assertEq(cashOutCount, 500, "buyback hook's cashOutCount");
        assertEq(totalSupply, 5000, "buyback hook's totalSupply");
    }

    function test_beforeCashOut_zeroTiers_forwardsToUserHook() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(customHookAddr, true, true);
        deployer.launchProjectFor(
            projectOwner, "test", _empty721Config(), configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
        JBCashOutHookSpecification[] memory cashOutSpecs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            customHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(2000), uint256(100), uint256(1000), cashOutSpecs)
        );
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, block.timestamp, randomAddr);
        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);
        assertEq(taxRate, 2000, "user hook's tax rate");
        assertEq(cashOutCount, 100, "user hook's cashOutCount");
        assertEq(totalSupply, 1000, "user hook's totalSupply");
    }

    function test_beforeCashOut_zeroTiers_noUserHook_returnsOriginal() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);
        deployer.launchProjectFor(
            projectOwner, "test", _empty721Config(), configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, block.timestamp, randomAddr);
        (uint256 taxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(context);
        assertEq(taxRate, context.cashOutTaxRate, "original tax rate");
        assertEq(cashOutCount, context.cashOutCount);
        assertEq(totalSupply, context.totalSupply);
    }

    // ---------------------------------------------------------------
    // hasMintPermissionFor: multi-source
    // ---------------------------------------------------------------

    function test_hasMintPermission_suckerAlwaysTrue() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );
        JBRuleset memory ruleset;
        ruleset.id = uint48(block.timestamp);
        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, sucker));
    }

    function test_hasMintPermission_userHookGrantsPermission() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        vm.mockCall(
            customHookAddr, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(true)
        );
        vm.mockCall(
            hookAddr, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(false)
        );
        JBRuleset memory ruleset;
        ruleset.id = uint48(block.timestamp);
        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    function test_hasMintPermission_721HookNotChecked() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        vm.mockCall(
            customHookAddr, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(false)
        );
        JBRuleset memory ruleset;
        ruleset.id = uint48(block.timestamp);
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    function test_hasMintPermission_dataHookSaysNo_returnsFalse() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        vm.mockCall(
            customHookAddr, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(false)
        );
        JBRuleset memory ruleset;
        ruleset.id = uint48(block.timestamp);
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    function test_hasMintPermission_721Only_noUserHook_returnsFalse() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        JBRuleset memory ruleset;
        ruleset.id = uint48(block.timestamp);
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    function test_hasMintPermission_noHooksAtAll_returnsFalse() public {
        JBRuleset memory ruleset;
        ruleset.id = 999;
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    // ---------------------------------------------------------------
    // launchRulesetsFor (721 path): stores 721 hook
    // ---------------------------------------------------------------

    function test_launch721RulesetsFor_stores721Hook() public {
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchRulesetsFor.selector),
            abi.encode(uint256(block.timestamp))
        );
        vm.prank(projectOwner);
        (, IJB721TiersHook hook) = deployer.launchRulesetsFor({
            projectId: projectId,
            deploy721Config: JBOmnichain721Config({deployTiersHookConfig: _emptyHookConfig(), useDataHookForCashOut: false, salt: bytes32(0)}),
            rulesetConfigurations: _make721RulesetConfigs(buybackHookAddr, true, false),
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: "",
            controller: controller
        });
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(projectId, block.timestamp);
        assertEq(address(stored721), hookAddr);
        assertEq(address(hook), hookAddr);
    }

    // ---------------------------------------------------------------
    // queueRulesetsOf (721 path): stores 721 hook
    // ---------------------------------------------------------------

    function test_queue721RulesetsOf_stores721Hook() public {
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(uint256(block.timestamp))
        );
        vm.prank(projectOwner);
        (, IJB721TiersHook hook) = deployer.queueRulesetsOf({
            projectId: projectId,
            deploy721Config: JBOmnichain721Config({deployTiersHookConfig: _emptyHookConfig(), useDataHookForCashOut: false, salt: bytes32(0)}),
            rulesetConfigurations: _make721RulesetConfigs(buybackHookAddr, true, false),
            memo: "",
            controller: controller
        });
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(projectId, block.timestamp);
        assertEq(address(stored721), hookAddr);
        assertEq(address(hook), hookAddr);
    }

    // ---------------------------------------------------------------
    // non-721 functions: unchanged behavior
    // ---------------------------------------------------------------

    function test_launchProjectFor_zeroTiers_still721Hook() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(buybackHookAddr, true, false);
        deployer.launchProjectFor(
            projectOwner, "test", _empty721Config(), configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(projectId, block.timestamp);
        assertEq(address(stored721), hookAddr, "721 hook always deployed even with 0 tiers");
        JBDeployerHookConfig memory storedHook = deployer.extraDataHookOf(projectId, block.timestamp);
        assertEq(address(storedHook.dataHook), buybackHookAddr, "user hook stored");
        assertTrue(storedHook.useDataHookForPay);
    }

    function test_beforePay_zeroTiers_buybackComposesWith721() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(buybackHookAddr, true, false);
        deployer.launchProjectFor(
            projectOwner, "test", _empty721Config(), configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
        JBPayHookSpecification[] memory buybackSpecs = new JBPayHookSpecification[](1);
        buybackSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(buybackHookAddr), amount: 0.5 ether, metadata: bytes("")});
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(888), buybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 888, "buyback weight");
        assertEq(specs.length, 2, "721 spec + buyback spec");
        assertEq(address(specs[0].hook), hookAddr, "first = 721 hook");
        assertEq(specs[0].amount, 0, "721 hook amount = 0");
        assertEq(address(specs[1].hook), buybackHookAddr, "second = buyback");
    }

    // ---------------------------------------------------------------
    // beforePayRecordedWith: weight adjustment for splits
    // ---------------------------------------------------------------

    function test_beforePay_weightAdjustedForSplits() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0.5 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(500), hookSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 500, "weight reduced by split ratio");
    }

    function test_beforePay_buybackSeesReducedAmount() public {
        _launch721({dataHook: customHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0.4 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        JBPayHookSpecification[] memory emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            customHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(2000), emptySpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 1200, "weight = customWeight * (amount - split) / amount");
    }

    function test_beforePay_fullSplit_weightZero() public {
        _launch721({dataHook: address(0), useForPay: false, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 1 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 0, "full split = zero weight");
    }

    function test_beforePay_noSplit_noAdjustment() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), hookSpecs)
        );
        JBPayHookSpecification[] memory buybackSpecs = new JBPayHookSpecification[](1);
        buybackSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(buybackHookAddr), amount: 0, metadata: bytes("")});
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(888), buybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 888, "no split = no weight adjustment");
    }

    // ---------------------------------------------------------------
    // beforePayRecordedWith: 721 splits + buyback (AMM vs mint path)
    // ---------------------------------------------------------------

    function test_beforePay_splitPlusBuybackAMM_correctWeight() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0.4 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(600), hookSpecs)
        );
        uint256 buybackWeight = 2000;
        JBPayHookSpecification[] memory buybackSpecs = new JBPayHookSpecification[](1);
        buybackSpecs[0] =
            JBPayHookSpecification({hook: IJBPayHook(buybackHookAddr), amount: 0.6 ether, metadata: bytes("swap")});
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(buybackWeight, buybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 1200, "weight = buybackWeight * (amount - split) / amount");
        assertEq(specs.length, 2, "721 spec + buyback spec");
        assertEq(address(specs[0].hook), hookAddr, "first = 721 hook");
        assertEq(specs[0].amount, 0.4 ether, "721 split amount");
        assertEq(address(specs[1].hook), buybackHookAddr, "second = buyback");
        assertEq(specs[1].amount, 0.6 ether, "buyback gets reduced amount");
    }

    function test_beforePay_splitPlusBuybackMintPath_correctWeight() public {
        _launch721({dataHook: buybackHookAddr, useForPay: true, useForCashOut: false, use721ForCashOut: false});
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(hookAddr), amount: 0.2 ether, metadata: bytes("")});
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(800), hookSpecs)
        );
        uint256 mintPathWeight = 1000;
        JBPayHookSpecification[] memory emptyBuybackSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            buybackHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(mintPathWeight, emptyBuybackSpecs)
        );
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, block.timestamp);
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 800, "weight = buybackWeight * (amount - split) / amount");
        assertEq(specs.length, 1, "only 721 spec (buyback empty)");
        assertEq(address(specs[0].hook), hookAddr, "spec = 721 hook");
        assertEq(specs[0].amount, 0.2 ether, "721 split amount");
    }

    // ---------------------------------------------------------------
    // tiered721HookOf getter
    // ---------------------------------------------------------------

    function test_tiered721HookOf_returnsZeroByDefault() public view {
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(999, 0);
        assertEq(address(stored721), address(0));
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _launch721(
        address dataHook,
        bool useForPay,
        bool useForCashOut,
        bool use721ForCashOut
    )
        internal
        returns (uint256 pid, IJB721TiersHook hook, address[] memory suckers)
    {
        return deployer.launchProjectFor({
            owner: projectOwner,
            projectUri: "test",
            deploy721Config: JBOmnichain721Config({
                deployTiersHookConfig: _emptyHookConfig(),
                useDataHookForCashOut: use721ForCashOut,
                salt: bytes32(0)
            }),
            rulesetConfigurations: _make721RulesetConfigs(dataHook, useForPay, useForCashOut),
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: "",
            suckerDeploymentConfiguration: _emptySuckerConfig(),
            controller: controller
        });
    }

    function _makePayContext(uint256 pid, uint256 rid) internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: randomAddr,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: pid,
            rulesetId: rid,
            beneficiary: randomAddr,
            weight: 1000,
            reservedPercent: 0,
            metadata: ""
        });
    }

    function _makeCashOutContext(
        uint256 pid,
        uint256 rid,
        address holder
    )
        internal
        returns (JBBeforeCashOutRecordedContext memory)
    {
        return JBBeforeCashOutRecordedContext({
            terminal: makeAddr("terminal"),
            holder: holder,
            projectId: pid,
            rulesetId: rid,
            cashOutCount: 1000,
            totalSupply: 10_000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000,
            metadata: ""
        });
    }

    function _makeRulesetConfig(
        address dataHook,
        bool useForPay,
        bool useForCashOut
    )
        internal
        pure
        returns (JBRulesetConfig memory)
    {
        JBRulesetConfig memory config;
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
            useDataHookForPay: useForPay,
            useDataHookForCashOut: useForCashOut,
            dataHook: dataHook,
            metadata: 0
        });
        return config;
    }

    function _make721RulesetConfigs() internal pure returns (JBRulesetConfig[] memory) {
        return _make721RulesetConfigs(address(0), false, false);
    }

    function _make721RulesetConfigs(
        address dataHook,
        bool useForPay,
        bool useForCashOut
    )
        internal
        pure
        returns (JBRulesetConfig[] memory configs)
    {
        configs = new JBRulesetConfig[](1);
        configs[0] = JBRulesetConfig({
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
                useDataHookForPay: useForPay,
                useDataHookForCashOut: useForCashOut,
                dataHook: dataHook,
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    function _emptyHookConfig() internal pure returns (JBDeploy721TiersHookConfig memory config) {
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        tiers[0].price = 0.01 ether;
        tiers[0].initialSupply = 100;
        config.tiersConfig.tiers = tiers;
    }

    function _empty721Config() internal pure returns (JBOmnichain721Config memory config) {}

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
