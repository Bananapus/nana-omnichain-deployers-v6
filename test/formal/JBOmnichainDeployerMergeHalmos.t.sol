// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../../src/structs/JBDeployerHookConfig.sol";
import {JBTiered721HookConfig} from "../../src/structs/JBTiered721HookConfig.sol";

/// @notice Halmos proofs for the omnichain deployer's data-hook composition: pay/cash-out spec ordering, the
/// split-credit fallback, the NFT-vs-fungible cash-out routing, the ERC-721 receipt guard, and the peer-chain
/// fail-open. These exercise the pure branch/array logic that the merge regression suite covers only by example;
/// here it is proven over all inputs SMT can reach.
contract JBOmnichainDeployerMergeHalmos {
    /// @notice Project ID used across the proofs.
    uint256 internal constant PROJECT_ID = 1;

    /// @notice Ruleset ID used across the proofs.
    uint256 internal constant RULESET_ID = 7;

    /// @notice Deployer under test, with internal hook configs exposed for direct seeding.
    MergeHarness internal _deployer;

    /// @notice Mock controller wired into the deployer at construction.
    MergeMockController internal _controller;

    /// @notice Mock sucker registry — configured with no suckers / zero remote state for these proofs.
    MergeMockSuckerRegistry internal _suckerRegistry;

    /// @notice Mock 721 hook used as a configurable data hook for cash-out / pay routing.
    MergeMockDataHook internal _hook721;

    /// @notice Mock extra hook used as a configurable data hook for cash-out / pay routing.
    MergeMockDataHook internal _extraHook;

    /// @notice The address of `JBProjects`, used to drive `onERC721Received`.
    address internal _projectsAddress;

    constructor() {
        MergeMockDirectory directory = new MergeMockDirectory();
        _projectsAddress = address(new MergeMockProjects());
        _controller = new MergeMockController({
            directory: IJBDirectory(address(directory)), projects: IJBProjects(_projectsAddress)
        });
        _suckerRegistry = new MergeMockSuckerRegistry();
        _hook721 = new MergeMockDataHook();
        _extraHook = new MergeMockDataHook();

        _deployer = new MergeHarness({
            suckerRegistry: _suckerRegistry,
            hookDeployer: new MergeMockHookDeployer(),
            permissions: new MergeMockPermissions(),
            controller: _controller
        });
    }

    //*********************************************************************//
    // ----------------- beforeCashOutRecordedWith merge ----------------- //
    //*********************************************************************//

    /// @notice Proves that when the 721 hook handles cash-out, only its spec is returned and the extra hook is never
    /// consulted, regardless of the extra hook's configuration. The 721 hook's totalSupply/surplus win (NFT-local).
    /// @param tax The tax the 721 hook reports.
    /// @param count The cash-out count the 721 hook reports.
    /// @param supply The total supply the 721 hook reports.
    /// @param surplus The surplus the 721 hook reports.
    function check_cashOut721HandlesReturnsOnly721Spec(uint16 tax, uint96 count, uint96 supply, uint96 surplus) public {
        // 721 hook participates in cash-out and returns exactly one spec.
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), true);
        _hook721.setCashOut({taxRate: tax, count: count, supply: supply, surplus: surplus, specCount: 1});

        // Extra hook is configured for cash-out but must never be called (it would revert if it were).
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), false, true);
        _extraHook.setRevertOnCashOut(true);

        (
            uint256 outTax,
            uint256 outCount,
            uint256 outSupply,
            uint256 outSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = _deployer.beforeCashOutRecordedWith(_cashOutContext(address(2), false, 0, 0, 0));

        // 721 hook owns all cash-out denominators when it handles cash-out.
        assert(outTax == tax);
        assert(outCount == count);
        assert(outSupply == supply);
        assert(outSurplus == surplus);

        // Exactly the 721 hook's single spec is returned, pointing at the 721 hook.
        assert(specs.length == 1);
        assert(address(specs[0].hook) == address(_hook721));
    }

    /// @notice Proves that when only the extra hook participates in cash-out (no 721 cash-out), the extra hook's specs
    /// are returned but its totalSupply/surplus are discarded in favor of the deployer's cross-chain values.
    /// @dev The extra hook's spec count is fixed at 2 here: a symbolic dynamic-array length makes halmos abort with a
    /// NotConcreteError on the memory offset, so the wider count sweep lives in the forge fuzz companion.
    /// @param localSupply The local supply before the extra hook adjustment.
    /// @param localSurplus The local surplus before the extra hook adjustment.
    function check_cashOutExtraOnlyReturnsExtraSpecsAndExtraDenominators(
        uint96 localSupply,
        uint96 localSurplus
    )
        public
    {
        uint256 extraSpecCount = 2;

        // No 721 cash-out handling.
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        // Extra hook handles cash-out and returns `extraSpecCount` specs.
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), false, true);
        // The extra hook reports adjusted supply/surplus that must be preserved.
        _extraHook.setCashOut({
            taxRate: 9999, count: 12_345, supply: type(uint96).max, surplus: type(uint96).max, specCount: extraSpecCount
        });

        (,, uint256 outSupply, uint256 outSurplus, JBCashOutHookSpecification[] memory specs) =
            _deployer.beforeCashOutRecordedWith(_cashOutContext(address(2), false, 0, localSupply, localSurplus));

        // Extra hook denominator adjustments are preserved.
        assert(outSupply == type(uint96).max);
        assert(outSurplus == type(uint96).max);

        // The returned spec count equals exactly the extra hook's spec count, all pointing at the extra hook.
        assert(specs.length == extraSpecCount);
        for (uint256 i; i < specs.length; i++) {
            assert(address(specs[i].hook) == address(_extraHook));
        }
    }

    /// @notice Proves the no-spec cash-out branch: when neither the 721 hook nor the extra hook returns any spec, the
    /// deployer returns an empty spec array while still carrying the (possibly hook-adjusted) tax/count/denominators.
    /// Here the 721 hook handles cash-out with a 0-length spec set, so the early return at the "neither hook returned
    /// specs" branch is taken with the 721 hook's denominators.
    /// @param tax The tax the 721 hook reports.
    /// @param count The cash-out count the 721 hook reports.
    /// @param supply The total supply the 721 hook reports.
    /// @param surplus The surplus the 721 hook reports.
    function check_cashOutNoSpecsReturnsEmptyWithAdjustedValues(
        uint16 tax,
        uint96 count,
        uint96 supply,
        uint96 surplus
    )
        public
    {
        // 721 handles cash-out but returns zero specs.
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), true);
        _hook721.setCashOut({taxRate: tax, count: count, supply: supply, surplus: surplus, specCount: 0});

        (
            uint256 outTax,
            uint256 outCount,
            uint256 outSupply,
            uint256 outSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = _deployer.beforeCashOutRecordedWith(_cashOutContext(address(2), false, 0, 0, 0));

        assert(specs.length == 0);
        assert(outTax == tax);
        assert(outCount == count);
        assert(outSupply == supply);
        assert(outSurplus == surplus);
    }

    //*********************************************************************//
    // ------------------- beforePayRecordedWith merge ------------------- //
    //*********************************************************************//

    /// @notice Proves the split-credit fallback: when the extra (e.g. buyback) hook returns weight 0 but a positive
    /// split-credit weight was reported by the 721 hook, the deployer restores `weight == splitCreditWeight` so tier
    /// split issuance is never erased. The 721 hook here returns weight == context.weight (issueTokensForSplits true)
    /// so the split-ratio rescale is the identity and does not interfere.
    /// @param splitCreditWeight The split-credit weight to encode in the 721 hook's spec metadata.
    /// @param contextWeight The ruleset weight passed in the context.
    function check_payZeroExtraWeightFallsBackToSplitCredit(uint96 splitCreditWeight, uint96 contextWeight) public {
        if (splitCreditWeight == 0) return;
        if (contextWeight == 0) return;

        // 721 hook returns weight == contextWeight (identity ratio) and a spec carrying splitCreditWeight in metadata.
        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        _hook721.setPay({weight: contextWeight, splitAmount: 0, splitCreditWeight: splitCreditWeight, returnSpec: true});

        // Extra hook participates in pay and returns weight 0 (no profitable swap), no specs.
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), true, false);
        _extraHook.setPay({weight: 0, splitAmount: 0, splitCreditWeight: 0, returnSpec: false});

        (uint256 weight,) = _deployer.beforePayRecordedWith(_payContext(contextWeight, 100));

        // Weight must fall back to the split-credit weight, not 0.
        assert(weight == splitCreditWeight);
    }

    /// @notice Proves the pay-time spec ordering: the 721 hook's single spec (when present) is always at index 0,
    /// followed by every extra-hook spec, with merged length `1 + extraSpecCount`.
    /// @dev The extra hook's spec count is fixed at 2 here (concrete) for the same NotConcreteError reason as the
    /// cash-out merge proof; the symbolic count sweep lives in the forge fuzz companion.
    function check_payMergeOrdersTiered721First() public {
        uint256 extraSpecCount = 2;

        _deployer.seedTiered721Hook(PROJECT_ID, RULESET_ID, IJB721TiersHook(address(_hook721)), false);
        // 721 hook returns a single spec with weight == context weight (identity ratio).
        _deployer.seedExtraHook(PROJECT_ID, RULESET_ID, IJBRulesetDataHook(address(_extraHook)), true, false);

        uint256 contextWeight = 1000;
        _hook721.setPay({weight: contextWeight, splitAmount: 0, splitCreditWeight: 0, returnSpec: true});
        _extraHook.setPay({
            weight: contextWeight, splitAmount: 0, splitCreditWeight: 0, returnSpecCount: extraSpecCount
        });

        (, JBPayHookSpecification[] memory specs) = _deployer.beforePayRecordedWith(_payContext(contextWeight, 100));

        // 1 (the 721 spec) + extraSpecCount.
        assert(specs.length == 1 + extraSpecCount);
        // 721 hook spec is first.
        assert(address(specs[0].hook) == address(_hook721));
        for (uint256 i; i < extraSpecCount; i++) {
            assert(address(specs[1 + i].hook) == address(_extraHook));
        }
    }

    //*********************************************************************//
    // -------------------------- onERC721Received ----------------------- //
    //*********************************************************************//

    /// @notice Proves the deployer accepts a project-NFT mint (`from == 0`) when the caller IS `PROJECTS`. The call is
    /// routed through the projects mock so `msg.sender == address(PROJECTS)` is genuinely satisfied.
    /// @param operator An arbitrary operator address (unused by the guard).
    /// @param tokenId An arbitrary token ID.
    function check_onERC721ReceivedAcceptsProjectsMint(address operator, uint256 tokenId) public view {
        bytes4 ret = MergeMockProjects(_projectsAddress)
            .callOnReceived({target: address(_deployer), operator: operator, from: address(0), tokenId: tokenId});
        assert(ret == bytes4(0x150b7a02)); // IERC721Receiver.onERC721Received.selector
    }

    /// @notice Proves the deployer reverts on any non-mint transfer (`from != 0`) even when the caller is `PROJECTS`.
    /// @param from A nonzero sender of the transfer.
    /// @param tokenId An arbitrary token ID.
    function check_onERC721ReceivedRejectsNonMint(address from, uint256 tokenId) public view {
        if (from == address(0)) return;
        try MergeMockProjects(_projectsAddress)
            .callOnReceived({target: address(_deployer), operator: address(9), from: from, tokenId: tokenId}) returns (
            bytes4
        ) {
            assert(false);
        } catch {}
    }

    /// @notice Proves the deployer reverts when the caller is not `PROJECTS`, even for a mint (`from == 0`). The proof
    /// caller is `address(this)`, which is not the deployer's immutable `PROJECTS`.
    /// @param tokenId An arbitrary token ID.
    function check_onERC721ReceivedRejectsNonProjectsSender(uint256 tokenId) public view {
        // `address(this)` (this proof contract) is not `PROJECTS`, so the deployer must reject the mint.
        try _deployer.onERC721Received(address(9), address(0), tokenId, "") returns (bytes4) {
            assert(false);
        } catch {}
    }

    //*********************************************************************//
    // --------------------- peerChainAdjustedAccountsOf ----------------- //
    //*********************************************************************//

    /// @notice Proves `peerChainAdjustedAccountsOf` returns `(0, empty)` when no extra hook is configured for the
    /// current ruleset (the fail-open default that prevents masking remote adjustments while never reverting).
    function check_peerChainAdjustedNoExtraHookReturnsEmpty() public {
        // No extra hook seeded for the current ruleset (controller reports RULESET_ID as current).
        // forge-lint: disable-next-line(unsafe-typecast)
        _controller.setCurrentRulesetId(uint48(RULESET_ID));

        (uint256 supply,) = _deployer.peerChainAdjustedAccountsOf(PROJECT_ID);
        assert(supply == 0);
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Builds a cash-out context for the proofs.
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

    /// @notice Builds a pay context for the proofs.
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

/// @notice Harness exposing internal helpers + seeders for the merge proofs.
contract MergeHarness is JBOmnichainDeployer {
    constructor(
        MergeMockSuckerRegistry suckerRegistry,
        MergeMockHookDeployer hookDeployer,
        MergeMockPermissions permissions,
        MergeMockController controller
    )
        JBOmnichainDeployer(
            IJBSuckerRegistry(address(suckerRegistry)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            IJBPermissions(address(permissions)),
            IJBController(address(controller)),
            address(0)
        )
    {}

    /// @notice Seeds the per-ruleset 721 hook config directly.
    function seedTiered721Hook(
        uint256 projectId,
        uint256 rulesetId,
        IJB721TiersHook hook,
        bool useForCashOut
    )
        external
    {
        _tiered721HookOf[projectId][rulesetId] =
            JBTiered721HookConfig({hook: hook, useDataHookForCashOut: useForCashOut});
    }

    /// @notice Seeds the per-ruleset extra hook config directly.
    function seedExtraHook(
        uint256 projectId,
        uint256 rulesetId,
        IJBRulesetDataHook hook,
        bool useForPay,
        bool useForCashOut
    )
        external
    {
        _extraDataHookOf[projectId][rulesetId] =
            JBDeployerHookConfig({dataHook: hook, useDataHookForPay: useForPay, useDataHookForCashOut: useForCashOut});
    }
}

/// @notice Mock `JBProjects`. Because this contract IS the deployer's immutable `PROJECTS`, routing `onERC721Received`
/// through `callOnReceived` makes `msg.sender == address(PROJECTS)` genuinely hold for the accept-case proof.
contract MergeMockProjects {
    function callOnReceived(
        address target,
        address operator,
        address from,
        uint256 tokenId
    )
        external
        view
        returns (bytes4)
    {
        return JBOmnichainDeployer(target).onERC721Received(operator, from, tokenId, "");
    }
}

/// @notice Controller mock for construction + current-ruleset reads.
contract MergeMockController {
    IJBDirectory public DIRECTORY;
    IJBProjects public PROJECTS;
    uint48 internal _currentRulesetId = 1;

    constructor(IJBDirectory directory, IJBProjects projects) {
        DIRECTORY = directory;
        PROJECTS = projects;
    }

    function setCurrentRulesetId(uint48 id) external {
        _currentRulesetId = id;
    }

    function currentRulesetOf(uint256)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset.id = _currentRulesetId;
        metadata.metadata = 0;
    }
}

/// @notice Directory mock.
contract MergeMockDirectory {
    mapping(uint256 => address) public controllerOfProject;

    function controllerOf(uint256 projectId) external view returns (address) {
        return controllerOfProject[projectId];
    }
}

/// @notice Permissions mock.
contract MergeMockPermissions {
    function setPermissionsFor(address, JBPermissionsData calldata) external pure {}
}

/// @notice Hook deployer mock.
contract MergeMockHookDeployer {
    function deployHookFor(
        uint256,
        JBDeploy721TiersHookConfig memory,
        bytes32
    )
        external
        pure
        returns (IJB721TiersHook hook)
    {
        return IJB721TiersHook(address(5));
    }
}

/// @notice Sucker registry mock — no suckers, zero remote state (so cross-chain denominators are local-only).
contract MergeMockSuckerRegistry {
    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function totalRemoteSurplusOf(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        pure
        returns (address[] memory)
    {
        return new address[](0);
    }
}

/// @notice Configurable data hook mock used for both 721 and extra hook roles in the composition proofs.
contract MergeMockDataHook {
    // Cash-out config.
    uint256 internal _coTax;
    uint256 internal _coCount;
    uint256 internal _coSupply;
    uint256 internal _coSurplus;
    uint256 internal _coSpecCount;
    bool internal _revertOnCashOut;

    // Pay config.
    uint256 internal _payWeight;
    uint256 internal _paySplitAmount;
    uint256 internal _paySplitCreditWeight;
    uint256 internal _paySpecCount;

    function setCashOut(uint256 taxRate, uint256 count, uint256 supply, uint256 surplus, uint256 specCount) external {
        _coTax = taxRate;
        _coCount = count;
        _coSupply = supply;
        _coSurplus = surplus;
        _coSpecCount = specCount;
    }

    function setRevertOnCashOut(bool flag) external {
        _revertOnCashOut = flag;
    }

    function setPay(uint256 weight, uint256 splitAmount, uint256 splitCreditWeight, bool returnSpec) external {
        _payWeight = weight;
        _paySplitAmount = splitAmount;
        _paySplitCreditWeight = splitCreditWeight;
        _paySpecCount = returnSpec ? 1 : 0;
    }

    function setPay(uint256 weight, uint256 splitAmount, uint256 splitCreditWeight, uint256 returnSpecCount) external {
        _payWeight = weight;
        _paySplitAmount = splitAmount;
        _paySplitCreditWeight = splitCreditWeight;
        _paySpecCount = returnSpecCount;
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        view
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        require(!_revertOnCashOut, "extra hook must not be called");
        hookSpecifications = new JBCashOutHookSpecification[](_coSpecCount);
        for (uint256 i; i < _coSpecCount; i++) {
            hookSpecifications[i] =
                JBCashOutHookSpecification({hook: IJBCashOutHook(address(this)), noop: false, amount: i, metadata: ""});
        }
        return (_coTax, _coCount, _coSupply, _coSurplus, hookSpecifications);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        hookSpecifications = new JBPayHookSpecification[](_paySpecCount);
        for (uint256 i; i < _paySpecCount; i++) {
            // The 721 hook's first spec carries (address, address, bytes, uint256 splitCreditWeight) metadata at
            // >=128B.
            bytes memory md = i == 0 ? abi.encode(address(0), address(0), bytes(""), _paySplitCreditWeight) : bytes("");
            hookSpecifications[i] = JBPayHookSpecification({
                hook: IJBPayHook(address(this)), noop: false, amount: _paySplitAmount, metadata: md
            });
        }
        return (_payWeight, hookSpecifications);
    }
}
