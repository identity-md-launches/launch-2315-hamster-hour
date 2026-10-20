// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFixture} from "./helpers/HookFixture.sol";

/// @dev Test-only prefunded router: runs several swaps inside one unlock and settles the net from its
///      own balance afterwards (post-settlement, like V4Router's SETTLE_ALL). Never pulls from a third party.
contract BatchSwapper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(PoolKey memory key, SwapParams[] memory swaps) external returns (BalanceDelta[] memory) {
        return abi.decode(manager.unlock(abi.encode(key, swaps)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, SwapParams[] memory swaps) = abi.decode(data, (PoolKey, SwapParams[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            deltas[i] = manager.swap(key, swaps[i], "");
        }
        _close(key.currency0);
        _close(key.currency1);
        return abi.encode(deltas);
    }

    function _close(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}

contract AdversarialEdgesTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    BatchSwapper internal batch;

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        hamster = new HamsterHourToken();
        vm.etch(DeploymentConfig.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = IERC20(DeploymentConfig.IMD);
        MockERC20(DeploymentConfig.IMD).mint(address(this), 100_000_000 ether);
        deal(DeploymentConfig.IMD, DeploymentConfig.FEE_RECIPIENT, 0);
        _createPool();
        _seed();
        batch = new BatchSwapper(manager);
        MockERC20(DeploymentConfig.IMD).mint(address(batch), type(uint128).max);
        hamster.transfer(address(batch), 10_000_000 ether);
    }

    function _buyLimit() internal view returns (uint160) {
        return buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _sellLimit() internal view returns (uint160) {
        return buyZeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
    }

    function _imdDelta(BalanceDelta d) internal view returns (int128) {
        return buyZeroForOne ? d.amount0() : d.amount1();
    }

    function _hamsterDelta(BalanceDelta d) internal view returns (int128) {
        return buyZeroForOne ? d.amount1() : d.amount0();
    }

    function _owed() internal view returns (uint256) {
        return imd.balanceOf(DeploymentConfig.FEE_RECIPIENT)
            + manager.balanceOf(address(hook), uint256(uint160(DeploymentConfig.IMD)));
    }

    function _assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_quoteInputRefusesEveryExternalCaller(address caller, bool zeroForOne, int128 amount) public {
        vm.assume(caller != address(hook));
        vm.prank(caller);
        vm.expectRevert(AntiSniperHook.OnlySelf.selector);
        hook.quoteInput(key, SwapParams(zeroForOne, int256(amount), _buyLimit()));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_afterSwapAndUnlockCallbackRefuseNonManager(address caller, int128 a0, int128 a1) public {
        vm.assume(caller != address(manager));
        vm.startPrank(caller);
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.afterSwap(caller, key, SwapParams(buyZeroForOne, 1 ether, _buyLimit()), toBalanceDelta(a0, a1), "");
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.beforeSwap(caller, key, SwapParams(buyZeroForOne, -1 ether, _buyLimit()), "");
        vm.expectRevert(AntiSniperHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.stopPrank();
    }

    /// @dev The extreme specified amount: int256.min exact input, bounded only by a price limit one
    ///      spacing away. The hook must not overflow, revert, or tax the unspent budget.
    function test_int256MinExactInputBuyIsTaxedOnlyOnSpentInput() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(buyZeroForOne ? int24(-60) : int24(60));
        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = SwapParams(buyZeroForOne, type(int256).min, limit);
        uint256 owedBefore = _owed();
        BalanceDelta[] memory d = batch.run(key, swaps);
        uint256 gross = uint256(-int256(_imdDelta(d[0])));
        assertGt(gross, 0);
        assertLt(gross, 100_000 ether, "only the price-limited input is spent");
        assertGt(_hamsterDelta(d[0]), 0);
        assertEq(_owed() - owedBefore, gross * 3000 / 10_000);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        _assertSettled();
    }

    /// @dev "The same call twice": several buys in one unlock each pay the full current rate.
    ///      Splitting a buy across swaps within a transaction does not dodge the fee.
    function test_repeatedBuysInOneUnlockEachPayTheFullRate() public {
        vm.warp(launchedAt + 120);
        uint256 rate = hook.currentFeeBps();
        assertEq(rate, 2500);
        SwapParams[] memory swaps = new SwapParams[](4);
        swaps[0] = SwapParams(buyZeroForOne, -1 ether, _buyLimit());
        swaps[1] = SwapParams(buyZeroForOne, -1 ether, _buyLimit());
        swaps[2] = SwapParams(buyZeroForOne, 0.5 ether, _buyLimit());
        swaps[3] = SwapParams(!buyZeroForOne, -1 ether, _sellLimit());
        uint256 owedBefore = _owed();
        BalanceDelta[] memory d = batch.run(key, swaps);
        uint256 expected;
        for (uint256 i; i < 3; ++i) {
            expected += uint256(-int256(_imdDelta(d[i]))) * rate / 10_000;
        }
        assertEq(uint256(-int256(_imdDelta(d[0]))), 1 ether);
        assertEq(uint256(int256(_hamsterDelta(d[2]))), 0.5 ether);
        assertEq(_owed() - owedBefore, expected, "each buy taxed once at the full rate, the sell not at all");
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_sellNeverTaxedAtAnyTimeOrMode(uint64 raw, uint32 elapsed, bool exactOutput, bool prepay) public {
        uint256 amount = bound(uint256(raw), 1, 100 ether);
        vm.warp(launchedAt + uint256(elapsed));
        uint256 owedBefore = _owed();
        uint256 tokensBefore = hamster.balanceOf(address(this));
        uint256 quoteBefore = imd.balanceOf(address(this));
        BalanceDelta d = _swap(false, exactOutput ? int256(amount) : -int256(amount), 1000 ether, prepay);
        uint256 spent = _input(d, false);
        uint256 received = _output(d, false);
        if (exactOutput) assertEq(received, amount);
        else assertEq(spent, amount);
        assertEq(tokensBefore - hamster.balanceOf(address(this)), spent);
        assertEq(imd.balanceOf(address(this)) - quoteBefore, received);
        assertEq(_owed(), owedBefore, "a sell paid the recipient");
        assertEq(hook.feeBps(!buyZeroForOne), 0);
        _assertSettled();
    }

    /// @dev Sell at t=0, the moment the buy fee is at its 30% maximum, in a manager holding no spare IMD
    ///      beyond pool liquidity: it must go through untaxed and never touch the recipient.
    function test_sellAtLaunchSecondIsUntaxedAndBuyBackIsTaxed() public {
        assertEq(block.timestamp, launchedAt);
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams(!buyZeroForOne, -10 ether, _sellLimit());
        swaps[1] = SwapParams(buyZeroForOne, -10 ether, _buyLimit());
        BalanceDelta[] memory d = batch.run(key, swaps);
        assertEq(uint256(-int256(_hamsterDelta(d[0]))), 10 ether);
        assertGt(_imdDelta(d[0]), 0);
        assertEq(uint256(-int256(_imdDelta(d[1]))), 10 ether);
        assertEq(_owed(), 3 ether, "only the buy pays: 30% of 10");
        _assertSettled();
    }

    /// @dev Fuzzes the rate at every elapsed second, including far past decay and before launch.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_rateIsMonotoneAndNeverBelowFloor(uint256 a, uint256 b) public {
        uint256 t1 = bound(a, 0, type(uint64).max);
        uint256 t2 = bound(b, t1, type(uint64).max);
        vm.warp(launchedAt + t1);
        uint256 r1 = hook.currentFeeBps();
        vm.warp(launchedAt + t2);
        uint256 r2 = hook.currentFeeBps();
        assertLe(r2, r1, "rate rose over time");
        assertGe(r2, 500, "rate fell under the floor");
        assertGt(r2, 0);
        if (t2 >= 600) assertEq(r2, 500);
        if (t1 < 600) assertGt(r1, 500, "floor reached before DECAY_SECONDS");
    }

    /// @dev Exactly-one-second steps around the decay end: 599 -> 504, 600 -> 500, and no step ever adds bps.
    function test_everySecondOfTheDecayWindow() public {
        uint256 previous = type(uint256).max;
        for (uint256 s; s <= 600; ++s) {
            vm.warp(launchedAt + s);
            uint256 r = hook.currentFeeBps();
            assertEq(r, 500 + 2500 * (600 - s) / 600);
            assertLe(r, previous);
            previous = r;
        }
        vm.warp(launchedAt + 599);
        assertGt(hook.currentFeeBps(), DeploymentConfig.FLOOR_BPS);
    }

    /// @dev A second initialize of the same key, at the launch second or later, is refused by core and
    ///      cannot reset poolInitialisedAt.
    function test_reinitializeCannotResetClock() public {
        vm.warp(launchedAt + 500);
        vm.expectRevert();
        manager.initialize(key, PRICE_1_1);
        assertEq(hook.poolInitialisedAt(), launchedAt);
        assertEq(hook.currentFeeBps(), uint256(916));
    }

    /// @dev Anyone may call redeem; with nothing held it is a no-op and it never pays its caller.
    function test_redeemFromStrangerPaysOnlyRecipient() public {
        address stranger = makeAddr("stranger");
        uint256 strangerBefore = imd.balanceOf(stranger);
        vm.prank(stranger);
        assertEq(hook.redeem(), 0);
        assertEq(imd.balanceOf(stranger), strangerBefore);
        _assertSettled();
    }
}
