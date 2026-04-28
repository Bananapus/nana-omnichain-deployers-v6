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

/// @title SplitCreditWeightTest
/// @notice Tests the splitCreditWeight decode + fallback logic in JBOmnichainDeployer.beforePayRecordedWith
///         (lines 545-583). Covers the scenario where issueTokensForSplits=true and a buyback hook
///         returns weight=0, requiring the split credit weight to preserve minting for split beneficiaries.
contract SplitCreditWeightTest is Test {
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
        // Mock hasPermission to always return true.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Default: no address is a sucker.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Default: no remote supply or surplus.
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

        // Default mock: 721 hook returns context weight and empty specs.
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );

        // Launch the project so hook configs are stored (with a custom extra hook for pay).
        _launchProject(makeAddr("buybackHook"));
        rulesetId = block.timestamp;
    }

    // =========================================================================
    // Test 1: Buyback returns weight=0 → splitCreditWeight fallback fires
    // =========================================================================
    /// @notice When the extra hook (buyback) returns weight=0 but splitCreditWeight > 0 in the 721
    ///         hook's metadata, the deployer falls back to splitCreditWeight (lines 581-582).
    function test_buybackReturnsZero_fallbackToSplitCreditWeight() public {
        address mock721 = makeAddr("mock721_splitCredit");
        address buyback = makeAddr("buybackHook");

        // Store the 721 hook for this project's ruleset.
        _storeTiered721Hook(mock721);

        // 721 hook returns weight == context.weight (issueTokensForSplits=true behavior)
        // with a spec whose metadata encodes splitCreditWeight=300.
        uint256 contextWeight = 1000;
        uint256 splitCredit = 300;
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(mock721),
            noop: false,
            amount: 0.5 ether,
            metadata: abi.encode(address(0), address(0), bytes(""), splitCredit)
        });

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(contextWeight, specs)
        );

        // Buyback hook returns weight=0 (no profitable swap found).
        vm.mockCall(
            buyback,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), new JBPayHookSpecification[](0))
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext();
        ctx.weight = contextWeight;
        ctx.amount.value = 1 ether;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        assertEq(weight, splitCredit, "Should fall back to splitCreditWeight when buyback returns 0");
    }

    // =========================================================================
    // Test 2: Buyback returns non-zero → no fallback, use buyback weight
    // =========================================================================
    /// @notice When the extra hook returns a non-zero weight, the splitCreditWeight fallback
    ///         does not fire (line 581 condition is false).
    function test_buybackReturnsNonZero_noFallback() public {
        address mock721 = makeAddr("mock721_noFallback");
        address buyback = makeAddr("buybackHook");

        _storeTiered721Hook(mock721);

        uint256 contextWeight = 1000;
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(mock721),
            noop: false,
            amount: 0.5 ether,
            metadata: abi.encode(address(0), address(0), bytes(""), uint256(300))
        });

        // 721 hook returns context weight (issueTokensForSplits=true).
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(contextWeight, specs)
        );

        // Buyback returns weight=800 (profitable swap found).
        vm.mockCall(
            buyback,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(800), new JBPayHookSpecification[](0))
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext();
        ctx.weight = contextWeight;
        ctx.amount.value = 1 ether;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // tiered721Weight == context.weight → no mulDiv scaling → weight stays 800.
        assertEq(weight, 800, "Should use buyback weight directly when non-zero");
    }

    // =========================================================================
    // Test 3: No extra hook → 721 weight used directly
    // =========================================================================
    /// @notice When no extra hook is configured, the 721 hook's weight is used directly (line 589).
    function test_noExtraHook_721WeightDirect() public {
        // Clear the extra hook stored during setUp by zeroing its storage slot.
        _clearExtraDataHook();

        address mock721 = makeAddr("mock721_directWeight");
        _storeTiered721Hook(mock721);

        uint256 contextWeight = 1000;
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(mock721),
            noop: false,
            amount: 0.3 ether,
            metadata: abi.encode(address(0), address(0), bytes(""), uint256(300))
        });

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(contextWeight, specs)
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext();
        ctx.weight = contextWeight;
        ctx.amount.value = 1 ether;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        assertEq(weight, contextWeight, "Should use 721 hook weight directly when no extra hook");
    }

    // =========================================================================
    // Test 4: Short metadata → decode skipped, splitCreditWeight stays 0
    // =========================================================================
    /// @notice When the 721 hook's spec metadata is shorter than 128 bytes, the splitCreditWeight
    ///         decode is skipped (line 545 guard). If buyback returns 0, weight stays 0.
    function test_shortMetadata_decodeSkipped() public {
        address mock721 = makeAddr("mock721_shortMeta");
        address buyback = makeAddr("buybackHook");

        _storeTiered721Hook(mock721);

        uint256 contextWeight = 700;
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        // Short metadata (32 bytes < 128): splitCreditWeight decode will be skipped.
        specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(mock721), noop: false, amount: 0.3 ether, metadata: abi.encode(uint256(42))
        });

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(contextWeight, specs)
        );

        // Buyback returns weight=0.
        vm.mockCall(
            buyback,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), new JBPayHookSpecification[](0))
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext();
        ctx.weight = contextWeight;
        ctx.amount.value = 1 ether;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // splitCreditWeight = 0 (decode skipped), buyback returned 0 → no fallback → weight = 0.
        assertEq(weight, 0, "Weight should be 0 when metadata too short for splitCreditWeight decode");
    }

    // =========================================================================
    // Test 5: splitCreditWeight=0 → no fallback even when buyback returns 0
    // =========================================================================
    /// @notice When splitCreditWeight is explicitly 0 in metadata, the fallback condition
    ///         (line 581) is false even when buyback returns weight=0.
    function test_splitCreditWeightZero_noFallback() public {
        address mock721 = makeAddr("mock721_zeroCredit");
        address buyback = makeAddr("buybackHook");

        _storeTiered721Hook(mock721);

        uint256 contextWeight = 700;
        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        // Metadata encodes splitCreditWeight=0.
        specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(mock721),
            noop: false,
            amount: 0.3 ether,
            metadata: abi.encode(address(0), address(0), bytes(""), uint256(0))
        });

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(contextWeight, specs)
        );

        // Buyback returns weight=0.
        vm.mockCall(
            buyback,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), new JBPayHookSpecification[](0))
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext();
        ctx.weight = contextWeight;
        ctx.amount.value = 1 ether;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);

        // splitCreditWeight=0 → fallback condition false → weight stays 0.
        assertEq(weight, 0, "Weight should be 0 when splitCreditWeight is explicitly 0");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Launches a project through the deployer with an optional custom hook.
    function _launchProject(address customHook) internal {
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
        // Mock safeTransferFrom for project NFT.
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(customHook, customHook != address(0), false);

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

    /// @dev Clears the extra data hook from storage (slot 0: _extraDataHookOf).
    function _clearExtraDataHook() internal {
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(0)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        vm.store(address(deployer), innerSlot, bytes32(0));
    }

    /// @dev Stores a mock 721 hook in the deployer's storage via vm.store.
    ///      _tiered721HookOf is at storage slot 1 (second mapping after _extraDataHookOf at slot 0).
    function _storeTiered721Hook(address hook721) internal {
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(1)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        // Pack: address (160 bits) | useDataHookForCashOut (1 byte at bit 160).
        bytes32 value = bytes32(uint256(uint160(hook721)) | (uint256(1) << 160));
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

    /// @dev Returns an empty sucker deployment config.
    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
