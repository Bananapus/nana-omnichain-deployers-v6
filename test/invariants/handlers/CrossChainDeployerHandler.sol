// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

import {JBOmnichainDeployer} from "../../../src/JBOmnichainDeployer.sol";

/// @title CrossChainDeployerHandler
/// @notice Extended fuzzing handler that adds ruleset queuing, remote supply mocking,
///         and reserved token distribution to the base invariant testing operations.
///         Tracks cross-chain-specific ghost variables for invariant verification.
contract CrossChainDeployerHandler is Test {
    using JBMetadataResolver for bytes;

    // ───────────────────────── Core references
    JBOmnichainDeployer public deployer;
    IJBMultiTerminal public terminal;
    IJBController public controller;
    IJBTokens public tokens;
    IJBTerminalStore public terminalStore;
    IJBSuckerRegistry public suckerRegistry;

    uint256 public projectId;
    IJB721TiersHook public hook;

    // ───────────────────────── Actors
    address[] public actors;
    address public suckerAddr;
    address public projectOwner;

    // ───────────────────────── Ghost variables — conservation
    uint256 public ghostTotalPaidIn;
    uint256 public ghostTotalCashedOut;
    uint256 public ghostTotalTokensMinted;
    uint256 public ghostTotalTokensBurned;

    // ───────────────────────── Ghost variables — cross-chain
    uint256 public ghostMockedRemoteSupply;
    uint256 public ghostMockedRemoteSurplus;
    bool public ghostSuckerCashOutTaxAlwaysZero = true;

    // ───────────────────────── Ghost variables — ruleset queuing
    uint256 public ghostRulesetsQueued;
    uint256[] public ghostQueuedRulesetIds;
    bool public ghostCarryForwardAlwaysPreservesHook = true;

    // ───────────────────────── Ghost variables — reserved tokens
    uint256 public ghostReservedTokensDistributed;

    // ───────────────────────── Per-actor tracking
    mapping(address => uint256) public ghostActorContributed;
    mapping(address => uint256) public ghostActorExtracted;

    // ───────────────────────── Operation counters
    uint256 public callsPayProject;
    uint256 public callsCashOutTokens;
    uint256 public callsPayAsSucker;
    uint256 public callsCashOutAsSucker;
    uint256 public callsWarpTime;
    uint256 public callsQueueRuleset;
    uint256 public callsMockRemoteSupply;
    uint256 public callsSendReservedTokens;

    constructor(
        JBOmnichainDeployer _deployer,
        IJBMultiTerminal _terminal,
        IJBController _controller,
        IJBTokens _tokens,
        IJBTerminalStore _terminalStore,
        IJBSuckerRegistry _suckerRegistry,
        uint256 _projectId,
        IJB721TiersHook _hook,
        address[] memory _actors,
        address _suckerAddr,
        address _projectOwner
    ) {
        deployer = _deployer;
        terminal = _terminal;
        controller = _controller;
        tokens = _tokens;
        terminalStore = _terminalStore;
        suckerRegistry = _suckerRegistry;
        projectId = _projectId;
        hook = _hook;
        actors = _actors;
        suckerAddr = _suckerAddr;
        projectOwner = _projectOwner;

        // Seed ghost with any tokens minted before handler starts tracking (e.g. pool liquidity).
        ghostTotalTokensMinted = tokens.totalSupplyOf(_projectId);
    }

    // ───────────────────────── Actor helpers

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ───────────────────────── Operations

    /// @notice Pay the project with a random amount (0.01-5 ETH). Optionally includes tier metadata.
    function payProject(uint256 seed) external {
        callsPayProject++;

        address actor = _selectActor(seed);
        uint256 amount = bound(seed, 0.01 ether, 5 ether);
        vm.deal(actor, actor.balance + amount);

        // 50% chance of including tier metadata.
        bytes memory metadata;
        if (seed % 2 == 0 && address(hook) != address(0)) {
            address metadataTarget = hook.METADATA_ID_TARGET();
            uint16[] memory tierIds = new uint16[](1);
            tierIds[0] = 1;
            bytes memory tierData = abi.encode(true, tierIds);
            bytes4 tierMetadataId = JBMetadataResolver.getId("pay", metadataTarget);
            bytes4[] memory ids = new bytes4[](1);
            ids[0] = tierMetadataId;
            bytes[] memory datas = new bytes[](1);
            datas[0] = tierData;
            metadata = JBMetadataResolver.createMetadata(ids, datas);
        }

        uint256 supplyBefore = tokens.totalSupplyOf(projectId);

        vm.prank(actor);
        try terminal.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "handler:pay",
            metadata: metadata
        }) returns (
            uint256
        ) {
            ghostTotalPaidIn += amount;
            ghostActorContributed[actor] += amount;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyAfter > supplyBefore) {
                ghostTotalTokensMinted += supplyAfter - supplyBefore;
            }
        } catch {
            // Payment may fail if tier is sold out or other reasons — ok.
        }
    }

    /// @notice Cash out a random portion of a holder's tokens.
    function cashOutTokens(uint256 seed) external {
        callsCashOutTokens++;

        address actor = _selectActor(seed);
        uint256 balance = tokens.totalBalanceOf(actor, projectId);
        if (balance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, balance);
        uint256 supplyBefore = tokens.totalSupplyOf(projectId);

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectId,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (
            uint256 reclaimed
        ) {
            ghostTotalCashedOut += reclaimed;
            ghostActorExtracted[actor] += reclaimed;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyBefore > supplyAfter) {
                ghostTotalTokensBurned += supplyBefore - supplyAfter;
            }
        } catch {
            // May fail if insufficient surplus or other reasons — ok.
        }
    }

    /// @notice Pay as the sucker address.
    function payAsSucker(uint256 seed) external {
        callsPayAsSucker++;

        uint256 amount = bound(seed, 0.01 ether, 2 ether);
        vm.deal(suckerAddr, suckerAddr.balance + amount);

        uint256 supplyBefore = tokens.totalSupplyOf(projectId);

        vm.prank(suckerAddr);
        try terminal.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: suckerAddr,
            minReturnedTokens: 0,
            memo: "handler:sucker-pay",
            metadata: ""
        }) returns (
            uint256
        ) {
            ghostTotalPaidIn += amount;
            ghostActorContributed[suckerAddr] += amount;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyAfter > supplyBefore) {
                ghostTotalTokensMinted += supplyAfter - supplyBefore;
            }
        } catch {}
    }

    /// @notice Cash out as the sucker address — should always get 0% tax.
    function cashOutAsSucker(uint256 seed) external {
        callsCashOutAsSucker++;

        uint256 balance = tokens.totalBalanceOf(suckerAddr, projectId);
        if (balance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, balance);
        uint256 supplyBefore = tokens.totalSupplyOf(projectId);

        // Compute expected pro-rata before cashout.
        uint256 surplus = terminalStore.balanceOf(address(terminal), projectId, JBConstants.NATIVE_TOKEN);
        uint256 totalSupply = tokens.totalSupplyOf(projectId);
        uint256 expectedProRata = totalSupply > 0 ? (surplus * cashOutAmount) / totalSupply : 0;

        vm.prank(suckerAddr);
        try terminal.cashOutTokensOf({
            holder: suckerAddr,
            projectId: projectId,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(suckerAddr),
            metadata: ""
        }) returns (
            uint256 reclaimed
        ) {
            ghostTotalCashedOut += reclaimed;
            ghostActorExtracted[suckerAddr] += reclaimed;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyBefore > supplyAfter) {
                ghostTotalTokensBurned += supplyBefore - supplyAfter;
            }

            // Sucker should get full pro-rata (0% tax). Allow 1 wei tolerance for rounding.
            if (expectedProRata > 0 && reclaimed + 1 < expectedProRata) {
                ghostSuckerCashOutTaxAlwaysZero = false;
            }
        } catch {
            // May fail if insufficient surplus — ok.
        }
    }

    /// @notice Advance time by 1-7 days. Required for ruleset transitions.
    function warpTime(uint256 seed) external {
        callsWarpTime++;
        uint256 jump = bound(seed, 1 days, 7 days);
        vm.warp(block.timestamp + jump);
    }

    // ───────────────────────── NEW: Ruleset queuing

    /// @notice Queue a new ruleset with the simplified interface (carry-forward hook).
    ///         Varies the cashOutTaxRate to test different bonding curve parameters.
    function queueRuleset(uint256 seed) external {
        callsQueueRuleset++;

        // Must warp at least 1 second to avoid same-block collision.
        vm.warp(block.timestamp + 1);

        uint16 newCashOutTaxRate = uint16(bound(seed, 0, 10_000));

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: 1000e18,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: uint16(bound(seed >> 16, 0, 5000)),
                cashOutTaxRate: newCashOutTaxRate,
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
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(projectOwner);
        try deployer.queueRulesetsOf({
            projectId: projectId, rulesetConfigurations: rulesets, memo: "handler:queue", controller: controller
        }) returns (
            uint256 rulesetId, IJB721TiersHook queuedHook
        ) {
            ghostRulesetsQueued++;
            ghostQueuedRulesetIds.push(rulesetId);

            // Verify hook carryforward: the queued hook should be the same as the launch hook.
            if (address(queuedHook) != address(hook)) {
                ghostCarryForwardAlwaysPreservesHook = false;
            }
        } catch {
            // May fail if same-block or other constraint — ok.
        }
    }

    // ───────────────────────── NEW: Remote supply/surplus mocking

    /// @notice Mock the sucker registry to report different remote supply/surplus values.
    ///         This simulates tokens bridging to/from other chains.
    function mockRemoteSupply(uint256 seed) external {
        callsMockRemoteSupply++;

        uint256 newRemoteSupply = bound(seed, 0, 100_000e18);
        uint256 newRemoteSurplus = bound(seed >> 128, 0, 50 ether);

        ghostMockedRemoteSupply = newRemoteSupply;
        ghostMockedRemoteSurplus = newRemoteSurplus;

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, projectId),
            abi.encode(newRemoteSupply)
        );

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector),
            abi.encode(newRemoteSurplus)
        );
    }

    // ───────────────────────── NEW: Reserved token distribution

    /// @notice Distribute pending reserved tokens to splits.
    function sendReservedTokens() external {
        callsSendReservedTokens++;

        uint256 supplyBefore = tokens.totalSupplyOf(projectId);

        try controller.sendReservedTokensToSplitsOf(projectId) returns (uint256 distributed) {
            ghostReservedTokensDistributed += distributed;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyAfter > supplyBefore) {
                ghostTotalTokensMinted += supplyAfter - supplyBefore;
            }
        } catch {
            // May fail if no reserved tokens pending — ok.
        }
    }

    // ───────────────────────── View helpers

    function ghostQueuedRulesetCount() external view returns (uint256) {
        return ghostQueuedRulesetIds.length;
    }
}
