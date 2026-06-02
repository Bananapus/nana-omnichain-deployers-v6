// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBPeerChainAdjustedAccounts} from "@bananapus/suckers-v6/src/interfaces/IJBPeerChainAdjustedAccounts.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {IJBOmnichainDeployer} from "../../src/interfaces/IJBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";

/// @notice Halmos proofs for omnichain deployer cross-component guards and cross-chain cash-out accounting.
contract JBOmnichainDeployerHalmos {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Mock controller used as the deployer's canonical controller.
    MockController internal _controller;

    /// @notice Mock directory used by `_requireController`.
    MockDirectory internal _directory;

    /// @notice Deployer under test.
    OmnichainDeployerHarness internal _deployer;

    /// @notice Mock 721 hook deployer used to inspect deterministic salts.
    MockHookDeployer internal _hookDeployer;

    /// @notice Mock sucker registry used to model local and remote bridge state.
    MockSuckerRegistry internal _suckerRegistry;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor() {
        _directory = new MockDirectory();
        _controller =
            new MockController({directory: IJBDirectory(address(_directory)), projects: IJBProjects(address(1))});
        _hookDeployer = new MockHookDeployer();
        _suckerRegistry = new MockSuckerRegistry();

        _deployer = new OmnichainDeployerHarness({
            suckerRegistry: _suckerRegistry,
            hookDeployer: _hookDeployer,
            permissions: new MockPermissions(),
            controller: _controller
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Proves non-sucker cash outs aggregate remote supply and surplus when local scoping is disabled.
    /// @param cashOutCount The local cash-out count.
    /// @param localSupply The local total token supply.
    /// @param localSurplus The local surplus value.
    /// @param remoteSupply The peer-chain total supply.
    /// @param remoteSurplus The peer-chain surplus.
    /// @param cashOutTaxRate The input cash-out tax rate.
    function check_beforeCashOutAggregatesRemoteStateForUnscopedHolders(
        uint96 cashOutCount,
        uint96 localSupply,
        uint96 localSurplus,
        uint96 remoteSupply,
        uint96 remoteSurplus,
        uint16 cashOutTaxRate
    )
        public
    {
        uint256 projectId = 1;
        address holder = address(2);

        _suckerRegistry.setRemoteState({totalSupply: remoteSupply, surplus: remoteSurplus});

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
        ) = _deployer.beforeCashOutRecordedWith(
            _cashOutContext({
                projectId: projectId,
                holder: holder,
                cashOutCount: cashOutCount,
                totalSupply: localSupply,
                surplus: localSurplus,
                scopeCashOutsToLocalBalances: false,
                cashOutTaxRate: cashOutTaxRate
            })
        );

        assert(returnedCashOutTaxRate == cashOutTaxRate);
        assert(returnedCashOutCount == cashOutCount);
        assert(returnedTotalSupply == uint256(localSupply) + remoteSupply);
        assert(returnedSurplus == uint256(localSurplus) + remoteSurplus);
    }

    /// @notice Proves sucker cash outs always bypass taxes and use only local accounting values.
    /// @param cashOutCount The local cash-out count.
    /// @param localSupply The local total token supply.
    /// @param localSurplus The local surplus value.
    /// @param cashOutTaxRate The input cash-out tax rate which should be bypassed.
    function check_beforeCashOutUsesLocalStateForSuckers(
        uint96 cashOutCount,
        uint96 localSupply,
        uint96 localSurplus,
        uint16 cashOutTaxRate
    )
        public
    {
        uint256 projectId = 1;
        address sucker = address(2);

        _suckerRegistry.setSucker({projectId: projectId, sucker: sucker, flag: true});
        // Sucker cash outs are the bridge accounting path and must not read remote totals.
        _suckerRegistry.setRevertOnRemote({flag: true});

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
        ) = _deployer.beforeCashOutRecordedWith(
            _cashOutContext({
                projectId: projectId,
                holder: sucker,
                cashOutCount: cashOutCount,
                totalSupply: localSupply,
                surplus: localSurplus,
                scopeCashOutsToLocalBalances: false,
                cashOutTaxRate: cashOutTaxRate
            })
        );

        assert(returnedCashOutTaxRate == 0);
        assert(returnedCashOutCount == cashOutCount);
        assert(returnedTotalSupply == localSupply);
        assert(returnedSurplus == localSurplus);
    }

    /// @notice Proves scoped non-sucker cash outs do not read peer-chain state.
    /// @param cashOutCount The local cash-out count.
    /// @param localSupply The local total token supply.
    /// @param localSurplus The local surplus value.
    /// @param cashOutTaxRate The input cash-out tax rate.
    function check_beforeCashOutUsesLocalStateWhenScoped(
        uint96 cashOutCount,
        uint96 localSupply,
        uint96 localSurplus,
        uint16 cashOutTaxRate
    )
        public
    {
        uint256 projectId = 1;
        address holder = address(2);

        // If the deployer accidentally reads remote state in a locally scoped cash out, this call will fail.
        _suckerRegistry.setRevertOnRemote({flag: true});

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
        ) = _deployer.beforeCashOutRecordedWith(
            _cashOutContext({
                projectId: projectId,
                holder: holder,
                cashOutCount: cashOutCount,
                totalSupply: localSupply,
                surplus: localSurplus,
                scopeCashOutsToLocalBalances: true,
                cashOutTaxRate: cashOutTaxRate
            })
        );

        assert(returnedCashOutTaxRate == cashOutTaxRate);
        assert(returnedCashOutCount == cashOutCount);
        assert(returnedTotalSupply == localSupply);
        assert(returnedSurplus == localSurplus);
    }

    /// @notice Proves an empty default-ruleset config is rejected before reading index 0.
    function check_default721ConfigRejectsEmptyRulesets() public view {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](0);

        try _deployer.default721ConfigFor({rulesetConfigurations: rulesetConfigurations}) returns (
            JBOmnichain721Config memory
        ) {
            assert(false);
        } catch {}
    }

    /// @notice Proves default 721 config derives currency from the first ruleset and keeps the empty-tier defaults.
    /// @param firstBaseCurrency The base currency of the first ruleset.
    /// @param secondBaseCurrency The base currency of the second ruleset, which should not be used.
    function check_default721ConfigUsesFirstRuleset(uint32 firstBaseCurrency, uint32 secondBaseCurrency) public view {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](2);
        rulesetConfigurations[0].metadata.baseCurrency = firstBaseCurrency;
        rulesetConfigurations[1].metadata.baseCurrency = secondBaseCurrency;

        JBOmnichain721Config memory config =
            _deployer.default721ConfigFor({rulesetConfigurations: rulesetConfigurations});

        assert(config.deployTiersHookConfig.tiersConfig.currency == firstBaseCurrency);
        assert(config.deployTiersHookConfig.tiersConfig.decimals == 18);
        assert(config.deployTiersHookConfig.tiersConfig.tiers.length == 0);
        assert(!config.useDataHookForCashOut);
        assert(config.salt == bytes32(0));
    }

    /// @notice Proves zero salts are forwarded unchanged to the 721 hook deployer.
    function check_deploy721HookKeepsZeroSalt() public {
        _deployer.deploy721HookForProof({projectId: 1, salt: bytes32(0)});

        assert(_hookDeployer.lastProjectId() == 1);
        assert(_hookDeployer.lastSalt() == bytes32(0));
    }

    /// @notice Proves nonzero 721 deployment salts are bound to the caller for cross-chain replay protection.
    /// @param salt The nonzero caller-provided salt.
    function check_deploy721HookSenderBindsNonzeroSalt(bytes32 salt) public {
        if (salt == bytes32(0)) return;

        _deployer.deploy721HookForProof({projectId: 1, salt: salt});

        assert(_hookDeployer.lastProjectId() == 1);
        assert(_hookDeployer.lastSalt() == keccak256(abi.encode(address(this), salt)));
    }

    /// @notice Proves suckers get mint permission without consulting optional extra hooks.
    /// @param projectId The project ID whose sucker is checked.
    function check_hasMintPermissionAllowsSuckers(uint96 projectId) public {
        address sucker = address(2);
        JBRuleset memory ruleset;

        _suckerRegistry.setSucker({projectId: projectId, sucker: sucker, flag: true});

        assert(_deployer.hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: sucker}));
    }

    /// @notice Proves `_requireController` accepts an unset directory entry only when explicitly allowed.
    function check_requireControllerAllowsUnsetOnlyWhenConfigured() public {
        uint256 projectId = 1;

        _directory.setController({projectId: projectId, controller: address(0)});
        _deployer.requireControllerFor({projectId: projectId, allowUnset: true});

        try _deployer.requireControllerFor({projectId: projectId, allowUnset: false}) {
            assert(false);
        } catch {}
    }

    /// @notice Proves `_requireController` rejects a controller other than this deployer's immutable controller.
    /// @param otherController A mismatched controller address.
    function check_requireControllerRejectsMismatch(address otherController) public {
        if (otherController == address(0) || otherController == address(_controller)) return;

        uint256 projectId = 1;
        _directory.setController({projectId: projectId, controller: otherController});

        try _deployer.requireControllerFor({projectId: projectId, allowUnset: true}) {
            assert(false);
        } catch {}
    }

    /// @notice Proves `_requireController` accepts this deployer's immutable controller.
    /// @param allowUnset Whether unset controllers would also be allowed.
    function check_requireControllerUsesImmutableController(bool allowUnset) public {
        uint256 projectId = 1;
        _directory.setController({projectId: projectId, controller: address(_controller)});

        _deployer.requireControllerFor({projectId: projectId, allowUnset: allowUnset});
    }

    /// @notice Proves ERC-165 exposes the deployer, data-hook, peer-adjustment, ERC-721 receiver, and IERC165 IDs.
    function check_supportsExpectedInterfaces() public view {
        assert(_deployer.supportsInterface(type(IJBOmnichainDeployer).interfaceId));
        assert(_deployer.supportsInterface(type(IJBRulesetDataHook).interfaceId));
        assert(_deployer.supportsInterface(type(IJBPeerChainAdjustedAccounts).interfaceId));
        assert(_deployer.supportsInterface(type(IERC721Receiver).interfaceId));
        assert(_deployer.supportsInterface(type(IERC165).interfaceId));
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Builds a cash-out context with only the fields used by these proofs populated.
    function _cashOutContext(
        uint256 projectId,
        address holder,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 surplus,
        bool scopeCashOutsToLocalBalances,
        uint256 cashOutTaxRate
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        context = JBBeforeCashOutRecordedContext({
            terminal: address(3),
            holder: holder,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({token: address(4), decimals: 18, currency: 1, value: surplus}),
            scopeCashOutsToLocalBalances: scopeCashOutsToLocalBalances,
            cashOutTaxRate: cashOutTaxRate,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }
}

/// @notice Test harness exposing internal deployer helpers to Halmos.
contract OmnichainDeployerHarness is JBOmnichainDeployer {
    /// @param suckerRegistry Mock sucker registry.
    /// @param hookDeployer Mock 721 hook deployer.
    /// @param permissions Mock permissions contract.
    /// @param controller Mock canonical controller.
    constructor(
        MockSuckerRegistry suckerRegistry,
        MockHookDeployer hookDeployer,
        MockPermissions permissions,
        MockController controller
    )
        JBOmnichainDeployer(
            IJBSuckerRegistry(address(suckerRegistry)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            IJBPermissions(address(permissions)),
            IJBController(address(controller)),
            address(0)
        )
    {}

    /// @notice Exposes `_default721Config`.
    /// @param rulesetConfigurations The ruleset configurations to derive defaults from.
    /// @return config The default 721 config.
    function default721ConfigFor(JBRulesetConfig[] memory rulesetConfigurations)
        external
        pure
        returns (JBOmnichain721Config memory config)
    {
        return _default721Config(rulesetConfigurations);
    }

    /// @notice Exposes `_deploy721Hook`.
    /// @param projectId The project ID to deploy the hook for.
    /// @param salt The caller-provided salt.
    /// @return hook The deployed hook address returned by the mock deployer.
    function deploy721HookForProof(uint256 projectId, bytes32 salt) external returns (IJB721TiersHook hook) {
        JBOmnichain721Config memory config;
        config.salt = salt;
        return _deploy721Hook({projectId: projectId, config: config});
    }

    /// @notice Exposes `_requireController`.
    /// @param projectId The project ID to check.
    /// @param allowUnset Whether an unset controller is valid.
    function requireControllerFor(uint256 projectId, bool allowUnset) external view {
        _requireController({projectId: projectId, allowUnset: allowUnset});
    }
}

/// @notice Minimal controller mock for constructor and current-ruleset reads.
contract MockController {
    /// @notice The mocked directory.
    IJBDirectory public DIRECTORY;

    /// @notice The mocked projects registry.
    IJBProjects public PROJECTS;

    /// @notice The current ruleset ID returned by `currentRulesetOf`.
    uint48 public currentRulesetId = 1;

    /// @param directory The directory returned by `DIRECTORY()`.
    /// @param projects The projects registry returned by `PROJECTS()`.
    constructor(IJBDirectory directory, IJBProjects projects) {
        DIRECTORY = directory;
        PROJECTS = projects;
    }

    /// @notice Mock current-ruleset lookup.
    /// @return ruleset The current ruleset.
    /// @return metadata Empty metadata.
    function currentRulesetOf(uint256)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset.id = currentRulesetId;
        metadata.metadata = 0;
    }
}

/// @notice Minimal directory mock for controller checks.
contract MockDirectory {
    /// @notice Controller address for each project ID.
    mapping(uint256 projectId => address controller) public controllerOfProject;

    /// @notice Returns the controller for a project.
    /// @param projectId The project ID to check.
    /// @return controller The configured controller.
    function controllerOf(uint256 projectId) external view returns (IERC165 controller) {
        return IERC165(controllerOfProject[projectId]);
    }

    /// @notice Sets the controller for a project.
    /// @param projectId The project ID to configure.
    /// @param controller The controller address to return.
    function setController(uint256 projectId, address controller) external {
        controllerOfProject[projectId] = controller;
    }
}

/// @notice Minimal 721 hook deployer mock which records the salt used.
contract MockHookDeployer {
    /// @notice The last project ID passed to `deployHookFor`.
    uint256 public lastProjectId;

    /// @notice The last salt passed to `deployHookFor`.
    bytes32 public lastSalt;

    /// @notice Records the deployment request and returns a nonzero hook address.
    /// @param projectId The project ID to deploy the hook for.
    /// @param salt The deterministic deployment salt.
    /// @return hook The mocked hook address.
    function deployHookFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory,
        bytes32 salt
    )
        external
        returns (IJB721TiersHook hook)
    {
        lastProjectId = projectId;
        lastSalt = salt;
        return IJB721TiersHook(address(5));
    }
}

/// @notice Minimal permissions mock used by the deployer constructor.
contract MockPermissions {
    /// @notice Accepts permission setup from the deployer constructor.
    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

/// @notice Minimal sucker registry mock for local/remote bridge accounting proofs.
contract MockSuckerRegistry {
    /// @notice Reverts when remote aggregate state is queried.
    error MockSuckerRegistry_RemoteReadForbidden();

    /// @notice Whether an address is a sucker for a project.
    mapping(uint256 projectId => mapping(address sucker => bool flag)) public isSucker;

    /// @notice Remote surplus returned by `totalRemoteSurplusOf`.
    uint256 public remoteSurplus;

    /// @notice Remote total supply returned by `remoteTotalSupplyOf`.
    uint256 public remoteTotalSupply;

    /// @notice Whether remote reads should revert.
    bool public revertOnRemote;

    /// @notice Sucker lookup matching `IJBSuckerRegistry.isSuckerOf`.
    /// @param projectId The project ID to check.
    /// @param addr The address to check.
    /// @return flag Whether `addr` is a sucker for `projectId`.
    function isSuckerOf(uint256 projectId, address addr) external view returns (bool flag) {
        return isSucker[projectId][addr];
    }

    /// @notice Remote surplus lookup matching `IJBSuckerRegistry.totalRemoteSurplusOf`.
    /// @return surplus The configured remote surplus.
    function totalRemoteSurplusOf(uint256, uint256, uint256) external view returns (uint256 surplus) {
        if (revertOnRemote) revert MockSuckerRegistry_RemoteReadForbidden();
        return remoteSurplus;
    }

    /// @notice Remote total-supply lookup matching `IJBSuckerRegistry.remoteTotalSupplyOf`.
    /// @return totalSupply The configured remote total supply.
    function remoteTotalSupplyOf(uint256) external view returns (uint256 totalSupply) {
        if (revertOnRemote) revert MockSuckerRegistry_RemoteReadForbidden();
        return remoteTotalSupply;
    }

    /// @notice Configures whether an address is a sucker.
    /// @param projectId The project ID to configure.
    /// @param sucker The sucker address.
    /// @param flag Whether the address should be treated as a sucker.
    function setSucker(uint256 projectId, address sucker, bool flag) external {
        isSucker[projectId][sucker] = flag;
    }

    /// @notice Configures remote aggregate state.
    /// @param totalSupply The remote total supply.
    /// @param surplus The remote surplus.
    function setRemoteState(uint256 totalSupply, uint256 surplus) external {
        remoteTotalSupply = totalSupply;
        remoteSurplus = surplus;
    }

    /// @notice Configures whether remote reads revert.
    /// @param flag Whether remote reads should revert.
    function setRevertOnRemote(bool flag) external {
        revertOnRemote = flag;
    }

    /// @notice Stubbed deploy function to satisfy accidental calls.
    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        pure
        returns (address[] memory suckers)
    {
        return new address[](0);
    }
}
