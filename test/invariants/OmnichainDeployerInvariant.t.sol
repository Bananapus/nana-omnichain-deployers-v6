// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OmnichainInvariantTestBase} from "./OmnichainInvariantTestBase.sol";
import {OmnichainDeployerHandler} from "./handlers/OmnichainDeployerHandler.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @title OmnichainDeployerInvariant
/// @notice Invariant test suite for the omnichain deployer. Uses a stateful fuzzing handler
///         to randomly execute payments, cashouts, and time warps while verifying critical invariants.
///
/// Run with: forge test --match-contract OmnichainDeployerInvariant -vvv
contract OmnichainDeployerInvariant is OmnichainInvariantTestBase {
    OmnichainDeployerHandler handler;

    address actor1;
    address actor2;
    address actor3;
    address suckerAddr;
    uint256 launchRulesetId;

    function setUp() public override {
        super.setUp();

        // Deploy a local project with the same 721/deployer/sucker composition used by the fork smoke tests.
        launchRulesetId = block.timestamp;
        (uint256 pid, IJB721TiersHook hook) = _deploy721Project(5000);

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

    /// @notice Checks every core property in one campaign.
    /// @dev Foundry runs a full stateful campaign for each public `invariant_*`
    /// function. Keeping one entrypoint avoids replaying the same fork-backed
    /// handler exploration once per property while preserving all assertions.
    function invariant_OmnichainCoreProperties() public view {
        _assertSuckerAlwaysZeroTax();
        _assert721SpecAlwaysFirst();
        _assertFundConservation();
        _assertTokenSupplyConsistency();
        _assertDeployerNeverHoldsETH();
        _assertHookStorageConsistency();
    }

    // ───────────────────────── Sucker always gets 0% tax

    /// @notice Suckers should always receive full pro-rata reclaim (0% tax).
    function _assertSuckerAlwaysZeroTax() internal view {
        assertTrue(handler.ghostSuckerCashOutTaxAlwaysZero(), "Sucker should always get 0% tax on cashout");
    }

    // ───────────────────────── 721 spec always first
    // Note: This is tracked by beforePayRecordedWith composition logic.
    // The handler doesn't directly verify spec ordering (it's a view function),
    // but the ghost variable confirms it was never violated during operations.

    function _assert721SpecAlwaysFirst() internal view {
        assertTrue(handler.ghost721SpecAlwaysFirst(), "721 hook spec should always be first in merged array");
    }

    // ───────────────────────── Fund conservation

    /// @notice Total paid in should be >= total cashed out + current terminal balance.
    ///         (Accounting for fees going to project 1.)
    function _assertFundConservation() internal view {
        uint256 projectId = handler.projectId();
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        // Total inflows >= terminal balance + total outflows (some goes to fees).
        assertGe(handler.ghostTotalPaidIn(), handler.ghostTotalCashedOut(), "Total paid in must be >= total cashed out");
        // Terminal balance can't exceed total paid in.
        assertGe(handler.ghostTotalPaidIn(), terminalBalance, "Total paid in must be >= terminal balance");
    }

    // ───────────────────────── Token supply consistency

    /// @notice Minted tokens minus burned tokens should equal current total supply.
    function _assertTokenSupplyConsistency() internal view {
        uint256 projectId = handler.projectId();
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 minted = handler.ghostTotalTokensMinted();
        uint256 burned = handler.ghostTotalTokensBurned();

        assertGe(minted, burned, "Minted should be >= burned");
        // +1 tolerance: handler may miss micro-mints from reserved token rounding.
        assertGe(
            minted - burned + 1,
            totalSupply,
            "Token supply must not exceed tracked mints minus burns (tolerance: 1 wei)"
        );
    }

    // ───────────────────────── Deployer never holds ETH

    /// @notice The deployer contract should never hold ETH — it's a pass-through.
    function _assertDeployerNeverHoldsETH() internal view {
        assertEq(address(omnichainDeployer).balance, 0, "Deployer should never hold ETH");
    }

    // ───────────────────────── Hook storage consistency

    /// @notice After deployment, tiered721HookOf should be set for the launch ruleset.
    function _assertHookStorageConsistency() internal view {
        uint256 projectId = handler.projectId();
        (IJB721TiersHook hook,) = omnichainDeployer.tiered721HookOf(projectId, launchRulesetId);
        assertTrue(address(hook) != address(0), "721 hook should be stored after deployment");
    }
}
