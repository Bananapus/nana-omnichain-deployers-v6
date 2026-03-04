// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script, stdJson, VmSafe} from "forge-std/Script.sol";

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";

import "src/JBOmnichainDeployer.sol";

contract Deploy is Script, Sphinx {
    bytes32 constant NANA_OMNICHAIN_DEPLOYER_SALT = "JBOmnichainDeployerV6_";

    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the deployment of the 721 hook contracts for the chain we are deploying to.
    Hook721Deployment hook;

    /// @notice tracks the deployment of the sucker contracts for the chain we are deploying to.
    SuckerDeployment suckers;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-omnichain-deployers-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        hook = Hook721DeploymentLib.getDeployment(
            vm.envOr("NANA_721_DEPLOYMENT_PATH", string("node_modules/@bananapus/721-hook-v6/deployments/"))
        );
        // Get the deployment addresses for the suckers contracts for this chain.
        suckers = SuckerDeploymentLib.getDeployment(
            vm.envOr("NANA_SUCKERS_DEPLOYMENT_PATH", string("node_modules/@bananapus/suckers-v6/deployments/"))
        );

        // Deploy the contracts.
        deploy();
    }

    function deploy() public sphinx {
        // Only deploy if this bytecode is not already deployed.
        if (!_isDeployed(
                NANA_OMNICHAIN_DEPLOYER_SALT,
                type(JBOmnichainDeployer).creationCode,
                abi.encode(
                    suckers.registry, hook.hook_deployer, core.permissions, core.projects, core.trustedForwarder
                )
            )) {
            new JBOmnichainDeployer{salt: NANA_OMNICHAIN_DEPLOYER_SALT}(
                suckers.registry, hook.hook_deployer, core.permissions, core.projects, core.trustedForwarder
            );
        }
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
