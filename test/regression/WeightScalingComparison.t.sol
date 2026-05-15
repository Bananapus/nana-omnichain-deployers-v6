// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
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

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

/// @title WeightScalingComparisonTest
/// @notice Verifies the omnichain deployer uses the 721 hook's weight directly
///         (already split-adjusted) instead of re-scaling with mulDiv.
contract WeightScalingComparisonTest is Test {
    // The deployer under test.
    JBOmnichainDeployer deployer;

    // Mock addresses for external dependencies.
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    // Test actors and addresses.
    address projectOwner = makeAddr("projectOwner");
    address hookAddr = makeAddr("hook721");

    // Project and ruleset identifiers.
    uint256 projectId = 42;
    uint256 rulesetId;

    function setUp() public {
        // Mock permissions.setPermissionsFor (called in constructor).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        // Deploy the omnichain deployer with mock dependencies.
        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, directory, address(0));

        // Mock project ownership for permission checks.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        // Mock hasPermission to always return true for simplicity.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Default: no address is a sucker.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Default: no remote supply or surplus (non-omnichain project).
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector),
            abi.encode(uint256(0))
        );

        // Mock hook deployer to return our mock hook address.
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        // Mock transferOwnershipToProject on the hook.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Default mock: 721 hook returns context weight and empty specs (no splits).
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );

        // Launch the project so hook configs are stored.
        _launchProject(address(0));
        // The first ruleset ID is block.timestamp.
        rulesetId = block.timestamp;
    }

    // =========================================================================
    // Test: 721 hook's split-adjusted weight is used directly, not re-scaled
    // =========================================================================
    // Scenario: 721 hook returns a weight that already accounts for 50% split
    // deductions (e.g., weight=500 from original 1000). The deployer should use
    // 500 directly, NOT re-compute weight * projectAmount / totalAmount.
    function test_721HookWeightUsedDirectly_notReScaled() public {
        // Create a mock 721 hook that simulates split-adjusted weight.
        address mock721 = makeAddr("mock721WithSplits");
        // Store the mock 721 hook for this project's ruleset.
        _storeTiered721Hook(mock721);

        // Configure the 721 hook to return:
        // - weight = 500 (split-adjusted: original 1000 cut in half by 50% splits)
        // - specs with 0.5 ether split amount (50% of 1 ether payment)
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        // The spec claims 0.5 ether for tier splits.
        specs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), noop: false, amount: 0.5 ether, metadata: ""});

        // Mock the 721 hook to return weight=500 (already adjusted for splits).
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(500), specs)
        );

        // Build a pay context with 1 ether payment and context weight 1000.
        JBBeforePayRecordedContext memory ctx = _makePayContext();
        // Set context weight to 1000 (the base weight before splits).
        ctx.weight = 1000;
        // Set payment amount to 1 ether.
        ctx.amount.value = 1 ether;

        // Call beforePayRecordedWith on the deployer.
        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // The deployer should use the 721 hook's weight (500) directly.
        // If it re-scaled with mulDiv, it would compute: 500 * 0.5e18 / 1e18 = 250.
        // The correct behavior is weight = 500 (no re-scaling).
        assertEq(weight, 500, "Weight should be 500 (721 hook's split-adjusted weight used directly)");

        // No need to check weight != 250 — assertEq(weight, 500) above already proves it.
    }

    // =========================================================================
    // Test: Context weight returned when 721 hook has no splits
    // =========================================================================
    // When the 721 hook returns the context weight unchanged (no splits),
    // the deployer should pass it through directly.
    function test_721HookWeightPassthrough_noSplits() public {
        // Create a mock 721 hook with no split deductions.
        address mock721 = makeAddr("mock721NoSplits");
        // Store the mock 721 hook for this project's ruleset.
        _storeTiered721Hook(mock721);

        // Mock the 721 hook to return weight=7777 and no specs (no splits).
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(7777), new JBPayHookSpecification[](0))
        );

        // Build a pay context with weight 7777.
        JBBeforePayRecordedContext memory ctx = _makePayContext();
        // Set context weight to 7777.
        ctx.weight = 7777;

        // Call beforePayRecordedWith on the deployer.
        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // The deployer should return the 721 hook's weight directly.
        assertEq(weight, 7777, "Weight should be 7777 (passed through from 721 hook)");
    }

    // =========================================================================
    // Test: Custom hook weight is scaled by 721 split ratio
    // =========================================================================
    // When both a 721 hook and a custom hook are configured, the custom hook's
    // returned weight is scaled by the 721 split ratio so the terminal doesn't
    // over-mint tokens relative to the funds entering the project.
    function test_customHookWeightScaledBy721SplitRatio() public {
        // First re-launch with a custom hook configured.
        _launchProject(makeAddr("customHook"));
        // Update rulesetId after re-launch.
        rulesetId = block.timestamp;

        // Create a mock 721 hook with split-adjusted weight.
        address mock721 = makeAddr("mock721ForCustom");
        // Store the mock 721 hook for this project's ruleset.
        _storeTiered721Hook(mock721);

        // 721 hook returns weight=600 and 0.4 ether split.
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        // The spec claims 0.4 ether for tier splits.
        specs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), noop: false, amount: 0.4 ether, metadata: ""});

        // Mock the 721 hook: weight=600 (split-adjusted), specs with 0.4 ether split.
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(600), specs)
        );

        // The custom hook receives context.weight = 1000 (the original, not 721's) and
        // returns it unchanged (mint path behavior).
        vm.mockCall(
            makeAddr("customHook"),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );

        // Build a pay context with 1 ether and weight 1000.
        JBBeforePayRecordedContext memory ctx = _makePayContext();
        // Set context weight to 1000 (base weight).
        ctx.weight = 1000;
        // Set payment amount to 1 ether.
        ctx.amount.value = 1 ether;

        // Call beforePayRecordedWith on the deployer.
        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // The custom hook returned 1000, scaled by 721 split ratio 600/1000 = 600.
        assertEq(weight, 600, "Custom hook weight scaled by 721 split ratio");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Launches a project through the deployer with an optional custom hook.
    function _launchProject(address customHook) internal {
        // Mock external calls needed for project launch.
        IJBController controller = IJBController(makeAddr("controller"));
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(IJBProjects.createFor.selector, address(deployer)),
            abi.encode(projectId)
        );
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchRulesetsFor.selector),
            abi.encode(uint256(block.timestamp))
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(bytes4(keccak256("setUriOf(uint256,string)"))), abi.encode()
        );
        // Mock project NFT transfer.
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256)"))),
            abi.encode()
        );

        // Build ruleset config with optional custom hook for pay.
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(customHook, customHook != address(0), false);

        // Launch with empty 721 config (deployer still creates a hook).
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

    /// @dev Stores a mock 721 hook in the deployer's storage via vm.store.
    function _storeTiered721Hook(address hook721) internal {
        // _tiered721HookOf is at base slot 1 (second storage variable).
        // Mapping layout: keccak256(rulesetId . keccak256(projectId . 1))
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(1)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        // Pack: address (160 bits) | useDataHookForCashOut bool (1 bit at position 160).
        bytes32 value = bytes32(uint256(uint160(hook721)) | (uint256(1) << 160));
        // Write to deployer's storage.
        vm.store(address(deployer), innerSlot, value);
        // Verify the hook was stored correctly.
        (IJB721TiersHook storedHook,) = deployer.tiered721HookOf(projectId, rulesetId);
        assertEq(address(storedHook), hook721, "721 hook should be stored correctly");
    }

    /// @dev Creates a standard pay context for testing.
    function _makePayContext() internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: makeAddr("payer"),
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: projectId,
            rulesetId: rulesetId,
            beneficiary: makeAddr("beneficiary"),
            weight: 1000,
            reservedPercent: 0,
            metadata: ""
        });
    }

    /// @dev Creates a ruleset config with optional data hook.
    function _makeRulesetConfig(
        address hook,
        bool useForPay,
        bool useForCashOut
    )
        internal
        pure
        returns (JBRulesetConfig memory)
    {
        // Build a minimal ruleset config.
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
            scopeCashOutsToLocalBalances: true,
            pauseCrossProjectFeeFreeInflows: false,
            useDataHookForPay: useForPay,
            useDataHookForCashOut: useForCashOut,
            dataHook: hook,
            metadata: 0
        });
        return config;
    }

    /// @dev Returns an empty sucker deployment config (no suckers).
    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        // salt = 0 means skip sucker deployment.
        config.salt = bytes32(0);
    }
}
