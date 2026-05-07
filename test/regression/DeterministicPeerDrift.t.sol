// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract DeterministicPeerDriftTest is Test {
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant USER_SALT = bytes32("regression-peer-drift");

    address internal constant USER = address(0x1111111111111111111111111111111111111111);
    address internal constant OMNICHAIN_DEPLOYER_A = address(0x2222222222222222222222222222222222222222);
    address internal constant OMNICHAIN_DEPLOYER_B = address(0x3333333333333333333333333333333333333333);
    address internal constant REGISTRY_A = address(0x4444444444444444444444444444444444444444);
    address internal constant REGISTRY_B = address(0x5555555555555555555555555555555555555555);
    address internal constant SUCKER_DEPLOYER = address(0x6666666666666666666666666666666666666666);
    address internal constant SINGLETON = address(0x7777777777777777777777777777777777777777);

    function test_sameUserSameExplicitSalt_butDifferentOmnichainDeployer_breaksPeerSymmetry() public pure {
        address predictedA = _predictedSuckerAddress({
            user: USER,
            deployer: OMNICHAIN_DEPLOYER_A,
            registry: REGISTRY_A,
            suckerDeployer: SUCKER_DEPLOYER,
            singleton: SINGLETON,
            userSalt: USER_SALT
        });

        address predictedB = _predictedSuckerAddress({
            user: USER,
            deployer: OMNICHAIN_DEPLOYER_B,
            registry: REGISTRY_A,
            suckerDeployer: SUCKER_DEPLOYER,
            singleton: SINGLETON,
            userSalt: USER_SALT
        });

        assertNotEq(predictedA, predictedB, "peer addresses must differ when omnichain deployer differs");
    }

    function test_sameUserSameExplicitSalt_butDifferentRegistry_breaksPeerSymmetry() public pure {
        address predictedA = _predictedSuckerAddress({
            user: USER,
            deployer: OMNICHAIN_DEPLOYER_A,
            registry: REGISTRY_A,
            suckerDeployer: SUCKER_DEPLOYER,
            singleton: SINGLETON,
            userSalt: USER_SALT
        });

        address predictedB = _predictedSuckerAddress({
            user: USER,
            deployer: OMNICHAIN_DEPLOYER_A,
            registry: REGISTRY_B,
            suckerDeployer: SUCKER_DEPLOYER,
            singleton: SINGLETON,
            userSalt: USER_SALT
        });

        assertNotEq(predictedA, predictedB, "peer addresses must differ when registry differs");
    }

    function _predictedSuckerAddress(
        address user,
        address deployer,
        address registry,
        address suckerDeployer,
        address singleton,
        bytes32 userSalt
    )
        internal
        pure
        returns (address)
    {
        bytes32 deployerSalt = keccak256(abi.encode(userSalt, user));
        bytes32 registrySalt = keccak256(abi.encode(deployer, deployerSalt));
        bytes32 finalSalt = keccak256(abi.encodePacked(registry, registrySalt));
        return LibClone.predictDeterministicAddress(singleton, finalSalt, suckerDeployer);
    }
}
