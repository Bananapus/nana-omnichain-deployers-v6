// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBLaunchProjectConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchProjectConfig.sol";
import {JBLaunchRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchRulesetsConfig.sol";
import {JBPayDataHookRulesetConfig} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetConfig.sol";
import {JBPayDataHookRulesetMetadata} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetMetadata.sol";
import {JBQueueRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBQueueRulesetsConfig.sol";
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
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {IJBOmnichainDeployer} from "./interfaces/IJBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "./structs/JBDeployerHookConfig.sol";
import {JBSuckerDeploymentConfig} from "./structs/JBSuckerDeploymentConfig.sol";

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
    // --------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice Each project's tiered 721 hook, stored separately from the custom data hook.
    /// @custom:param projectId The ID of the project to get the 721 hook for.
    mapping(uint256 projectId => IJB721TiersHook) public override tiered721HookOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Each project's data hook provided on deployment.
    /// @custom:param projectId The ID of the project to get the data hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the data hook for.
    mapping(uint256 projectId => mapping(uint256 rulesetId => JBDeployerHookConfig)) internal _dataHookOf;

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

        // If a 721 hook exists, it handles cashouts (NFT-based semantics take priority).
        IJB721TiersHook tiered721Hook = tiered721HookOf[context.projectId];
        if (address(tiered721Hook) != address(0)) {
            return IJBRulesetDataHook(address(tiered721Hook)).beforeCashOutRecordedWith(context);
        }

        // Otherwise, forward to the user's custom data hook.
        JBDeployerHookConfig memory hook = _dataHookOf[context.projectId][context.rulesetId];

        // If no data hook is set, or the data hook is not used for cash outs, return the original values.
        if (address(hook.dataHook) == address(0) || !hook.useDataHookForCashOut) {
            return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, hookSpecifications);
        }

        // If the ruleset has a data hook, forward the call to the datahook.
        // slither-disable-next-line unused-return
        return hook.dataHook.beforeCashOutRecordedWith(context);
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
        // Call user data hook for weight + specs.
        JBDeployerHookConfig memory hook = _dataHookOf[context.projectId][context.rulesetId];
        JBPayHookSpecification[] memory userSpecs;
        if (address(hook.dataHook) != address(0) && hook.useDataHookForPay) {
            (weight, userSpecs) = hook.dataHook.beforePayRecordedWith(context);
        } else {
            weight = context.weight;
        }

        // Call the 721 hook to get its specs (includes split amounts and tier metadata).
        IJB721TiersHook tiered721Hook = tiered721HookOf[context.projectId];
        JBPayHookSpecification[] memory hookSpecs;
        if (address(tiered721Hook) != address(0)) {
            (, hookSpecs) = IJBRulesetDataHook(address(tiered721Hook)).beforePayRecordedWith(context);
        }

        bool uses721 = hookSpecs.length > 0;
        bool usesUserHook = userSpecs.length > 0;

        // If neither hook produces specs, return early.
        if (!uses721 && !usesUserHook) return (weight, hookSpecifications);

        // Merge specifications: 721 hook specs first, then user hook specs.
        hookSpecifications = new JBPayHookSpecification[](hookSpecs.length + userSpecs.length);

        for (uint256 i; i < hookSpecs.length; i++) {
            hookSpecifications[i] = hookSpecs[i];
        }

        for (uint256 i; i < userSpecs.length; i++) {
            hookSpecifications[hookSpecs.length + i] = userSpecs[i];
        }
    }

    /// @notice Get the data hook for a project and ruleset.
    /// @custom:param projectId The ID of the project to get the data hook for.
    /// @custom:param rulesetId The ID of the ruleset to get the data hook for.
    /// @return useDataHookForPay Whether the data hook is used for pay.
    /// @return useDataHookForCashOut Whether the data hook is used for cash out.
    /// @return dataHook The data hook.
    function dataHookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        override
        returns (bool useDataHookForPay, bool useDataHookForCashOut, IJBRulesetDataHook dataHook)
    {
        JBDeployerHookConfig memory hook = _dataHookOf[projectId][rulesetId];
        return (hook.useDataHookForPay, hook.useDataHookForCashOut, hook.dataHook);
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

        // Check user data hook.
        JBDeployerHookConfig memory hook = _dataHookOf[projectId][ruleset.id];
        if (address(hook.dataHook) != address(0)) {
            if (hook.dataHook.hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: addr})) {
                return true;
            }
        }

        // Check 721 hook.
        IJB721TiersHook tiered721Hook = tiered721HookOf[projectId];
        if (address(tiered721Hook) != address(0)) {
            if (IJBRulesetDataHook(address(tiered721Hook))
                    .hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: addr})) return true;
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

    /// @notice Launches a new project with a 721 tiers hook attached, and with suckers.
    /// @param owner The address to set as the owner of the project. The ERC-721 which confers this project's ownership
    /// will be sent to this address.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param launchProjectConfig Configuration which dictates the behavior of the project which is being launched.
    /// @param salt A salt to use for the deterministic deployment. Combined with `_msgSender()` internally, so
    /// cross-chain deterministic addresses require the same sender on each chain.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launch721ProjectFor(
        address owner,
        JBDeploy721TiersHookConfig calldata deployTiersHookConfig,
        JBLaunchProjectConfig calldata launchProjectConfig,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller,
        address dataHook,
        bytes32 salt
    )
        external
        override
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        // Get the next project ID.
        projectId = PROJECTS.count() + 1;

        // Deploy the hook.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
        hook = HOOK_DEPLOYER.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: deployTiersHookConfig,
            salt: salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), salt))
        });

        // Store the 721 hook separately from the custom data hook.
        tiered721HookOf[projectId] = hook;

        // Launch the project, and sanity check the project ID.
        // slither-disable-next-line reentrancy-benign
        if (
            projectId
                != controller.launchProjectFor({
                    owner: address(this),
                    projectUri: launchProjectConfig.projectUri,
                    // Convert the 721 ruleset configurations and set up this deployer as the data hook wrapper.
                    rulesetConfigurations: _setup({
                        projectId: projectId,
                        rulesetConfigurations: _from721Config({
                            launchProjectConfig: launchProjectConfig.rulesetConfigurations, dataHook: dataHook
                        })
                    }),
                    terminalConfigurations: launchProjectConfig.terminalConfigurations,
                    memo: launchProjectConfig.memo
                })
        ) revert JBOmnichainDeployer_ProjectIdMismatch();

        // Transfer the hook's ownership to the project.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // Deploy the suckers.
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

    /// @notice Launches new rulesets for a project with a 721 tiers hook attached, using this contract as the data
    /// hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param launchRulesetsConfig Configuration which dictates the behavior of the rulesets which are being launched.
    /// @param salt A salt to use for the deterministic deployment. Combined with `_msgSender()` internally, so
    /// cross-chain deterministic addresses require the same sender on each chain.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launch721RulesetsFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBLaunchRulesetsConfig calldata launchRulesetsConfig,
        IJBController controller,
        address dataHook,
        bytes32 salt
    )
        external
        override
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

        // Deploy the hook.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
        hook = HOOK_DEPLOYER.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: deployTiersHookConfig,
            salt: salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), salt))
        });

        // Store the 721 hook separately from the custom data hook.
        tiered721HookOf[projectId] = hook;

        // Transfer the hook's ownership to the project.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);

        // Convert the 721 ruleset configurations to regular ruleset configurations.
        // Pass the user's custom data hook (not the 721 hook) for storage in _dataHookOf.
        // slither-disable-next-line reentrancy-benign
        JBRulesetConfig[] memory rulesetConfigurations = _setup({
            projectId: projectId,
            rulesetConfigurations: _from721Config({
                launchProjectConfig: launchRulesetsConfig.rulesetConfigurations, dataHook: dataHook
            })
        });

        // Configure the rulesets.
        rulesetId = controller.launchRulesetsFor({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: launchRulesetsConfig.terminalConfigurations,
            memo: launchRulesetsConfig.memo
        });
    }

    /// @notice Creates a project with suckers.
    /// @dev This will mint the project's ERC-721 to the `owner`'s address, queue the specified rulesets, and set up the
    /// specified splits and terminals. Each operation within this transaction can be done in sequence separately.
    /// @dev Anyone can deploy a project to any `owner`'s address.
    /// @param owner The project's owner. The project ERC-721 will be minted to this address.
    /// @param projectUri The project's metadata URI. This is typically an IPFS hash, optionally with the `ipfs://`
    /// prefix. This can be updated by the project's owner.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The project's ID.
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
        returns (uint256 projectId, address[] memory suckers)
    {
        // Get the next project ID.
        projectId = PROJECTS.count() + 1;

        rulesetConfigurations = _setup({projectId: projectId, rulesetConfigurations: rulesetConfigurations});

        // Launch the project.
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

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // Deploy the suckers.
            // Note: the salt includes `_msgSender()` for replay protection (see above).
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

    /// @notice Launches new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256)
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

        return controller.launchRulesetsFor({
            projectId: projectId,
            rulesetConfigurations: _setup({projectId: projectId, rulesetConfigurations: rulesetConfigurations}),
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });
    }

    /// @dev Make sure this contract can only receive project NFTs from `JBProjects`.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        // Make sure the 721 received is from the `JBProjects` contract.
        if (msg.sender != address(PROJECTS)) revert JBOmnichainDeployer_UnexpectedNFTReceived();

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Queues new rulesets for a project with a 721 tiers hook attached, using this contract as the data hook.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook which is being
    /// deployed.
    /// @param queueRulesetsConfig Configuration which dictates the behavior of the rulesets which are being queued.
    /// @param salt A salt to use for the deterministic deployment. Combined with `_msgSender()` internally, so
    /// cross-chain deterministic addresses require the same sender on each chain.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function queue721RulesetsOf(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBQueueRulesetsConfig calldata queueRulesetsConfig,
        IJBController controller,
        address dataHook,
        bytes32 salt
    )
        external
        override
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
        if (controller.RULESETS().latestRulesetIdOf(projectId) >= block.timestamp) {
            revert JBOmnichainDeployer_RulesetIdsUnpredictable();
        }

        // Deploy the hook.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
        hook = HOOK_DEPLOYER.deployHookFor({
            projectId: projectId,
            deployTiersHookConfig: deployTiersHookConfig,
            salt: salt == bytes32(0) ? bytes32(0) : keccak256(abi.encode(_msgSender(), salt))
        });

        // Store the 721 hook separately from the custom data hook.
        tiered721HookOf[projectId] = hook;

        // Transfer the hook's ownership to the project.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);

        // Convert the 721 ruleset configurations to regular ruleset configurations.
        // Pass the user's custom data hook (not the 721 hook) for storage in _dataHookOf.
        // slither-disable-next-line reentrancy-benign
        JBRulesetConfig[] memory rulesetConfigurations = _setup({
            projectId: projectId,
            rulesetConfigurations: _from721Config({
                launchProjectConfig: queueRulesetsConfig.rulesetConfigurations, dataHook: dataHook
            })
        });

        // Configure the rulesets.
        rulesetId = controller.queueRulesetsOf({
            projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: queueRulesetsConfig.memo
        });
    }

    /// @notice Queues new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for queuing the rulesets.
    /// @return rulesetId The ID of the newly queued rulesets.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Validate that the controller matches the project's controller in the directory.
        _validateController({projectId: projectId, controller: controller});

        // Revert if the project already had rulesets queued in this block, which would make our
        // `block.timestamp + i` ruleset ID prediction incorrect.
        if (controller.RULESETS().latestRulesetIdOf(projectId) >= block.timestamp) {
            revert JBOmnichainDeployer_RulesetIdsUnpredictable();
        }

        return controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _setup({projectId: projectId, rulesetConfigurations: rulesetConfigurations}),
            memo: memo
        });
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice Converts a 721 ruleset configuration to a regular ruleset configuration.
    /// @param launchProjectConfig The 721 ruleset configuration to convert.
    /// @param dataHook The custom data hook address to store (user's hook, not the 721 hook).
    /// @return rulesetConfigurations The converted ruleset configuration.
    function _from721Config(
        JBPayDataHookRulesetConfig[] calldata launchProjectConfig,
        address dataHook
    )
        internal
        pure
        returns (JBRulesetConfig[] memory rulesetConfigurations)
    {
        rulesetConfigurations = new JBRulesetConfig[](launchProjectConfig.length);

        for (uint256 i; i < launchProjectConfig.length; i++) {
            JBPayDataHookRulesetMetadata calldata hookMetadata = launchProjectConfig[i].metadata;
            JBRulesetMetadata memory metadata = JBRulesetMetadata({
                // useDataHookForPay is always true — the 721 hook needs it via beforePayRecordedWith.
                useDataHookForPay: true,
                allowSetCustomToken: false,
                dataHook: dataHook,
                // These fields are present in the 721 metadata.
                reservedPercent: hookMetadata.reservedPercent,
                cashOutTaxRate: hookMetadata.cashOutTaxRate,
                baseCurrency: hookMetadata.baseCurrency,
                pausePay: hookMetadata.pausePay,
                pauseCreditTransfers: hookMetadata.pauseCreditTransfers,
                allowOwnerMinting: hookMetadata.allowOwnerMinting,
                allowTerminalMigration: hookMetadata.allowTerminalMigration,
                allowSetController: hookMetadata.allowSetController,
                allowSetTerminals: hookMetadata.allowSetTerminals,
                allowAddAccountingContext: hookMetadata.allowAddAccountingContext,
                allowAddPriceFeed: hookMetadata.allowAddPriceFeed,
                ownerMustSendPayouts: hookMetadata.ownerMustSendPayouts,
                holdFees: hookMetadata.holdFees,
                useTotalSurplusForCashOuts: hookMetadata.useTotalSurplusForCashOuts,
                useDataHookForCashOut: hookMetadata.useDataHookForCashOut,
                metadata: hookMetadata.metadata
            });

            rulesetConfigurations[i] = JBRulesetConfig({
                mustStartAtOrAfter: launchProjectConfig[i].mustStartAtOrAfter,
                duration: launchProjectConfig[i].duration,
                weight: launchProjectConfig[i].weight,
                weightCutPercent: launchProjectConfig[i].weightCutPercent,
                approvalHook: launchProjectConfig[i].approvalHook,
                metadata: metadata,
                splitGroups: launchProjectConfig[i].splitGroups,
                fundAccessLimitGroups: launchProjectConfig[i].fundAccessLimitGroups
            });
        }
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

    /// @notice Sets up a project's rulesets.
    /// @dev Stores data hook configs keyed by predicted ruleset IDs (`block.timestamp + i`). This prediction is correct
    /// because `JBRulesets.queueFor` assigns IDs as: `latestId >= block.timestamp ? latestId + 1 : block.timestamp`.
    /// For new projects (launch*) and first rulesets (launchRulesets*), `latestId` starts at 0, so the first ID is
    /// always `block.timestamp` and subsequent IDs increment from there. For `queueRulesetsOf` on existing projects,
    /// callers must ensure `latestRulesetIdOf < block.timestamp` (i.e., no rulesets were queued earlier in this block).
    /// @param projectId The ID of the project to set up.
    /// @param rulesetConfigurations The rulesets to set up.
    /// @return rulesetConfigurations The rulesets that were set up.
    function _setup(
        uint256 projectId,
        JBRulesetConfig[] memory rulesetConfigurations
    )
        internal
        returns (JBRulesetConfig[] memory)
    {
        for (uint256 i; i < rulesetConfigurations.length; i++) {
            // Make sure there's no infinite loop.
            if (rulesetConfigurations[i].metadata.dataHook == address(this)) revert JBOmnichainDeployer_InvalidHook();

            // Store the data hook keyed by predicted ruleset ID.
            _dataHookOf[projectId][block.timestamp + i] = JBDeployerHookConfig({
                useDataHookForPay: rulesetConfigurations[i].metadata.useDataHookForPay,
                useDataHookForCashOut: rulesetConfigurations[i].metadata.useDataHookForCashOut,
                dataHook: IJBRulesetDataHook(rulesetConfigurations[i].metadata.dataHook)
            });

            // Set this contract as the data hook.
            rulesetConfigurations[i].metadata.dataHook = address(this);
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
