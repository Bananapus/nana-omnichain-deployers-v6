// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBApprovalStatus} from "@bananapus/core-v6/src/enums/JBApprovalStatus.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
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
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBOmnichainDeployer} from "./interfaces/IJBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "./structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "./structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "./structs/JBSuckerDeploymentConfig.sol";
import {JBTiered721HookConfig} from "./structs/JBTiered721HookConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice One-stop deployer and data hook wrapper for omnichain Juicebox projects. Launches a project with a tiered
/// 721 hook and cross-chain suckers in a single transaction, then inserts itself as every ruleset's data hook so it can
/// coordinate between the 721 hook, an optional extra hook (e.g. buyback), and the sucker registry at pay/cash-out
/// time. At pay time it merges weight and hook specifications from both the 721 hook and the extra hook. At cash-out
/// time it
/// computes cross-chain total supply and surplus (so the bonding curve reflects all chains), grants suckers 0% cash-out
/// tax, and delegates tax-rate adjustments to the underlying hooks.
/// @dev Project NFTs sent to this contract are not recoverable. The deployer does not implement any NFT rescue
/// mechanism beyond `onERC721Received` for `JBProjects`. This is acceptable because the deployer should never own
/// project NFTs —
/// it creates projects and transfers ownership in the same transaction.
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

    /// @notice Thrown when an empty `rulesetConfigurations` array is passed to a simplified overload that needs at
    /// least one ruleset to derive a default 721 config.
    error JBOmnichainDeployer_NoRulesetConfigurations();

    /// @notice Thrown when the project ID returned by the controller does not match the expected project ID.
    error JBOmnichainDeployer_ProjectIdMismatch();

    /// @notice Thrown when queueing rulesets for a project whose latest ruleset was already queued in the same block.
    /// @dev Ruleset IDs are predicted as `block.timestamp + i`. This prediction fails if
    /// `latestRulesetIdOf >= block.timestamp`, which can only happen if rulesets were already queued in the same block.
    error JBOmnichainDeployer_RulesetIdsUnpredictable();

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

    /// @notice The directory used to validate controllers. Stored as immutable to prevent a user-provided
    /// controller from returning a fake directory that confirms itself.
    IJBDirectory public immutable DIRECTORY;

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
    /// @param directory The directory used to validate controllers against a trusted source.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBSuckerRegistry suckerRegistry,
        IJB721TiersHookDeployer hookDeployer,
        IJBPermissions permissions,
        IJBProjects projects,
        IJBDirectory directory,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        PROJECTS = projects;
        SUCKER_REGISTRY = suckerRegistry;
        HOOK_DEPLOYER = hookDeployer;
        DIRECTORY = directory;

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
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy new cross-chain suckers for an existing project. Each sucker enables token bridging between this
    /// chain and a peer chain. The registry also maps configured tokens on each new sucker in the same call.
    /// @dev Only the project's owner or an operator with `JBPermissionIds.DEPLOY_SUCKERS` can call this. The salt
    /// includes `msg.sender` for replay protection — the same sender must call on both chains for deterministic
    /// address
    /// matching.
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
        return _launchProjectFor({
            owner: owner,
            projectUri: projectUri,
            deploy721Config: deploy721Config,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            controller: controller
        });
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
        return _launchProjectFor({
            owner: owner,
            projectUri: projectUri,
            deploy721Config: _default721Config(rulesetConfigurations),
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            controller: controller
        });
    }

    /// @notice Launches new rulesets for a project with a 721 tiers hook attached, using this contract as the data
    /// hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param projectUri The project's metadata URI. Pass an empty string to leave it unchanged.
    /// @param deploy721Config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @param rulesetConfigurations The rulesets to launch. Custom data hooks are read from each ruleset's metadata.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
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
        return _launchRulesetsFor({
            projectId: projectId,
            projectUri: projectUri,
            deploy721Config: deploy721Config,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo,
            controller: controller
        });
    }

    /// @notice Launches new rulesets for a project with a default (empty-tier) 721 hook.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param projectUri The project's metadata URI. Pass an empty string to leave it unchanged.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return _launchRulesetsFor({
            projectId: projectId,
            projectUri: projectUri,
            deploy721Config: _default721Config(rulesetConfigurations),
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo,
            controller: controller
        });
    }

    /// @dev Make sure this contract can only receive project NFTs minted from `JBProjects` (not transferred).
    function onERC721Received(address, address from, uint256, bytes calldata) external view returns (bytes4) {
        // Make sure the 721 received is from the `JBProjects` contract.
        if (msg.sender != address(PROJECTS)) revert JBOmnichainDeployer_UnexpectedNFTReceived();
        // Only accept mints (from == address(0)), not transfers of existing project NFTs.
        if (from != address(0)) revert JBOmnichainDeployer_UnexpectedNFTReceived();

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
        return _queueRulesetsOf({
            projectId: projectId,
            deploy721Config: deploy721Config,
            rulesetConfigurations: rulesetConfigurations,
            memo: memo,
            controller: controller
        });
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
        return _queueRulesetsOf({
            projectId: projectId,
            deploy721Config: _default721Config(rulesetConfigurations),
            rulesetConfigurations: rulesetConfigurations,
            memo: memo,
            controller: controller
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Called by the terminal before recording a cash out. Suckers get 0% tax so bridged tokens redeem at face
    /// value. For all other holders, this function aggregates total supply and surplus across all peer chains so the
    /// bonding curve reflects the project's global state, then delegates to the 721 hook and extra hook for further
    /// adjustments.
    /// @dev Part of `IJBRulesetDataHook`. The 721 hook's returned `totalSupply` and `effectiveSurplusValue` are used
    /// when it handles cash outs (NFT redemptions use local denominators). Otherwise this contract's cross-chain values
    /// take precedence.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of project tokens that are cashed out.
    /// @return totalSupply The total token supply across all chains (for both proportional reclaim and tax).
    /// @return effectiveSurplusValue The global surplus across all chains for proportional reclaim.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // If the cash out is from a sucker, bypass all taxes and fees.
        // Pass through the local surplus so the reclaim calculation can compute the pro-rata share.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // Start with the values from the context. Hooks below may override these.
        cashOutTaxRate = context.cashOutTaxRate;
        cashOutCount = context.cashOutCount;

        // Compute the cross-chain total supply: local supply + sum of known peer chain supplies.
        // This prevents the cash out tax from vanishing when a holder dominates the local supply.
        totalSupply = context.totalSupply + SUCKER_REGISTRY.remoteTotalSupplyOf(context.projectId);

        // Compute the cross-chain surplus: local surplus + sum of known peer chain surpluses.
        // This prevents disproportionate reclaim when tokens bridge away but surplus stays.
        effectiveSurplusValue = context.surplus.value
            + SUCKER_REGISTRY.remoteSurplusOf({
                projectId: context.projectId,
                decimals: context.surplus.decimals,
                currency: uint256(context.surplus.currency)
            });

        // Will hold the 721 hook's cash out specifications (always 0 or 1 element).
        JBCashOutHookSpecification[] memory tiered721HookSpecifications;

        // Look up the 721 hook configured for this project's ruleset.
        JBTiered721HookConfig memory tiered721Config = _tiered721HookOf[context.projectId][context.rulesetId];

        // If a 721 hook is set and opted into cash out handling, let it adjust the cash out parameters.
        if (address(tiered721Config.hook) != address(0) && tiered721Config.useDataHookForCashOut) {
            // Forward to the 721 hook. It may change the tax rate, count, and return hook specs.
            // Capture the 721 hook's totalSupply and effectiveSurplusValue — NFT cash-outs should use
            // local-only denominators so holders reclaim against local surplus, not omnichain surplus.
            // slither-disable-next-line unused-return
            (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, tiered721HookSpecifications) =
                IJBRulesetDataHook(address(tiered721Config.hook)).beforeCashOutRecordedWith(context);
        }

        // Will hold the extra data hook's cash out specifications.
        JBCashOutHookSpecification[] memory extraHookSpecifications;

        // Look up any extra data hook configured for this project's ruleset.
        JBDeployerHookConfig memory extraHook = _extraDataHookOf[context.projectId][context.rulesetId];

        // If an extra hook is set and opted into cash out handling, let it adjust the cash out parameters.
        if (address(extraHook.dataHook) != address(0) && extraHook.useDataHookForCashOut) {
            // Build a mutable copy of the context with the latest values (possibly updated by the 721 hook).
            JBBeforeCashOutRecordedContext memory hookContext = context;
            hookContext.cashOutTaxRate = cashOutTaxRate;
            hookContext.cashOutCount = cashOutCount;
            hookContext.totalSupply = totalSupply;
            hookContext.surplus.value = effectiveSurplusValue;

            // Forward to the extra hook. It may further change the tax rate and return hook specs.
            // We always discard totalSupply and effectiveSurplusValue — this contract computes
            // cross-chain values for both. When the 721 hook is active, we also discard cashOutCount
            // because the 721 hook redefines both cashOutCount and totalSupply as NFT cash-out weights
            // (sum of tier prices), not fungible token counts. Letting the extra hook override
            // cashOutCount would corrupt NFT pricing in the bonding curve.
            if (address(tiered721Config.hook) != address(0) && tiered721Config.useDataHookForCashOut) {
                // slither-disable-next-line unused-return
                (cashOutTaxRate,,,, extraHookSpecifications) = extraHook.dataHook.beforeCashOutRecordedWith(hookContext);
            } else {
                // slither-disable-next-line unused-return
                (cashOutTaxRate, cashOutCount,,, extraHookSpecifications) =
                    extraHook.dataHook.beforeCashOutRecordedWith(hookContext);
            }
        }

        // If neither hook returned any specifications, return the adjusted values with no hook specs.
        if (tiered721HookSpecifications.length == 0 && extraHookSpecifications.length == 0) {
            return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
        }

        // Merge both hooks' specifications: 721 spec (if any) first, then extra hook specs.
        if (tiered721HookSpecifications.length != 0 && extraHookSpecifications.length != 0) {
            // Both hooks returned specs — combine them.
            hookSpecifications = new JBCashOutHookSpecification[](1 + extraHookSpecifications.length);
            hookSpecifications[0] = tiered721HookSpecifications[0];
            for (uint256 i; i < extraHookSpecifications.length; i++) {
                hookSpecifications[1 + i] = extraHookSpecifications[i];
            }
        } else if (tiered721HookSpecifications.length != 0) {
            // Only the 721 hook returned a spec.
            hookSpecifications = tiered721HookSpecifications;
        } else {
            // Only the extra hook returned specs.
            hookSpecifications = extraHookSpecifications;
        }

        return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
    }

    /// @notice Called by the terminal before recording a payment. Coordinates the 721 hook (which handles tier-based
    /// NFT minting and split deductions) with the extra hook (e.g. buyback, which may swap for a better token price).
    /// Merges
    /// their weight adjustments and hook specifications into a single response for the terminal.
    /// @dev Part of `IJBRulesetDataHook`. The 721 hook's weight already accounts for tier-split deductions. The extra
    /// hook receives the post-split amount so it only routes funds actually entering the project. If both return
    /// specifications, the 721 spec comes first.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which project tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of the payment) to send to pay hooks instead of the project. Useful for
    /// automatically routing funds from a treasury as payments come in.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Get the 721 hook's weight, spec, and total split amount.
        // The 721 hook's returned weight already accounts for tier-split deductions
        // (via JB721TiersHookLib.calculateWeight), so we use it directly instead of re-scaling.
        JBTiered721HookConfig memory tiered721Config = _tiered721HookOf[context.projectId][context.rulesetId];
        JBPayHookSpecification memory tiered721HookSpec;
        uint256 totalSplitAmount;
        bool hasTiered721Spec;
        // The weight returned by the 721 hook (already scaled for splits).
        uint256 tiered721Weight;
        // The weight attributable to tier splits when issueTokensForSplits is true.
        uint256 splitCreditWeight;
        // Whether a 721 hook is configured for this project's ruleset.
        bool has721Hook;
        if (address(tiered721Config.hook) != address(0)) {
            // Mark that a 721 hook is configured.
            has721Hook = true;
            // Call the 721 hook directly — useDataHookForPay is always true for 721 hooks.
            JBPayHookSpecification[] memory tiered721HookSpecs;
            // slither-disable-next-line unused-return
            (tiered721Weight, tiered721HookSpecs) =
                IJBRulesetDataHook(address(tiered721Config.hook)).beforePayRecordedWith(context);
            // The 721 hook returns a single spec (itself) whose amount is the total split amount.
            // Only the first spec is used by design — JB721TiersHook always returns exactly one spec.
            if (tiered721HookSpecs.length > 0) {
                hasTiered721Spec = true;
                tiered721HookSpec = tiered721HookSpecs[0];
                totalSplitAmount = tiered721HookSpec.amount;

                // Decode splitCreditWeight from the 721 hook's metadata (4th field).
                // When issueTokensForSplits is true and splits exist, this holds the weight portion
                // attributable to tier splits — used to prevent split credit erasure if the extra
                // hook (e.g. buyback) returns weight=0.
                if (tiered721HookSpec.metadata.length >= 128) {
                    (,,, splitCreditWeight) = abi.decode(tiered721HookSpec.metadata, (address, address, bytes, uint256));
                }
            }
        }

        // The amount entering the project after tier splits.
        uint256 projectAmount = totalSplitAmount >= context.amount.value ? 0 : context.amount.value - totalSplitAmount;

        // Get the custom data hook's weight and specs. Reduce the amount so it only considers funds entering the
        // project, and pass the 721 hook's weight so the data hook sees the split-adjusted weight.
        JBPayHookSpecification[] memory dataHookSpecs;
        bool customHookCalled;
        {
            JBDeployerHookConfig memory extraHook = _extraDataHookOf[context.projectId][context.rulesetId];
            if (address(extraHook.dataHook) != address(0) && extraHook.useDataHookForPay) {
                JBBeforePayRecordedContext memory hookContext = context;
                hookContext.amount.value = projectAmount;
                // Pass the original context.weight — NOT the 721 hook's split-adjusted weight.
                // The extra hook (e.g. buyback) applies its own weight logic; using the 721 hook's
                // already-split-adjusted weight would double-discount the split ratio.
                (weight, dataHookSpecs) = extraHook.dataHook.beforePayRecordedWith(hookContext);
                customHookCalled = true;

                // The custom hook (e.g. buyback) returned a weight based on the original context.weight.
                // If the 721 hook scaled weight down for tier splits, apply the same ratio so the terminal
                // doesn't over-mint tokens relative to the funds actually entering the project.
                // When issueTokensForSplits is true, tiered721Weight == context.weight and the ratio is 1x.
                if (has721Hook && context.weight > 0 && tiered721Weight != context.weight) {
                    weight = mulDiv(weight, tiered721Weight, context.weight);
                }

                // When the extra hook returns weight=0 (e.g. buyback found no profitable swap) but tier
                // splits exist with issueTokensForSplits=true, the split credit must still mint fungible tokens.
                // The split credit weight is independent of buyback routing — it represents the token issuance
                // for funds forwarded to tier split beneficiaries.
                if (weight == 0 && splitCreditWeight > 0) {
                    weight = splitCreditWeight;
                }
            }
        }

        if (!customHookCalled) {
            // Use the 721 hook's weight directly (already scaled for splits) or fall back to context weight.
            weight = has721Hook ? tiered721Weight : context.weight;
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

    /// @notice Returns whether an address may mint a project's tokens on-demand. Suckers always get mint permission (so
    /// bridged tokens can be minted on the destination chain). Otherwise delegates to the extra data hook.
    /// @dev Part of `IJBRulesetDataHook`. The 721 hook never grants mint permission, so only the extra hook is checked.
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
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

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
        // Reserve the project ID up front so permissionless project creations cannot invalidate hook deployment.
        projectId = PROJECTS.createFor(address(this));

        // Deploy a 721 hook and set up rulesets.
        hook = _deploy721Hook({projectId: projectId, config: deploy721Config});
        // slither-disable-next-line reentrancy-benign
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Launch the rulesets for the reserved project.
        // slither-disable-start unused-return
        controller.launchRulesetsFor({
            projectId: projectId,
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });
        // slither-disable-end unused-return

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

        // Transfer ownership of the project to the owner. Uses safeTransferFrom so contract receivers
        // get an onERC721Received callback.
        PROJECTS.safeTransferFrom({from: address(this), to: owner, tokenId: projectId});
    }

    /// @notice Internal implementation of `launchRulesetsFor`.
    function _launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        internal
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        address owner = PROJECTS.ownerOf(projectId);

        // Enforce permissions. Use LAUNCH_RULESETS (not QUEUE_RULESETS) because this function calls
        // controller.launchRulesetsFor, which sets terminals and requires the broader launch permission.
        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.LAUNCH_RULESETS});

        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.SET_TERMINALS});

        if (bytes(projectUri).length != 0) {
            _requirePermissionFrom({
                account: owner, projectId: projectId, permissionId: JBPermissionIds.SET_PROJECT_URI
            });
        }

        // Validate that the controller matches the project's controller in the directory.
        _validateController({projectId: projectId, controller: controller});

        // Deploy a 721 hook, transfer its ownership to the project, and set up rulesets.
        hook = _deploy721Hook({projectId: projectId, config: deploy721Config});
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
            projectUri: projectUri,
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
        // forge-lint: disable-next-line(block-timestamp)
        if (latestRulesetId >= block.timestamp) {
            revert JBOmnichainDeployer_RulesetIdsUnpredictable();
        }

        // Deploy a new 721 hook if tiers are provided, otherwise carry forward the existing hook.
        // Track whether to use the 721 hook for cash outs.
        bool use721ForCashOut;

        if (deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0) {
            hook = _deploy721Hook({projectId: projectId, config: deploy721Config});
            JBOwnable(address(hook)).transferOwnershipToProject(projectId);
            // Use the caller-provided flag when deploying a new hook.
            use721ForCashOut = deploy721Config.useDataHookForCashOut;
        } else {
            uint256 sourceRulesetId;
            {
                // First try the latest queued ruleset — if it's been explicitly approved
                // (or has no approval hook), its hook config should take precedence.
                // Conservative: only use Approved or Empty status. ApprovalExpected is intentionally
                // excluded because hook selection is irreversible — if the pending ruleset is later rejected
                // by the approval hook, we'd have locked in a hook from a ruleset that never became active.
                (JBRuleset memory latestQueued, JBApprovalStatus approvalStatus) =
                    controller.RULESETS().latestQueuedOf(projectId);
                if (
                    latestQueued.id != 0
                        && (approvalStatus == JBApprovalStatus.Approved || approvalStatus == JBApprovalStatus.Empty)
                        && address(_tiered721HookOf[projectId][latestQueued.id].hook) != address(0)
                ) {
                    sourceRulesetId = latestQueued.id;
                } else {
                    // Fall back to the current (active, approved) ruleset.
                    sourceRulesetId = controller.RULESETS().currentOf(projectId).id;
                }
            }
            JBTiered721HookConfig memory previousConfig = _tiered721HookOf[projectId][sourceRulesetId];
            hook = previousConfig.hook;
            // Revert if no hook exists to carry forward — this means no tiers were provided and
            // no previous ruleset had a 721 hook deployed through this contract.
            if (address(hook) == address(0)) revert JBOmnichainDeployer_InvalidHook();
            // Preserve the previous ruleset's cash-out flag when carrying forward.
            use721ForCashOut = previousConfig.useDataHookForCashOut;
        }

        // slither-disable-next-line reentrancy-benign
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: use721ForCashOut
        });

        // Configure the rulesets.
        rulesetId = controller.queueRulesetsOf({
            projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: memo
        });
    }

    /// @notice Wires up each ruleset so this contract acts as the data hook wrapper. Stores the 721 hook and any extra
    /// data hook (from the ruleset's metadata) in per-project/per-ruleset mappings, then overwrites each ruleset's
    /// metadata to point at this contract with both pay and cash-out delegation enabled.
    /// @dev Stores the 721 hook in `_tiered721HookOf` per-ruleset and any custom hook (from metadata) in
    /// `_extraDataHookOf`. Ruleset IDs are predicted as `block.timestamp + i`.
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
            // forge-lint: disable-next-line(block-timestamp)
            _tiered721HookOf[projectId][block.timestamp + i] =
                JBTiered721HookConfig({hook: hook721, useDataHookForCashOut: use721ForCashOut});

            // Store custom hook from metadata (same as _setup).
            if (rulesetConfigurations[i].metadata.dataHook != address(0)) {
                // forge-lint: disable-next-line(block-timestamp)
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

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
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
        if (rulesetConfigurations.length == 0) revert JBOmnichainDeployer_NoRulesetConfigurations();
        config.deployTiersHookConfig.tiersConfig.currency = rulesetConfigurations[0].metadata.baseCurrency;
        config.deployTiersHookConfig.tiersConfig.decimals = 18;
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

    /// @notice Validates that the provided controller matches the project's controller in the directory.
    /// @dev Uses the immutable DIRECTORY instead of querying the controller, preventing a malicious
    /// controller from returning a fake directory that confirms itself.
    /// @param projectId The ID of the project to validate the controller for.
    /// @param controller The controller to validate.
    function _validateController(uint256 projectId, IJBController controller) internal view {
        address current = address(DIRECTORY.controllerOf(projectId));
        // Allow address(0) for fresh projects that haven't launched rulesets yet.
        if (current != address(0) && current != address(controller)) {
            revert JBOmnichainDeployer_ControllerMismatch();
        }
    }
}
