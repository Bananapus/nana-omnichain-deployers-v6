// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
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

/// @notice Tests that an extra data hook cannot override 721 hook cash-out semantics.
/// The 721 hook returns NFT-specific cashOutCount based on tier weights. Extra hooks are
/// skipped for NFT cash-outs because the terminal's after-hook context only carries the
/// original fungible burn count.
contract ExtraCashOutHookZeroReclaimTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RULESET_ID = 100;
    uint256 internal constant NFT_CASH_OUT_WEIGHT = 10 ether;
    uint256 internal constant NFT_TOTAL_WEIGHT = 100 ether;
    uint256 internal constant LOCAL_SURPLUS = 50 ether;

    Harness deployer;
    Mock721CashOutHook nftHook;

    function setUp() public {
        MockPermissions permissions = new MockPermissions();
        MockSuckerRegistry suckers = new MockSuckerRegistry();
        MockController controller = new MockController();
        deployer = new Harness({
            permissions: IJBPermissions(address(permissions)),
            suckers: IJBSuckerRegistry(address(suckers)),
            controller: IJBController(address(controller))
        });
        nftHook = new Mock721CashOutHook();
    }

    /// @notice A malicious extra hook cannot zero out the 721 hook's NFT-specific cashOutCount
    /// or override its cash-out tax rate/specs.
    function test_extraHookCannotZeroCashOutCount() external {
        // Deploy a malicious extra hook that returns cashOutCount = 0.
        MaliciousExtraCashOutHook maliciousHook = new MaliciousExtraCashOutHook();

        deployer.setTiered721HookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBTiered721HookConfig({hook: IJB721TiersHook(address(nftHook)), useDataHookForCashOut: true})
        });
        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(maliciousHook)),
                useDataHookForPay: false,
                useDataHookForCashOut: true
            })
        });

        JBBeforeCashOutRecordedContext memory context = _makeContext();

        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory specs
        ) = deployer.beforeCashOutRecordedWith(context);

        // The 721 hook's cashOutCount must be preserved despite the malicious extra hook returning 0.
        assertEq(effectiveCashOutCount, NFT_CASH_OUT_WEIGHT, "721 hook cashOutCount must be preserved");

        // The extra hook is skipped entirely for NFT cash-outs.
        assertEq(cashOutTaxRate, context.cashOutTaxRate, "721 hook cashOutTaxRate must be preserved");

        // 721 hook uses local-only denominators.
        assertEq(effectiveTotalSupply, NFT_TOTAL_WEIGHT, "totalSupply from 721 hook");
        assertEq(effectiveSurplusValue, LOCAL_SURPLUS, "surplus from 721 hook");

        // Only the 721 hook's spec is returned.
        assertEq(specs.length, 1, "only 721 hook spec");

        // Reclaim must be non-zero: NFT holder is entitled to their share of surplus.
        uint256 reclaim = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: effectiveCashOutCount,
            totalSupply: effectiveTotalSupply,
            cashOutTaxRate: cashOutTaxRate
        });
        assertGt(reclaim, 0, "NFT holder reclaim must be non-zero");
    }

    /// @notice When the extra hook passes through cashOutCount unchanged, the deployer still preserves the 721 hook's
    /// value.
    function test_benignExtraHookPreservesCashOutCount() external {
        // Deploy a benign extra hook that passes through context.cashOutCount.
        BenignExtraCashOutHook benignHook = new BenignExtraCashOutHook();

        deployer.setTiered721HookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBTiered721HookConfig({hook: IJB721TiersHook(address(nftHook)), useDataHookForCashOut: true})
        });
        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(benignHook)), useDataHookForPay: false, useDataHookForCashOut: true
            })
        });

        JBBeforeCashOutRecordedContext memory context = _makeContext();

        (, uint256 effectiveCashOutCount,,,) = deployer.beforeCashOutRecordedWith(context);

        // cashOutCount must be the 721 hook's value, not the extra hook's pass-through.
        assertEq(effectiveCashOutCount, NFT_CASH_OUT_WEIGHT, "721 hook cashOutCount preserved with benign extra hook");
    }

    /// @notice When only an extra hook is active (no 721 hook for cash-outs), the extra hook's
    /// cashOutCount should be used as-is (no restoration).
    function test_extraHookAloneSetsOwnCashOutCount() external {
        uint256 extraHookCashOutCount = 42 ether;
        ExtraOnlyCashOutHook extraHook = new ExtraOnlyCashOutHook(extraHookCashOutCount);

        // No 721 hook configured.
        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(extraHook)), useDataHookForPay: false, useDataHookForCashOut: true
            })
        });

        JBBeforeCashOutRecordedContext memory context = _makeContext();

        (, uint256 effectiveCashOutCount,,,) = deployer.beforeCashOutRecordedWith(context);

        // Without a 721 hook, the extra hook's cashOutCount should be used directly.
        assertEq(effectiveCashOutCount, extraHookCashOutCount, "extra hook alone should set cashOutCount");
    }

    /// @notice When the 721 hook exists but useDataHookForCashOut is false, the extra hook's
    /// cashOutCount should be used (no restoration since 721 hook didn't participate).
    function test_721HookNotUsedForCashOut_extraHookSetsCount() external {
        uint256 extraHookCashOutCount = 77 ether;
        ExtraOnlyCashOutHook extraHook = new ExtraOnlyCashOutHook(extraHookCashOutCount);

        deployer.setTiered721HookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            // useDataHookForCashOut = false: 721 hook exists but is NOT used for cash-outs.
            config: JBTiered721HookConfig({hook: IJB721TiersHook(address(nftHook)), useDataHookForCashOut: false})
        });
        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(extraHook)), useDataHookForPay: false, useDataHookForCashOut: true
            })
        });

        JBBeforeCashOutRecordedContext memory context = _makeContext();

        (, uint256 effectiveCashOutCount,,,) = deployer.beforeCashOutRecordedWith(context);

        // 721 hook was not used for cash-outs, so extra hook's cashOutCount should be respected.
        assertEq(
            effectiveCashOutCount, extraHookCashOutCount, "extra hook cashOutCount used when 721 not active for cashout"
        );
    }

    function _makeContext() internal pure returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: address(0x1),
            holder: address(0x2),
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: 0,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: 1, value: LOCAL_SURPLUS}),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }
}

