// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {HookBehavior} from "./helpers/HookBehavior.sol";

contract AntiSniperHookTest is HookBehavior {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        hamster = _tokenOnSide(false);
        _installQuote();
        _createPool();
        _seed();
    }

    function _tokenOnSide(bool above) internal returns (HamsterHourToken token) {
        for (uint256 i; i < 256; ++i) {
            token = new HamsterHourToken{salt: bytes32(i)}();
            if ((address(token) > DeploymentConfig.IMD) == above) return token;
        }
        revert("could not place test token");
    }

    function _installQuote() internal {
        bytes memory init = abi.encodePacked(type(MockERC20).creationCode, abi.encode("IMD", "IMD", 100_000_000 ether));
        vm.etch(DeploymentConfig.IMD, init);
        (bool ok, bytes memory runtime) = DeploymentConfig.IMD.call("");
        require(ok, "local quote fixture construction");
        vm.etch(DeploymentConfig.IMD, runtime);
        imd = IERC20(DeploymentConfig.IMD);
    }

    function test_immutablesAndPermissionsMatchMinedAddress() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.hamster(), address(hamster));
        assertEq(hook.START_BPS(), 3000);
        assertEq(hook.FLOOR_BPS(), 500);
        assertEq(hook.DECAY_SECONDS(), 600);
        assertEq(hook.FEE_RECIPIENT(), DeploymentConfig.FEE_RECIPIENT);
        assertEq(hook.poolInitialisedAt(), launchedAt);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.REQUIRED);
        assertEq(HookFlags.REQUIRED, 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
    }

    function test_allEnabledCallbacksRejectUnauthorizedCallers() public {
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE_1_1);
        SwapParams memory params = SwapParams(buyZeroForOne, -1 ether, PRICE_1_1);
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
        vm.expectRevert(PoolDriver.OnlyManager.selector);
        driver.unlockCallback("");
        vm.expectRevert(AntiSniperHook.OnlySelf.selector);
        hook.quoteInput(key, params);
    }

    function test_initializeOnlyAcceptsIntendedPoolAndDoesNotResetClock() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), key, PRICE_1_1), IHooks.beforeInitialize.selector);
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert(AntiSniperHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), wrong, PRICE_1_1);
        wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert(AntiSniperHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), wrong, PRICE_1_1);
        vm.expectRevert();
        manager.initialize(key, PRICE_1_1);
        assertEq(hook.poolInitialisedAt(), launchedAt);
        vm.warp(launchedAt + 1);
        vm.expectRevert(AntiSniperHook.InitializationMustBeAtomic.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, PRICE_1_1);
    }

    function test_wrongCurrencyAndHookCannotReuseTheHook() public {
        PoolKey memory wrong = key;
        wrong.currency0 = Currency.wrap(address(new MockERC20("Other", "OTHER", 1 ether)));
        vm.expectRevert(AntiSniperHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), wrong, PRICE_1_1);
        wrong = key;
        wrong.hooks = IHooks(makeAddr("other-hook"));
        vm.expectRevert(AntiSniperHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), wrong, SwapParams(buyZeroForOne, -1 ether, PRICE_1_1), "");
        vm.expectRevert(AntiSniperHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), wrong, SwapParams(buyZeroForOne, 1 ether, PRICE_1_1), toBalanceDelta(0, 0), "");
    }

    function test_zeroAddressesAndChangedEconomicsCannotDeploy() public {
        vm.expectRevert(AntiSniperHook.ZeroAddress.selector);
        new AntiSniperHook(manager, address(hamster), 3000, 500, 600, address(0));
        vm.expectRevert(AntiSniperHook.ZeroAddress.selector);
        new AntiSniperHook(IPoolManager(address(0)), address(hamster), 3000, 500, 600, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.ZeroAddress.selector);
        new AntiSniperHook(manager, address(0), 3000, 500, 600, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.InvalidToken.selector);
        new AntiSniperHook(manager, DeploymentConfig.IMD, 3000, 500, 600, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.InvalidConfiguration.selector);
        new AntiSniperHook(manager, address(hamster), 3001, 500, 600, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.InvalidConfiguration.selector);
        new AntiSniperHook(manager, address(hamster), 3000, 0, 600, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.InvalidConfiguration.selector);
        new AntiSniperHook(manager, address(hamster), 3000, 500, 0, DeploymentConfig.FEE_RECIPIENT);
        vm.expectRevert(AntiSniperHook.InvalidConfiguration.selector);
        new AntiSniperHook(manager, address(hamster), 3000, 500, 600, address(this));
    }

    function test_prelaunchTimestampDoesNotUnderflow() public {
        vm.warp(launchedAt - 1);
        assertEq(hook.currentFeeBps(), 3000);
    }

    function test_noAdministrativeOrWithdrawalSelectors() public {
        string[12] memory selectors = [
            "owner()",
            "pause()",
            "unpause()",
            "setFee(uint256)",
            "setStartBps(uint256)",
            "setFloorBps(uint256)",
            "setFeeRecipient(address)",
            "setPoolInitialisedAt(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "rescue(address,uint256)",
            "sweep(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(DeploymentConfig.FEE_RECIPIENT);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(selectors[i], address(this), 0));
            assertFalse(ok, selectors[i]);
        }
        assertEq(hook.currentFeeBps(), 3000);
    }

    function test_arbitraryHookDataCannotWaiveFeeOrRedirectRecipient() public {
        uint256 before = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        driver.swap(
            PoolDriver.SwapRequest(
                key,
                SwapParams(
                    buyZeroForOne,
                    -int256(10 ether),
                    buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                10 ether,
                1,
                false,
                abi.encode(address(this), uint256(0), false)
            )
        );
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - before, 3 ether);
    }

    function test_failedSlippageCheckRollsBackFeeAndSwap() public {
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 payerBefore = imd.balanceOf(address(this));
        vm.expectRevert(PoolDriver.Slippage.selector);
        driver.swap(
            PoolDriver.SwapRequest(
                key,
                SwapParams(
                    buyZeroForOne,
                    -int256(10 ether),
                    buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                10 ether,
                100 ether,
                true,
                ""
            )
        );
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), recipientBefore);
        assertEq(imd.balanceOf(address(this)), payerBefore);
        _assertClean();
    }

    function test_partialFillExactInputFeesOnlyActualInputAndRefundsUnusedBudget() public {
        uint256 before = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 payerBefore = imd.balanceOf(address(this));
        BalanceDelta delta = _swapLimit(
            true,
            -int256(1000 ether),
            1000 ether,
            true,
            TickMath.getSqrtPriceAtTick(buyZeroForOne ? int24(-1) : int24(1))
        );
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - before, _input(delta, true) * 3000 / 10_000);
        assertLt(_input(delta, true), 1000 ether);
        assertGt(_output(delta, true), 0);
        assertEq(payerBefore - imd.balanceOf(address(this)), _input(delta, true));
        _assertClean();
    }

    function test_unfilledExactInputBuyCannotTakeFee() public {
        driver.modify(key, ModifyLiquidityParams(-887220, 887220, -int256(LIQUIDITY), bytes32(0)), 0, 0);
        uint256 fees = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 funds = imd.balanceOf(address(this));
        BalanceDelta delta = _swap(true, -int256(10 ether), 10 ether, true);
        assertEq(_input(delta, true), 0);
        assertEq(_output(delta, true), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), fees);
        assertEq(imd.balanceOf(address(this)), funds);
        _assertClean();
    }

    function test_partialFillExactOutputFeesOnlyActualInput() public {
        uint256 before = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta delta = _swapLimit(
            true,
            int256(1000 ether),
            1000 ether,
            true,
            TickMath.getSqrtPriceAtTick(buyZeroForOne ? int24(-1) : int24(1))
        );
        assertGt(_output(delta, true), 0);
        assertLt(_output(delta, true), 1000 ether);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - before, _input(delta, true) * 3000 / 10_000);
        _assertClean();
    }

    function test_dustBuyCanRoundFeeToZeroButRateIsNeverZero() public {
        uint256 before = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        _swap(true, -1, 1, true);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), before);
        assertEq(hook.currentFeeBps(), 3000);
        _assertClean();
    }

    function test_recipientContractCannotRejectERC20Payment() public {
        // A recipient reverting on every call cannot veto an ordinary ERC-20 transfer.
        vm.etch(DeploymentConfig.FEE_RECIPIENT, hex"60006000fd");
        _assertExactInputBuy(1 ether, 3000, false);
    }

    function testFuzz_previewLeavesExactlyOneSwapAndOneLPFee(bool priceLimited) public {
        PoolKey memory control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(control, PRICE_1_1);
        driver.modify(
            control, ModifyLiquidityParams(-887220, 887220, int256(LIQUIDITY), bytes32(0)), LIQUIDITY, LIQUIDITY
        );
        uint160 limit = priceLimited
            ? TickMath.getSqrtPriceAtTick(buyZeroForOne ? int24(-1) : int24(1))
            : (buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        BalanceDelta taxed = _swapLimit(true, -int256(1000 ether), 1000 ether, true, limit);
        BalanceDelta plain = driver.swap(
            PoolDriver.SwapRequest(
                control, SwapParams(buyZeroForOne, -int256(700 ether), limit), 700 ether, 0, true, ""
            )
        );
        assertEq(_output(taxed, true), _output(plain, true));
        uint256 gross = _input(taxed, true);
        assertEq(gross - _input(plain, true), gross * 3000 / 10_000);
        (uint160 priceA, int24 tickA,,) = manager.getSlot0(key.toId());
        (uint160 priceB, int24 tickB,,) = manager.getSlot0(control.toId());
        assertEq(priceA, priceB);
        assertEq(tickA, tickB);
        (uint256 fees0A, uint256 fees1A) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 fees0B, uint256 fees1B) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(fees0A, fees0B);
        assertEq(fees1A, fees1B);
        _assertClean();
    }

    function test_invalidPriceLimitRevertsWithoutChargingFee() public {
        uint256 fees = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 funds = imd.balanceOf(address(this));
        vm.expectRevert();
        _swapLimit(true, -int256(1 ether), 1 ether, true, PRICE_1_1);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), fees);
        assertEq(imd.balanceOf(address(this)), funds);
        _assertClean();
    }
}

contract ReversedCurrencyOrderTest is AntiSniperHookTest {
    function setUp() public override {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        hamster = _tokenOnSide(true);
        _installQuote();
        _createPool();
        _seed();
    }
}
