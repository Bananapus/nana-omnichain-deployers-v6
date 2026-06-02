// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OmnichainInvariantTestBase} from "./OmnichainInvariantTestBase.sol";
import {CrossChainDeployerHandler} from "./handlers/CrossChainDeployerHandler.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @title CrossChainDeployerInvariant
/// @notice Extended invariant tests exercising cross-chain supply effects, ruleset queuing with hook
///         carryforward, and reserved token distribution alongside standard pay/cashout operations.
///
///         Extends the base invariant suite (OmnichainDeployerInvariant) with:
///         - queueRuleset: queues new rulesets with varying cashOutTaxRate/reservedPercent
///         - mockRemoteSupply: varies what the sucker registry reports as remote supply/surplus
///         - sendReservedTokens: distributes pending reserved tokens to splits
///
/// Run with: forge test --match-contract CrossChainDeployerInvariant -vvv
contract CrossChainDeployerInvariant is OmnichainInvariantTestBase {
    CrossChainDeployerHandler handler;

    address actor1;
    address actor2;
    address actor3;
    address suckerAddr;
    uint256 launchRulesetId;
    uint256 projectId;
    IJB721TiersHook hook721;

    function setUp() public override {
        super.setUp();

        // Deploy a local project with 721 hook + 50% cashOutTaxRate.
        launchRulesetId = block.timestamp;
        (projectId, hook721) = _deploy721Project(5000);

        // Create actors.
        actor1 = makeAddr("xchain_actor1");
        actor2 = makeAddr("xchain_actor2");
        actor3 = makeAddr("xchain_actor3");
        suckerAddr = makeAddr("xchain_sucker");

        // Mock sucker registry for the sucker address.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, suckerAddr),
            abi.encode(true)
        );

        // Initialize remote supply/surplus at 0.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, projectId),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.totalRemoteSurplusOf.selector),
            abi.encode(0)
        );

        // Fund actors.
        vm.deal(actor1, 200 ether);
        vm.deal(actor2, 200 ether);
        vm.deal(actor3, 200 ether);
        vm.deal(suckerAddr, 200 ether);

        address[] memory actors = new address[](3);
        actors[0] = actor1;
        actors[1] = actor2;
        actors[2] = actor3;

        handler = new CrossChainDeployerHandler(
            omnichainDeployer,
            jbMultiTerminal(),
            IJBController(address(jbController())),
            jbTokens(),
            jbTerminalStore(),
            suckerRegistry,
            projectId,
            hook721,
            actors,
            suckerAddr,
            multisig()
        );

        // Target only the handler.
        targetContract(address(handler));

        // Target all 8 operations.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CrossChainDeployerHandler.payProject.selector;
        selectors[1] = CrossChainDeployerHandler.cashOutTokens.selector;
        selectors[2] = CrossChainDeployerHandler.payAsSucker.selector;
        selectors[3] = CrossChainDeployerHandler.cashOutAsSucker.selector;
        selectors[4] = CrossChainDeployerHandler.warpTime.selector;
        selectors[5] = CrossChainDeployerHandler.queueRuleset.selector;
        selectors[6] = CrossChainDeployerHandler.mockRemoteSupply.selector;
        selectors[7] = CrossChainDeployerHandler.sendReservedTokens.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Checks every cross-chain property in one campaign.
    /// @dev Foundry runs a full stateful campaign for each public `invariant_*`
    /// function. Keeping one entrypoint avoids replaying the same fork-backed
    /// handler exploration once per property while preserving all assertions.
    function invariant_CrossChainProperties() public view {
        _assertSuckerZeroTaxWithRemoteSupply();
        _assertFundConservationAcrossRulesets();
        _assertTokenSupplyWithReserved();
        _assertDeployerNeverHoldsETH();
        _assertHookCarryForwardPreservesHook();
        _assertAllQueuedRulesetsHaveHookConfig();
        _assertLaunchHookConfigImmutable();
        _assertNoActorProfits();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Sucker always gets 0% tax (regardless of remote supply)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Even when remote supply is inflated, suckers should always get full pro-rata reclaim.
    function _assertSuckerZeroTaxWithRemoteSupply() internal view {
        assertTrue(
            handler.ghostSuckerCashOutTaxAlwaysZero(), "Sucker should get 0% tax regardless of mocked remote supply"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Fund conservation holds across ruleset transitions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total paid in >= total cashed out, even after queuing new rulesets
    ///         with different cashOutTaxRates and reserved percents.
    function _assertFundConservationAcrossRulesets() internal view {
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        assertGe(handler.ghostTotalPaidIn(), handler.ghostTotalCashedOut(), "Total paid >= total cashed out");
        assertGe(handler.ghostTotalPaidIn(), terminalBalance, "Total paid >= terminal balance");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Token supply consistency (with reserved distribution)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Minted - burned >= totalSupply. Reserved distributions are tracked as mints.
    function _assertTokenSupplyWithReserved() internal view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 minted = handler.ghostTotalTokensMinted();
        uint256 burned = handler.ghostTotalTokensBurned();

        assertGe(minted, burned, "Minted >= burned");
        // +1 tolerance: handler may miss micro-mints from reserved token rounding.
        assertGe(
            minted - burned + 1,
            totalSupply,
            "Token supply must not exceed tracked mints minus burns (tolerance: 1 wei)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Deployer never holds ETH (even during ruleset queuing)
    // ═══════════════════════════════════════════════════════════════════════

    function _assertDeployerNeverHoldsETH() internal view {
        assertEq(address(omnichainDeployer).balance, 0, "Deployer should never hold ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook carryforward preserves the 721 hook
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When queuing without new tiers, the returned hook must be the same as the launch hook.
    function _assertHookCarryForwardPreservesHook() internal view {
        assertTrue(
            handler.ghostCarryForwardAlwaysPreservesHook(), "Carry-forward should always return the same 721 hook"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Every queued ruleset has hook config stored
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For every ruleset queued through the deployer, tiered721HookOf must be set.
    function _assertAllQueuedRulesetsHaveHookConfig() internal view {
        uint256 count = handler.ghostQueuedRulesetCount();
        for (uint256 i; i < count; i++) {
            uint256 rulesetId = handler.ghostQueuedRulesetIds(i);
            (IJB721TiersHook storedHook,) = omnichainDeployer.tiered721HookOf(projectId, rulesetId);
            assertNotEq(address(storedHook), address(0), "Queued ruleset must have hook config stored");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Launch ruleset hook config is immutable
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Queuing new rulesets must not overwrite the launch ruleset's hook config.
    function _assertLaunchHookConfigImmutable() internal view {
        (IJB721TiersHook storedHook,) = omnichainDeployer.tiered721HookOf(projectId, launchRulesetId);
        assertEq(address(storedHook), address(hook721), "Launch ruleset hook must remain unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  No actor profits from operations (inflows >= outflows)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice No single actor should extract more than they contributed (accounting for fees).
    ///         This is the no-profit invariant at the per-actor level.
    function _assertNoActorProfits() internal view {
        // Include the mocked sucker. This local invariant mocks remote aggregate supply/surplus, but it never gives
        // the sucker extra local backing, so its zero-tax cash outs still must not extract more than local inflows.
        address[4] memory actorsToCheck = [actor1, actor2, actor3, suckerAddr];
        for (uint256 i; i < 4; i++) {
            uint256 contributed = handler.ghostActorContributed(actorsToCheck[i]);
            uint256 extracted = handler.ghostActorExtracted(actorsToCheck[i]);
            assertGe(contributed, extracted, "Actor should not profit from pay+cashout");
        }
    }
}
