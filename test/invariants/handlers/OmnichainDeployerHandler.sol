// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

import {JBOmnichainDeployer} from "../../../src/JBOmnichainDeployer.sol";

/// @title OmnichainDeployerHandler
/// @notice Stateful fuzzing handler for invariant testing of the omnichain deployer.
///         Ghost variables track all value flows for strict invariant verification.
contract OmnichainDeployerHandler is Test {
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
    uint256 public ghost_totalPaidIn;
    uint256 public ghost_totalCashedOut;
    uint256 public ghost_totalTokensMinted;
    uint256 public ghost_totalTokensBurned;

    // ───────────────────────── Ghost variables — invariants
    bool public ghost_suckerCashOutTaxAlwaysZero = true;
    bool public ghost_721SpecAlwaysFirst = true;

    // ───────────────────────── Per-actor tracking
    mapping(address => uint256) public ghost_actorContributed;
    mapping(address => uint256) public ghost_actorExtracted;

    // ───────────────────────── Operation counters
    uint256 public calls_payProject;
    uint256 public calls_cashOutTokens;
    uint256 public calls_payAsSucker;
    uint256 public calls_cashOutAsSucker;
    uint256 public calls_warpTime;

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
        ghost_totalTokensMinted = tokens.totalSupplyOf(_projectId);
    }

    // ───────────────────────── Actor helpers

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ───────────────────────── Operations

    /// @notice Pay the project with a random amount (0.01-5 ETH). Optionally includes tier metadata.
    function payProject(uint256 seed) external {
        calls_payProject++;

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
            ghost_totalPaidIn += amount;
            ghost_actorContributed[actor] += amount;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyAfter > supplyBefore) {
                ghost_totalTokensMinted += supplyAfter - supplyBefore;
            }
        } catch {
            // Payment may fail if tier is sold out or other reasons — ok.
        }
    }

    /// @notice Cash out a random portion of a holder's tokens.
    function cashOutTokens(uint256 seed) external {
        calls_cashOutTokens++;

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
            ghost_totalCashedOut += reclaimed;
            ghost_actorExtracted[actor] += reclaimed;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyBefore > supplyAfter) {
                ghost_totalTokensBurned += supplyBefore - supplyAfter;
            }
        } catch {
            // May fail if insufficient surplus or other reasons — ok.
        }
    }

    /// @notice Pay as the sucker address.
    function payAsSucker(uint256 seed) external {
        calls_payAsSucker++;

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
            ghost_totalPaidIn += amount;
            ghost_actorContributed[suckerAddr] += amount;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyAfter > supplyBefore) {
                ghost_totalTokensMinted += supplyAfter - supplyBefore;
            }
        } catch {}
    }

    /// @notice Cash out as the sucker address — should always get 0% tax.
    function cashOutAsSucker(uint256 seed) external {
        calls_cashOutAsSucker++;

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
            ghost_totalCashedOut += reclaimed;
            ghost_actorExtracted[suckerAddr] += reclaimed;

            uint256 supplyAfter = tokens.totalSupplyOf(projectId);
            if (supplyBefore > supplyAfter) {
                ghost_totalTokensBurned += supplyBefore - supplyAfter;
            }

            // Sucker should get full pro-rata (0% tax). Allow 1 wei tolerance for rounding.
            if (expectedProRata > 0 && reclaimed + 1 < expectedProRata) {
                ghost_suckerCashOutTaxAlwaysZero = false;
            }
        } catch {
            // May fail if insufficient surplus — ok.
        }
    }

    /// @notice Advance time by 1-7 days.
    function warpTime(uint256 seed) external {
        calls_warpTime++;
        uint256 jump = bound(seed, 1 days, 7 days);
        vm.warp(block.timestamp + jump);
    }
}
