// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./OmnichainForkTestBase.sol";

/// @notice Fork tests for JBOmnichainDeployer cash-out behavior.
///
/// The omnichain deployer has simpler cash-out logic than REVDeployer:
/// - No fee logic (no 2.5% fee to fee project)
/// - No cash-out delay
/// - Sucker exemption returns 0% tax
/// - 721 hook handles cash-out if present
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestOmnichainCashOutFork -vvv
contract TestOmnichainCashOutFork is OmnichainForkTestBase {
    /// @notice Sucker address gets 0% tax on cash-out (full pro-rata reclaim).
    function test_fork_omnichain_cashOut_suckerExempt() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address sucker = makeAddr("sucker");
        vm.deal(sucker, 100 ether);

        // Pay to get tokens.
        vm.prank(sucker);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: sucker,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 suckerTokens = jbTokens().totalBalanceOf(sucker, projectId);
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // Mock sucker registry.
        vm.mockCall(
            address(SUCKER_REGISTRY),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        vm.prank(sucker);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: sucker,
                projectId: projectId,
                cashOutCount: suckerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(sucker),
                metadata: ""
            });

        // Full pro-rata reclaim.
        uint256 expectedReclaim = (surplus * suckerTokens) / totalSupply;
        assertEq(reclaimedAmount, expectedReclaim, "sucker should get full pro-rata reclaim");
    }

    /// @notice Deploy with 721 hook + useDataHookForCashOut: fungible cashout reverts
    ///         because the 721 hook can't handle ERC-20 token cashouts.
    function test_fork_omnichain_cashOut_721HookRevertsForFungible() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        // Pay to get tokens (no tier metadata, so payer gets fungible tokens).
        vm.prank(PAYER);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, projectId);
        assertGt(payerTokens, 0, "payer should have tokens");

        // Cash out — 721 hook has useDataHookForCashOut=true, so it will be invoked.
        // The 721 hook reverts for fungible token cashouts (can't handle ERC-20).
        vm.prank(PAYER);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: PAYER,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });
    }

    /// @notice Deploy with 721 hook + useDataHookForCashOut=false: fungible cashout succeeds
    ///         with original tax rate applied (721 hook not invoked for cashout).
    function test_fork_omnichain_cashOut_721HookNotUsedForCashOut() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000, false);
        _setupPool(projectId, 10_000 ether);

        // Pay to get tokens (no tier metadata, so payer gets fungible tokens).
        vm.prank(PAYER);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, projectId);
        assertGt(payerTokens, 0, "payer should have tokens");

        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        vm.prank(PAYER);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: PAYER,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });

        // Pro-rata share with 50% tax applied.
        uint256 proRataShare = surplus; // cashing out all tokens
        assertLt(reclaimedAmount, proRataShare, "should get less than pro-rata due to 50% tax");
        assertGt(reclaimedAmount, 0, "should get some reclaim");
    }

    /// @notice Plain project (no hooks) — original values returned unchanged.
    function test_fork_omnichain_cashOut_noHooksPassthrough() public {
        uint256 projectId = _deployPlain(5000);

        // Pay to get tokens.
        vm.prank(PAYER);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, projectId);
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // Cash out all tokens.
        vm.prank(PAYER);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: PAYER,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });

        // With 50% tax and cashing out all supply, bonding curve gives 100% of surplus.
        // But the terminal takes a 2.5% fee on the reclaimed amount.
        uint256 fee = surplus * 25 / 1000;
        assertEq(reclaimedAmount, surplus - fee, "cashing out all supply should return surplus minus 2.5% fee");
    }
}
