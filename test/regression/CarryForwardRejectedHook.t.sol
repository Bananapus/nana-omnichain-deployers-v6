// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBApprovalStatus} from "@bananapus/core-v6/src/enums/JBApprovalStatus.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBChainAccounting} from "@bananapus/suckers-v6/src/structs/JBChainAccounting.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "@bananapus/suckers-v6/src/structs/JBSuckersPair.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

contract RejectingApprovalHook is ERC165, IJBRulesetApprovalHook {
    // forge-lint: disable-next-line(mixed-case-function)
    function DURATION() external pure override returns (uint256) {
        return 0;
    }

    function approvalStatusOf(uint256, JBRuleset calldata) external pure override returns (JBApprovalStatus) {
        return JBApprovalStatus.Failed;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract HookStub {
    uint256 public lastProjectId;

    function transferOwnershipToProject(uint256 projectId) external {
        lastProjectId = projectId;
    }
}

contract SequentialHookDeployer is IJB721TiersHookDeployer {
    HookStub[] internal _hooks;
    uint256 internal _index;

    constructor(HookStub[] memory hooks) {
        _hooks = hooks;
    }

    function deployHookFor(
        uint256,
        JBDeploy721TiersHookConfig calldata,
        bytes32
    )
        external
        override
        returns (IJB721TiersHook)
    {
        return IJB721TiersHook(address(_hooks[_index++]));
    }
}

contract MockSuckerRegistryCarryForward is IJBSuckerRegistry {
    // forge-lint: disable-next-line(mixed-case-function)
    function DIRECTORY() external pure override returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function PROJECTS() external pure override returns (IJBProjects) {
        return IJBProjects(address(0));
    }

    function isSuckerOf(uint256, address) external pure override returns (bool) {
        return false;
    }

    function suckerDeployerIsAllowed(address) external pure override returns (bool) {
        return false;
    }

    function suckerPairsOf(uint256) external pure override returns (JBSuckersPair[] memory) {
        return new JBSuckersPair[](0);
    }

    function suckersOf(uint256) external pure override returns (address[] memory) {
        return new address[](0);
    }

    function allSuckersOf(uint256) external pure override returns (address[] memory) {
        return new address[](0);
    }

    function peerChainAccountsOf(uint256, uint256) external pure override returns (JBChainAccounting[] memory) {
        return new JBChainAccounting[](0);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function MAX_TO_REMOTE_FEE() external pure override returns (uint256) {
        return 0;
    }

    function toRemoteFee() external pure override returns (uint256) {
        return 0;
    }

    function setToRemoteFee(uint256) external override {}
    function allowSuckerDeployer(address) external override {}
    function allowSuckerDeployers(address[] calldata) external override {}

    function tokenMappingIsAllowed(address, uint256, bytes32) external pure override returns (bool) {
        return true;
    }

    function requireTokenMappingAllowed(address, uint256, bytes32) external pure override {}
    function allowTokenMapping(address, uint256, bytes32) external override {}
    function allowTokenMappings(address[] calldata, uint256[] calldata, bytes32[] calldata) external override {}
    function removeTokenMapping(address, uint256, bytes32) external override {}
    function removeTokenMappings(address[] calldata, uint256[] calldata, bytes32[] calldata) external override {}

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] memory
    )
        external
        pure
        override
        returns (address[] memory)
    {
        return new address[](0);
    }

    function remoteTotalSupplyOf(uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalRemoteBalanceOf(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalRemoteSurplusOf(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function removeDeprecatedSucker(uint256, address) external override {}
    function removeSuckerDeployer(address) external override {}
}

contract CarryForwardRejectedHookTest is TestBaseWorkflow {
    JBOmnichainDeployer internal deployer;
    RejectingApprovalHook internal rejectHook;
    SequentialHookDeployer internal hookDeployer;
    HookStub internal initialHook;
    HookStub internal rejectedHook;
    MockSuckerRegistryCarryForward internal suckerRegistry;

    address internal owner;

    function setUp() public override {
        super.setUp();

        owner = multisig();
        rejectHook = new RejectingApprovalHook();
        initialHook = new HookStub();
        rejectedHook = new HookStub();
        HookStub[] memory hooks = new HookStub[](2);
        hooks[0] = initialHook;
        hooks[1] = rejectedHook;
        hookDeployer = new SequentialHookDeployer(hooks);
        suckerRegistry = new MockSuckerRegistryCarryForward();

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(address(suckerRegistry)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            IJBPermissions(address(jbPermissions())),
            IJBController(address(jbController())),
            trustedForwarder()
        );

        vm.prank(multisig());
        jbDirectory().setIsAllowedToSetFirstController(address(deployer), true);
    }

    function test_queueCarryForward_usesRejectedRulesetHook_notCurrentRulesetHook() public {
        JBRulesetConfig[] memory initialRulesets = _makeRulesets(rejectHook);
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);
        JBOmnichain721Config memory configWithTiers = _configWithTiers(false);

        (uint256 projectId, IJB721TiersHook launchedHook,) = deployer.launchProjectFor(
            owner, "ipfs://project", configWithTiers, initialRulesets, terminals, "launch", _emptySuckerConfig()
        );
        uint256 initialRulesetId = jbRulesets().latestRulesetIdOf(projectId);

        assertEq(address(launchedHook), address(initialHook), "launch should use the first hook");

        _grantQueuePermissions(projectId);

        vm.warp(block.timestamp + 1);

        JBOmnichain721Config memory rejectedConfig = _configWithTiers(true);
        (uint256 rejectedRulesetId,) = deployer.queueRulesetsOf(
            projectId, rejectedConfig, _makeRulesets(IJBRulesetApprovalHook(address(0))), "rejected"
        );

        JBRuleset memory currentRuleset = jbRulesets().currentOf(projectId);
        assertEq(currentRuleset.id, initialRulesetId, "core should still use the last approved ruleset");

        vm.warp(block.timestamp + 2);

        (uint256 carriedRulesetId,) = deployer.queueRulesetsOf(
            projectId, _default721Config(), _makeRulesets(IJBRulesetApprovalHook(address(0))), "carry"
        );

        (IJB721TiersHook carriedHook, bool carriedCashOutFlag) = deployer.tiered721HookOf(projectId, carriedRulesetId);
        (IJB721TiersHook currentHook, bool currentCashOutFlag) = deployer.tiered721HookOf(projectId, initialRulesetId);
        (IJB721TiersHook rejectedStoredHook, bool rejectedCashOutFlag) =
            deployer.tiered721HookOf(projectId, rejectedRulesetId);

        assertEq(address(currentHook), address(initialHook), "approved ruleset should point to the initial hook");
        assertFalse(currentCashOutFlag, "approved ruleset should preserve its original cash-out flag");

        assertEq(address(rejectedStoredHook), address(rejectedHook), "rejected ruleset should store the second hook");
        assertTrue(rejectedCashOutFlag, "rejected ruleset should store the second cash-out flag");

        // The carry-forward uses currentOf (the approved ruleset), not the rejected queued one.
        assertEq(
            address(carriedHook),
            address(initialHook),
            "carry-forward should inherit the current (approved) hook, not the rejected one"
        );
        assertFalse(carriedCashOutFlag, "carry-forward should inherit the current (approved) cash-out flag");
    }

    function _configWithTiers(bool useDataHookForCashOut) internal pure returns (JBOmnichain721Config memory config) {
        config = _default721Config();
        config.useDataHookForCashOut = useDataHookForCashOut;
        config.deployTiersHookConfig.tiersConfig.tiers = new JB721TierConfig[](1);
        config.deployTiersHookConfig.tiersConfig.tiers[0].price = 1 ether;
        config.deployTiersHookConfig.tiersConfig.tiers[0].initialSupply = 10;
    }

    function _default721Config() internal pure returns (JBOmnichain721Config memory config) {
        config.deployTiersHookConfig.tiersConfig.currency =
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32(uint160(address(0x000000000000000000000000000000000000EEEe)));
        config.deployTiersHookConfig.tiersConfig.decimals = 18;
    }

    function _makeRulesets(IJBRulesetApprovalHook approvalHook)
        internal
        pure
        returns (JBRulesetConfig[] memory configs)
    {
        configs = new JBRulesetConfig[](1);
        configs[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: uint112(1e18),
            weightCutPercent: uint32(0),
            approvalHook: approvalHook,
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                // forge-lint: disable-next-line(unsafe-typecast)
                baseCurrency: uint32(uint160(address(0x000000000000000000000000000000000000EEEe))),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetController: false,
                allowSetTerminals: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory) {
        return JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
    }

    function _grantQueuePermissions(uint256 projectId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.QUEUE_RULESETS;

        vm.prank(owner);
        jbPermissions()
            .setPermissionsFor(
                owner,
                // forge-lint: disable-next-line(unsafe-typecast)
                JBPermissionsData({operator: address(this), projectId: uint64(projectId), permissionIds: permissionIds})
            );

        vm.prank(owner);
        jbPermissions()
            .setPermissionsFor(
                owner,
                JBPermissionsData({
                operator: address(deployer),
                // forge-lint: disable-next-line(unsafe-typecast)
                projectId: uint64(projectId),
                permissionIds: permissionIds
            })
            );
    }
}
