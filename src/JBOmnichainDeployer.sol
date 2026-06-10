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
import {IJBPeerChainAdjustedAccounts} from "@bananapus/suckers-v6/src/interfaces/IJBPeerChainAdjustedAccounts.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSourceContext} from "@bananapus/suckers-v6/src/structs/JBSourceContext.sol";
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
/// time it computes cross-chain total supply and surplus (so the bonding curve reflects all chains), grants suckers 0%
/// cash-out tax, and delegates tax-rate adjustments to the underlying hooks.
/// @dev Project NFTs sent to this contract are not recoverable. The deployer does not implement any NFT rescue
/// mechanism beyond `onERC721Received` for `JBProjects`. This is acceptable because the deployer should never own
/// project NFTs — it creates projects and transfers ownership in the same transaction.
contract JBOmnichainDeployer is
    ERC2771Context,
    JBPermissioned,
    IJBOmnichainDeployer,
    IJBRulesetDataHook,
    IJBPeerChainAdjustedAccounts,
    IERC721Receiver
{
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a project is not using this deployer's canonical controller.
    error JBOmnichainDeployer_ControllerMismatch(
        uint256 projectId, address expectedController, address actualController
    );

    /// @notice Thrown when a data hook is invalid for the project ruleset being configured.
    error JBOmnichainDeployer_InvalidHook(address hook, uint256 projectId, uint256 rulesetId);

    /// @notice Thrown when an empty `rulesetConfigurations` array is passed to a simplified overload that needs at
    /// least one ruleset to derive a default 721 config.
    error JBOmnichainDeployer_NoRulesetConfigurations(uint256 rulesetConfigurationCount);

    /// @notice Thrown when queueing rulesets for a project whose latest ruleset was already queued in the same block.
    /// @dev Ruleset IDs are predicted as `block.timestamp + i`. This prediction fails if
    /// `latestRulesetIdOf >= block.timestamp`, which can only happen if rulesets were already queued in the same block.
    error JBOmnichainDeployer_RulesetIdsUnpredictable(
        uint256 projectId, uint256 latestRulesetId, uint256 currentTimestamp
    );

    /// @notice Thrown when this contract receives a project NFT from an unexpected sender or transfer.
    error JBOmnichainDeployer_UnexpectedNFTReceived(address caller, address from, uint256 tokenId);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The canonical controller used for every project launch and ruleset queue.
    IJBController public immutable override CONTROLLER;

    /// @notice The directory used to confirm existing projects still use this deployer's canonical controller.
    IJBDirectory public immutable DIRECTORY;

    /// @notice Deploys tiered ERC-721 hooks for projects.
    IJB721TiersHookDeployer public immutable HOOK_DEPLOYER;

    /// @notice Mints ERC-721s that represent Juicebox project ownership and transfers.
    IJBProjects public immutable PROJECTS;

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
    /// @param controller The controller to use for every project launch and ruleset queue.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBSuckerRegistry suckerRegistry,
        IJB721TiersHookDeployer hookDeployer,
        IJBPermissions permissions,
        IJBController controller,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        CONTROLLER = controller;
        PROJECTS = controller.PROJECTS();
        SUCKER_REGISTRY = suckerRegistry;
        HOOK_DEPLOYER = hookDeployer;
        DIRECTORY = controller.DIRECTORY();

        // Let the sucker registry map tokens for projects this deployer administers.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        // Grant the registry a deployer-scoped wildcard permission.
        JBPermissionsData memory permissionData =
            JBPermissionsData({operator: address(SUCKER_REGISTRY), projectId: 0, permissionIds: permissionIds});

        PERMISSIONS.setPermissionsFor({account: address(this), permissionsData: permissionData});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy new cross-chain suckers for an existing project. Each sucker enables token bridging between this
    /// chain and a peer chain. The registry also maps configured tokens on each new sucker in the same call.
    /// @dev Only the project's owner or an operator with `JBPermissionIds.DEPLOY_SUCKERS` can call this. Supplying
    /// an explicit non-default peer also requires `JBPermissionIds.SET_SUCKER_PEER`, matching the registry's
    /// direct-call authorization model. The salt includes `msg.sender` for replay protection — the same sender must
    /// call on both chains for deterministic address matching.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        override
        returns (address[] memory suckers)
    {
        // Resolve the project owner once because Juicebox permissions are checked against the owner's permission table.
        address owner = PROJECTS.ownerOf(projectId);

        // `DEPLOY_SUCKERS` authorizes this wrapper to ask the registry for new suckers, but it does not authorize
        // choosing a non-default remote peer.
        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS});

        // Mirror the registry's explicit-peer gate against the original project authority before this wrapper becomes
        // the registry caller.
        _requireExplicitSuckerPeerPermissionFrom({
            account: owner, projectId: projectId, suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });

        // Deploy the suckers.
        // Note: the salt includes `_msgSender()` for replay protection. Cross-chain deterministic
        // address matching requires using the same sender address on each chain.
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
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        payable
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
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
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
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    /// @return suckers The addresses of the deployed suckers.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        payable
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
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
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
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
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
            memo: memo
        });
    }

    /// @notice Launches new rulesets for a project with a default (empty-tier) 721 hook.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param projectUri The project's metadata URI. Pass an empty string to leave it unchanged.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
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
            memo: memo
        });
    }

    /// @dev Make sure this contract can only receive project NFTs minted from `JBProjects` (not transferred).
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        // Only accept mints (from == address(0)) from the `JBProjects` contract, not arbitrary transfers.
        if (msg.sender != address(PROJECTS) || from != address(0)) {
            revert JBOmnichainDeployer_UnexpectedNFTReceived({caller: msg.sender, from: from, tokenId: tokenId});
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Queues new rulesets for a project with a 721 tiers hook attached, using this contract as the data hook.
    /// @dev If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, a new 721 hook is deployed.
    /// Otherwise, the 721 hook from the latest ruleset is carried forward.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deploy721Config The 721 hook deployment config (hook config + cash-out flag + salt).
    /// @param rulesetConfigurations The rulesets to queue. Custom data hooks are read from each ruleset's metadata.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook (newly deployed or carried forward from the previous ruleset).
    function queueRulesetsOf(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return _queueRulesetsOf({
            projectId: projectId,
            deploy721Config: deploy721Config,
            rulesetConfigurations: rulesetConfigurations,
            memo: memo
        });
    }

    /// @notice Queues new rulesets for a project with a default (empty-tier) 721 hook, carrying forward the existing
    /// hook.
    /// @dev Uses `baseCurrency` from the first ruleset and `decimals = 18` for the default 721 config. With 0 tiers in
    /// the default config, the existing hook is always carried forward.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook carried forward from the previous ruleset.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo
    )
        external
        override
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        return _queueRulesetsOf({
            projectId: projectId,
            deploy721Config: _default721Config(rulesetConfigurations),
            rulesetConfigurations: rulesetConfigurations,
            memo: memo
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
        // Sucker cash-outs are the bridge accounting path: the value moving out of this chain must stay proportional
        // to this chain's local backing. Do not add remote supply/surplus here.
        if (SUCKER_REGISTRY.isSuckerOf({projectId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // Start with the values from the context. Hooks below may override these.
        cashOutTaxRate = context.cashOutTaxRate;
        cashOutCount = context.cashOutCount;

        // Start with local values.
        totalSupply = context.totalSupply;
        effectiveSurplusValue = context.surplus.value;

        // If the ruleset aggregates cross-chain state, add remote supply and surplus.
        if (!context.scopeCashOutsToLocalBalances) {
            totalSupply += SUCKER_REGISTRY.remoteTotalSupplyOf(context.projectId);
            effectiveSurplusValue += SUCKER_REGISTRY.totalRemoteSurplusOf({
                projectId: context.projectId,
                decimals: context.surplus.decimals,
                currency: uint256(context.surplus.currency)
            });
        }

        // Will hold the 721 hook's cash out specifications (always 0 or 1 element).
        JBCashOutHookSpecification[] memory tiered721HookSpecifications;

        // Look up the 721 hook configured for this project's ruleset.
        JBTiered721HookConfig memory tiered721Config = _tiered721HookOf[context.projectId][context.rulesetId];

        bool hasTiered721CashOut = address(tiered721Config.hook) != address(0) && tiered721Config.useDataHookForCashOut;

        // If a 721 hook is set and opted into cash out handling, let it adjust the cash out parameters.
        if (hasTiered721CashOut) {
            // Forward to the 721 hook. It may change the tax rate, count, and return hook specs.
            // Capture the 721 hook's totalSupply and effectiveSurplusValue — NFT cash-outs should use
            // local-only denominators so holders reclaim against local surplus, not omnichain surplus.
            (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, tiered721HookSpecifications) =
                IJBRulesetDataHook(address(tiered721Config.hook)).beforeCashOutRecordedWith(context);
        }

        // Will hold the extra data hook's cash out specifications.
        JBCashOutHookSpecification[] memory extraHookSpecifications;

        // Look up any extra data hook configured for this project's ruleset.
        JBDeployerHookConfig memory extraHook = _extraDataHookOf[context.projectId][context.rulesetId];

        // If an extra hook is set and opted into cash out handling, let it adjust the cash out parameters.
        // NFT cash-outs are excluded: the terminal later passes the original fungible burn count to after-hooks,
        // while the 721 hook expresses pricing as NFT cash-out weight. Generic cash-out hooks cannot safely execute
        // against that derived count.
        if (!hasTiered721CashOut && address(extraHook.dataHook) != address(0) && extraHook.useDataHookForCashOut) {
            // Build a mutable copy of the context with the latest values (possibly updated by the 721 hook).
            JBBeforeCashOutRecordedContext memory hookContext = context;
            hookContext.cashOutTaxRate = cashOutTaxRate;
            hookContext.cashOutCount = cashOutCount;
            hookContext.totalSupply = totalSupply;
            hookContext.surplus.value = effectiveSurplusValue;

            // Forward to the extra hook. It may further change the tax rate and return hook specs.
            // We always discard totalSupply and effectiveSurplusValue — this contract computes cross-chain values
            // for both.
            (cashOutTaxRate, cashOutCount,,, extraHookSpecifications) =
                extraHook.dataHook.beforeCashOutRecordedWith(hookContext);
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
    /// Merges their weight adjustments and hook specifications into a single response for the terminal.
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
                // The tuple's minimum ABI encoding is 160 bytes: 4 head words plus an empty `bytes` tail.
                if (tiered721HookSpec.metadata.length >= 160) {
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
                    weight = mulDiv({x: weight, y: tiered721Weight, denominator: context.weight});
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

    /// @notice Forwards peer-chain adjusted accounts from the stored extra data hook. Suckers call this on the active
    /// data hook (which is this deployer after wrapping) to learn about additional supply and per-context surplus and
    /// balance that should be included in cross-chain snapshots. Without forwarding, the extra hook's peer-chain
    /// adjustments are silently masked, causing the bonding curve to use only local values and over-reclaiming on peer
    /// chains.
    /// @dev Part of `IJBPeerChainAdjustedAccounts`. Uses staticcall to safely handle extra hooks that do not implement
    /// this interface.
    /// @param projectId The ID of the project to snapshot.
    /// @return supply The extra supply to include in `sourceTotalSupply`.
    /// @return contexts The extra per-context surplus and balance to include in the snapshot, un-valued.
    function peerChainAdjustedAccountsOf(uint256 projectId)
        external
        view
        override
        returns (uint256 supply, JBSourceContext[] memory contexts)
    {
        // Get the current ruleset from the canonical controller to look up the stored extra hook.
        (JBRuleset memory ruleset,) = CONTROLLER.currentRulesetOf(projectId);

        // Look up the extra data hook for this project's current ruleset.
        JBDeployerHookConfig memory extraHook = _extraDataHookOf[projectId][ruleset.id];
        if (address(extraHook.dataHook) == address(0)) return (0, new JBSourceContext[](0));

        // Forward via staticcall — the extra hook may or may not implement IJBPeerChainAdjustedAccounts.
        (bool success, bytes memory data) = address(extraHook.dataHook)
            .staticcall(abi.encodeCall(IJBPeerChainAdjustedAccounts.peerChainAdjustedAccountsOf, (projectId)));

        if (!success) return (0, new JBSourceContext[](0));

        return _peerChainAdjustedAccountsFrom(data);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @param interfaceId The interface ID to check.
    /// @return flag A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool flag) {
        return interfaceId == type(IJBOmnichainDeployer).interfaceId
            || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPeerChainAdjustedAccounts).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
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
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    /// @return suckers The addresses of the deployed suckers.
    function _launchProjectFor(
        address owner,
        string calldata projectUri,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        internal
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
    {
        // Reserve the project ID up front so permissionless project creations cannot invalidate hook deployment.
        projectId = PROJECTS.createFor{value: msg.value}(address(this));

        // A fresh project can start without a controller, but it must not already be assigned elsewhere.
        _requireController({projectId: projectId, allowUnset: true});

        // Deploy a 721 hook and set up rulesets.
        hook = _deploy721Hook({projectId: projectId, config: deploy721Config});
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Launch the rulesets for the reserved project.
        CONTROLLER.launchRulesetsFor({
            projectId: projectId,
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });

        // A fresh launch must leave the directory pointing at this deployer's canonical controller.
        _requireController({projectId: projectId, allowUnset: false});

        // Transfer the hook's ownership to the project after the project NFT has been minted.
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            // A launch-time project is still owned by this wrapper until the final NFT transfer, so check the
            // intended owner before the registry sees `address(this)` as the current project owner.
            _requireExplicitSuckerPeerPermissionFrom({
                account: owner, projectId: projectId, suckerDeploymentConfiguration: suckerDeploymentConfiguration
            });

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
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function _launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
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

        // Existing projects must still be controlled by this deployer's canonical controller.
        _requireController({projectId: projectId, allowUnset: true});

        // Deploy a 721 hook, transfer its ownership to the project, and set up rulesets.
        hook = _deploy721Hook({projectId: projectId, config: deploy721Config});
        JBOwnable(address(hook)).transferOwnershipToProject(projectId);
        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: deploy721Config.useDataHookForCashOut
        });

        // Configure the rulesets.
        rulesetId = CONTROLLER.launchRulesetsFor({
            projectId: projectId,
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: memo
        });

        // A blank project launch must leave the directory pointing at this deployer's canonical controller.
        _requireController({projectId: projectId, allowUnset: false});
    }

    /// @notice Internal implementation of `queueRulesetsOf`.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook (newly deployed or carried forward from the previous ruleset).
    function _queueRulesetsOf(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo
    )
        internal
        returns (uint256 rulesetId, IJB721TiersHook hook)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Existing projects must still be controlled by this deployer's canonical controller.
        _requireController({projectId: projectId, allowUnset: true});

        // Revert if the project already had rulesets queued in this block, which would make our
        // `block.timestamp + i` ruleset ID prediction incorrect.
        uint256 latestRulesetId = CONTROLLER.RULESETS().latestRulesetIdOf(projectId);
        // forge-lint: disable-next-line(block-timestamp)
        uint256 currentTimestamp = block.timestamp;
        if (latestRulesetId >= currentTimestamp) {
            revert JBOmnichainDeployer_RulesetIdsUnpredictable({
                projectId: projectId, latestRulesetId: latestRulesetId, currentTimestamp: currentTimestamp
            });
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
                // by the approval hook, the deployer would otherwise lock in a hook from a ruleset that never
                // became active.
                (JBRuleset memory latestQueued, JBApprovalStatus approvalStatus) =
                    CONTROLLER.RULESETS().latestQueuedOf(projectId);
                if (
                    latestQueued.id != 0
                        && (approvalStatus == JBApprovalStatus.Approved || approvalStatus == JBApprovalStatus.Empty)
                        && address(_tiered721HookOf[projectId][latestQueued.id].hook) != address(0)
                ) {
                    sourceRulesetId = latestQueued.id;
                } else {
                    // Fall back to the current (active, approved) ruleset.
                    sourceRulesetId = CONTROLLER.RULESETS().currentOf(projectId).id;
                }
            }
            JBTiered721HookConfig memory previousConfig = _tiered721HookOf[projectId][sourceRulesetId];
            hook = previousConfig.hook;
            // Revert if no hook exists to carry forward — this means no tiers were provided and
            // no previous ruleset had a 721 hook deployed through this contract.
            if (address(hook) == address(0)) {
                revert JBOmnichainDeployer_InvalidHook({
                    hook: address(hook), projectId: projectId, rulesetId: sourceRulesetId
                });
            }
            // Preserve the previous ruleset's cash-out flag when carrying forward.
            use721ForCashOut = previousConfig.useDataHookForCashOut;
        }

        rulesetConfigurations = _setup721({
            projectId: projectId,
            rulesetConfigurations: rulesetConfigurations,
            hook721: hook,
            use721ForCashOut: use721ForCashOut
        });

        // Configure the rulesets.
        rulesetId = CONTROLLER.queueRulesetsOf({
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
            // forge-lint: disable-next-line(block-timestamp)
            uint256 rulesetId = block.timestamp + i;

            // Validate no self-reference.
            if (rulesetConfigurations[i].metadata.dataHook == address(this)) {
                revert JBOmnichainDeployer_InvalidHook({
                    hook: rulesetConfigurations[i].metadata.dataHook, projectId: projectId, rulesetId: rulesetId
                });
            }

            // Store the 721 hook config per-ruleset.
            _tiered721HookOf[projectId][rulesetId] =
                JBTiered721HookConfig({hook: hook721, useDataHookForCashOut: use721ForCashOut});

            // Store any extra hook provided in ruleset metadata.
            if (rulesetConfigurations[i].metadata.dataHook != address(0)) {
                _extraDataHookOf[projectId][rulesetId] = JBDeployerHookConfig({
                    dataHook: IJBRulesetDataHook(rulesetConfigurations[i].metadata.dataHook),
                    useDataHookForPay: rulesetConfigurations[i].metadata.useDataHookForPay,
                    useDataHookForCashOut: rulesetConfigurations[i].metadata.useDataHookForCashOut
                });
            }

            // Set this contract as the data hook, forcing both pay and cash-out through this wrapper.
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
        if (rulesetConfigurations.length == 0) {
            revert JBOmnichainDeployer_NoRulesetConfigurations({
                rulesetConfigurationCount: rulesetConfigurations.length
            });
        }
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

    /// @notice Decodes a peer-chain adjusted accounting return, falling back to no contribution if malformed.
    /// @param data The raw return data from an extra hook's `peerChainAdjustedAccountsOf` call.
    /// @return supply The extra supply to include in `sourceTotalSupply`.
    /// @return contexts The extra per-context surplus and balance to include in the snapshot, un-valued.
    function _peerChainAdjustedAccountsFrom(bytes memory data)
        internal
        pure
        returns (uint256 supply, JBSourceContext[] memory contexts)
    {
        // `data` is a Solidity `bytes` value. Its first memory word is the byte length, and the ABI return payload
        // starts at `data + 32`.
        //
        // The payload for `(uint256, JBSourceContext[])` is:
        //   word 0: supply
        //   word 1: offset to the dynamic `contexts` array tail, relative to the payload start
        //   tail word 0: contexts.length
        //   tail words: each `JBSourceContext`, encoded as 4 ABI words.
        //
        // Anything shorter than the two tuple head words plus the array-length word cannot be decoded safely.
        if (data.length < 96) return (0, new JBSourceContext[](0));

        uint256 contextsOffset;
        assembly ("memory-safe") {
            // Skip the `bytes` length word, then read the first two ABI words from the payload head.
            supply := mload(add(data, 32))
            contextsOffset := mload(add(data, 64))
        }

        // The array tail must begin after the two-word tuple head, remain ABI-word aligned, and leave room for its own
        // length word. If the offset points into the head, into the middle of a word, or past the buffer, a normal
        // `abi.decode` would revert. This wrapper instead treats the optional hook contribution as absent.
        if (contextsOffset < 64 || contextsOffset % 32 != 0 || contextsOffset > data.length - 32) {
            return (0, new JBSourceContext[](0));
        }

        uint256 contextCount;
        assembly ("memory-safe") {
            // The offset is relative to the payload start (`data + 32`), not the start of the `bytes` object.
            contextCount := mload(add(add(data, 32), contextsOffset))
        }

        // Skip the array-length word to reach the first encoded `JBSourceContext`.
        uint256 contextsStart = contextsOffset + 32;
        // Each `JBSourceContext` has four static ABI words: token, decimals, surplus, and balance. Check the count
        // against the remaining bytes before allocating the array so a hostile length cannot force a large allocation
        // or make the loop read past the returned buffer.
        if (contextCount > (data.length - contextsStart) / 128) return (0, new JBSourceContext[](0));

        contexts = new JBSourceContext[](contextCount);

        for (uint256 i; i < contextCount; i++) {
            // Move to the encoded struct for this index. The offset is still payload-relative.
            uint256 contextOffset = contextsStart + i * 128;
            bytes32 token;
            uint256 decimals;
            uint256 surplus;
            uint256 contextBalance;

            assembly ("memory-safe") {
                // Point at the first word of this encoded struct and read its four ABI words directly.
                let contextPointer := add(add(data, 32), contextOffset)
                token := mload(contextPointer)
                decimals := mload(add(contextPointer, 32))
                surplus := mload(add(contextPointer, 64))
                contextBalance := mload(add(contextPointer, 96))
            }

            // The ABI decoder would reject values that do not fit their declared Solidity types. Because this function
            // decodes manually, it must enforce the same bounds before casting so malformed data cannot silently
            // truncate into `uint8` or `uint128`.
            if (decimals > type(uint8).max || surplus > type(uint128).max || contextBalance > type(uint128).max) {
                return (0, new JBSourceContext[](0));
            }

            // Store the checked values using the struct's real types. At this point every read was inside the buffer
            // and every narrowed cast has been proven safe.
            contexts[i] = JBSourceContext({
                token: token, decimals: uint8(decimals), surplus: uint128(surplus), balance: uint128(contextBalance)
            });
        }
    }

    /// @notice Revert unless the trusted directory records `CONTROLLER` for `projectId`.
    /// @dev Use `allowUnset = true` as a pre-launch check: a fresh project with no controller wired yet is accepted.
    /// Use `allowUnset = false` as a post-launch check: `CONTROLLER` must be live in the directory.
    /// @param projectId The ID of the project to check.
    /// @param allowUnset Whether `address(0)` (no controller assigned yet) is treated as valid.
    function _requireController(uint256 projectId, bool allowUnset) internal view {
        address current = address(DIRECTORY.controllerOf(projectId));
        if (allowUnset && current == address(0)) return;
        if (current != address(CONTROLLER)) {
            revert JBOmnichainDeployer_ControllerMismatch({
                projectId: projectId, expectedController: address(CONTROLLER), actualController: current
            });
        }
    }

    /// @notice Revert unless the caller may set explicit sucker peers for `projectId`.
    /// @dev The registry enforces this against its direct caller. Since this deployer wraps the registry call, it must
    /// mirror the check against the original caller so `DEPLOY_SUCKERS` alone cannot smuggle in arbitrary peers.
    /// @param account The project owner account whose permission table is checked.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The sucker deployment configuration to inspect.
    function _requireExplicitSuckerPeerPermissionFrom(
        address account,
        uint256 projectId,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        internal
        view
    {
        // Scan every requested sucker configuration because a single explicit peer changes cross-chain authority.
        for (uint256 i; i < suckerDeploymentConfiguration.deployerConfigurations.length;) {
            // Cache the configured peer so the default/explicit branch is evaluated from the exact value sent onward.
            bytes32 peer = suckerDeploymentConfiguration.deployerConfigurations[i].peer;

            // `peer == 0` preserves the sucker's deterministic same-address peer behavior.
            // Any nonzero peer is written directly into the new sucker and changes who can deliver remote roots.
            if (peer != bytes32(0)) {
                // Require the original project authority, not this wrapper, to authorize explicit remote peers.
                _requirePermissionFrom({
                    account: account, projectId: projectId, permissionId: JBPermissionIds.SET_SUCKER_PEER
                });

                // One explicit peer is enough to prove the caller needs the stronger permission.
                return;
            }

            unchecked {
                // Skip overflow checks because `i` is bounded by the calldata array length.
                ++i;
            }
        }
    }
}
