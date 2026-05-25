// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/Sphinx.sol";
import {Script} from "forge-std/Script.sol";

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {Hook721Deployment, Hook721DeploymentLib} from "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import {SuckerDeployment, SuckerDeploymentLib} from "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";

import {JBOmnichainDeployer} from "src/JBOmnichainDeployer.sol";

contract Deploy is Script, Sphinx {
    bytes32 constant NANA_OMNICHAIN_DEPLOYER_SALT = "JBOmnichainDeployerV6_";

    /// @notice Tracks the core deployment for the current chain.
    CoreDeployment core;

    /// @notice Tracks the 721 hook deployment for the current chain.
    Hook721Deployment hook;

    /// @notice Tracks the sucker deployment for the current chain.
    SuckerDeployment suckers;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-omnichain-deployers-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the core deployment addresses for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@bananapus/core-v6/deployments/")
            })
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        hook = Hook721DeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_721_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/721-hook-v6/deployments/")
            })
        );
        // Get the deployment addresses for the suckers contracts for this chain.
        suckers = SuckerDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_SUCKERS_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/suckers-v6/deployments/")
            })
        );

        // Deploy the contracts.
        deploy();
    }

    function deploy() public sphinx {
        // Only deploy if this bytecode is not already deployed.
        if (!_isDeployed({
                salt: NANA_OMNICHAIN_DEPLOYER_SALT,
                creationCode: type(JBOmnichainDeployer).creationCode,
                arguments: abi.encode(
                    suckers.registry, hook.hookDeployer, core.permissions, core.controller, core.trustedForwarder
                ),
                deployer: safeAddress()
            })) {
            new JBOmnichainDeployer{salt: NANA_OMNICHAIN_DEPLOYER_SALT}({
                suckerRegistry: suckers.registry,
                hookDeployer: hook.hookDeployer,
                permissions: core.permissions,
                controller: core.controller,
                trustedForwarder: core.trustedForwarder
            });
        }
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments,
        address deployer
    )
        internal
        view
        returns (bool)
    {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt, initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)), deployer: deployer
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
