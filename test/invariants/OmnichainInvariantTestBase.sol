// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";

import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

/// @notice Local base for randomized invariant campaigns.
/// @dev Keep the long stateful campaigns local. Real fork/V4/buyback behavior is
/// covered by targeted tests under test/fork, while these invariants repeatedly
/// exercise the deployer, 721 hook, terminal, controller, and sucker registry
/// accounting without paying mainnet fork overhead for every handler operation.
abstract contract OmnichainInvariantTestBase is TestBaseWorkflow {
    JBOmnichainDeployer omnichainDeployer;
    JB721TiersHook exampleHook;
    IJB721TiersHookDeployer hookDeployer721;
    IJB721TiersHookStore hookStore;
    IJBAddressRegistry addressRegistry;
    IJBSuckerRegistry suckerRegistry;

    address splitBeneficiary = makeAddr("splitBeneficiary");
    uint256 private _deploySaltNonce;

    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30%
    uint112 constant INITIAL_ISSUANCE = 1000e18;

    function setUp() public virtual override {
        super.setUp();

        suckerRegistry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        hookStore = new JB721TiersHookStore();
        exampleHook = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            hookStore,
            jbSplits(),
            new JB721CheckpointsDeployer(hookStore),
            address(0)
        );
        addressRegistry = new JBAddressRegistry();
        hookDeployer721 = new JB721TiersHookDeployer(exampleHook, hookStore, addressRegistry, multisig());

        omnichainDeployer = new JBOmnichainDeployer(
            suckerRegistry, hookDeployer721, jbPermissions(), IJBController(address(jbController())), address(0)
        );

        // Allow the deployer to set first controller.
        vm.prank(multisig());
        jbDirectory().setIsAllowedToSetFirstController(address(omnichainDeployer), true);
    }

    function _build721Config() internal view returns (JBDeploy721TiersHookConfig memory) {
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        JBSplit[] memory tierSplits = new JBSplit[](1);
        tierSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        tiers[0] = JB721TierConfig({
            price: TIER_PRICE,
            initialSupply: 100,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: bytes32("tier1"),
            category: 1,
            discountPercent: 0,
            flags: JB721TierConfigFlags({
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: false,
                transfersPausable: false,
                useVotingUnits: false,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: SPLIT_PERCENT,
            splits: tierSplits
        });

        return JBDeploy721TiersHookConfig({
            name: "Omni NFT",
            symbol: "ONFT",
            baseUri: "ipfs://",
            tokenUriResolver: IJB721TokenUriResolver(address(0)),
            contractUri: "ipfs://contract",
            tiersConfig: JB721InitTiersConfig({
                tiers: tiers, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals: 18
            }),
            flags: JB721TiersHookFlags({
                noNewTiersWithReserves: false,
                noNewTiersWithVotes: false,
                noNewTiersWithOwnerMinting: false,
                preventOverspending: false,
                issueTokensForSplits: false
            })
        });
    }

    function _buildLaunchConfig(uint16 cashOutTaxRate)
        internal
        view
        returns (
            JBRulesetConfig[] memory rulesets,
            JBTerminalConfig[] memory tc,
            JBSuckerDeploymentConfig memory suckerConfig
        )
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        rulesets = new JBRulesetConfig[](1);
        rulesets[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: cashOutTaxRate,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowSetCustomToken: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        suckerConfig =
            JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
    }

    function _deploy721Project(uint16 cashOutTaxRate) internal returns (uint256 projectId, IJB721TiersHook hook) {
        (
            JBRulesetConfig[] memory rulesets,
            JBTerminalConfig[] memory tc,
            JBSuckerDeploymentConfig memory suckerConfig
        ) = _buildLaunchConfig(cashOutTaxRate);

        (projectId, hook,) = omnichainDeployer.launchProjectFor({
            owner: multisig(),
            projectUri: "ipfs://omnichain-invariant",
            deploy721Config: JBOmnichain721Config({
                deployTiersHookConfig: _build721Config(), useDataHookForCashOut: true, salt: bytes32(++_deploySaltNonce)
            }),
            rulesetConfigurations: rulesets,
            terminalConfigurations: tc,
            memo: "invariant test",
            suckerDeploymentConfiguration: suckerConfig
        });
    }
}
