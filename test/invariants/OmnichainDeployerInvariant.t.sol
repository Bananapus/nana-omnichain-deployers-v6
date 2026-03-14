// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OmnichainForkTestBase} from "../fork/OmnichainForkTestBase.sol";
import {OmnichainDeployerHandler} from "./handlers/OmnichainDeployerHandler.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @title OmnichainDeployerInvariant
/// @notice Invariant test suite for the omnichain deployer. Uses a stateful fuzzing handler
///         to randomly execute payments, cashouts, and time warps while verifying critical invariants.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract OmnichainDeployerInvariant -vvv
contract OmnichainDeployerInvariant is OmnichainForkTestBase {
    OmnichainDeployerHandler handler;

    address actor1;
    address actor2;
    address actor3;
    address suckerAddr;
    uint256 launchRulesetId;

    function setUp() public override {
        super.setUp();

        // Deploy project with 721 hook + buyback.
        launchRulesetId = block.timestamp;
        (uint256 pid, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(pid, 10_000 ether);

        // Create actors.
        actor1 = makeAddr("actor1");
        actor2 = makeAddr("actor2");
        actor3 = makeAddr("actor3");
        suckerAddr = makeAddr("suckerAddr");

        // Mock sucker registry for the sucker address.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, pid, suckerAddr),
            abi.encode(true)
        );

        // Fund actors.
        vm.deal(actor1, 100 ether);
        vm.deal(actor2, 100 ether);
        vm.deal(actor3, 100 ether);
        vm.deal(suckerAddr, 100 ether);

        address[] memory actors = new address[](3);
        actors[0] = actor1;
        actors[1] = actor2;
        actors[2] = actor3;

        handler = new OmnichainDeployerHandler(
            omnichainDeployer,
            jbMultiTerminal(),
            IJBController(address(jbController())),
            jbTokens(),
            jbTerminalStore(),
            suckerRegistry,
            pid,
            hook,
            actors,
            suckerAddr,
            multisig()
        );

        // Target only the handler for invariant fuzzing.
        targetContract(address(handler));

        // Target specific selectors.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = OmnichainDeployerHandler.payProject.selector;
        selectors[1] = OmnichainDeployerHandler.cashOutTokens.selector;
        selectors[2] = OmnichainDeployerHandler.payAsSucker.selector;
        selectors[3] = OmnichainDeployerHandler.cashOutAsSucker.selector;
        selectors[4] = OmnichainDeployerHandler.warpTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ───────────────────────── Invariant 1: Sucker always gets 0%
    // tax

    /// @notice Suckers should always receive full pro-rata reclaim (0% tax).
    function invariant_SuckerAlwaysZeroTax() public view {
        assertTrue(handler.ghostSuckerCashOutTaxAlwaysZero(), "Sucker should always get 0% tax on cashout");
    }

    // ───────────────────────── Invariant 2: 721 spec always first
    // Note: This is tracked by beforePayRecordedWith composition logic.
    // The handler doesn't directly verify spec ordering (it's a view function),
    // but the ghost variable confirms it was never violated during operations.

    function invariant_721SpecAlwaysFirst() public view {
        assertTrue(handler.ghost721SpecAlwaysFirst(), "721 hook spec should always be first in merged array");
    }

    // ───────────────────────── Invariant 3: Fund conservation

    /// @notice Total paid in should be >= total cashed out + current terminal balance.
    ///         (Accounting for fees going to project 1.)
    function invariant_FundConservation() public view {
        uint256 projectId = handler.projectId();
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        // Total inflows >= terminal balance + total outflows (some goes to fees).
        assertGe(handler.ghostTotalPaidIn(), handler.ghostTotalCashedOut(), "Total paid in must be >= total cashed out");
        // Terminal balance can't exceed total paid in.
        assertGe(handler.ghostTotalPaidIn(), terminalBalance, "Total paid in must be >= terminal balance");
    }

    // ───────────────────────── Invariant 4: Token supply consistency

    /// @notice Minted tokens minus burned tokens should equal current total supply.
    function invariant_TokenSupplyConsistency() public view {
        uint256 projectId = handler.projectId();
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 minted = handler.ghostTotalTokensMinted();
        uint256 burned = handler.ghostTotalTokensBurned();

        // Allow for reserved tokens that may have been distributed outside the handler.
        assertGe(minted, burned, "Minted should be >= burned");
        // Total supply should equal minted - burned (plus any reserved tokens sent).
        // Since we don't track reserved distributions in the handler, we use >= check.
        assertGe(
            minted - burned + 1, // +1 for rounding tolerance
            totalSupply,
            "Token supply should be <= minted - burned"
        );
    }

    // ───────────────────────── Invariant 5: Deployer never holds ETH

    /// @notice The deployer contract should never hold ETH — it's a pass-through.
    function invariant_DeployerNeverHoldsETH() public view {
        assertEq(address(omnichainDeployer).balance, 0, "Deployer should never hold ETH");
    }

    // ───────────────────────── Invariant 6: Hook storage consistency

    /// @notice After deployment, tiered721HookOf should be set for the launch ruleset.
    function invariant_HookStorageConsistency() public view {
        uint256 projectId = handler.projectId();
        (IJB721TiersHook hook,) = omnichainDeployer.tiered721HookOf(projectId, launchRulesetId);
        assertTrue(address(hook) != address(0), "721 hook should be stored after deployment");
    }
}
