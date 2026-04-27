// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBDeployerHookConfig} from "../../src/structs/JBDeployerHookConfig.sol";
import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBTiered721HookConfig} from "../../src/structs/JBTiered721HookConfig.sol";

contract ExtraCashOutHookZeroReclaimTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RULESET_ID = 100;
    uint256 internal constant NFT_CASH_OUT_WEIGHT = 10 ether;
    uint256 internal constant NFT_TOTAL_WEIGHT = 100 ether;
    uint256 internal constant LOCAL_SURPLUS = 50 ether;

    function testExtraCashOutHookCanZeroNftReclaimAfter721RewritesCashOutCount() external {
        MockPermissions permissions = new MockPermissions();
        MockSuckerRegistry suckers = new MockSuckerRegistry();
        Harness deployer = new Harness(IJBPermissions(address(permissions)), IJBSuckerRegistry(address(suckers)));

        Mock721CashOutHook nftHook = new Mock721CashOutHook();
        MockExtraCashOutHook extraHook = new MockExtraCashOutHook();

        deployer.setTiered721HookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBTiered721HookConfig({hook: IJB721TiersHook(address(nftHook)), useDataHookForCashOut: true})
        });
        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(extraHook)), useDataHookForPay: false, useDataHookForCashOut: true
            })
        });

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(0x1),
            holder: address(0x2),
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: 0,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: 1, value: LOCAL_SURPLUS}),
            useTotalSurplus: false,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory specs
        ) = deployer.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE);
        assertEq(effectiveCashOutCount, NFT_CASH_OUT_WEIGHT);
        assertEq(effectiveTotalSupply, NFT_TOTAL_WEIGHT);
        assertEq(effectiveSurplusValue, LOCAL_SURPLUS);
        assertEq(specs.length, 2);

        uint256 reclaim = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: effectiveCashOutCount,
            totalSupply: effectiveTotalSupply,
            cashOutTaxRate: cashOutTaxRate
        });
        assertEq(reclaim, 0);
    }
}

contract Harness is JBOmnichainDeployer {
    constructor(
        IJBPermissions permissions,
        IJBSuckerRegistry suckers
    )
        JBOmnichainDeployer(
            suckers,
            IJB721TiersHookDeployer(address(0)),
            permissions,
            IJBProjects(address(0)),
            IJBDirectory(address(0)),
            address(0)
        )
    {}

    function setTiered721HookOf(uint256 projectId, uint256 rulesetId, JBTiered721HookConfig memory config) external {
        _tiered721HookOf[projectId][rulesetId] = config;
    }

    function setExtraDataHookOf(uint256 projectId, uint256 rulesetId, JBDeployerHookConfig memory config) external {
        _extraDataHookOf[projectId][rulesetId] = config;
    }
}

contract MockPermissions {
    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract MockSuckerRegistry {
    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract Mock721CashOutHook {
    uint256 internal constant NFT_CASH_OUT_WEIGHT = 10 ether;
    uint256 internal constant NFT_TOTAL_WEIGHT = 100 ether;

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] =
            JBCashOutHookSpecification({hook: IJBCashOutHook(address(0x721)), noop: false, amount: 0, metadata: ""});

        return
            (context.cashOutTaxRate, NFT_CASH_OUT_WEIGHT, NFT_TOTAL_WEIGHT, context.surplus.value, hookSpecifications);
    }
}

contract MockExtraCashOutHook {
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] =
            JBCashOutHookSpecification({hook: IJBCashOutHook(address(0xB0B)), noop: false, amount: 0, metadata: ""});

        return (JBConstants.MAX_CASH_OUT_TAX_RATE, context.cashOutCount, context.totalSupply, 0, hookSpecifications);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (0, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }
}
