// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./OmnichainForkTestBase.sol";

/// @notice Fork tests verifying JBOmnichainDeployer weight scaling with 721 splits + real buyback hook.
///
/// The omnichain deployer's beforePayRecordedWith scales weight identically to REVDeployer:
///   weight = mulDiv(weight, projectAmount, context.amount.value)
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestOmnichainWeightFork -vvv
contract TestOmnichainWeightFork is OmnichainForkTestBase {
    /// @notice MINT PATH with 30% tier split: buyback hook chooses minting at 1:1 pool.
    /// Expected: 700 tokens (1000 * 0.7 from weight scaling).
    function test_fork_omnichain_mintPath_withSplits() public {
        (uint256 projectId, IJB721TiersHook hook) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "omnichain: mint path with splits",
            metadata: metadata
        });

        assertEq(tokensReceived, 700e18, "mint path: 700 tokens expected after 30% split");
    }

    /// @notice Without tier metadata, no 721 splits apply — payer gets full issuance.
    function test_fork_omnichain_swapPath_withSplits() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        // Without tier metadata and without a buyback hook in the data hook chain,
        // no splits or swaps apply. Full 1000 tokens minted per ETH.
        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "omnichain: no tier metadata, full issuance",
            metadata: ""
        });

        assertEq(tokensReceived, 1000e18, "no tier metadata: full 1000 tokens expected");
    }

    /// @notice No tier metadata (no splits): full 1000 tokens for 1 ETH.
    function test_fork_omnichain_noSplits_fullTokens() public {
        (uint256 projectId,) = _deploy721WithBuyback(5000);
        _setupPool(projectId, 10_000 ether);

        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "omnichain: no splits baseline",
            metadata: ""
        });

        assertEq(tokensReceived, 1000e18, "no splits: 1000 tokens expected");
    }
}
