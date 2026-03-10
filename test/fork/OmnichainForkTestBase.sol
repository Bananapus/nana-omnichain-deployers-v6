// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "@bananapus/suckers-v6/src/structs/JBSuckersPair.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";

import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBLaunchProjectConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchProjectConfig.sol";
import {JBPayDataHookRulesetConfig} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetConfig.sol";
import {JBPayDataHookRulesetMetadata} from "@bananapus/721-hook-v6/src/structs/JBPayDataHookRulesetMetadata.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

// Buyback hook
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IWETH9} from "@bananapus/buyback-hook-v6/src/interfaces/external/IWETH9.sol";
import {IGeomeanOracle} from "@bananapus/buyback-hook-v6/src/interfaces/IGeomeanOracle.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract OmnichainLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    )
        external
        payable
    {
        bytes memory data = abi.encode(AddLiqParams(key, tickLower, tickUpper, liquidityDelta));
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        AddLiqParams memory params = abi.decode(data, (AddLiqParams));
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());
        _takeIfPositive(params.key.currency0, callerDelta.amount0());
        _takeIfPositive(params.key.currency1, callerDelta.amount1());
        return abi.encode(callerDelta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        uint256 amount = uint256(uint128(-delta));
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        poolManager.take(currency, address(this), uint256(uint128(delta)));
    }

    receive() external payable {}
}

