// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";

/// @notice Harness exposing the internal `_requireController` so tests can probe every cell of the 2x4 matrix
/// (allowUnset ∈ {true, false} × current ∈ {address(0), CONTROLLER, OTHER}).
contract _ReqCtrlHarness is JBOmnichainDeployer {
    constructor(
        IJBPermissions permissions,
        IJBController controller
    )
        JBOmnichainDeployer(
            IJBSuckerRegistry(address(0)), IJB721TiersHookDeployer(address(0)), permissions, controller, address(0)
        )
    {}

    function exposed_requireController(uint256 projectId, bool allowUnset) external view {
        _requireController({projectId: projectId, allowUnset: allowUnset});
    }
}

/// @notice Exhaustive coverage of `_requireController`'s 2x4 outcome matrix. Existing tests cover the
/// `allowUnset=true + OTHER -> revert` case (the easy-to-miss edge) only through the higher-level wrappers; this
/// file pins every cell directly. If `_requireController`'s semantics ever change (e.g. someone makes `allowUnset`
/// also permit OTHER, or accidentally returns silently on a CONTROLLER mismatch), one of these cells will flip.
contract RequireControllerMatrix is Test {
    _ReqCtrlHarness internal harness;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBController internal CONTROLLER = IJBController(makeAddr("canonicalController"));
    IJBController internal OTHER = IJBController(makeAddr("otherController"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));

    uint256 internal constant PROJECT_ID = 7;

    function setUp() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(address(CONTROLLER), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects));
        vm.mockCall(
            address(CONTROLLER), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );
        harness = new _ReqCtrlHarness(permissions, CONTROLLER);
    }

    function _setControllerOf(address current) internal {
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, PROJECT_ID),
            abi.encode(IERC165(current))
        );
    }

    // -- allowUnset = true --

    /// @notice allowUnset=true + current=address(0) -> silent return (fresh project pre-launch).
    function test_allowUnsetTrue_currentZero_silentReturn() public {
        _setControllerOf(address(0));
        harness.exposed_requireController(PROJECT_ID, true);
    }

    /// @notice allowUnset=true + current=CONTROLLER -> silent return (already canonical).
    function test_allowUnsetTrue_currentCanonical_silentReturn() public {
        _setControllerOf(address(CONTROLLER));
        harness.exposed_requireController(PROJECT_ID, true);
    }

    /// @notice allowUnset=true + current=OTHER -> reverts. The easy-to-miss cell.
    function test_allowUnsetTrue_currentOther_reverts() public {
        _setControllerOf(address(OTHER));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector,
                PROJECT_ID,
                address(CONTROLLER),
                address(OTHER)
            )
        );
        harness.exposed_requireController(PROJECT_ID, true);
    }

    // -- allowUnset = false --

    /// @notice allowUnset=false + current=address(0) -> reverts (post-launch must be canonical).
    function test_allowUnsetFalse_currentZero_reverts() public {
        _setControllerOf(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector,
                PROJECT_ID,
                address(CONTROLLER),
                address(0)
            )
        );
        harness.exposed_requireController(PROJECT_ID, false);
    }

    /// @notice allowUnset=false + current=CONTROLLER -> silent return (post-launch success).
    function test_allowUnsetFalse_currentCanonical_silentReturn() public {
        _setControllerOf(address(CONTROLLER));
        harness.exposed_requireController(PROJECT_ID, false);
    }

    /// @notice allowUnset=false + current=OTHER -> reverts.
    function test_allowUnsetFalse_currentOther_reverts() public {
        _setControllerOf(address(OTHER));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector,
                PROJECT_ID,
                address(CONTROLLER),
                address(OTHER)
            )
        );
        harness.exposed_requireController(PROJECT_ID, false);
    }
}
