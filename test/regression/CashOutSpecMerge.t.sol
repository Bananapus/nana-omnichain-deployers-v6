// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
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

/// @title CashOutSpecMergeTest
/// @notice Tests the cashout hook specification merge logic in JBOmnichainDeployer.beforeCashOutRecordedWith
///         Verifies that NFT cash-outs return only 721 hook specs, while non-NFT cash-outs still use extra hook specs.
contract CashOutSpecMergeTest is Test {
    JBOmnichainDeployer deployer;

    // Mock addresses for external dependencies.
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBController canonicalController = IJBController(makeAddr("controller"));

    address projectOwner = makeAddr("projectOwner");
    address hookAddr = makeAddr("hook721");

    uint256 projectId = 42;
    uint256 rulesetId;

    // Distinct mock hook addresses for identification in specs.
    address mock721 = makeAddr("mock721_cashout");
    address extraHookAddr = makeAddr("extraCashoutHook");

    function setUp() public {
        // Mock permissions.setPermissionsFor (called in constructor).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(
            address(canonicalController), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects)
        );
        vm.mockCall(
            address(canonicalController),
            abi.encodeWithSelector(IJBController.DIRECTORY.selector),
            abi.encode(directory)
        );

        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, canonicalController, address(0));

        // Mock project ownership.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Default: no address is a sucker (avoid early return at line 408).
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
            abi.encodeWithSelector(IJBSuckerRegistry.totalRemoteSurplusOf.selector),
            abi.encode(uint256(0))
        );

        // Mock hook deployer.
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Default 721 hook mock (pay path — needed for launch).
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), new JBPayHookSpecification[](0))
        );

        // Launch project with extra hook configured for cashout.
        _launchProject(extraHookAddr);
        rulesetId = block.timestamp;
    }

    // =========================================================================
    // Test 1: NFT cash-outs return only 721 specs.
    // =========================================================================
    /// @notice When the 721 hook handles cash-out pricing, the deployer does not compose
    ///         generic extra cash-out hook specs.
    function test_721CashOutReturnsOnly721Specs() public {
        // Store 721 hook with useDataHookForCashOut=true.
        _storeTiered721Hook(mock721, true);
        // Store extra hook with useDataHookForCashOut=true.
        _storeExtraDataHook(extraHookAddr, false, true);

        // 721 hook returns: taxRate=5000, cashOutCount=100, totalSupply=1000, surplus=10 ether, 1 spec.
        JBCashOutHookSpecification[] memory specs721 = new JBCashOutHookSpecification[](1);
        specs721[0] =
            JBCashOutHookSpecification({hook: IJBCashOutHook(mock721), noop: false, amount: 0.3 ether, metadata: ""});

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(5000), uint256(100), uint256(1000), uint256(10 ether), specs721)
        );

        vm.mockCallRevert(
            extraHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            bytes("extra hook must not be called")
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext();
        ctx.cashOutCount = 0;

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory merged
        ) = deployer.beforeCashOutRecordedWith(ctx);

        // Spec assertions.
        assertEq(merged.length, 1, "only the 721 hook spec should be returned");
        assertEq(address(merged[0].hook), mock721, "First spec should be from 721 hook");

        // 721 hook's cash-out semantics must be preserved.
        // NFT cash-outs use local-only denominators so holders reclaim against local surplus.
        assertEq(totalSupply, 1000, "totalSupply should be 721 hook's value");
        assertEq(effectiveSurplusValue, 10 ether, "surplus should be 721 hook's value");

        assertEq(cashOutCount, 100, "cashOutCount should be 721 hook's value");

        assertEq(cashOutTaxRate, 5000, "cashOutTaxRate should be 721 hook's value");
    }

    // =========================================================================
    // Test 2: Only 721 returns specs → 721's array used directly
    // =========================================================================
    /// @notice When only the 721 hook returns specs, its array is used directly (line 491).
    function test_only721ReturnsSpecs() public {
        _storeTiered721Hook(mock721, true);
        _storeExtraDataHook(extraHookAddr, false, true);

        // 721 hook returns 1 spec.
        JBCashOutHookSpecification[] memory specs721 = new JBCashOutHookSpecification[](1);
        specs721[0] =
            JBCashOutHookSpecification({hook: IJBCashOutHook(mock721), noop: false, amount: 0.3 ether, metadata: ""});

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(5000), uint256(100), uint256(1000), uint256(10 ether), specs721)
        );

        // Extra hook is skipped for NFT cash-outs.
        vm.mockCallRevert(
            extraHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            bytes("extra hook must not be called")
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext();
        ctx.cashOutCount = 0;

        (,,,, JBCashOutHookSpecification[] memory result) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(result.length, 1, "Should have 1 spec from 721 hook only");
        assertEq(address(result[0].hook), mock721, "Spec should be from 721 hook");
    }

    // =========================================================================
    // Test 3: Only extra hook returns specs → extra's array used
    // =========================================================================
    /// @notice When only the extra hook returns specs, its array is used directly (line 494).
    function test_onlyExtraReturnsSpecs() public {
        _storeTiered721Hook(mock721, false);
        _storeExtraDataHook(extraHookAddr, false, true);

        // Extra hook returns 2 specs.
        JBCashOutHookSpecification[] memory specsExtra = new JBCashOutHookSpecification[](2);
        specsExtra[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(makeAddr("onlyExtra1")), noop: false, amount: 0.15 ether, metadata: ""
        });
        specsExtra[1] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(makeAddr("onlyExtra2")), noop: false, amount: 0.25 ether, metadata: ""
        });

        vm.mockCall(
            extraHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(4000), uint256(80), uint256(900), uint256(9 ether), specsExtra)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext();

        (,,,, JBCashOutHookSpecification[] memory result) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(result.length, 2, "Should have 2 specs from extra hook only");
        assertEq(address(result[0].hook), makeAddr("onlyExtra1"), "First spec from extra hook");
        assertEq(address(result[1].hook), makeAddr("onlyExtra2"), "Second spec from extra hook");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Launches a project with an optional extra hook for cashout.
    function _launchProject(address extraHook) internal {
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
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(controller)
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(bytes4(keccak256("setUriOf(uint256,string)"))), abi.encode()
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(extraHook, false, extraHook != address(0));

        JBOmnichain721Config memory empty721Config;
        deployer.launchProjectFor(
            projectOwner, "test", empty721Config, configs, new JBTerminalConfig[](0), "", _emptySuckerConfig()
        );
    }

    /// @dev Stores a mock 721 hook at storage slot 1 (_tiered721HookOf).
    function _storeTiered721Hook(address hook721, bool useForCashOut) internal {
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(1)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        bytes32 value = bytes32(uint256(uint160(hook721)) | (useForCashOut ? uint256(1) << 160 : uint256(0)));
        vm.store(address(deployer), innerSlot, value);
    }

    /// @dev Stores a mock extra data hook at storage slot 0 (_extraDataHookOf).
    ///      Packing: dataHook(160 bits) | useDataHookForPay(byte at 160) | useDataHookForCashOut(byte at 168).
    function _storeExtraDataHook(address hook, bool useForPay, bool useForCashOut) internal {
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(0)));
        bytes32 innerSlot = keccak256(abi.encode(rulesetId, outerSlot));
        bytes32 value = bytes32(
            uint256(uint160(hook)) | (useForPay ? uint256(1) << 160 : uint256(0))
                | (useForCashOut ? uint256(1) << 168 : uint256(0))
        );
        vm.store(address(deployer), innerSlot, value);
    }

    /// @dev Creates a standard cashout context.
    function _makeCashOutContext() internal returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: makeAddr("terminal"),
            holder: makeAddr("holder"),
            projectId: projectId,
            rulesetId: rulesetId,
            cashOutCount: 100,
            totalSupply: 1000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 10 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
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
            scopeCashOutsToLocalBalances: true,
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
