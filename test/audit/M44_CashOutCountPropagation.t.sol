// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";

/// @notice Regression test for M-44: cashOutCount from the 721 hook must be propagated
/// to the extra data hook's context. Before fix, the extra hook receives the stale
/// context.cashOutCount instead of the 721-adjusted value.
contract M44_CashOutCountPropagationTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RULESET_ID = 123;

    // The 721 hook will change cashOutCount from ORIGINAL to ADJUSTED.
    uint256 internal constant ORIGINAL_CASH_OUT_COUNT = 50 ether;
    uint256 internal constant ADJUSTED_CASH_OUT_COUNT = 7 ether;
    uint256 internal constant NFT_TOTAL_SUPPLY = 21 ether;
    uint256 internal constant LOCAL_SURPLUS = 10 ether;

    address internal holder = makeAddr("holder");
    address internal permissions = makeAddr("permissions");
    address internal projects = makeAddr("projects");
    address internal hookDeployer = makeAddr("hookDeployer");
    address internal suckerRegistry = makeAddr("suckerRegistry");
    address internal directory = makeAddr("directory");

    JBOmnichainDeployer internal deployer;
    Mock721HookM44 internal nftHook;
    address internal extraHookAddr;

    function setUp() public {
        vm.mockCall(permissions, abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode());

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(suckerRegistry),
            IJB721TiersHookDeployer(hookDeployer),
            IJBPermissions(permissions),
            IJBProjects(projects),
            IJBDirectory(directory),
            address(0)
        );

        nftHook = new Mock721HookM44(ADJUSTED_CASH_OUT_COUNT, NFT_TOTAL_SUPPLY);
        extraHookAddr = makeAddr("extraHook");

        _storeTiered721Hook(address(nftHook), true);
        _storeExtraDataHook(extraHookAddr, true);
        _mockSuckerRegistry();
        _mockExtraHook();
    }

    /// @notice The extra data hook should receive the 721-adjusted cashOutCount,
    /// not the original context.cashOutCount.
    function test_M44_extraHookReceivesAdjustedCashOutCount() public {
        // Build the expected context that the extra hook should receive.
        // The deployer copies the original context and patches cashOutTaxRate, totalSupply, surplus.value.
        // With the fix, it should also patch cashOutCount.
        // NOTE: We build expectedContext separately (not via pointer alias) to avoid Solidity memory aliasing.
        JBBeforeCashOutRecordedContext memory expectedContext = JBBeforeCashOutRecordedContext({
            terminal: address(0x1234),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: ADJUSTED_CASH_OUT_COUNT, // THIS IS THE FIX — must be the 721-adjusted value
            totalSupply: NFT_TOTAL_SUPPLY, // from 721 hook
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: LOCAL_SURPLUS // 721 hook passes through surplus value
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000, // 721 hook passes through
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        // Build the input context with the ORIGINAL cashOutCount.
        JBBeforeCashOutRecordedContext memory context = _cashOutContext();

        // Sanity: the original context has a different cashOutCount than what the 721 hook returns.
        assertEq(context.cashOutCount, ORIGINAL_CASH_OUT_COUNT);
        assertTrue(ORIGINAL_CASH_OUT_COUNT != ADJUSTED_CASH_OUT_COUNT);

        // Expect the extra hook to be called with the adjusted context (including adjusted cashOutCount).
        vm.expectCall(extraHookAddr, abi.encodeCall(IJBRulesetDataHook.beforeCashOutRecordedWith, (expectedContext)));

        deployer.beforeCashOutRecordedWith(context);
    }

    function _cashOutContext() internal view returns (JBBeforeCashOutRecordedContext memory context) {
        context = JBBeforeCashOutRecordedContext({
            terminal: address(0x1234),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: ORIGINAL_CASH_OUT_COUNT,
            totalSupply: 100 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: LOCAL_SURPLUS
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function _mockSuckerRegistry() internal {
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, PROJECT_ID, holder),
            abi.encode(false)
        );
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID),
            abi.encode(0)
        );
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(
                IJBSuckerRegistry.remoteSurplusOf.selector,
                PROJECT_ID,
                uint256(18),
                uint256(uint32(uint160(JBConstants.NATIVE_TOKEN)))
            ),
            abi.encode(0)
        );
    }

    /// @dev Mock the extra hook to return passthrough values.
    function _mockExtraHook() internal {
        // We use a broad mock: any call to beforeCashOutRecordedWith returns passthrough values.
        // The vm.expectCall will check the exact arguments.
        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            extraHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(5000), uint256(0), uint256(0), uint256(0), specs)
        );
    }

    /// @dev Store the 721 hook at _tiered721HookOf[PROJECT_ID][RULESET_ID] (slot 1).
    function _storeTiered721Hook(address hook, bool useDataHookForCashOut) internal {
        bytes32 outerSlot = keccak256(abi.encode(PROJECT_ID, uint256(1)));
        bytes32 valueSlot = keccak256(abi.encode(RULESET_ID, outerSlot));

        uint256 packed = uint256(uint160(hook));
        if (useDataHookForCashOut) packed |= uint256(1) << 160;

        vm.store(address(deployer), valueSlot, bytes32(packed));
    }

    /// @dev Store the extra data hook at _extraDataHookOf[PROJECT_ID][RULESET_ID] (slot 0).
    /// JBDeployerHookConfig has: IJBRulesetDataHook dataHook (20 bytes), bool useDataHookForPay (1 byte),
    /// bool useDataHookForCashOut (1 byte). All pack into a single slot.
    function _storeExtraDataHook(address hook, bool useDataHookForCashOut) internal {
        bytes32 outerSlot = keccak256(abi.encode(PROJECT_ID, uint256(0)));
        bytes32 valueSlot = keccak256(abi.encode(RULESET_ID, outerSlot));

        uint256 packed = uint256(uint160(hook));
        // useDataHookForPay is at bit 160, useDataHookForCashOut is at bit 168.
        if (useDataHookForCashOut) packed |= uint256(1) << 168;

        vm.store(address(deployer), valueSlot, bytes32(packed));
    }
}

/// @notice Mock 721 hook that returns adjusted cashOutCount and totalSupply values.
contract Mock721HookM44 is IJBRulesetDataHook {
    uint256 internal immutable _cashOutCount;
    uint256 internal immutable _totalSupply;

    constructor(uint256 cashOutCount_, uint256 totalSupply_) {
        _cashOutCount = cashOutCount_;
        _totalSupply = totalSupply_;
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        returns (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = context.cashOutTaxRate;
        effectiveCashOutCount = _cashOutCount;
        effectiveTotalSupply = _totalSupply;
        effectiveSurplusValue = context.surplus.value;
        hookSpecifications = new JBCashOutHookSpecification[](0);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
