// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBOmnichainDeployer} from "./interfaces/IJBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "./structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "./structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "./structs/JBSuckerDeploymentConfig.sol";
import {JBTiered721HookConfig} from "./structs/JBTiered721HookConfig.sol";

/// @notice Deploys, manages, and operates Juicebox projects with suckers.
contract JBOmnichainDeployer is
    ERC2771Context,
    JBPermissioned,
    IJBOmnichainDeployer,
    IJBRulesetDataHook,
    IERC721Receiver
{
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the provided controller does not match the project's controller in the directory.
    error JBOmnichainDeployer_ControllerMismatch();

    /// @notice Thrown when a data hook is set to this contract.
    error JBOmnichainDeployer_InvalidHook();

    /// @notice Thrown when the project ID returned by the controller does not match the expected project ID.
    error JBOmnichainDeployer_ProjectIdMismatch();

    /// @notice Thrown when queueing rulesets for a project whose latest ruleset was already queued in the same block.
    /// @dev Ruleset IDs are predicted as `block.timestamp + i`. This prediction fails if
    /// `latestRulesetIdOf >= block.timestamp`, which can only happen if rulesets were already queued in the same block.
    error JBOmnichainDeployer_RulesetIdsUnpredictable();

    /// @notice Thrown when the contract receives an NFT that is not from the `JBProjects` contract.
    error JBOmnichainDeployer_UnexpectedNFT();

    error JBOmnichainDeployer_UnexpectedNFTReceived();

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent Juicebox project ownership and transfers.
    IJBProjects public immutable PROJECTS;

    /// @notice Deploys tiered ERC-721 hooks for projects.
    IJB721TiersHookDeployer public immutable HOOK_DEPLOYER;

    /// @notice Deploys and tracks suckers for projects.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Each project's extra data hook (e.g. buyback hook) per ruleset, separate from the 721 hook.
    /// @custom:param projectId The ID of the project to get the extra data hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the extra data hook for.
    mapping(uint256 projectId => mapping(uint256 rulesetId => JBDeployerHookConfig)) internal _extraDataHookOf;

    /// @notice Each project's tiered 721 hook config per ruleset.
    /// @custom:param projectId The ID of the project to get the 721 hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the 721 hook for.
    mapping(uint256 projectId => mapping(uint256 rulesetId => JBTiered721HookConfig)) internal _tiered721HookOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param suckerRegistry The registry to use for deploying and tracking each project's suckers.
    /// @param hookDeployer The deployer to use for project's tiered ERC-721 hooks.
    /// @param permissions The permissions to use for the contract.
    /// @param projects The projects to use for the contract.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBSuckerRegistry suckerRegistry,
        IJB721TiersHookDeployer hookDeployer,
        IJBPermissions permissions,
        IJBProjects projects,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        PROJECTS = projects;
        SUCKER_REGISTRY = suckerRegistry;
        HOOK_DEPLOYER = hookDeployer;

        // Give the sucker registry permission to map tokens for all revnets.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        // Give the operator the permission.
        // Set up the permission data.
        JBPermissionsData memory permissionData =
            JBPermissionsData({operator: address(SUCKER_REGISTRY), projectId: 0, permissionIds: permissionIds});

        // Set the permissions.
        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Allow cash outs from suckers without a tax.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a cash out.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of project tokens that are cashed out.
    /// @return totalSupply The total project token supply.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, hookSpecifications);
        }

        // Check the 721 hook first.
        JBTiered721HookConfig memory tiered721Config = _tiered721HookOf[context.projectId][context.rulesetId];
        if (address(tiered721Config.hook) != address(0) && tiered721Config.useDataHookForCashOut) {
            // slither-disable-next-line unused-return
            return IJBRulesetDataHook(address(tiered721Config.hook)).beforeCashOutRecordedWith(context);
        }

        // Check the extra data hook.
        JBDeployerHookConfig memory extraHook = _extraDataHookOf[context.projectId][context.rulesetId];
        if (address(extraHook.dataHook) != address(0) && extraHook.useDataHookForCashOut) {
            // slither-disable-next-line unused-return
            return extraHook.dataHook.beforeCashOutRecordedWith(context);
        }

        // No hooks handled it — return original values.
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, hookSpecifications);
    }

    /// @notice Forward the call to the original data hook.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a payment.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which project tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of what's being paid in) to be sent to pay hooks instead of being paid
    /// into the project. Useful for automatically routing funds from a treasury as payments come in.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Get the 721 hook's spec and total split amount.
        // The 721 hook only contributes specs (split amounts), not weight.
        JBTiered721HookConfig memory tiered721Config = _tiered721HookOf[context.projectId][context.rulesetId];
        JBPayHookSpecification memory tiered721HookSpec;
        uint256 totalSplitAmount;
        bool hasTiered721Spec;
        if (address(tiered721Config.hook) != address(0)) {
            // Call the 721 hook directly — useDataHookForPay is always true for 721 hooks.
            JBPayHookSpecification[] memory tiered721HookSpecs;
            // slither-disable-next-line unused-return
            (, tiered721HookSpecs) = IJBRulesetDataHook(address(tiered721Config.hook)).beforePayRecordedWith(context);
            // The 721 hook returns a single spec (itself) whose amount is the total split amount.
            if (tiered721HookSpecs.length > 0) {
                hasTiered721Spec = true;
                tiered721HookSpec = tiered721HookSpecs[0];
                totalSplitAmount = tiered721HookSpec.amount;
            }
        }

        // The amount entering the project after tier splits.
        uint256 projectAmount = totalSplitAmount >= context.amount.value ? 0 : context.amount.value - totalSplitAmount;

        // Get the custom data hook's weight and specs. Reduce the amount so it only considers funds entering the
        // project.
        JBPayHookSpecification[] memory dataHookSpecs;
        bool customHookCalled;
        {
            JBDeployerHookConfig memory extraHook = _extraDataHookOf[context.projectId][context.rulesetId];
            if (address(extraHook.dataHook) != address(0) && extraHook.useDataHookForPay) {
                JBBeforePayRecordedContext memory hookContext = context;
                hookContext.amount.value = projectAmount;
                (weight, dataHookSpecs) = extraHook.dataHook.beforePayRecordedWith(hookContext);
                customHookCalled = true;
            }
        }

        if (!customHookCalled) {
            weight = context.weight;
        }

        // Scale the data hook's weight for splits so the terminal mints tokens only for the project's share.
        // Preserves weight=0 from hooks like buyback (buying back, not minting).
        if (projectAmount == 0) {
            weight = 0;
        } else if (projectAmount < context.amount.value) {
            weight = mulDiv(weight, projectAmount, context.amount.value);
        }

        // Merge specifications: 721 hook spec first, then data hook specs.
        bool hasDataHookSpecs = dataHookSpecs.length > 0;
        if (!hasTiered721Spec && !hasDataHookSpecs) return (weight, hookSpecifications);

        hookSpecifications = new JBPayHookSpecification[]((hasTiered721Spec ? 1 : 0) + dataHookSpecs.length);

        uint256 specIndex;
        if (hasTiered721Spec) hookSpecifications[specIndex++] = tiered721HookSpec;
        for (uint256 i; i < dataHookSpecs.length; i++) {
            hookSpecifications[specIndex + i] = dataHookSpecs[i];
        }
    }

    /// @notice Get the extra data hook for a project and ruleset.
    /// @param projectId The ID of the project to get the extra data hook for.
    /// @param rulesetId The ID of the ruleset to get the extra data hook for.
    /// @return hook The extra data hook configured for the project/ruleset.
    function extraDataHookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        override
        returns (JBDeployerHookConfig memory hook)
    {
        return _extraDataHookOf[projectId][rulesetId];
    }

    /// @notice Get the tiered 721 hook config for a project and ruleset.
    /// @param projectId The ID of the project to get the 721 hook for.
    /// @param rulesetId The ID of the ruleset to get the 721 hook for.
    /// @return hook The 721 tiers hook.
    /// @return useDataHookForCashOut Whether the 721 hook is used for cash outs.
    function tiered721HookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        override
        returns (IJB721TiersHook hook, bool useDataHookForCashOut)
    {
        JBTiered721HookConfig memory config = _tiered721HookOf[projectId][rulesetId];
        return (config.hook, config.useDataHookForCashOut);
    }

    /// @notice A flag indicating whether an address has permission to mint a project's tokens on-demand.
    /// @dev A project's data hook can allow any address to mint its tokens.
    /// @param projectId The ID of the project whose token can be minted.
    /// @param ruleset The ruleset to check the token minting permission of.
    /// @param addr The address to check the token minting permission of.
    /// @return flag A flag indicating whether the address has permission to mint the project's tokens on-demand.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset memory ruleset,
        address addr
    )
        external
        view
        override
        returns (bool)
    {
        // Suckers always get mint permission.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: projectId, addr: addr})) return true;

        // Check the extra data hook (the 721 hook doesn't grant mint permission).
        JBDeployerHookConfig memory extraHook = _extraDataHookOf[projectId][ruleset.id];
        if (address(extraHook.dataHook) != address(0)) {
            if (extraHook.dataHook.hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: addr})) {
                return true;
            }
        }

        return false;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBOmnichainDeployer).interfaceId
            || interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploy new suckers for an existing project.
    /// @dev Only the juicebox's owner can deploy new suckers.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    function deploySuckersFor(
        uint256 projectId,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        override
        returns (address[] memory suckers)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS
        });

        // Deploy the suckers.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
        // slither-disable-next-line unused-return
        suckers = SUCKER_REGISTRY.deploySuckersFor({
            projectId: projectId,
            salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
            configurations: suckerDeploymentConfiguration.deployerConfigurations
        });
    }

    /// @notice Creates a project with a 721 tiers hook attached and with suckers.
    /// @param owner The address to set as the owner of the project. The ERC-721 which confers this project's ownership
    /// will be sent to this address.
    /// @param projectUri The project's metadata URI.
    /// @param deploy721Config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @param rulesetConfigurations The rulesets to queue. Custom data hooks are read from each ruleset's metadata.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    /// @return suckers The addresses of the deployed suckers.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBOmnichain721Config calldata deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        override
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        return _launchProjectFor(
            owner,
            projectUri,
            deploy721Config,
            rulesetConfigurations,
            terminalConfigurations,
            memo,
            suckerDeploymentConfiguration,
            controller
        );
    }

    /// @notice Creates a project with a default (empty-tier) 721 hook and with suckers.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config.
    /// @param owner The address to set as the owner of the project.
    /// @param projectUri The project's metadata URI.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    /// @return suckers The addresses of the deployed suckers.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        override
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        return _launchProjectFor(
            owner,
            projectUri,
            _default721Config(rulesetConfigurations),
            rulesetConfigurations,
            terminalConfigurations,
            memo,
            suckerDeploymentConfiguration,
            controller
        );
    }

    /// @notice Launches new rulesets for a project with a 721 tiers hook attached, using this contract as the data
    /// hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param deploy721Config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @param rulesetConfigurations The rulesets to launch. Custom data hooks are read from each ruleset's metadata.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return
            _launchRulesetsFor(
                projectId, deploy721Config, rulesetConfigurations, terminalConfigurations, memo, controller
            );
    }

    /// @notice Launches new rulesets for a project with a default (empty-tier) 721 hook.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return _launchRulesetsFor(
            projectId,
            _default721Config(rulesetConfigurations),
            rulesetConfigurations,
            terminalConfigurations,
            memo,
            controller
        );
    }

    /// @dev Make sure this contract can only receive project NFTs from `JBProjects`.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        // Make sure the 721 received is from the `JBProjects` contract.
        if (msg.sender != address(PROJECTS)) revert JBOmnichainDeployer_UnexpectedNFTReceived();

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Queues new rulesets for a project with a 721 tiers hook attached, using this contract as the data hook.
    /// @dev If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, a new 721 hook is deployed.
    /// Otherwise, the 721 hook from the latest ruleset is carried forward.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deploy721Config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @param rulesetConfigurations The rulesets to queue. Custom data hooks are read from each ruleset's metadata.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for queuing the rulesets.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook (newly deployed or carried forward from the previous ruleset).
    function queueRulesetsOf(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return _queueRulesetsOf(projectId, deploy721Config, rulesetConfigurations, memo, controller);
    }

    /// @notice Queues new rulesets for a project with a default (empty-tier) 721 hook, carrying forward the existing
    /// hook.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config. With 0 tiers in
    /// the default config, the existing hook is always carried forward.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for queuing the rulesets.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook carried forward from the previous ruleset.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return
            _queueRulesetsOf(
                projectId, _default721Config(rulesetConfigurations), rulesetConfigurations, memo, controller
            );
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns a default `JBOmnichain721Config` with `currency` from the first ruleset's `baseCurrency`,
    /// `decimals = 18`, empty tiers, no cash-out handling, and no salt.
    /// @param rulesetConfigurations The ruleset configurations to derive defaults from.
    /// @return config The default 721 config.
    function _default721Config(JBRulesetConfig[] memory rulesetConfigurations)
        internal
        pure
        returns (JBOmnichain721Config memory config)
    {
        config.deployTiersHookConfig.tiersConfig.currency = rulesetConfigurations[0].metadata.baseCurrency;
        config.deployTiersHookConfig.tiersConfig.decimals = 18;
    }

    /// @notice Internal implementation of `launchProjectFor`.
    function _launchProjectFor(
        address owner,
        string calldata projectUri,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        internal
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        // Get the next project ID.
        projectId = PROJECTS.count() + 1;

        // Deploy a 721 hook and set up rulesets.
        hook = _deploy721Hook(projectId, deploy721Config);
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Launch the project, and sanity check the project ID.
        // slither-disable-next-line reentrancy-benign
        if (
            projectId
                != controller.launchProjectFor({
                    owner: address(this),
                    projectUri: projectUri,
                    rulesetConfigurations: rulesetConfigurations,
                    terminalConfigurations: terminalConfigurations,
                    memo: memo
                })
        ) revert JBOmnichainDeployer_ProjectIdMismatch();

        // Transfer the hook's ownership to the project (now that the project NFT has been minted).
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // slither-disable-next-line unused-return
            suckers = SUCKER_REGISTRY.deploySuckersFor({
                projectId: projectId,
                salt: keccak256(abi.encode(suckerDeploymentConfiguration.salt, _msgSender())),
                configurations: suckerDeploymentConfiguration.deployerConfigurations
            });
        }

        // Transfer ownership of the project to the owner.
        PROJECTS.transferFrom(address(this), owner, projectId);
    }

    /// @notice Internal implementation of `launchRulesetsFor`.
    function _launchRulesetsFor(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        internal
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_TERMINALS
        });

        // Validate that the controller matches the project's controller in the directory.
        _validateController({projectId: projectId, controller: controller});

        // Deploy a 721 hook, transfer its ownership to the project, and set up rulesets.
        hook = _deploy721Hook(projectId, deploy721Config);
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);
        // slither-disable-next-line reentrancy-benign
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Configure the rulesets.
        rulesetId = controller.launchRulesetsFor({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });
    }

    /// @notice Internal implementation of `queueRulesetsOf`.
    function _queueRulesetsOf(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        internal
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Validate that the controller matches the project's controller in the directory.
        _validateController({projectId: projectId, controller: controller});

        // Revert if the project already had rulesets queued in this block, which would make our
        // `block.timestamp + i` ruleset ID prediction incorrect.
        uint256 latestRulesetId = controller.RULESETS().latestRulesetIdOf(projectId);
        if (latestRulesetId >= block.timestamp) {
            revert JBOmnichainDeployer_RulesetIdsUnpredictable();
        }

        // Deploy a new 721 hook if tiers are provided, otherwise carry forward the existing hook.
        if (deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0) {
            hook = _deploy721Hook(projectId, deploy721Config);
            JBOwnable(address(hook)).transferOwnershipToProject(projectId);
        } else {
            hook = _tiered721HookOf[projectId][latestRulesetId].hook;
        }

        // slither-disable-next-line reentrancy-benign
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Configure the rulesets.
        rulesetId = controller.queueRulesetsOf({
            projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: memo
        });
    }

    /// @notice Deploys a 721 tiers hook for a project.
    /// @dev The caller is responsible for transferring ownership to the project via
    /// `JBOwnable(address(hook)).transferOwnershipToProject(projectId)` after the project NFT has been minted.
    /// @param projectId The ID of the project to deploy the hook for.
    /// @param config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @return hook The deployed 721 tiers hook.
    function _deploy721Hook(
        uint256 projectId,
        JBOmnichain721Config memory config
    )
        internal
        returns (IJB721TiersHook hook)
    {
        // Deploy the hook.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
        hook = HOOK_DEPLOYER.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: config.deployTiersHookConfig,
            salt: config.salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), config.salt))
        });
    }

    /// @notice Sets up a project's rulesets with a 721 hook.
    /// @dev Stores the 721 hook in `_tiered721HookOf` per-ruleset and any custom hook (from metadata) in
    /// `_extraDataHookOf`.
    /// @param projectId The ID of the project to set up.
    /// @param rulesetConfigurations The rulesets to set up.
    /// @param hook721 The 721 tiers hook.
    /// @param use721ForCashOut Whether the 721 hook should handle cash outs.
    /// @return rulesetConfigurations The rulesets that were set up.
    function _setup721(
        uint256 projectId,
        JBRulesetConfig[] memory rulesetConfigurations,
        IJB721TiersHook hook721,
        bool use721ForCashOut
    )
        internal
        returns (JBRulesetConfig[] memory)
    {
        for (uint256 i; i < rulesetConfigurations.length; i++) {
            // Validate no self-reference.
            if (rulesetConfigurations[i].metadata.dataHook == address(this)) revert JBOmnichainDeployer_InvalidHook();

            // Store the 721 hook config per-ruleset.
            // slither-disable-next-line reentrancy-benign
            _tiered721HookOf[projectId][block.timestamp + i] =
                JBTiered721HookConfig({hook: hook721, useDataHookForCashOut: use721ForCashOut});

            // Store custom hook from metadata (same as _setup).
            if (rulesetConfigurations[i].metadata.dataHook != address(0)) {
                _extraDataHookOf[projectId][block.timestamp + i] = JBDeployerHookConfig({
                    dataHook: IJBRulesetDataHook(rulesetConfigurations[i].metadata.dataHook),
                    useDataHookForPay: rulesetConfigurations[i].metadata.useDataHookForPay,
                    useDataHookForCashOut: rulesetConfigurations[i].metadata.useDataHookForCashOut
                });
            }

            // Set this contract as the data hook, force both pay and cashout through this wrapper.
            rulesetConfigurations[i].metadata.dataHook = address(this);
            rulesetConfigurations[i].metadata.useDataHookForPay = true;
            rulesetConfigurations[i].metadata.useDataHookForCashOut = true;
        }

        return rulesetConfigurations;
    }

    /// @notice Validates that the provided controller matches the project's controller in the directory.
    /// @param projectId The ID of the project to validate the controller for.
    /// @param controller The controller to validate.
    function _validateController(uint256 projectId, IJBController controller) internal view {
        if (address(controller.DIRECTORY().controllerOf(projectId)) != address(controller)) {
            revert JBOmnichainDeployer_ControllerMismatch();
        }
    }
}
