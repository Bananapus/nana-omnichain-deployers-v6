// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";

contract NftCashoutSupplyMismatchTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RULESET_ID = 123;
    uint256 internal constant NFT_CASH_OUT_WEIGHT = 1 ether;
    uint256 internal constant NFT_TOTAL_CASH_OUT_WEIGHT = 3 ether;
    uint256 internal constant LOCAL_SURPLUS = 10 ether;

    address internal holder = makeAddr("holder");
    address internal permissions = makeAddr("permissions");
    address internal projects = makeAddr("projects");
    address internal hookDeployer = makeAddr("hookDeployer");
    address internal suckerRegistry = makeAddr("suckerRegistry");
    address internal directory = makeAddr("directory");
    address internal controller = makeAddr("controller");

    JBOmnichainDeployer internal deployer;
    MockNftCashOutHook internal nftHook;
    CashOutHarness internal cashOutHarness;

    function setUp() public {
        vm.mockCall(permissions, abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode());
        vm.mockCall(
            controller, abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(IJBProjects(projects))
        );
        vm.mockCall(
            controller, abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(IJBDirectory(directory))
        );

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(suckerRegistry),
            IJB721TiersHookDeployer(hookDeployer),
            IJBPermissions(permissions),
            IJBController(controller),
            address(0)
        );

        nftHook = new MockNftCashOutHook(NFT_CASH_OUT_WEIGHT, NFT_TOTAL_CASH_OUT_WEIGHT);
        cashOutHarness = new CashOutHarness();
        _storeTiered721Hook(address(nftHook), true);
    }

    function testNftCashoutUsesNftCashoutWeightSupplyNotFungibleSupply() public {
        uint256 fungibleTokenSupply = 700 ether;
        _mockSuckerRegistry(false, 0, 0);

        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
        ) = deployer.beforeCashOutRecordedWith(_cashOutContext(fungibleTokenSupply));

        uint256 intendedReclaim =
            cashOutHarness.cashOutFrom(LOCAL_SURPLUS, NFT_CASH_OUT_WEIGHT, NFT_TOTAL_CASH_OUT_WEIGHT, cashOutTaxRate);
        uint256 actualReclaim = cashOutHarness.cashOutFrom(
            effectiveSurplusValue, effectiveCashOutCount, effectiveTotalSupply, cashOutTaxRate
        );

        // The deployer passes through the 721 hook's NFT-denominated local-only denominators instead of using fungible
        // token supply.
        assertEq(effectiveCashOutCount, NFT_CASH_OUT_WEIGHT);
        assertEq(effectiveTotalSupply, NFT_TOTAL_CASH_OUT_WEIGHT);
        assertEq(intendedReclaim, 3.333_333_333_333_333_333 ether);
        assertEq(actualReclaim, intendedReclaim);
    }

    function testNftCashoutUsesHookSupplyEvenWhenFungibleSupplyIsZero() public {
        _mockSuckerRegistry(false, 0, 0);

        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
        ) = deployer.beforeCashOutRecordedWith(_cashOutContext(0));

        uint256 intendedReclaim =
            cashOutHarness.cashOutFrom(LOCAL_SURPLUS, NFT_CASH_OUT_WEIGHT, NFT_TOTAL_CASH_OUT_WEIGHT, cashOutTaxRate);
        uint256 actualReclaim = cashOutHarness.cashOutFrom(
            effectiveSurplusValue, effectiveCashOutCount, effectiveTotalSupply, cashOutTaxRate
        );

        // Even when fungible supply is zero, the deployer passes through the 721 hook's NFT total cash-out weight,
        // preventing full surplus drain.
        assertEq(effectiveCashOutCount, NFT_CASH_OUT_WEIGHT);
        assertEq(effectiveTotalSupply, NFT_TOTAL_CASH_OUT_WEIGHT);
        assertEq(intendedReclaim, 3.333_333_333_333_333_333 ether);
        assertEq(actualReclaim, intendedReclaim);
    }

    function _cashOutContext(uint256 totalSupply)
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        context = JBBeforeCashOutRecordedContext({
            terminal: address(0x1234),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: 0,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: LOCAL_SURPLUS
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function _mockSuckerRegistry(bool isSucker, uint256 remoteTotalSupply, uint256 remoteSurplus) internal {
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, PROJECT_ID, holder),
            abi.encode(isSucker)
        );
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID),
            abi.encode(remoteTotalSupply)
        );
        vm.mockCall(
            suckerRegistry,
            abi.encodeWithSelector(
                IJBSuckerRegistry.totalRemoteSurplusOf.selector,
                PROJECT_ID,
                uint256(uint32(uint160(JBConstants.NATIVE_TOKEN))),
                uint256(18)
            ),
            abi.encode(remoteSurplus)
        );
    }

    function _storeTiered721Hook(address hook, bool useDataHookForCashOut) internal {
        bytes32 outerSlot = keccak256(abi.encode(PROJECT_ID, uint256(1)));
        bytes32 valueSlot = keccak256(abi.encode(RULESET_ID, outerSlot));

        uint256 packed = uint256(uint160(hook));
        if (useDataHookForCashOut) packed |= uint256(1) << 160;

        vm.store(address(deployer), valueSlot, bytes32(packed));
    }
}

contract MockNftCashOutHook is IJBRulesetDataHook {
    uint256 internal immutable _cashOutWeight;
    uint256 internal immutable _totalCashOutWeight;

    constructor(uint256 cashOutWeight, uint256 totalCashOutWeight) {
        _cashOutWeight = cashOutWeight;
        _totalCashOutWeight = totalCashOutWeight;
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
        effectiveCashOutCount = _cashOutWeight;
        effectiveTotalSupply = _totalCashOutWeight;
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

contract CashOutHarness {
    function cashOutFrom(
        uint256 surplus,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        external
        pure
        returns (uint256)
    {
        return JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);
    }
}
