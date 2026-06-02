// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

contract ExplicitPeerPermissionBypassTest is TestBaseWorkflow {
    JBSuckerRegistry internal registry;
    JBOmnichainDeployer internal deployer;
    FakeSuckerDeployer internal fakeSuckerDeployer;

    address internal projectOwner = makeAddr("projectOwner");
    address internal deployOperator = makeAddr("deployOperator");
    uint256 internal projectId;

    function setUp() public override {
        super.setUp();

        registry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), jbPrices(), address(this), address(0));
        fakeSuckerDeployer = new FakeSuckerDeployer(jbDirectory());
        registry.allowSuckerDeployer(address(fakeSuckerDeployer));

        deployer = new JBOmnichainDeployer(
            registry,
            IJB721TiersHookDeployer(address(0)),
            jbPermissions(),
            IJBController(address(jbController())),
            address(0)
        );

        projectId = jbProjects().createFor(projectOwner);
    }

    function test_wrapperRequiresSetSuckerPeerForExplicitPeer() public {
        bytes32 explicitPeer = bytes32(uint256(0xBEEF));
        JBSuckerDeployerConfig[] memory configs = _explicitPeerConfig(explicitPeer);

        _grant(projectOwner, deployOperator, _one(JBPermissionIds.DEPLOY_SUCKERS));
        _grant(projectOwner, address(deployer), _two(JBPermissionIds.DEPLOY_SUCKERS, JBPermissionIds.SET_SUCKER_PEER));

        vm.prank(deployOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                deployOperator,
                projectId,
                JBPermissionIds.SET_SUCKER_PEER
            )
        );
        deployer.deploySuckersFor(
            projectId,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBSuckerDeploymentConfig({deployerConfigurations: configs, salt: bytes32("salt")})
        );

        _grant(projectOwner, deployOperator, _two(JBPermissionIds.DEPLOY_SUCKERS, JBPermissionIds.SET_SUCKER_PEER));

        vm.prank(deployOperator);
        address[] memory suckers = deployer.deploySuckersFor(
            projectId,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBSuckerDeploymentConfig({deployerConfigurations: configs, salt: bytes32("salt")})
        );

        assertEq(suckers.length, 1);
        assertTrue(registry.isSuckerOf(projectId, suckers[0]));
        assertEq(FakeSucker(suckers[0]).peer(), explicitPeer);
    }

    function test_wrapperAllowsDeployOnlyOperatorForDefaultPeer() public {
        JBSuckerDeployerConfig[] memory configs = _explicitPeerConfig(bytes32(0));

        _grant(projectOwner, deployOperator, _one(JBPermissionIds.DEPLOY_SUCKERS));
        _grant(projectOwner, address(deployer), _one(JBPermissionIds.DEPLOY_SUCKERS));

        vm.prank(deployOperator);
        address[] memory suckers = deployer.deploySuckersFor(
            projectId,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBSuckerDeploymentConfig({deployerConfigurations: configs, salt: bytes32("default")})
        );

        assertEq(suckers.length, 1);
        assertTrue(registry.isSuckerOf(projectId, suckers[0]));
        assertEq(FakeSucker(suckers[0]).peer(), bytes32(0));
    }

    function test_wrapperRequiresSetSuckerPeerForRegistryAddressPeer() public {
        bytes32 registryPeer = bytes32(uint256(uint160(address(registry))));
        JBSuckerDeployerConfig[] memory configs = _explicitPeerConfig(registryPeer);

        _grant(projectOwner, deployOperator, _one(JBPermissionIds.DEPLOY_SUCKERS));
        _grant(projectOwner, address(deployer), _two(JBPermissionIds.DEPLOY_SUCKERS, JBPermissionIds.SET_SUCKER_PEER));

        vm.prank(deployOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                deployOperator,
                projectId,
                JBPermissionIds.SET_SUCKER_PEER
            )
        );
        deployer.deploySuckersFor(
            projectId,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBSuckerDeploymentConfig({deployerConfigurations: configs, salt: bytes32("registry-peer")})
        );
    }

    function _explicitPeerConfig(bytes32 explicitPeer) internal view returns (JBSuckerDeployerConfig[] memory configs) {
        configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({
            deployer: IJBSuckerDeployer(address(fakeSuckerDeployer)),
            peer: explicitPeer,
            mappings: new JBTokenMapping[](0)
        });
    }

    function _grant(address account, address operator, uint8[] memory permissionIds) internal {
        vm.prank(account);
        jbPermissions()
            .setPermissionsFor(
                account,
                // forge-lint: disable-next-line(unsafe-typecast)
                JBPermissionsData({operator: operator, projectId: uint64(projectId), permissionIds: permissionIds})
            );
    }

    function _one(uint8 a) internal pure returns (uint8[] memory permissionIds) {
        permissionIds = new uint8[](1);
        permissionIds[0] = a;
    }

    function _two(uint8 a, uint8 b) internal pure returns (uint8[] memory permissionIds) {
        permissionIds = new uint8[](2);
        permissionIds[0] = a;
        permissionIds[1] = b;
    }
}

contract FakeSuckerDeployer is IJBSuckerDeployer {
    IJBDirectory public immutable override DIRECTORY;
    address public immutable override LAYER_SPECIFIC_CONFIGURATOR = address(0);
    IJBTokens public immutable override TOKENS = IJBTokens(address(0));

    mapping(address => bool) public override isSucker;

    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
    }

    function createForSender(uint256, bytes32, bytes32 peer) external override returns (IJBSucker sucker) {
        FakeSucker newSucker = new FakeSucker(peer);
        isSucker[address(newSucker)] = true;
        return IJBSucker(address(newSucker));
    }
}

    contract FakeSucker {
        bytes32 public immutable peer;

        constructor(bytes32 peer_) {
            peer = peer_;
        }

        function peerChainId() external pure returns (uint256) {
            return 1;
        }

        function mapTokens(JBTokenMapping[] calldata) external payable {}
    }
