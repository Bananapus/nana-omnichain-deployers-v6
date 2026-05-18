// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

contract CountingSuckerRegistry {
    uint256 public deployCalls;
    uint256 public lastProjectId;
    bytes32 public lastSalt;
    uint256 public lastConfigCount;

    function deploySuckersFor(
        uint256 projectId,
        bytes32 salt,
        JBSuckerDeployerConfig[] calldata configurations
    )
        external
        returns (address[] memory suckers)
    {
        deployCalls++;
        lastProjectId = projectId;
        lastSalt = salt;
        lastConfigCount = configurations.length;

        suckers = new address[](configurations.length);
        for (uint256 i; i < configurations.length; i++) {
            suckers[i] = 0x000000000000000000000000000000000000bEEF;
        }
    }
}

contract CodexNemesisZeroSaltSuckerSkipTest is Test {
    uint256 internal constant PROJECT_ID = 42;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer internal hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBController internal controller = IJBController(makeAddr("controller"));

    CountingSuckerRegistry internal registry;
    JBOmnichainDeployer internal deployer;

    address internal projectOwner = makeAddr("projectOwner");
    address internal hook = makeAddr("hook");

    function setUp() public {
        registry = new CountingSuckerRegistry();

        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(address(registry)), hookDeployer, permissions, projects, directory, address(0)
        );

        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(IJBProjects.createFor.selector, address(deployer)),
            abi.encode(PROJECT_ID)
        );
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256)"))),
            abi.encode()
        );

        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hook))
        );
        vm.mockCall(hook, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchRulesetsFor.selector),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    function test_launchProjectSkipsNonemptySuckerConfigWhenSaltIsZero() public {
        JBSuckerDeploymentConfig memory suckerConfig = _nonemptySuckerConfig(bytes32(0));

        (uint256 projectId,, address[] memory suckers) = deployer.launchProjectFor({
            owner: projectOwner,
            projectUri: "ipfs://project",
            deploy721Config: JBOmnichain721Config({
                deployTiersHookConfig: _empty721Config(), useDataHookForCashOut: false, salt: bytes32(0)
            }),
            rulesetConfigurations: _rulesetConfigurations(),
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: "launch",
            suckerDeploymentConfiguration: suckerConfig,
            controller: controller
        });

        assertEq(projectId, PROJECT_ID);
        assertEq(suckerConfig.deployerConfigurations.length, 1);
        assertEq(registry.deployCalls(), 0, "nonempty sucker config was not sent to the registry");
        assertEq(suckers.length, 0, "launch returned no suckers");
    }

    function test_standaloneDeploySuckersUsesSameZeroSaltConfig() public {
        JBSuckerDeploymentConfig memory suckerConfig = _nonemptySuckerConfig(bytes32(0));

        address[] memory suckers = deployer.deploySuckersFor(PROJECT_ID, suckerConfig);

        assertEq(registry.deployCalls(), 1);
        assertEq(registry.lastProjectId(), PROJECT_ID);
        assertEq(registry.lastSalt(), keccak256(abi.encode(bytes32(0), address(this))));
        assertEq(registry.lastConfigCount(), 1);
        assertEq(suckers.length, 1);
    }

    function _nonemptySuckerConfig(bytes32 salt) internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](1);
        config.salt = salt;
    }

    function _empty721Config() internal pure returns (JBDeploy721TiersHookConfig memory config) {}

    function _rulesetConfigurations() internal pure returns (JBRulesetConfig[] memory rulesetConfigurations) {
        rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
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
}
