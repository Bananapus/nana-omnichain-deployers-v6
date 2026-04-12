// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBApprovalStatus} from "@bananapus/core-v6/src/enums/JBApprovalStatus.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
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
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";

/// @notice Mock data hook that returns custom cashout values and grants mint permission.
contract CustomCashOutHook is IJBRulesetDataHook {
    uint256 public cashOutTaxRateReturn;
    uint256 public cashOutCountReturn;
    uint256 public totalSupplyReturn;
    bool public mintPermission;
    bool public shouldReturnCashOutHookSpecification;
    uint256 public cashOutHookAmountReturn;
    bytes public cashOutHookMetadataReturn;

    function setReturns(uint256 taxRate, uint256 count, uint256 supply) external {
        cashOutTaxRateReturn = taxRate;
        cashOutCountReturn = count;
        totalSupplyReturn = supply;
    }

    function setMintPermission(bool granted) external {
        mintPermission = granted;
    }

    function setCashOutHookSpecification(uint256 amount, bytes calldata metadata) external {
        shouldReturnCashOutHookSpecification = true;
        cashOutHookAmountReturn = amount;
        cashOutHookMetadataReturn = metadata;
    }

    function clearCashOutHookSpecification() external {
        shouldReturnCashOutHookSpecification = false;
        cashOutHookAmountReturn = 0;
        cashOutHookMetadataReturn = "";
    }

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
        view
        override
        returns (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        JBCashOutHookSpecification[] memory hookSpecifications;

        if (shouldReturnCashOutHookSpecification) {
            hookSpecifications = new JBCashOutHookSpecification[](1);
            hookSpecifications[0] = JBCashOutHookSpecification({
                hook: IJBCashOutHook(address(this)),
                noop: false,
                amount: cashOutHookAmountReturn,
                metadata: cashOutHookMetadataReturn
            });
        }

        return (cashOutTaxRateReturn, cashOutCountReturn, totalSupplyReturn, totalSupplyReturn, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external view override returns (bool) {
        return mintPermission;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @title OmnichainDeployerEdgeCases
/// @notice Mock-based unit tests for edge cases and error paths not covered by existing tests.
contract OmnichainDeployerEdgeCases is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    address projectOwner = makeAddr("projectOwner");
    address sucker = makeAddr("sucker");
    address attacker = makeAddr("attacker");
    address hookAddr = makeAddr("hook721");

    CustomCashOutHook customHook;

    uint256 projectId = 42;
    uint256 rulesetId;

    function setUp() public {
        customHook = new CustomCashOutHook();

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

        // Default: not a sucker.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Hook deployer mocks (every path now deploys a 721 hook).
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Default mock: 721 hook returns context weight and empty specs (0 tiers, no splits).
        // A real 721 hook with no tiers returns contextWeight unchanged.
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );
    }

    // =========================================================================
    // Error path: InvalidHook — setting dataHook to deployer itself
    // =========================================================================
    function test_setup_revert_InvalidHook() public {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(deployer), true, false);

        JBOmnichain721Config memory empty721Config;
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_InvalidHook.selector);
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

    // =========================================================================
    // Error path: ProjectIdMismatch — controller returns wrong project ID
    // =========================================================================
    function test_launch_revert_ProjectIdMismatch() public {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        // Controller returns project ID 99 instead of expected 42.
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchProjectFor.selector),
            abi.encode(uint256(99))
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        JBOmnichain721Config memory empty721Config;
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_ProjectIdMismatch.selector);
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

    // =========================================================================
    // Weight edge case: weight = 0 when totalSplitAmount >= context.amount.value
    // =========================================================================
    function test_beforePay_weightZero_whenProjectAmountZero() public {
        // Launch project with no custom hook.
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        // Mock a 721 hook that returns a spec whose amount equals the full payment.
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), noop: false, amount: 1 ether, metadata: ""});

        // 721 hook returns weight=0 when splits consume the entire payment.
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), specs)
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.amount.value = 1 ether;
        ctx.weight = 1000;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, 0, "Weight should be 0 when full amount goes to splits");
    }

    // =========================================================================
    // Weight edge case: weight preserved when no splits and no hooks
    // =========================================================================
    function test_beforePay_weightPreserved_whenNoSplits() public {
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        // Override the default 721 mock: with no splits, 721 hook returns contextWeight (12345) and empty specs.
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(12_345), new JBPayHookSpecification[](0))
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.weight = 12_345;

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, 12_345, "Weight should be preserved with no hooks");
        assertEq(specs.length, 0, "No specs expected");
    }

    // =========================================================================
    // Weight edge case: large weight near max — verify no overflow in mulDiv
    // =========================================================================
    function test_beforePay_largeWeight_customHookPassthrough() public {
        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        // Custom hook returns near-max weight.
        vm.mockCall(
            address(customHook),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(type(uint256).max, new JBPayHookSpecification[](0))
        );

        // Mock a 721 hook that takes 50% as splits (returns weight=500, scaled for 50% splits).
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        JBPayHookSpecification[] memory specs721 = new JBPayHookSpecification[](1);
        specs721[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), noop: false, amount: 0.5 ether, metadata: ""});

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(500), specs721)
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.amount.value = 1 ether;
        ctx.weight = 1000;

        // The custom hook's weight is used directly (no mulDiv scaling).
        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, type(uint256).max, "custom hook's large weight should pass through directly");
    }

    // =========================================================================
    // Cashout edge case: no hooks returns original values
    // =========================================================================
    function test_beforeCashOut_noHooks_returnsOriginalValues() public {
        // Launch with no custom hook.
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount");
        assertEq(totalSupply, 10_000, "Should return original totalSupply");
    }

    // =========================================================================
    // Cashout edge case: custom hook only (no 721) forwards correctly
    // =========================================================================
    function test_beforeCashOut_customHookOnly_forwardsCorrectly() public {
        customHook.setReturns(2000, 500, 8000);

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 2000, "Should return custom hook tax rate");
        assertEq(cashOutCount, 500, "Should return custom hook cashOutCount");
        assertEq(totalSupply, 8000, "Should return custom hook totalSupply");
    }

    // =========================================================================
    // Cashout edge case: sucker bypasses 721 hook entirely
    // =========================================================================
    function test_beforeCashOut_suckerPriority_overrides721() public {
        // Launch with custom hook.
        customHook.setReturns(9000, 999, 999);

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        // Store a 721 hook too.
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        // Mark as sucker.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, sucker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 0, "Sucker should get 0 tax regardless of hooks");
        assertEq(cashOutCount, 1000, "Sucker should get original cashOutCount");
        assertEq(totalSupply, 10_000, "Sucker should get original totalSupply");
    }

    // =========================================================================
    // Cashout edge case: 721 hook skipped when useDataHookForCashOut is false
    // =========================================================================
    function test_beforeCashOut_721HookSkipped_whenFlagFalse() public {
        // Launch with useDataHookForCashOut = false (pay-only hook).
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        // Store a 721 hook with useDataHookForCashOut = false.
        address mock721 = makeAddr("mock721ForCashOut");
        _storeTiered721Hook(mock721, false);

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(9999), uint256(1), uint256(1), uint256(1), new JBCashOutHookSpecification[](0))
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is false, the 721 hook should NOT be called.
        // Original values should be returned.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate, not 721 hook's 9999");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount, not 721 hook's 1");
        assertEq(totalSupply, 10_000, "Should return original totalSupply, not 721 hook's 1");
    }

    // =========================================================================
    // Cashout edge case: custom hook called when useDataHookForCashOut is true
    // =========================================================================
    function test_beforeCashOut_customHookCalled_whenFlagTrue() public {
        // Custom hook with useDataHookForCashOut = true handles cashouts.
        customHook.setReturns(9999, 1, 1);

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is true, the custom hook SHOULD be called.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 9999, "Should return custom hook's tax rate");
        assertEq(cashOutCount, 1, "Should return custom hook's cashOutCount");
        assertEq(totalSupply, 1, "Should return custom hook's totalSupply");
    }

    function test_beforeCashOut_merges721AndCustomHookSpecifications() public {
        customHook.setReturns(2000, 500, 8000);
        customHook.setCashOutHookSpecification(22, abi.encode(uint256(2)));

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        address mock721 = makeAddr("mock721CashOutMerge");
        _storeTiered721Hook(mock721, true);

        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(mock721), noop: false, amount: 11, metadata: abi.encode(uint256(1))
        });

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(4000), uint256(700), uint256(9000), uint256(9000), specs)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            ,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(cashOutTaxRate, 2000, "Custom hook should receive and override 721-adjusted tax rate");
        assertEq(cashOutCount, 500, "Custom hook should receive and override 721-adjusted cashOutCount");
        assertEq(totalSupply, 8000, "Custom hook should receive and override 721-adjusted totalSupply");
        assertEq(hookSpecifications.length, 2, "721 and custom cash out specs should both be returned");
        assertEq(address(hookSpecifications[0].hook), mock721, "721 hook spec should come first");
        assertEq(hookSpecifications[0].amount, 11, "721 hook spec amount should be preserved");
        assertEq(hookSpecifications[0].metadata, abi.encode(uint256(1)), "721 hook metadata should be preserved");
        assertEq(address(hookSpecifications[1].hook), address(customHook), "Custom hook spec should come second");
        assertEq(hookSpecifications[1].amount, 22, "Custom hook spec amount should be preserved");
        assertEq(hookSpecifications[1].metadata, abi.encode(uint256(2)), "Custom hook metadata should be preserved");
    }

    // =========================================================================
    // Cashout edge case: custom hook skipped when useDataHookForCashOut is false
    // =========================================================================
    function test_beforeCashOut_customHookSkipped_whenFlagFalse() public {
        // Launch with useDataHookForCashOut = false but a custom hook set.
        customHook.setReturns(2000, 1, 1);
        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is false, the custom hook should NOT be called.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate, not custom hook's 2000");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount, not custom hook's 1");
        assertEq(totalSupply, 10_000, "Should return original totalSupply, not custom hook's 1");
    }

    // =========================================================================
    // Cashout edge case: flag true, no hooks set, returns original values
    // =========================================================================
    function test_beforeCashOut_flagTrue_noHooks_returnsOriginal() public {
        // Launch with useDataHookForCashOut = true but no custom hook and no 721 hook.
        _launchProjectWithCustomCashOutHook(address(0));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // No 721 hook, no custom hook — should fall through to original values.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount");
        assertEq(totalSupply, 10_000, "Should return original totalSupply");
    }

    // =========================================================================
    // Mint permission: custom hook grants
    // =========================================================================
    function test_hasMintPermission_customHookGrants() public {
        customHook.setMintPermission(true);

        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        JBRuleset memory ruleset;
        // forge-lint: disable-next-line(unsafe-typecast)
        ruleset.id = uint48(rulesetId);

        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, attacker), "Custom hook should grant mint");
    }

    // =========================================================================
    // Mint permission: custom hook denies but sucker overrides
    // =========================================================================
    function test_hasMintPermission_customHookDenies_suckerOverrides() public {
        customHook.setMintPermission(false);

        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBRuleset memory ruleset;
        // forge-lint: disable-next-line(unsafe-typecast)
        ruleset.id = uint48(rulesetId);

        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, sucker), "Sucker should override custom hook deny");
    }

    // =========================================================================
    // Mint permission: no hook returns false
    // =========================================================================
    function test_hasMintPermission_noHook_returnsFalse() public {
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        JBRuleset memory ruleset;
        // forge-lint: disable-next-line(unsafe-typecast)
        ruleset.id = uint48(rulesetId);

        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, attacker), "No hook should return false");
    }

    // =========================================================================
    // Permission: launchRulesetsFor requires LAUNCH_RULESETS (not QUEUE_RULESETS)
    // =========================================================================
    function test_launchRulesetsFor_requiresLaunchRulesetsPermission() public {
        IJBController controller = IJBController(makeAddr("controller"));
        IJBDirectory directory = IJBDirectory(makeAddr("directory"));

        // Mock controller validation chain.
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(address(controller))
        );

        // Deny ALL permissions — this ensures the first permission check (LAUNCH_RULESETS) fails.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), true, false);

        JBOmnichain721Config memory empty721Config;
        vm.prank(projectOwner);
        vm.expectRevert();
        deployer.launchRulesetsFor(projectId, empty721Config, configs, new JBTerminalConfig[](0), "", controller);
    }

    // =========================================================================
    // Error path: InvalidHook — queueRulesetsOf with no tiers and no prior hook
    // =========================================================================
    function test_queueRulesetsOf_revert_InvalidHook_noTiersNoPriorHook() public {
        // First launch a project (so it exists).
        _launchProjectWithHook(address(0));

        IJBController controller = IJBController(makeAddr("controller"));
        IJBDirectory directory = IJBDirectory(makeAddr("directory"));
        IJBRulesets rulesets = IJBRulesets(makeAddr("rulesets"));

        // Mock controller validation chain.
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(address(controller))
        );

        // Warp forward so block.timestamp > latestRulesetId (avoids RulesetIdsUnpredictable).
        vm.warp(100);

        // Mock latestRulesetIdOf to return a past timestamp.
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesets));
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, projectId),
            abi.encode(uint256(50)) // A past ruleset ID — no hook stored at this ID
        );

        // Mock latestQueuedOf to return a ruleset with id=50 (no hook stored for this id via the deployer).
        // The carry-forward logic checks latestQueuedOf first; since no hook was stored at id=50,
        // it falls through to currentOf.
        JBRuleset memory latestQueuedRuleset;
        latestQueuedRuleset.id = uint48(50);
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestQueuedOf.selector, projectId),
            abi.encode(latestQueuedRuleset, JBApprovalStatus.Empty)
        );

        // Mock currentOf to return a ruleset with id=50 (no hook stored for this id via the deployer).
        JBRuleset memory currentRuleset;
        currentRuleset.id = uint48(50);
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.currentOf.selector, projectId),
            abi.encode(currentRuleset)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), true, false);

        // Empty 721 config — no tiers, so it tries to carry forward an existing hook.
        // But no hook was stored for rulesetId=50 via this deployer.
        JBOmnichain721Config memory empty721Config;
        vm.prank(projectOwner);
        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_InvalidHook.selector);
        deployer.queueRulesetsOf(projectId, empty721Config, configs, "", controller);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _launchProjectWithHook(address hook) internal {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(hook, true, false);

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

    function _launchProjectWithCustomCashOutHook(address hook) internal {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(hook, false, true);

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

    function _storeTiered721Hook(address hook721) internal {
        _storeTiered721Hook(hook721, true);
    }

    function _storeTiered721Hook(address hook721, bool useCashOut) internal {
        // Use vm.store to set _tiered721HookOf[projectId][rulesetId] = JBTiered721HookConfig(hook, useCashOut).
        // _tiered721HookOf is at base slot 1 (second storage variable, after _extraDataHookOf).
        // For mapping(uint256 => mapping(uint256 => struct)):
        //   slot = keccak256(rulesetId . keccak256(projectId . 1))
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(1)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        // Pack: address (160 bits) | bool (1 bit at position 160)
        bytes32 value = bytes32(uint256(uint160(hook721)) | (useCashOut ? uint256(1) << 160 : 0));
        vm.store(address(deployer), innerSlot, value);
        (IJB721TiersHook storedHook,) = deployer.tiered721HookOf(projectId, rulesetId);
        assertEq(address(storedHook), hook721, "721 hook should be stored");
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
