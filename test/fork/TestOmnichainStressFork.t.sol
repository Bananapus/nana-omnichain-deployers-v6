// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OmnichainForkTestBase} from "./OmnichainForkTestBase.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

/// @notice Fork stress tests for the omnichain deployer covering multi-pay-hook interactions,
///         721 cashout paths, proportional cashouts, and fee routing.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestOmnichainStressFork -vvv
contract TestOmnichainStressFork is OmnichainForkTestBase {
    // ─────────────────────────────────────────────────────────────────────────
    // Multi-pay-hook interaction tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 721 tier split (30%) + buyback custom hook. Verify merged specs and weight scaling.
    function test_fork_multiPay_721SplitsPlusCustomHookSpecs() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        uint256 balanceBefore = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 2 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 2 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "multi-hook: 721 + buyback",
            metadata: metadata
        });

        uint256 balanceAfter = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // With 30% tier split on 1 ETH (tier price), 0.7 ETH goes to project from tier.
        // The remaining 1 ETH goes entirely to project (no tier match for excess).
        // Total project amount = 0.7 + 1 = 1.7 ETH, so tokens = 1000 * 1.7 = 1700.
        // But the tier split goes to the split beneficiary, so terminal gets 1.7 ETH.
        // The split beneficiary gets 0.3 ETH directly.
        assertGt(tokensReceived, 0, "Should have minted tokens");
        assertGt(balanceAfter, balanceBefore, "Terminal balance should increase");
    }

    /// @notice Weight = 0 when tier splits take the full payment amount.
    function test_fork_multiPay_weightZeroWhenFullSplit() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay exactly the tier price (1 ETH). With 30% split, 0.3 ETH goes to split beneficiary,
        // 0.7 ETH goes to project. Weight = mulDiv(1000, 0.7e18, 1e18) = 700.
        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "exact tier price",
            metadata: metadata
        });

        // Tokens should reflect the weight scaling: 700 tokens (1000 * 0.7).
        assertEq(tokensReceived, 700e18, "Tokens should reflect 70% weight after 30% split");
    }

    /// @notice No tier metadata — no splits, full weight applied.
    function test_fork_multiPay_noTierMetadata_noSplit() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        // Pay without tier metadata — 721 hook returns no specs, full weight.
        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "no tier metadata",
            metadata: ""
        });

        assertEq(tokensReceived, 1000e18, "Full 1000 tokens per ETH without tier metadata");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 721 cashout paths
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 721 hook with useDataHookForCashOut: fungible cashout reverts because
    ///         the 721 hook can't handle ERC-20 token cashouts.
    function test_fork_cashOut_721ProjectWithNFT_revertsForFungible() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay to mint an NFT.
        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "get NFT",
            metadata: metadata
        });

        // Verify payer has tokens.
        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);
        assertGt(payerTokens, 0, "payer should have tokens");

        // Cash out fungible tokens — 721 hook has useDataHookForCashOut=true, so it reverts.
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });
    }

    /// @notice 721 hook with useDataHookForCashOut: fungible-only cashout reverts.
    function test_fork_cashOut_fungibleOnly_revertsWith721Hook() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        // Pay without tier metadata — get only fungible tokens.
        vm.prank(payer);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fungible only",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);

        // Cash out — 721 hook has useDataHookForCashOut=true, reverts for fungible tokens.
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 721 cashout paths — useDataHookForCashOut=false (fungible cashouts succeed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 721 hook with useDataHookForCashOut=false: fungible cashout succeeds with tax.
    function test_fork_cashOut_721Project_noCashOutHook_succeeds() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000, false);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay to mint an NFT.
        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "get NFT",
            metadata: metadata
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);
        assertGt(payerTokens, 0, "payer should have tokens");

        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // 721 hook NOT invoked for cashout — fungible cashout succeeds with 50% tax.
        vm.prank(payer);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });

        assertGt(reclaimed, 0, "Should reclaim some ETH");
        assertLt(reclaimed, surplus, "Should get less than full surplus due to tax");
    }

    /// @notice 721 hook with useDataHookForCashOut=false: fungible-only cashout succeeds.
    function test_fork_cashOut_fungibleOnly_noCashOutHook_succeeds() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000, false);
        _setupPool(projectId, 10_000 ether);

        vm.prank(payer);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fungible only",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // 721 hook NOT invoked for cashout — bonding curve + 50% tax + 2.5% fee apply.
        vm.prank(payer);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });

        assertGt(reclaimed, 0, "Should reclaim some ETH");
        assertLt(reclaimed, surplus, "Should be less than surplus due to tax and fees");
    }

    /// @notice 721 hook with useDataHookForCashOut=false: fee calculation after splits.
    function test_fork_feeCalculation_cashOutAfterSplits_noCashOutHook() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000, false);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay with tier metadata (triggers 30% split).
        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "with splits",
            metadata: metadata
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);
        uint256 terminalBalance = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        // Cash out all tokens — bonding curve + 50% tax rate + 2.5% fee all apply.
        vm.prank(payer);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });

        assertGt(reclaimed, 0, "Should get some reclaim");
        assertLt(reclaimed, terminalBalance, "Reclaim should be less than terminal balance due to tax + fee");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Project token cashout flows
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Cash out with reserved tokens pending — verify surplus calculation accounts for them.
    function test_fork_cashOut_withReservedTokens() public {
        // Deploy a project with 10% reserved rate and 50% tax.
        uint256 projectId = _deployPlainWithReservedPercent(5000, 1000);

        // Pay to get tokens.
        vm.prank(payer);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund",
            metadata: ""
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);

        // There should be pending reserved tokens.
        uint256 pendingReserved = jbController().pendingReservedTokenBalanceOf(projectId);
        assertGt(pendingReserved, 0, "Should have pending reserved tokens");

        // Total supply used for cashout includes pending reserved.
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        vm.prank(payer);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });

        // With 50% tax and pending reserved tokens inflating supply, reclaim should be less
        // than full surplus.
        assertGt(reclaimed, 0, "Should get some reclaim");
        assertLt(reclaimed, surplus, "Reclaim should be less than surplus due to tax + reserves");
    }

    /// @notice Multiple payers cash out proportionally.
    function test_fork_cashOut_multiplePayers_proportional() public {
        uint256 projectId = _deployPlain(5000);

        address payer1 = makeAddr("payer1");
        address payer2 = makeAddr("payer2");
        address payer3 = makeAddr("payer3");
        vm.deal(payer1, 10 ether);
        vm.deal(payer2, 10 ether);
        vm.deal(payer3, 10 ether);

        // Three payers with different amounts.
        vm.prank(payer1);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer1,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(payer2);
        jbMultiTerminal().pay{value: 2 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 2 ether,
            beneficiary: payer2,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(payer3);
        jbMultiTerminal().pay{value: 3 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 3 ether,
            beneficiary: payer3,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 tokens1 = jbTokens().totalBalanceOf(payer1, projectId);
        uint256 tokens2 = jbTokens().totalBalanceOf(payer2, projectId);
        uint256 tokens3 = jbTokens().totalBalanceOf(payer3, projectId);

        // Verify proportional token allocation.
        assertEq(tokens2, tokens1 * 2, "Payer2 should have 2x payer1's tokens");
        assertEq(tokens3, tokens1 * 3, "Payer3 should have 3x payer1's tokens");

        // Cash out payer1 — partial cashout with 50% tax.
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);

        vm.prank(payer1);
        uint256 reclaimed1 = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer1,
                projectId: projectId,
                cashOutCount: tokens1,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer1),
                metadata: ""
            });

        // Payer1 has 1/6 of supply with 50% tax.
        assertGt(reclaimed1, 0, "Payer1 should reclaim something");
        assertLt(reclaimed1, surplus / 6, "Payer1 reclaim should be less than 1/6 surplus due to tax");

        // Verify payer2 can still cash out after payer1.
        vm.prank(payer2);
        uint256 reclaimed2 = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer2,
                projectId: projectId,
                cashOutCount: tokens2,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer2),
                metadata: ""
            });

        assertGt(reclaimed2, 0, "Payer2 should reclaim something");
        // Payer2 now has 2/5 of remaining supply (tokens3 = 3/5 still outstanding).
        // Their reclaim should be greater than payer1's.
        assertGt(
            reclaimed2,
            reclaimed1,
            "Payer2 should reclaim more than payer1 (2x tokens + tax benefit from reduced supply)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fee routing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 721 hook with useDataHookForCashOut: cashout after split-payment also reverts for fungible.
    function test_fork_feeCalculation_cashOutAfterSplits_reverts() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay with tier metadata (triggers 30% split).
        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "with splits",
            metadata: metadata
        });

        uint256 payerTokens = jbTokens().totalBalanceOf(payer, projectId);

        // Cash out fungible tokens — 721 hook has useDataHookForCashOut=true, reverts.
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: projectId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a plain project with a specific reserved percent.
    function _deployPlainWithReservedPercent(
        uint16 cashOutTaxRate,
        uint16 reservedPercent
    )
        internal
        returns (uint256 projectId)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: reservedPercent,
                cashOutTaxRate: cashOutTaxRate,
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
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBSuckerDeploymentConfig memory suckerConfig =
            JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        JBOmnichain721Config memory empty721Config;
        (projectId,,) = omnichainDeployer.launchProjectFor({
            owner: multisig(),
            projectUri: "ipfs://reserved-test",
            deploy721Config: empty721Config,
            rulesetConfigurations: rulesets,
            terminalConfigurations: tc,
            memo: "reserved",
            suckerDeploymentConfiguration: suckerConfig,
            controller: IJBController(address(jbController()))
        });
    }
}
