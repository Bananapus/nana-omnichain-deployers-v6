// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IJBPeerChainAdjustedAccounts} from "@bananapus/suckers-v6/src/interfaces/IJBPeerChainAdjustedAccounts.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSourceContext} from "@bananapus/suckers-v6/src/structs/JBSourceContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../../src/structs/JBDeployerHookConfig.sol";

contract PeerAdjustmentForwardingTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint48 internal constant RULESET_ID = 123;

    function test_wrapperForwardsPeerChainAdjustedAccounts() external {
        MockDirectory directory = new MockDirectory();
        MockController controller =
            new MockController({rulesetId: RULESET_ID, directory: IJBDirectory(address(directory))});
        directory.setControllerOf(PROJECT_ID, address(controller));

        Harness deployer =
            new Harness(IJBPermissions(address(new MockPermissions())), IJBController(address(controller)));
        ExtraPeerAccountingHook extraHook = new ExtraPeerAccountingHook();

        deployer.setExtraDataHookOf({
            projectId: PROJECT_ID,
            rulesetId: RULESET_ID,
            config: JBDeployerHookConfig({
                dataHook: IJBRulesetDataHook(address(extraHook)), useDataHookForPay: true, useDataHookForCashOut: true
            })
        });

        // Direct call to extra hook returns expected values.
        (uint256 directSupply, JBSourceContext[] memory directContexts) =
            extraHook.peerChainAdjustedAccountsOf(PROJECT_ID);
        assertEq(directSupply, 1000 ether);
        assertEq(directContexts.length, 1);
        assertEq(uint256(directContexts[0].surplus), 100 ether);
        assertEq(uint256(directContexts[0].balance), 100 ether);

        // The deployer forwards the call to the extra hook.
        (bool success, bytes memory data) = address(deployer)
            .staticcall(abi.encodeCall(IJBPeerChainAdjustedAccounts.peerChainAdjustedAccountsOf, (PROJECT_ID)));

        assertTrue(success, "wrapper forwards peer-accounting calls to stored extra hook");
        (uint256 supply, JBSourceContext[] memory contexts) = abi.decode(data, (uint256, JBSourceContext[]));
        assertEq(supply, 1000 ether, "forwarded supply matches extra hook");
        assertEq(contexts.length, 1, "forwarded contexts match extra hook");
        assertEq(uint256(contexts[0].surplus), 100 ether, "forwarded surplus matches extra hook");
        assertEq(uint256(contexts[0].balance), 100 ether, "forwarded balance matches extra hook");

        // With correct forwarding, reclaim uses global values — no over-reclaim.
        uint256 correctReclaim = JBCashOuts.cashOutFrom({
            surplus: 200 ether, cashOutCount: 100 ether, totalSupply: 1100 ether, cashOutTaxRate: 0
        });

        assertEq(correctReclaim, 18.181_818_181_818_181_818 ether, "reclaim uses global supply+surplus");
    }

    function test_noExtraHook_returnsZero() external {
        MockDirectory directory = new MockDirectory();
        MockController controller =
            new MockController({rulesetId: RULESET_ID, directory: IJBDirectory(address(directory))});
        directory.setControllerOf(PROJECT_ID, address(controller));

        Harness deployer =
            new Harness(IJBPermissions(address(new MockPermissions())), IJBController(address(controller)));

        // No extra hook set — should return zero supply and no contexts.
        (uint256 supply, JBSourceContext[] memory contexts) = deployer.peerChainAdjustedAccountsOf(PROJECT_ID);
        assertEq(supply, 0);
        assertEq(contexts.length, 0);
    }
}

contract Harness is JBOmnichainDeployer {
    constructor(
        IJBPermissions permissions,
        IJBController controller
    )
        JBOmnichainDeployer(
            IJBSuckerRegistry(address(0)), IJB721TiersHookDeployer(address(0)), permissions, controller, address(0)
        )
    {}

    function setExtraDataHookOf(uint256 projectId, uint256 rulesetId, JBDeployerHookConfig memory config) external {
        _extraDataHookOf[projectId][rulesetId] = config;
    }
}

contract MockPermissions {
    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract MockDirectory {
    mapping(uint256 => address) internal _controllers;

    function setControllerOf(uint256 projectId, address controller) external {
        _controllers[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (IERC165) {
        return IERC165(_controllers[projectId]);
    }
}

contract MockController {
    IJBProjects public immutable PROJECTS = IJBProjects(address(0));
    IJBDirectory public immutable DIRECTORY;

    uint48 internal _rulesetId;

    constructor(uint48 rulesetId, IJBDirectory directory) {
        _rulesetId = rulesetId;
        DIRECTORY = directory;
    }

    function currentRulesetOf(uint256)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset.id = _rulesetId;
        metadata.reservedPercent = 0;
    }
}

contract ExtraPeerAccountingHook is IJBRulesetDataHook, IJBPeerChainAdjustedAccounts {
    address internal constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    function peerChainAdjustedAccountsOf(uint256)
        external
        pure
        returns (uint256 supply, JBSourceContext[] memory contexts)
    {
        contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(TOKEN))), decimals: 18, surplus: 100 ether, balance: 100 ether
        });
        return (1000 ether, contexts);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return (
            context.cashOutTaxRate, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications
        );
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (context.weight, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPeerChainAdjustedAccounts).interfaceId;
    }
}
