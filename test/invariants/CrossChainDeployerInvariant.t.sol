// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OmnichainForkTestBase} from "../fork/OmnichainForkTestBase.sol";
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
contract CrossChainDeployerInvariant is OmnichainForkTestBase {
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

        // Deploy project with 721 hook + buyback + 50% cashOutTaxRate.
        launchRulesetId = block.timestamp;
        (projectId, hook721) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

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
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector), abi.encode(0)
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

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 1: Sucker always gets 0% tax (regardless of remote supply)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Even when remote supply is inflated, suckers should always get full pro-rata reclaim.
    function invariant_SuckerZeroTaxWithRemoteSupply() public view {
        assertTrue(
            handler.ghostSuckerCashOutTaxAlwaysZero(), "Sucker should get 0% tax regardless of mocked remote supply"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 2: Fund conservation holds across ruleset transitions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total paid in >= total cashed out, even after queuing new rulesets
    ///         with different cashOutTaxRates and reserved percents.
    function invariant_FundConservationAcrossRulesets() public view {
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        assertGe(handler.ghostTotalPaidIn(), handler.ghostTotalCashedOut(), "Total paid >= total cashed out");
        assertGe(handler.ghostTotalPaidIn(), terminalBalance, "Total paid >= terminal balance");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 3: Token supply consistency (with reserved distribution)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Minted - burned >= totalSupply. Reserved distributions are tracked as mints.
    function invariant_TokenSupplyWithReserved() public view {
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
    //  INVARIANT 4: Deployer never holds ETH (even during ruleset queuing)
    // ═══════════════════════════════════════════════════════════════════════

    function invariant_DeployerNeverHoldsETH() public view {
        assertEq(address(omnichainDeployer).balance, 0, "Deployer should never hold ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 5: Hook carryforward preserves the 721 hook
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When queuing without new tiers, the returned hook must be the same as the launch hook.
    function invariant_HookCarryForwardPreservesHook() public view {
        assertTrue(
            handler.ghostCarryForwardAlwaysPreservesHook(), "Carry-forward should always return the same 721 hook"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 6: Every queued ruleset has hook config stored
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For every ruleset queued through the deployer, tiered721HookOf must be set.
    function invariant_AllQueuedRulesetsHaveHookConfig() public view {
        uint256 count = handler.ghostQueuedRulesetCount();
        for (uint256 i; i < count; i++) {
            uint256 rulesetId = handler.ghostQueuedRulesetIds(i);
            (IJB721TiersHook storedHook,) = omnichainDeployer.tiered721HookOf(projectId, rulesetId);
            assertTrue(address(storedHook) != address(0), "Queued ruleset must have hook config stored");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 7: Launch ruleset hook config is immutable
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Queuing new rulesets must not overwrite the launch ruleset's hook config.
    function invariant_LaunchHookConfigImmutable() public view {
        (IJB721TiersHook storedHook,) = omnichainDeployer.tiered721HookOf(projectId, launchRulesetId);
        assertEq(address(storedHook), address(hook721), "Launch ruleset hook must remain unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANT 8: No actor profits from operations (inflows >= outflows)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice No single actor should extract more than they contributed (accounting for fees).
    ///         This is the no-profit invariant at the per-actor level.
    function invariant_NoActorProfits() public view {
        // Check regular actors.
        address[3] memory actorsToCheck = [actor1, actor2, actor3];
        for (uint256 i; i < 3; i++) {
            uint256 contributed = handler.ghostActorContributed(actorsToCheck[i]);
            uint256 extracted = handler.ghostActorExtracted(actorsToCheck[i]);
            assertGe(contributed, extracted, "Actor should not profit from pay+cashout");
        }
    }
}
