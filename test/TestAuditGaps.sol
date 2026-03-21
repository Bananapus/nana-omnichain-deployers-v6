// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

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
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../src/structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mock hooks for adversarial tests
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Hook that reverts on pay with a custom error.
contract PayRevertingHook is IJBRulesetDataHook {
    error CustomPayError();

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        revert CustomPayError();
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Hook that reverts on cash out with a custom error.
contract CashOutRevertingHook is IJBRulesetDataHook {
    error CustomCashOutError();

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        return (context.weight, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        revert CustomCashOutError();
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Hook that reverts on hasMintPermissionFor.
contract MintPermissionRevertingHook is IJBRulesetDataHook {
    error MintPermissionReverted();

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        return (context.weight, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        revert MintPermissionReverted();
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Hook that returns unexpected extreme values for cashout.
contract ExtremeCashOutHook is IJBRulesetDataHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        return (context.weight, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        // Return extreme values: max tax rate, zero count, max supply.
        return (type(uint256).max, 0, type(uint256).max, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Hook that returns a large array of pay hook specs.
contract ManySpecsHook is IJBRulesetDataHook {
    uint256 public specCount;

    constructor(uint256 _specCount) {
        specCount = _specCount;
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256, JBPayHookSpecification[] memory specs)
    {
        specs = new JBPayHookSpecification[](specCount);
        for (uint256 i; i < specCount; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            address hookAddr = address(uint160(200 + i));
            specs[i] =
                JBPayHookSpecification({hook: IJBPayHook(hookAddr), noop: false, amount: 0.001 ether, metadata: ""});
        }
        return (context.weight, specs);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Hook that returns weight = 0 (buyback AMM path).
contract ZeroWeightHook is IJBRulesetDataHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        // weight=0 simulates the buyback hook choosing the AMM path.
        return (0, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────

/// @title TestAuditGaps
/// @notice Tests for two audit gaps:
///   1. Hook failure adversarial -- behavior when hooks fail or return unexpected data
///   2. Rapid ruleset queueing -- rapid sequential ruleset queue operations
contract TestAuditGaps is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets rulesetsContract = IJBRulesets(makeAddr("rulesets"));

    address projectOwner = makeAddr("projectOwner");
    address hookAddr = makeAddr("hook721");
    address attacker = makeAddr("attacker");
    address sucker = makeAddr("sucker");

    uint256 projectId = 42;

    // Use a well-known base time so timestamps are unambiguous.
    uint256 constant BASE_TIME = 1_000_000;

    function setUp() public {
        // Warp to a well-known baseline so all timestamps are predictable.
        vm.warp(BASE_TIME);

        // Mock constructor dependency.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, address(0));

        // Default mocks.
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

        // Default 721 hook mock: returns original weight and empty specs (0 tiers).
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), new JBPayHookSpecification[](0))
        );
    }

    // =========================================================================
    // GAP 1: Hook failure adversarial
    // =========================================================================

    // -------------------------------------------------------------------------
    // 1a: Pay-reverting hook propagates revert to caller
    // -------------------------------------------------------------------------
    function test_hookFailure_payRevertingHook_propagatesCustomError() public {
        PayRevertingHook revertingHook = new PayRevertingHook();
        _launchProjectWithHook(address(revertingHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        vm.expectRevert(PayRevertingHook.CustomPayError.selector);
        deployer.beforePayRecordedWith(ctx);
    }

    // -------------------------------------------------------------------------
    // 1b: CashOut-reverting hook propagates revert to non-sucker caller
    // -------------------------------------------------------------------------
    function test_hookFailure_cashOutRevertingHook_propagatesForNonSucker() public {
        CashOutRevertingHook revertingHook = new CashOutRevertingHook();
        _launchProjectWithHook(address(revertingHook), false, true);
        uint256 storedRulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, attacker);

        vm.expectRevert(CashOutRevertingHook.CustomCashOutError.selector);
        deployer.beforeCashOutRecordedWith(ctx);
    }

    // -------------------------------------------------------------------------
    // 1c: CashOut-reverting hook is bypassed by sucker (sucker gets 0 tax)
    // -------------------------------------------------------------------------
    function test_hookFailure_cashOutRevertingHook_bypassedBySucker() public {
        CashOutRevertingHook revertingHook = new CashOutRevertingHook();
        _launchProjectWithHook(address(revertingHook), false, true);
        uint256 storedRulesetId = block.timestamp;

        // Mark holder as a sucker.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, sucker);

        // Sucker gets early return -- never hits the reverting hook.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 0, "Sucker should get 0 tax even with reverting hook");
        assertEq(cashOutCount, ctx.cashOutCount, "Sucker cashOutCount should pass through");
        assertEq(totalSupply, ctx.totalSupply, "Sucker totalSupply should pass through");
    }

    // -------------------------------------------------------------------------
    // 1d: hasMintPermissionFor reverts when custom hook reverts
    // -------------------------------------------------------------------------
    function test_hookFailure_mintPermissionRevert_propagates() public {
        MintPermissionRevertingHook revertingHook = new MintPermissionRevertingHook();
        _launchProjectWithHook(address(revertingHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        JBRuleset memory ruleset;
        // forge-lint: disable-next-line(unsafe-typecast)
        ruleset.id = uint48(storedRulesetId);

        vm.expectRevert(MintPermissionRevertingHook.MintPermissionReverted.selector);
        deployer.hasMintPermissionFor(projectId, ruleset, attacker);
    }

    // -------------------------------------------------------------------------
    // 1e: Sucker bypasses hasMintPermissionFor revert (gets true before hook is called)
    // -------------------------------------------------------------------------
    function test_hookFailure_mintPermissionRevert_suckerBypass() public {
        MintPermissionRevertingHook revertingHook = new MintPermissionRevertingHook();
        _launchProjectWithHook(address(revertingHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        // Mark as sucker.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBRuleset memory ruleset;
        // forge-lint: disable-next-line(unsafe-typecast)
        ruleset.id = uint48(storedRulesetId);

        // Sucker returns true before reaching the reverting hook.
        assertTrue(
            deployer.hasMintPermissionFor(projectId, ruleset, sucker),
            "Sucker should get mint permission even with reverting hook"
        );
    }

    // -------------------------------------------------------------------------
    // 1f: Hook returning extreme cashout values (max tax, zero count, max supply)
    // -------------------------------------------------------------------------
    function test_hookFailure_extremeCashOutValues_passThrough() public {
        ExtremeCashOutHook extremeHook = new ExtremeCashOutHook();
        _launchProjectWithHook(address(extremeHook), false, true);
        uint256 storedRulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, type(uint256).max, "Should pass through max tax rate from hook");
        assertEq(cashOutCount, 0, "Should pass through 0 count from hook");
        assertEq(totalSupply, type(uint256).max, "Should pass through max supply from hook");
    }

    // -------------------------------------------------------------------------
    // 1g: Hook returning many pay specs -- all compose with 721 spec correctly
    // -------------------------------------------------------------------------
    function test_hookFailure_manySpecs_composeCorrectly() public {
        uint256 specCount = 10;
        ManySpecsHook manySpecsHook = new ManySpecsHook(specCount);
        _launchProjectWithHook(address(manySpecsHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(ctx);

        // 721 hook returns empty specs (0 tiers mock), so only user hook specs.
        assertEq(specs.length, specCount, "Should have all user hook specs");
        assertEq(weight, ctx.weight, "Weight should come from user hook (passthrough)");

        // Verify each spec address.
        for (uint256 i; i < specCount; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(address(specs[i].hook), address(uint160(200 + i)), "Spec address mismatch");
        }
    }

    // -------------------------------------------------------------------------
    // 1h: Hook returning weight=0 (AMM path) preserves zero weight
    // -------------------------------------------------------------------------
    function test_hookFailure_zeroWeightHook_preservesZeroWeight() public {
        ZeroWeightHook zeroHook = new ZeroWeightHook();
        _launchProjectWithHook(address(zeroHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, 0, "Zero weight from hook should be preserved (AMM path)");
    }

    // -------------------------------------------------------------------------
    // 1i: Pay-reverting hook does not affect cash out path (independent paths)
    // -------------------------------------------------------------------------
    function test_hookFailure_payRevertingHook_cashOutStillWorks() public {
        PayRevertingHook revertingHook = new PayRevertingHook();
        _launchProjectWithHook(address(revertingHook), true, false);
        uint256 storedRulesetId = block.timestamp;

        // Cash out should work since the hook only reverts for pay (useDataHookForCashOut = false).
        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, ctx.cashOutTaxRate, "Cash out should return original tax rate");
        assertEq(cashOutCount, ctx.cashOutCount, "Cash out should return original count");
        assertEq(totalSupply, ctx.totalSupply, "Cash out should return original supply");
    }

    // -------------------------------------------------------------------------
    // 1j: CashOut-reverting hook does not affect pay path (independent paths)
    // -------------------------------------------------------------------------
    function test_hookFailure_cashOutRevertingHook_payStillWorks() public {
        CashOutRevertingHook revertingHook = new CashOutRevertingHook();
        _launchProjectWithHook(address(revertingHook), false, true);
        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        // Pay should work since the hook returns context.weight for pay.
        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, ctx.weight, "Pay should return original weight despite cashout-reverting hook");
        assertEq(specs.length, 0, "No specs expected");
    }

    // =========================================================================
    // GAP 2: Rapid ruleset queueing
    // =========================================================================

    // -------------------------------------------------------------------------
    // 2a: Queueing rulesets in the same block as launch reverts
    // -------------------------------------------------------------------------
    function test_rapidQueue_revertsIfSameBlockAsLaunch() public {
        _launchProjectWithHook(address(0), false, false);

        // latestRulesetIdOf = BASE_TIME (from the launch).
        // block.timestamp = BASE_TIME.
        // Guard: BASE_TIME >= BASE_TIME -> true -> revert.
        _mockLatestRulesetId(BASE_TIME);

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, configs, "", controller);
    }

    // -------------------------------------------------------------------------
    // 2b: Queueing succeeds one second after launch
    // -------------------------------------------------------------------------
    function test_rapidQueue_succeedsOneSecondAfterLaunch() public {
        _launchProjectWithHook(address(0), false, false);

        // Warp forward by 1 second.
        vm.warp(BASE_TIME + 1);

        // latestRulesetIdOf still = BASE_TIME (from launch).
        // Guard: BASE_TIME >= BASE_TIME + 1 -> false -> passes.
        _mockLatestRulesetId(BASE_TIME);

        uint256 expectedQueuedId = BASE_TIME + 1;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(expectedQueuedId)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721;
        (uint256 rulesetId,) = deployer.queueRulesetsOf(projectId, empty721, configs, "", controller);
        assertEq(rulesetId, expectedQueuedId, "Should return queued ruleset ID");
    }

    // -------------------------------------------------------------------------
    // 2c: Two sequential queues with warp between them succeed
    // -------------------------------------------------------------------------
    function test_rapidQueue_twoSequentialQueuesSucceed() public {
        _launchProjectWithHook(address(0), false, false);

        // Warp forward 1 second for first queue.
        vm.warp(BASE_TIME + 1);
        _mockLatestRulesetId(BASE_TIME);

        uint256 firstQueueTime = BASE_TIME + 1;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(firstQueueTime)
        );

        JBRulesetConfig[] memory configs1 = new JBRulesetConfig[](1);
        configs1[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721a;
        (uint256 rulesetId1,) = deployer.queueRulesetsOf(projectId, empty721a, configs1, "", controller);
        assertEq(rulesetId1, firstQueueTime, "First queue should succeed");

        // Second queue in the same block reverts because latestRulesetIdOf = firstQueueTime = block.timestamp.
        _mockLatestRulesetId(firstQueueTime);

        JBRulesetConfig[] memory configs2 = new JBRulesetConfig[](1);
        configs2[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721b;
        deployer.queueRulesetsOf(projectId, empty721b, configs2, "", controller);

        // Warp forward 1 more second. Now block.timestamp = BASE_TIME + 2.
        vm.warp(BASE_TIME + 2);

        uint256 secondQueueTime = BASE_TIME + 2;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(secondQueueTime)
        );

        JBRulesetConfig[] memory configs3 = new JBRulesetConfig[](1);
        configs3[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721c;
        (uint256 rulesetId2,) = deployer.queueRulesetsOf(projectId, empty721c, configs3, "", controller);
        assertEq(rulesetId2, secondQueueTime, "Second queue should succeed after warp");
    }

    // -------------------------------------------------------------------------
    // 2d: Multi-ruleset launch makes same-block queue impossible
    // -------------------------------------------------------------------------
    function test_rapidQueue_multiRulesetLaunch_sameBlockQueueReverts() public {
        // Launch with 3 rulesets: latestRulesetIdOf = BASE_TIME + 2.
        JBRulesetConfig[] memory launchConfigs = new JBRulesetConfig[](3);
        for (uint256 i; i < 3; i++) {
            launchConfigs[i] = _makeRulesetConfig(address(0), false, false);
        }

        JBOmnichain721Config memory empty721Config;
        deployer.launchProjectFor(
            projectOwner,
            "test",
            empty721Config,
            launchConfigs,
            new JBTerminalConfig[](0),
            "",
            _emptySuckerConfig(),
            controller
        );

        // latestRulesetIdOf = BASE_TIME + 2, which is > BASE_TIME (= block.timestamp).
        _mockLatestRulesetId(BASE_TIME + 2);

        JBRulesetConfig[] memory queueConfigs = new JBRulesetConfig[](1);
        queueConfigs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, queueConfigs, "", controller);
    }

    // -------------------------------------------------------------------------
    // 2e: Multi-ruleset launch with queue after sufficient warp
    // -------------------------------------------------------------------------
    function test_rapidQueue_multiRulesetLaunch_succeedsAfterWarp() public {
        // Launch with 3 rulesets: latestRulesetIdOf = BASE_TIME + 2.
        JBRulesetConfig[] memory launchConfigs = new JBRulesetConfig[](3);
        for (uint256 i; i < 3; i++) {
            launchConfigs[i] = _makeRulesetConfig(address(0), false, false);
        }

        JBOmnichain721Config memory empty721Config;
        deployer.launchProjectFor(
            projectOwner,
            "test",
            empty721Config,
            launchConfigs,
            new JBTerminalConfig[](0),
            "",
            _emptySuckerConfig(),
            controller
        );

        uint256 latestRulesetId = BASE_TIME + 2;

        // Warp past the latestRulesetId: block.timestamp = BASE_TIME + 3.
        vm.warp(BASE_TIME + 3);
        _mockLatestRulesetId(latestRulesetId);

        uint256 expectedQueuedId = BASE_TIME + 3;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(expectedQueuedId)
        );

        JBRulesetConfig[] memory queueConfigs = new JBRulesetConfig[](1);
        queueConfigs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721;
        (uint256 rulesetId,) = deployer.queueRulesetsOf(projectId, empty721, queueConfigs, "", controller);
        assertEq(rulesetId, expectedQueuedId, "Queue should succeed after warping past multi-ruleset launch");
    }

    // -------------------------------------------------------------------------
    // 2f: Queue stores hooks at correct predicted ruleset IDs
    // -------------------------------------------------------------------------
    function test_rapidQueue_storesHooksAtCorrectPredictedIds() public {
        address customHookAddr = makeAddr("customHook");
        _launchProjectWithHook(address(0), false, false);

        // Warp forward.
        vm.warp(BASE_TIME + 100);
        _mockLatestRulesetId(BASE_TIME);

        uint256 expectedQueuedId = BASE_TIME + 100;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(expectedQueuedId)
        );

        // Queue 2 rulesets with a custom data hook.
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](2);
        configs[0] = _makeRulesetConfig(customHookAddr, true, false);
        configs[1] = _makeRulesetConfig(customHookAddr, true, true);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, configs, "", controller);

        // Verify hooks stored at BASE_TIME+100 and BASE_TIME+101.
        JBDeployerHookConfig memory hook0 = deployer.extraDataHookOf(projectId, BASE_TIME + 100);
        JBDeployerHookConfig memory hook1 = deployer.extraDataHookOf(projectId, BASE_TIME + 101);

        assertEq(address(hook0.dataHook), customHookAddr, "Hook 0 should be stored");
        assertTrue(hook0.useDataHookForPay, "Hook 0 useDataHookForPay should be true");
        assertFalse(hook0.useDataHookForCashOut, "Hook 0 useDataHookForCashOut should be false");

        assertEq(address(hook1.dataHook), customHookAddr, "Hook 1 should be stored");
        assertTrue(hook1.useDataHookForPay, "Hook 1 useDataHookForPay should be true");
        assertTrue(hook1.useDataHookForCashOut, "Hook 1 useDataHookForCashOut should be true");
    }

    // -------------------------------------------------------------------------
    // 2g: Queue carries forward existing 721 hook when no new tiers provided
    // -------------------------------------------------------------------------
    function test_rapidQueue_carriesForwardExisting721Hook() public {
        _launchProjectWithHook(address(0), false, false);

        // Warp forward.
        vm.warp(BASE_TIME + 50);
        _mockLatestRulesetId(BASE_TIME);

        uint256 expectedQueuedId = BASE_TIME + 50;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(expectedQueuedId)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        JBOmnichain721Config memory empty721;
        (uint256 rulesetId, IJB721TiersHook hook) =
            deployer.queueRulesetsOf(projectId, empty721, configs, "", controller);

        assertEq(rulesetId, expectedQueuedId, "Should return correct ruleset ID");
        assertEq(address(hook), hookAddr, "Should carry forward existing 721 hook");

        // Verify the 721 hook is stored for the new ruleset.
        (IJB721TiersHook stored721,) = deployer.tiered721HookOf(projectId, BASE_TIME + 50);
        assertEq(address(stored721), hookAddr, "721 hook should be stored for the queued ruleset");
    }

    // -------------------------------------------------------------------------
    // 2h: Queue with controller mismatch reverts
    // -------------------------------------------------------------------------
    function test_rapidQueue_controllerMismatch_reverts() public {
        _launchProjectWithHook(address(0), false, false);

        vm.warp(BASE_TIME + 10);

        // Mock a different controller for the project.
        IJBController wrongController = IJBController(makeAddr("wrongController"));
        IJBDirectory wrongDirectory = IJBDirectory(makeAddr("wrongDirectory"));

        vm.mockCall(
            address(wrongController),
            abi.encodeWithSelector(IJBController.DIRECTORY.selector),
            abi.encode(wrongDirectory)
        );
        // controllerOf returns a different address than wrongController.
        vm.mockCall(
            address(wrongDirectory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(IERC165(makeAddr("otherController")))
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector);
        JBOmnichain721Config memory empty721;
        deployer.queueRulesetsOf(projectId, empty721, configs, "", wrongController);
    }

    // -------------------------------------------------------------------------
    // 2i: Rapid queue with the simplified (no 721 config) overload
    // -------------------------------------------------------------------------
    function test_rapidQueue_simplifiedOverload_sameBlockReverts() public {
        _launchProjectWithHook(address(0), false, false);

        _mockLatestRulesetId(BASE_TIME);

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_RulesetIdsUnpredictable.selector);
        // Use the simplified overload (no deploy721Config parameter).
        deployer.queueRulesetsOf(projectId, configs, "", controller);
    }

    // -------------------------------------------------------------------------
    // 2j: Rapid queue simplified overload succeeds after warp
    // -------------------------------------------------------------------------
    function test_rapidQueue_simplifiedOverload_succeedsAfterWarp() public {
        _launchProjectWithHook(address(0), false, false);

        vm.warp(BASE_TIME + 10);
        _mockLatestRulesetId(BASE_TIME);

        uint256 expectedQueuedId = BASE_TIME + 10;
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(expectedQueuedId)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.prank(projectOwner);
        (uint256 rulesetId, IJB721TiersHook hook) = deployer.queueRulesetsOf(projectId, configs, "", controller);
        assertEq(rulesetId, expectedQueuedId, "Should return queued ruleset ID");
        assertEq(address(hook), hookAddr, "Should carry forward 721 hook");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _launchProjectWithHook(address hook, bool useForPay, bool useForCashOut) internal {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(hook, useForPay, useForCashOut);

        JBOmnichain721Config memory empty721Config;
        deployer.launchProjectFor(
            projectOwner,
            "test",
            empty721Config,
            configs,
            new JBTerminalConfig[](0),
            "",
            _emptySuckerConfig(),
            controller
        );
    }

    function _mockLatestRulesetId(uint256 latestRulesetId) internal {
        vm.mockCall(
            address(rulesetsContract),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, projectId),
            abi.encode(latestRulesetId)
        );
    }

    function _makePayContext(uint256 pid, uint256 rid) internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: attacker,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: pid,
            rulesetId: rid,
            beneficiary: attacker,
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
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function _makeRulesetConfig(
        address hook,
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
            dataHook: hook,
            metadata: 0
        });
        return config;
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
