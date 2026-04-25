// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";

/// @notice PoC for cross-chain deterministic-address drift caused by hashing salts through the omnichain deployer.
contract CodexNemesisDeterministicDriftTest is Test {
    bytes32 internal constant DEPLOYER_SALT = bytes32("JBOmnichainDeployerV6_");

    function test_poc_deterministicAddressesDriftWhenDeployerAddressDiffers() external {
        // The deploy script uses the same salt everywhere, but constructor args come from chain-local deployments.
        address chainADeployer = _predictOmnichainDeployerAddress(
            address(0x1001), address(0x2001), address(0x3001), address(0x4001), address(0x5001)
        );
        address chainBDeployer = _predictOmnichainDeployerAddress(
            address(0x1002), address(0x2002), address(0x3002), address(0x4002), address(0x5002)
        );

        assertNotEq(chainADeployer, chainBDeployer, "constructor drift should change the deployer address");

        address sameUser = makeAddr("same-user");
        bytes32 userSalt = keccak256("same-cross-chain-salt");

        // JBOmnichainDeployer hashes the user salt once before forwarding it.
        bytes32 forwardedSalt = keccak256(abi.encode(sameUser, userSalt));

        // Both downstream factories hash again with msg.sender, which is the omnichain deployer contract.
        bytes32 hookSaltA = keccak256(abi.encode(chainADeployer, forwardedSalt));
        bytes32 hookSaltB = keccak256(abi.encode(chainBDeployer, forwardedSalt));
        bytes32 suckerSaltA = keccak256(abi.encode(chainADeployer, forwardedSalt));
        bytes32 suckerSaltB = keccak256(abi.encode(chainBDeployer, forwardedSalt));

        assertNotEq(hookSaltA, hookSaltB, "hook salt should drift with deployer address");
        assertNotEq(suckerSaltA, suckerSaltB, "sucker salt should drift with deployer address");

        // Even if the downstream factories and implementations were identical across chains, the final clone
        // addresses still diverge because the salt has already drifted.
        address sharedHookFactory = address(0x7001);
        address sharedHookImplementation = address(0x7101);
        address sharedSuckerDeployer = address(0x7201);
        address sharedSuckerImplementation = address(0x7301);

        address predictedHookA =
            LibClone.predictDeterministicAddress(sharedHookImplementation, hookSaltA, sharedHookFactory);
        address predictedHookB =
            LibClone.predictDeterministicAddress(sharedHookImplementation, hookSaltB, sharedHookFactory);
        address predictedSuckerA =
            LibClone.predictDeterministicAddress(sharedSuckerImplementation, suckerSaltA, sharedSuckerDeployer);
        address predictedSuckerB =
            LibClone.predictDeterministicAddress(sharedSuckerImplementation, suckerSaltB, sharedSuckerDeployer);

        assertNotEq(predictedHookA, predictedHookB, "721 hook address should not match across chains");
        assertNotEq(predictedSuckerA, predictedSuckerB, "sucker address should not match across chains");
    }

    function _predictOmnichainDeployerAddress(
        address suckerRegistry,
        address hookDeployer,
        address permissions,
        address projects,
        address trustedForwarder
    )
        internal
        view
        returns (address)
    {
        bytes memory creationCode = abi.encodePacked(
            type(JBOmnichainDeployer).creationCode,
            abi.encode(suckerRegistry, hookDeployer, permissions, projects, address(0), trustedForwarder)
        );

        // Sphinx deploys from its Safe; the exact deployer address is not important for the invariant.
        return vm.computeCreate2Address(DEPLOYER_SALT, keccak256(creationCode), address(0xBEEF));
    }
}
