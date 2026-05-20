// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "@bananapus/core-v6/src/interfaces/IJBFundAccessLimits.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplits} from "@bananapus/core-v6/src/interfaces/IJBSplits.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";

contract ForwardedPermissionsTest is Test {
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer internal hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBSuckerRegistry internal suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets internal rulesets = IJBRulesets(makeAddr("rulesets"));
    IJBSplits internal splits = IJBSplits(makeAddr("splits"));
    IJBFundAccessLimits internal fundAccessLimits = IJBFundAccessLimits(makeAddr("fundAccessLimits"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));

    address internal projectOwner = makeAddr("projectOwner");
    address internal hookAddr = makeAddr("hook721");
    uint256 internal constant PROJECT_ID = 42;
    uint256 internal constant RULESET_ID = 1;

    JBController internal controller;
    JBOmnichainDeployer internal deployer;

    function setUp() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        controller = new JBController({
            directory: directory,
            fundAccessLimits: fundAccessLimits,
            permissions: permissions,
            prices: prices,
            projects: projects,
            rulesets: rulesets,
            splits: splits,
            tokens: tokens,
            omnichainRulesetOperator: makeAddr("different-operator"),
            trustedForwarder: address(0)
        });

        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, controller, address(0));

        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(projectOwner)
        );
        // Mock controllerOf on the deployer's immutable DIRECTORY.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, PROJECT_ID),
            abi.encode(IERC165(address(controller)))
        );

        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        vm.mockCall(
            address(rulesets), abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, PROJECT_ID), abi.encode(0)
        );
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(
                IJBRulesets.queueFor.selector,
                PROJECT_ID,
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                uint256(0),
                uint256(0)
            ),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    id: uint48(RULESET_ID),
                    basedOnId: 0,
                    start: uint48(block.timestamp),
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                })
            )
        );
        vm.mockCall(address(directory), abi.encodeWithSelector(IJBDirectory.setControllerOf.selector), abi.encode());
        vm.mockCall(address(splits), abi.encodeWithSelector(IJBSplits.setSplitGroupsOf.selector), abi.encode());
        vm.mockCall(
            address(fundAccessLimits),
            abi.encodeWithSelector(IJBFundAccessLimits.setFundAccessLimitsFor.selector),
            abi.encode()
        );
    }

    function test_poc_launchRulesetsFor_revertsUnlessDeployerContractIsAuthorized() external {
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(
                IJBPermissions.hasPermission.selector,
                address(deployer),
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.LAUNCH_RULESETS,
                true,
                true
            ),
            abi.encode(false)
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _rulesetConfig();

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                address(deployer),
                PROJECT_ID,
                JBPermissionIds.LAUNCH_RULESETS
            )
        );
        deployer.launchRulesetsFor(PROJECT_ID, "", configs, new JBTerminalConfig[](0), "memo");
    }

    function test_poc_queueRulesetsOf_revertsUnlessDeployerContractIsAuthorized() external {
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(
                IJBPermissions.hasPermission.selector,
                address(deployer),
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.QUEUE_RULESETS,
                true,
                true
            ),
            abi.encode(false)
        );

        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, PROJECT_ID),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.currentOf.selector, PROJECT_ID),
            abi.encode(_currentRuleset())
        );
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestQueuedOf.selector, PROJECT_ID),
            abi.encode(_emptyRuleset(), uint8(0))
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _rulesetConfig();

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                address(deployer),
                PROJECT_ID,
                JBPermissionIds.QUEUE_RULESETS
            )
        );
        deployer.queueRulesetsOf(PROJECT_ID, _configWithTier(), configs, "memo");
    }

    function _configWithTier() internal pure returns (JBOmnichain721Config memory config) {
        config.deployTiersHookConfig = JBDeploy721TiersHookConfig({
            name: "Test",
            symbol: "TEST",
            baseUri: "",
            tokenUriResolver: IJB721TokenUriResolver(address(0)),
            contractUri: "",
            tiersConfig: JB721InitTiersConfig({
                tiers: _tiers(), currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals: 18
            }),
            flags: _hookFlags()
        });
    }

    function _tiers() internal pure returns (JB721TierConfig[] memory tiers) {
        tiers = new JB721TierConfig[](1);
        tiers[0] = JB721TierConfig({
            price: 1,
            initialSupply: 1,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: bytes32(0),
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
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }

    function _hookFlags() internal pure returns (JB721TiersHookFlags memory flags) {
        return JB721TiersHookFlags({
            noNewTiersWithReserves: false,
            noNewTiersWithVotes: false,
            noNewTiersWithOwnerMinting: false,
            preventOverspending: false,
            issueTokensForSplits: false
        });
    }

    function _rulesetConfig() internal pure returns (JBRulesetConfig memory config) {
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
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
        });
    }

    function _currentRuleset() internal view returns (JBRuleset memory ruleset) {
        ruleset = _emptyRuleset();
        ruleset.id = 123;
        ruleset.start = uint48(block.timestamp - 1);
    }

    function _emptyRuleset() internal pure returns (JBRuleset memory ruleset) {}
}
