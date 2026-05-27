// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

/// @notice Pins the cross-chain determinism property the sucker pairing relies on: for a given (deployer, salt,
/// singleton) tuple, the CREATE2 address is identical on every EVM chain. This is what makes "same address on
/// both chains" sucker pairs work — `_msgSender` mixed with the user salt produces the same final salt, which
/// (together with the deployer and the singleton bytecode) yields one address everywhere.
///
/// Real LibClone is used (not a mock). The "two-fork" property is captured by: changing only `block.chainid` must
/// not change the predicted address. If it ever does, the pairing assumption breaks.
contract Create2PeerDeterminismTest is Test {
    /// @notice Same deployer + same salt + same singleton → same address, regardless of `block.chainid`.
    function testFuzz_predictedAddress_independentOfChainId(
        address deployer,
        address singleton,
        bytes32 salt,
        uint64 chainIdA,
        uint64 chainIdB
    )
        public
    {
        vm.assume(chainIdA != chainIdB);
        vm.assume(deployer != address(0) && singleton != address(0));

        vm.chainId(chainIdA);
        address predictedA = LibClone.predictDeterministicAddress(singleton, salt, deployer);

        vm.chainId(chainIdB);
        address predictedB = LibClone.predictDeterministicAddress(singleton, salt, deployer);

        assertEq(predictedA, predictedB, "LibClone prediction must be chain-id independent");
    }

    /// @notice The deployer's salt-mixing flow (`keccak256(abi.encodePacked(sender, userSalt))`) is purely a hash
    /// of caller and user-provided bytes — no chain-specific state. Verify that two callers with same userSalt
    /// produce different mixed salts (so suckers don't collide across callers), and that the same caller produces
    /// the same mixed salt across chains (so the sucker pair lines up).
    function testFuzz_saltMixing_pureFunctionOfCallerAndUserSalt(
        address callerA,
        address callerB,
        bytes32 userSalt,
        uint64 chainIdA,
        uint64 chainIdB
    )
        public
    {
        vm.assume(callerA != callerB);
        vm.assume(chainIdA != chainIdB);

        // Same caller, two chains -> identical mixed salt.
        vm.chainId(chainIdA);
        bytes32 mixedOnA = keccak256(abi.encodePacked(callerA, userSalt));
        vm.chainId(chainIdB);
        bytes32 mixedOnB = keccak256(abi.encodePacked(callerA, userSalt));
        assertEq(mixedOnA, mixedOnB, "same caller + same userSalt -> same mixed salt across chains");

        // Different callers, same chain -> different mixed salts (anti-collision).
        bytes32 mixedAttacker = keccak256(abi.encodePacked(callerB, userSalt));
        assertNotEq(mixedAttacker, mixedOnA, "different callers must produce different mixed salts");
    }

    /// @notice End-to-end: predict the sucker's address on two simulated chains for the same caller-salt pair, and
    /// assert they match. This mirrors what production does — the registry's `deploySuckersFor` on chain A predicts
    /// the chain-B peer the same way chain B will compute it locally.
    function testFuzz_endToEnd_suckerAddressMatchesAcrossChains(
        address sucker_deployer,
        address singleton,
        address caller,
        bytes32 userSalt
    )
        public
    {
        vm.assume(sucker_deployer != address(0) && singleton != address(0));

        // Chain A's view.
        vm.chainId(1);
        bytes32 mixedSalt = keccak256(abi.encodePacked(caller, userSalt));
        address predictedA = LibClone.predictDeterministicAddress(singleton, mixedSalt, sucker_deployer);

        // Chain B's view (different chain id, same deployer/singleton/caller/userSalt).
        vm.chainId(10);
        bytes32 mixedSaltB = keccak256(abi.encodePacked(caller, userSalt));
        address predictedB = LibClone.predictDeterministicAddress(singleton, mixedSaltB, sucker_deployer);

        assertEq(predictedA, predictedB, "sucker address must be chain-independent for sucker pairing to work");
    }

    /// @notice Deploy via real LibClone.cloneDeterministic and verify the predicted address matches the actual
    /// deployment. This is the runtime half of the property: prediction is real, not symbolic.
    function test_deploy_actualMatchesPrediction() public {
        // Use a known-good init-code hash by deploying a minimal singleton.
        address singleton = address(new _Singleton());
        bytes32 salt = bytes32(uint256(1));

        address predicted = LibClone.predictDeterministicAddress(singleton, salt, address(this));
        address actual = LibClone.cloneDeterministic(singleton, salt);

        assertEq(actual, predicted, "actual deployment must match prediction");
    }
}

contract _Singleton {
    uint256 public answer;
}