/// @notice Shared base for omnichain deployer fork tests with real V4 PoolManager + buyback hook.
///
/// Requires: RPC_ETHEREUM_MAINNET env var.
abstract contract OmnichainForkTestBase is TestBaseWorkflow {
    using JBMetadataResolver for bytes;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ───────────────────────── Mainnet constants
    // ─────────────────────────

    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;

    // ───────────────────────── State
    // ─────────────────────────

    JBOmnichainDeployer DEPLOYER;
    JBBuybackHook BUYBACK_HOOK;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IJBSuckerRegistry SUCKER_REGISTRY;
    IPoolManager poolManager;
    IWETH9 weth;
    OmnichainLiquidityHelper liqHelper;

    address PAYER = makeAddr("payer");
    address SPLIT_BENEFICIARY = makeAddr("splitBeneficiary");

    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30%
    uint112 constant INITIAL_ISSUANCE = 1000e18;

    // ───────────────────────── Setup
    // ─────────────────────────

    function setUp() public virtual override {
        vm.createSelectFork("ethereum", 21_700_000);
        require(POOL_MANAGER_ADDR.code.length > 0, "PoolManager not deployed");

        super.setUp();

        poolManager = IPoolManager(POOL_MANAGER_ADDR);
        weth = IWETH9(WETH_ADDR);
        liqHelper = new OmnichainLiquidityHelper(poolManager);

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, jbSplits(), address(0));
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        BUYBACK_HOOK = new JBBuybackHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbProjects(), jbTokens(), weth, poolManager, address(0)
        );

        DEPLOYER = new JBOmnichainDeployer(SUCKER_REGISTRY, HOOK_DEPLOYER, jbPermissions(), jbProjects(), address(0));

        // Allow the deployer to set first controller.
        vm.prank(multisig());
        jbDirectory().setIsAllowedToSetFirstController(address(DEPLOYER), true);

        vm.deal(PAYER, 100 ether);
    }

    // ───────────────────────── Config Helpers
    // ─────────────────────────

    function _build721Config() internal view returns (JBDeploy721TiersHookConfig memory) {
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        JBSplit[] memory tierSplits = new JBSplit[](1);
        tierSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(SPLIT_BENEFICIARY),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        tiers[0] = JB721TierConfig({
            price: TIER_PRICE,
            initialSupply: 100,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: bytes32("tier1"),
            category: 1,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
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
                tiers: tiers,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                decimals: 18,
                prices: IJBPrices(address(0))
            }),
            reserveBeneficiary: address(0),
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
        returns (JBLaunchProjectConfig memory, JBSuckerDeploymentConfig memory)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        JBPayDataHookRulesetConfig[] memory rulesets = new JBPayDataHookRulesetConfig[](1);
        rulesets[0] = JBPayDataHookRulesetConfig({
            mustStartAtOrAfter: uint48(0),
            duration: uint32(0),
            weight: INITIAL_ISSUANCE,
            weightCutPercent: uint32(0),
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBPayDataHookRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: cashOutTaxRate,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                pausePay: false,
                pauseCreditTransfers: false,
                allowOwnerMinting: false,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                useTotalSurplusForCashOuts: false,
                useDataHookForCashOut: false,
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBLaunchProjectConfig memory launchConfig = JBLaunchProjectConfig({
            projectUri: "ipfs://omnichain-fork",
            rulesetConfigurations: rulesets,
            terminalConfigurations: tc,
            memo: "fork test"
        });

        JBSuckerDeploymentConfig memory suckerConfig =
            JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        return (launchConfig, suckerConfig);
    }

    /// @notice Deploy a project with 721 hook + buyback hook as custom data hook.
    function _deploy721WithBuyback(uint16 cashOutTaxRate) internal returns (uint256 projectId, IJB721TiersHook hook) {
        JBDeploy721TiersHookConfig memory hookConfig = _build721Config();
        (JBLaunchProjectConfig memory launchConfig, JBSuckerDeploymentConfig memory suckerConfig) =
            _buildLaunchConfig(cashOutTaxRate);

        (projectId, hook,) = DEPLOYER.launch721ProjectFor({
            owner: multisig(),
            deployTiersHookConfig: hookConfig,
            launchProjectConfig: launchConfig,
            suckerDeploymentConfiguration: suckerConfig,
            controller: IJBController(address(jbController())),
            dataHook: address(BUYBACK_HOOK),
            salt: bytes32("OMNI_721")
        });

        // Deploy an ERC20 token for the project so pool setup can use it.
        vm.prank(multisig());
        jbController().deployERC20For(projectId, "Omni Token", "OMNI", bytes32(0));
    }

    /// @notice Deploy a project without 721 hook via plain launchProjectFor.
    function _deployPlain(uint16 cashOutTaxRate) internal returns (uint256 projectId) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
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
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBSuckerDeploymentConfig memory suckerConfig =
            JBSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        (projectId,) = DEPLOYER.launchProjectFor({
            owner: multisig(),
            projectUri: "ipfs://plain",
            rulesetConfigurations: rulesets,
            terminalConfigurations: tc,
            memo: "plain",
            suckerDeploymentConfiguration: suckerConfig,
            controller: IJBController(address(jbController()))
        });
    }

    // ───────────────────────── Pool Helpers
    // ─────────────────────────

    function _setupPool(uint256 projectId, uint256 liquidityTokenAmount) internal returns (PoolKey memory key) {
        address projectToken = address(jbTokens().tokenOf(projectId));
        require(projectToken != address(0), "project token not deployed");

        address token0 = projectToken < WETH_ADDR ? projectToken : WETH_ADDR;
        address token1 = projectToken < WETH_ADDR ? WETH_ADDR : projectToken;

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 10_000, // 1% fee (matches REVDeployer DEFAULT_BUYBACK_POOL_FEE)
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(key, sqrtPrice);

        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), projectId, liquidityTokenAmount);
        vm.deal(address(liqHelper), liquidityTokenAmount);
        vm.prank(address(liqHelper));
        IWETH9(WETH_ADDR).deposit{value: liquidityTokenAmount}();

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        _mockOracle(liquidityDelta, 0, 2 days);

        vm.prank(multisig());
        BUYBACK_HOOK.setPoolFor({
            projectId: projectId, poolKey: key, twapWindow: 2 days, terminalToken: JBConstants.NATIVE_TOKEN
        });
    }

    function _mockOracle(int256 liquidity, int24 tick, uint256 twapWindow) internal {
        vm.etch(address(0), hex"00");
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(int32(uint32(twapWindow)));
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        secondsPerLiquidityCumulativeX128s[1] = uint160((twapWindow << 128) / liq);
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    // ───────────────────────── Balance Helpers
    // ─────────────────────────

    function _terminalBalance(uint256 projectId, address token) internal view returns (uint256) {
        return jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, token);
    }

    // ───────────────────────── Metadata Helpers
    // ─────────────────────────

    function _buildPayMetadataNoQuote(address hookMetadataTarget) internal view returns (bytes memory) {
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory tierData = abi.encode(true, tierIds);
        bytes4 tierMetadataId = JBMetadataResolver.getId("pay", hookMetadataTarget);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = tierMetadataId;
        bytes[] memory datas = new bytes[](1);
        datas[0] = tierData;
        return JBMetadataResolver.createMetadata(ids, datas);
    }

    function _buildPayMetadataWithQuote(
        address hookMetadataTarget,
        uint256 amountToSwapWith,
        uint256 minimumSwapAmountOut
    )
        internal
        view
        returns (bytes memory)
    {
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory tierData = abi.encode(true, tierIds);
        bytes4 tierMetadataId = JBMetadataResolver.getId("pay", hookMetadataTarget);
        bytes memory quoteData = abi.encode(amountToSwapWith, minimumSwapAmountOut);
        bytes4 quoteMetadataId = JBMetadataResolver.getId("quote");
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = tierMetadataId;
        ids[1] = quoteMetadataId;
        bytes[] memory datas = new bytes[](2);
        datas[0] = tierData;
        datas[1] = quoteData;
        return JBMetadataResolver.createMetadata(ids, datas);
    }
}
