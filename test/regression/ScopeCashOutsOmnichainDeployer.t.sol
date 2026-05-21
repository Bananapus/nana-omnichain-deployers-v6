// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";

/// @notice Minimal permissions mock for JBPermissioned.
contract OCDMockPermissions is IJBPermissions {
    // forge-lint: disable-next-line(mixed-case-function)
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return true;
    }
    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

/// @notice Regression test for `scopeCashOutsToLocalBalances` in JBOmnichainDeployer (Consumer 2).
/// @dev References TEST_IMPROVEMENT_PLAN.md Section 8.2, Consumer 2.
contract ScopeCashOutsOmnichainDeployerTest is Test {
    JBOmnichainDeployer deployer;

    address constant SUCKER_REGISTRY = address(0x3333);
    address constant HOOK_DEPLOYER = address(0x4444);
    address constant DIRECTORY = address(0x5555);
    address constant PROJECTS = address(0x6666);
    address constant CONTROLLER = address(0x6667);
    address constant HOLDER = address(0x7777);
    address constant TOKEN = address(0x8888);

    uint256 constant PROJECT_ID = 10;
    uint256 constant LOCAL_SUPPLY = 1000e18;
    uint256 constant LOCAL_SURPLUS = 50e18;
    uint256 constant REMOTE_SUPPLY = 500e18;
    uint256 constant REMOTE_SURPLUS = 25e18;
    uint256 constant CASH_OUT_TAX_RATE = 5000;

    function setUp() public {
        vm.etch(SUCKER_REGISTRY, hex"00");
        vm.etch(HOOK_DEPLOYER, hex"00");
        vm.etch(DIRECTORY, hex"00");
        vm.etch(PROJECTS, hex"00");
        vm.etch(CONTROLLER, hex"00");

        OCDMockPermissions permissions = new OCDMockPermissions();
        vm.mockCall(
            CONTROLLER, abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(IJBProjects(PROJECTS))
        );
        vm.mockCall(
            CONTROLLER, abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(IJBDirectory(DIRECTORY))
        );

        deployer = new JBOmnichainDeployer(
            IJBSuckerRegistry(SUCKER_REGISTRY),
            IJB721TiersHookDeployer(HOOK_DEPLOYER),
            permissions,
            IJBController(CONTROLLER),
            address(0)
        );

        // Holder is NOT a sucker
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (PROJECT_ID, HOLDER)), abi.encode(false)
        );

        // Remote values
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeCall(IJBSuckerRegistry.remoteTotalSupplyOf, (PROJECT_ID)),
            abi.encode(REMOTE_SUPPLY)
        );
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeCall(IJBSuckerRegistry.remoteSurplusOf, (PROJECT_ID, 18, uint256(1))),
            abi.encode(REMOTE_SURPLUS)
        );
    }

    function _buildContext(bool scopeToLocal) internal pure returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: address(0),
            holder: HOLDER,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: 100e18,
            totalSupply: LOCAL_SUPPLY,
            surplus: JBTokenAmount({token: TOKEN, decimals: 18, currency: 1, value: LOCAL_SURPLUS}),
            scopeCashOutsToLocalBalances: scopeToLocal,
            cashOutTaxRate: CASH_OUT_TAX_RATE,
            beneficiaryIsFeeless: false,
            metadata: bytes("")
        });
    }

    /// @notice scopeTrue: remote values excluded.
    function test_scopeTrue_excludesRemote() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContext(true);
        (,, uint256 totalSupply, uint256 surplus,) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(totalSupply, LOCAL_SUPPLY, "scopeTrue: totalSupply should be local-only");
        assertEq(surplus, LOCAL_SURPLUS, "scopeTrue: surplus should be local-only");
    }

    /// @notice scopeFalse: remote values included.
    function test_scopeFalse_includesRemote() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContext(false);
        (,, uint256 totalSupply, uint256 surplus,) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(totalSupply, LOCAL_SUPPLY + REMOTE_SUPPLY, "scopeFalse: totalSupply should include remote");
        assertEq(surplus, LOCAL_SURPLUS + REMOTE_SURPLUS, "scopeFalse: surplus should include remote");
    }

    /// @notice Sucker-exempt cash-outs always use local values regardless of flag.
    function test_suckerExempt_alwaysLocal() public {
        address sucker = address(0x9999);
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (PROJECT_ID, sucker)), abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = JBBeforeCashOutRecordedContext({
            terminal: address(0),
            holder: sucker,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: 100e18,
            totalSupply: LOCAL_SUPPLY,
            surplus: JBTokenAmount({token: TOKEN, decimals: 18, currency: 1, value: LOCAL_SURPLUS}),
            scopeCashOutsToLocalBalances: false, // even with false, sucker gets local
            cashOutTaxRate: CASH_OUT_TAX_RATE,
            beneficiaryIsFeeless: false,
            metadata: bytes("")
        });

        (uint256 taxRate,, uint256 totalSupply, uint256 surplus,) = deployer.beforeCashOutRecordedWith(ctx);

        assertEq(taxRate, 0, "sucker gets 0% cash-out tax");
        assertEq(totalSupply, LOCAL_SUPPLY, "sucker uses local-only supply");
        assertEq(surplus, LOCAL_SURPLUS, "sucker uses local-only surplus");
    }
}
