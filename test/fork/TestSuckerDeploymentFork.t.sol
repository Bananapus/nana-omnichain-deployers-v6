// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OmnichainForkTestBase} from "./OmnichainForkTestBase.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {JBOptimismSuckerDeployer} from "@bananapus/suckers-v6/src/deployers/JBOptimismSuckerDeployer.sol";
import {JBOptimismSucker} from "@bananapus/suckers-v6/src/JBOptimismSucker.sol";
import {IOPMessenger} from "@bananapus/suckers-v6/src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "@bananapus/suckers-v6/src/interfaces/IOPStandardBridge.sol";

import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {JBRemoteToken} from "@bananapus/suckers-v6/src/structs/JBRemoteToken.sol";

import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

/// @notice Fork tests verifying real sucker deployment through JBOmnichainDeployer.
///
/// Unlike TestOmnichainCashOutFork which uses vm.mockCall for the sucker registry,
/// these tests deploy real suckers via the OP sucker deployer on a mainnet fork.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestSuckerDeploymentFork -vvv
contract TestSuckerDeploymentFork is OmnichainForkTestBase {
    // ── Mainnet Optimism L1 addresses
    IOPMessenger constant L1_OP_MESSENGER = IOPMessenger(0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1);
    IOPStandardBridge constant L1_OP_BRIDGE = IOPStandardBridge(0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1);

    // ── Sucker deployer state
    JBOptimismSuckerDeployer opSuckerDeployer;

    function setUp() public override {
        super.setUp();

        // Deploy the OP sucker deployer. Use address(this) as configurator.
        opSuckerDeployer =
            new JBOptimismSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));

        // Set the chain-specific constants (L1 Optimism messenger and bridge).
        opSuckerDeployer.setChainSpecificConstants(L1_OP_MESSENGER, L1_OP_BRIDGE);

        // Deploy the singleton and configure it on the deployer.
        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: opSuckerDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: jbPrices(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: suckerRegistry,
            trustedForwarder: address(0)
        });
        opSuckerDeployer.configureSingleton(singleton);

        // Allowlist the deployer in the sucker registry.
        vm.prank(multisig());
        suckerRegistry.allowSuckerDeployer(address(opSuckerDeployer));
    }

    // ── Helpers ──

    /// @notice Build a sucker deployment config with a single OP deployer and NATIVE_TOKEN mapping.
    function _buildSuckerDeploymentConfig() internal view returns (JBSuckerDeploymentConfig memory) {
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory deployerConfigs = new JBSuckerDeployerConfig[](1);
        deployerConfigs[0] = JBSuckerDeployerConfig({
            deployer: IJBSuckerDeployer(address(opSuckerDeployer)), peer: bytes32(0), mappings: mappings
        });

        return JBSuckerDeploymentConfig({
            deployerConfigurations: deployerConfigs,
            // forge-lint: disable-next-line(unsafe-typecast)
            salt: bytes32("TEST_SUCKER_SALT")
        });
    }

    /// @notice Deploy a plain project (no 721 hook) with real suckers attached.
    /// @return projectId The deployed project ID.
    /// @return suckers The deployed sucker addresses.
    function _deployWithSuckers(uint16 cashOutTaxRate) internal returns (uint256 projectId, address[] memory suckers) {
        (JBRulesetConfig[] memory rulesets, JBTerminalConfig[] memory tc,) = _buildLaunchConfig(cashOutTaxRate);

        JBSuckerDeploymentConfig memory suckerConfig = _buildSuckerDeploymentConfig();

        (projectId,, suckers) = omnichainDeployer.launchProjectFor({
            owner: multisig(),
            projectUri: "ipfs://sucker-deploy-test",
            rulesetConfigurations: rulesets,
            terminalConfigurations: tc,
            memo: "sucker deployment fork test",
            suckerDeploymentConfiguration: suckerConfig,
            controller: IJBController(address(jbController()))
        });
    }

    // ── Tests ──

    /// @notice Deploy a project with real OP suckers and verify they are registered in the sucker registry.
    function testFork_SuckerDeploymentRegistersInRegistry() public {
        (uint256 projectId, address[] memory suckers) = _deployWithSuckers(5000);

        // Should have deployed exactly one sucker.
        assertEq(suckers.length, 1, "should deploy one sucker");
        address suckerAddr = suckers[0];
        assertTrue(suckerAddr != address(0), "sucker address should be non-zero");

        // Verify the registry returns this sucker for the project.
        address[] memory registeredSuckers = suckerRegistry.suckersOf(projectId);
        assertEq(registeredSuckers.length, 1, "registry should have one sucker for project");
        assertEq(registeredSuckers[0], suckerAddr, "registered sucker should match deployed sucker");

        // Verify isSuckerOf returns true.
        assertTrue(
            suckerRegistry.isSuckerOf(projectId, suckerAddr), "isSuckerOf should return true for deployed sucker"
        );

        // Sanity: isSuckerOf should return false for a random address.
        assertFalse(
            suckerRegistry.isSuckerOf(projectId, makeAddr("notASucker")),
            "isSuckerOf should return false for random address"
        );
    }

    /// @notice After deploying with real suckers, the omnichain deployer returns 0% cashout tax for the sucker address.
    function testFork_SuckerGetsZeroCashoutTax() public {
        (uint256 projectId, address[] memory suckers) = _deployWithSuckers(5000);
        address suckerAddr = suckers[0];

        // Pay the project to create surplus.
        vm.prank(payer);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 surplus = _terminalBalance(projectId, JBConstants.NATIVE_TOKEN);
        assertGt(totalSupply, 0, "should have tokens after payment");
        assertGt(surplus, 0, "should have surplus after payment");

        // Get the current ruleset ID.
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(projectId);

        // Construct a JBBeforeCashOutRecordedContext as if the sucker is cashing out.
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: suckerAddr,
            projectId: projectId,
            rulesetId: ruleset.id,
            cashOutCount: totalSupply / 2,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: surplus
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000, // 50% tax from ruleset
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        // Call beforeCashOutRecordedWith directly on the omnichain deployer.
        (uint256 returnedTaxRate, uint256 returnedCashOutCount, uint256 returnedTotalSupply,,) =
            omnichainDeployer.beforeCashOutRecordedWith(context);

        // Sucker should get 0% tax.
        assertEq(returnedTaxRate, 0, "sucker should get 0% cashout tax rate");
        assertEq(returnedCashOutCount, context.cashOutCount, "cashOutCount should be passed through");
        assertEq(returnedTotalSupply, context.totalSupply, "totalSupply should be passed through");
    }

    /// @notice After deploying with real suckers, verify the token mapping was applied to the deployed sucker.
    function testFork_SuckerTokenMappingApplied() public {
        (, address[] memory suckers) = _deployWithSuckers(5000);
        address suckerAddr = suckers[0];

        // Verify the NATIVE_TOKEN mapping was applied.
        assertTrue(IJBSucker(suckerAddr).isMapped(JBConstants.NATIVE_TOKEN), "sucker should have NATIVE_TOKEN mapped");

        // Verify the remote token details match the configured mapping.
        JBRemoteToken memory remote = IJBSucker(suckerAddr).remoteTokenFor(JBConstants.NATIVE_TOKEN);
        assertEq(
            remote.addr,
            bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            "remote token address should match configured mapping"
        );
        assertEq(remote.minGas, 200_000, "remote token minGas should match configured value");
        assertTrue(remote.enabled, "remote token mapping should be enabled");
    }

    /// @notice After deploying with real suckers, the omnichain deployer grants mint permission to the sucker.
    function testFork_SuckerHasMintPermission() public {
        (uint256 projectId, address[] memory suckers) = _deployWithSuckers(5000);
        address suckerAddr = suckers[0];

        // Get the current ruleset.
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(projectId);

        // Verify the sucker has mint permission.
        assertTrue(
            omnichainDeployer.hasMintPermissionFor(projectId, ruleset, suckerAddr), "sucker should have mint permission"
        );

        // Sanity: a random address should NOT have mint permission.
        assertFalse(
            omnichainDeployer.hasMintPermissionFor(projectId, ruleset, makeAddr("randomAddr")),
            "random address should not have mint permission"
        );
    }
}
