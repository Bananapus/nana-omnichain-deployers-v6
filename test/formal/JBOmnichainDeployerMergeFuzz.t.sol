// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {
    MergeHarness,
    MergeMockController,
    MergeMockDataHook,
    MergeMockDirectory,
    MergeMockHookDeployer,
    MergeMockPermissions,
    MergeMockProjects,
    MergeMockSuckerRegistry
} from "./JBOmnichainDeployerMergeHalmos.t.sol";

/// @notice Forge fuzz companion to `JBOmnichainDeployerMergeHalmos`. Same composition properties (cash-out routing /
/// denominators, pay-spec ordering, split-credit fallback, ERC-721 receipt guard, peer-chain fail-open) checked with
/// `forge` fuzzing over wider integer domains than the symbolic harness's small types reach. Dual implementation per
/// the house convention (a `check_` symbolic proof + a `testFuzz_` fuzz proof for each property).
contract JBOmnichainDeployerMergeFuzz is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RULESET_ID = 7;

    MergeHarness internal _deployer;
    MergeMockController internal _controller;
    MergeMockDataHook internal _hook721;
    MergeMockDataHook internal _extraHook;
    address internal _projectsAddress;

    function setUp() public {
        MergeMockDirectory directory = new MergeMockDirectory();
        _projectsAddress = address(new MergeMockProjects());
        _controller = new MergeMockController({
            directory: IJBDirectory(address(directory)), projects: IJBProjects(_projectsAddress)
        });
        _hook721 = new MergeMockDataHook();
        _extraHook = new MergeMockDataHook();

        _deployer = new MergeHarness({
            suckerRegistry: new MergeMockSuckerRegistry(),
            hookDeployer: new MergeMockHookDeployer(),
            permissions: new MergeMockPermissions(),
            controller: _controller
        });
    }

    /// @notice Fuzz: 721 handles cash-out => only 721's spec returned, 721's denominators win, extra hook untouched.
    function testFuzz_cashOut721HandlesReturnsOnly721Spec(
        uint16 tax,
        uint96 count,
        uint96 supply,
        uint96 surplus
    )
        public
    {
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), true);
        _hook721.setCashOut({taxRate: tax, count: count, supply: supply, surplus: surplus, specCount: 1});
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), false, true);
        _extraHook.setRevertOnCashOut(true);

        (
            uint256 outTax,
            uint256 outCount,
            uint256 outSupply,
            uint256 outSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = _deployer.beforeCashOutRecordedWith(_cashOutContext(address(2), false, 0, 0, 0));

        assertEq(outTax, tax);
        assertEq(outCount, count);
        assertEq(outSupply, supply);
        assertEq(outSurplus, surplus);
        assertEq(specs.length, 1);
        assertEq(address(specs[0].hook), address(_hook721));
    }

    /// @notice Fuzz: only extra hook handles cash-out => extra's specs returned, extra's denominators discarded.
    function testFuzz_cashOutExtraOnlyDiscardsExtraDenominators(
        uint8 extraSpecCount,
        uint96 localSupply,
        uint96 localSurplus
    )
        public
    {
        extraSpecCount = uint8(bound(extraSpecCount, 0, 4));
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), false, true);
        _extraHook.setCashOut({
            taxRate: 9999, count: 12_345, supply: type(uint96).max, surplus: type(uint96).max, specCount: extraSpecCount
        });

        (,, uint256 outSupply, uint256 outSurplus, JBCashOutHookSpecification[] memory specs) =
            _deployer.beforeCashOutRecordedWith(_cashOutContext(address(2), false, 0, localSupply, localSurplus));

        assertEq(outSupply, localSupply, "deployer denominators must win");
        assertEq(outSurplus, localSurplus, "deployer denominators must win");
        assertEq(specs.length, extraSpecCount);
        for (uint256 i; i < specs.length; i++) {
            assertEq(address(specs[i].hook), address(_extraHook));
        }
    }

    /// @notice Fuzz: extra hook weight 0 with positive split-credit weight => returned weight == split-credit weight.
    function testFuzz_payZeroExtraWeightFallsBackToSplitCredit(uint96 splitCreditWeight, uint96 contextWeight) public {
        splitCreditWeight = uint96(bound(splitCreditWeight, 1, type(uint96).max));
        contextWeight = uint96(bound(contextWeight, 1, type(uint96).max));

        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        _hook721.setPay({weight: contextWeight, splitAmount: 0, splitCreditWeight: splitCreditWeight, returnSpec: true});
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), true, false);
        _extraHook.setPay({weight: 0, splitAmount: 0, splitCreditWeight: 0, returnSpec: false});

        (uint256 weight,) = _deployer.beforePayRecordedWith(_payContext(contextWeight, 100));
        assertEq(weight, splitCreditWeight);
    }

    /// @notice Fuzz: pay-spec ordering — 721 spec first, then extra specs, length 1 + extraSpecCount.
    function testFuzz_payMergeOrdersTiered721First(uint8 extraSpecCount) public {
        extraSpecCount = uint8(bound(extraSpecCount, 0, 4));
        uint256 contextWeight = 1000;

        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), true, false);
        _hook721.setPay({weight: contextWeight, splitAmount: 0, splitCreditWeight: 0, returnSpec: true});
        _extraHook.setPay({
            weight: contextWeight, splitAmount: 0, splitCreditWeight: 0, returnSpecCount: uint256(extraSpecCount)
        });

        (, JBPayHookSpecification[] memory specs) = _deployer.beforePayRecordedWith(_payContext(contextWeight, 100));

        assertEq(specs.length, 1 + uint256(extraSpecCount));
        assertEq(address(specs[0].hook), address(_hook721));
        for (uint256 i; i < extraSpecCount; i++) {
            assertEq(address(specs[1 + i].hook), address(_extraHook));
        }
    }

    /// @notice Fuzz: onERC721Received accepts a mint (`from == 0`) when the caller IS PROJECTS (routed through the
    /// projects mock so msg.sender genuinely equals PROJECTS); rejects non-mint from PROJECTS.
    function testFuzz_onERC721ReceivedAcceptsProjectsMint(address operator, uint256 tokenId) public view {
        bytes4 ret =
            MergeMockProjects(_projectsAddress).callOnReceived(address(_deployer), operator, address(0), tokenId);
        assertEq(ret, bytes4(0x150b7a02));
    }

    /// @notice Fuzz: onERC721Received reverts on a non-mint transfer (`from != 0`) even from PROJECTS.
    function testFuzz_onERC721ReceivedRejectsNonMint(address from, uint256 tokenId) public {
        vm.assume(from != address(0));
        vm.expectRevert();
        MergeMockProjects(_projectsAddress).callOnReceived(address(_deployer), address(9), from, tokenId);
    }

    /// @notice Fuzz: onERC721Received reverts when the caller is not PROJECTS, even for a mint. The prank sender is a
    /// fuzzed non-PROJECTS address calling the deployer directly.
    function testFuzz_onERC721ReceivedRejectsNonProjectsSender(address sender, uint256 tokenId) public {
        vm.assume(sender != _projectsAddress);
        vm.prank(sender);
        vm.expectRevert();
        _deployer.onERC721Received(address(9), address(0), tokenId, "");
    }

    /// @notice Fuzz: peerChainAdjustedAccountsOf returns (0, empty) when no extra hook is configured.
    function testFuzz_peerChainAdjustedNoExtraHookEmpty(uint48 currentRulesetId) public {
        currentRulesetId = uint48(bound(currentRulesetId, 1, type(uint48).max));
        _controller.setCurrentRulesetId(currentRulesetId);
        (uint256 supply,) = _deployer.peerChainAdjustedAccountsOf(PROJECT_ID);
        assertEq(supply, 0);
    }

    // ----------------------- helpers -----------------------

    function _cashOutContext(
        address holder,
        bool scopeLocal,
        uint256 tax,
        uint256 supply,
        uint256 surplus
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        context = JBBeforeCashOutRecordedContext({
            terminal: address(3),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            cashOutCount: 0,
            totalSupply: supply,
            surplus: JBTokenAmount({token: address(4), decimals: 18, currency: 1, value: surplus}),
            scopeCashOutsToLocalBalances: scopeLocal,
            cashOutTaxRate: tax,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function _payContext(
        uint256 weight,
        uint256 amountValue
    )
        internal
        pure
        returns (JBBeforePayRecordedContext memory context)
    {
        context = JBBeforePayRecordedContext({
            terminal: address(3),
            payer: address(8),
            amount: JBTokenAmount({token: address(4), decimals: 18, currency: 1, value: amountValue}),
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            beneficiary: address(9),
            weight: weight,
            reservedPercent: 0,
            metadata: ""
        });
    }
}