// ============================================================================
// Test harness and mocks
// ============================================================================

contract Harness is JBOmnichainDeployer {
    constructor(
        IJBPermissions permissions,
        IJBSuckerRegistry suckers,
        IJBController controller
    )
        JBOmnichainDeployer(suckers, IJB721TiersHookDeployer(address(0)), permissions, controller, address(0))
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

contract MockController {
    IJBProjects public immutable PROJECTS = IJBProjects(address(0));
    IJBDirectory public immutable DIRECTORY = IJBDirectory(address(0));
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

/// @notice 721 hook that returns NFT-specific cashOutCount and totalSupply.
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

/// @notice Malicious extra hook that returns cashOutCount = 0, attempting to zero out NFT reclaim.
contract MaliciousExtraCashOutHook {
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

        // Malicious: return cashOutCount = 0 to try to zero out NFT holder reclaim.
        // Uses a 50% tax rate (not MAX) so that reclaim is non-zero when cashOutCount is preserved.
        return (JBConstants.MAX_CASH_OUT_TAX_RATE / 2, 0, context.totalSupply, 0, hookSpecifications);
    }
}

/// @notice Benign extra hook that passes through context.cashOutCount unchanged.
contract BenignExtraCashOutHook {
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
}

/// @notice Extra hook that sets a specific cashOutCount (used when no 721 hook is active).
contract ExtraOnlyCashOutHook {
    uint256 internal immutable _cashOutCount;

    constructor(uint256 cashOutCount_) {
        _cashOutCount = cashOutCount_;
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
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

        return (context.cashOutTaxRate, _cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
    }
}
