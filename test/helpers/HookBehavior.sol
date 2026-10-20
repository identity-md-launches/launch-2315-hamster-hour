// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeploymentConfig} from "../../src/DeploymentConfig.sol";
import {HookFixture} from "./HookFixture.sol";

/// @dev The same economic assertions run on both local currency orderings and actual mainnet state.
abstract contract HookBehavior is HookFixture {
    using TransientStateLibrary for IPoolManager;

    function test_exactDecayBoundariesAndPermanentFloor() public {
        assertEq(hook.currentFeeBps(), 3000);
        vm.warp(launchedAt + 300);
        assertEq(hook.currentFeeBps(), 1750);
        vm.warp(launchedAt + 599);
        assertEq(hook.currentFeeBps(), 504);
        vm.warp(launchedAt + 600);
        assertEq(hook.currentFeeBps(), 500);
        vm.warp(launchedAt + 601);
        assertEq(hook.currentFeeBps(), 500);
        vm.warp(type(uint256).max);
        assertEq(hook.currentFeeBps(), 500);
    }

    function testFuzz_rateMatchesFormulaAndNeverZero(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, type(uint256).max - launchedAt);
        vm.warp(launchedAt + elapsed);
        uint256 expected = elapsed >= 600 ? 500 : 500 + 2500 * (600 - elapsed) / 600;
        assertEq(hook.currentFeeBps(), expected);
        assertEq(hook.feeBps(buyZeroForOne), expected);
        assertEq(hook.feeBps(!buyZeroForOne), 0);
        assertGe(expected, 500);
        assertLe(expected, 3000);
    }

    function test_buyExactInputPayoutAtEveryBoundary() public {
        uint256[6] memory times = [uint256(0), 300, 599, 600, 601, 100 * 365 days];
        uint256[6] memory rates = [uint256(3000), 1750, 504, 500, 500, 500];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(launchedAt + times[i]);
            _assertExactInputBuy(10 ether, rates[i], false);
        }
    }

    function test_buyExactOutputPayoutAtEveryBoundary() public {
        uint256[5] memory times = [uint256(0), 300, 599, 600, 100 * 365 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(launchedAt + times[i]);
            _assertExactOutputBuy(1 ether, false);
        }
    }

    function test_sellsAreUntaxedExactInputAndOutputAtEveryBoundary() public {
        uint256[6] memory times = [uint256(0), 300, 599, 600, 601, 100 * 365 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(launchedAt + times[i]);
            uint256 before = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
            uint256 tokens = hamster.balanceOf(address(this));
            uint256 quote = imd.balanceOf(address(this));
            BalanceDelta d = _swap(false, -int256(1 ether), 1 ether, false);
            assertEq(_input(d, false), 1 ether);
            assertEq(hamster.balanceOf(address(this)), tokens - 1 ether);
            assertEq(imd.balanceOf(address(this)), quote + _output(d, false));
            assertGt(_output(d, false), 0);
            d = _swap(false, int256(1 ether), 10 ether, false);
            assertEq(_output(d, false), 1 ether);
            assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), before);
            _assertClean();
        }
    }

    function testFuzz_buyExactInputConservesBalances(uint96 rawAmount, uint32 elapsed, bool prepay) public {
        uint256 amount = bound(uint256(rawAmount), 100, 100 ether);
        vm.warp(launchedAt + uint256(elapsed));
        _assertExactInputBuy(amount, hook.currentFeeBps(), prepay);
    }

    function testFuzz_buyExactOutputConservesBalances(uint80 rawOutput, uint32 elapsed, bool prepay) public {
        uint256 output = bound(uint256(rawOutput), 100, 10 ether);
        vm.warp(launchedAt + uint256(elapsed));
        _assertExactOutputBuy(output, prepay);
    }

    function testFuzz_priceLimitedBuyTaxesOnlySpentInput(uint96 rawAmount, uint16 rawTick, uint32 elapsed) public {
        uint256 budget = bound(uint256(rawAmount), 100, 100_000 ether);
        int24 tick = int24(int256(bound(uint256(rawTick), 1, 600)));
        vm.warp(launchedAt + uint256(elapsed));
        uint256 payerBefore = imd.balanceOf(address(this));
        uint256 poolBefore = imd.balanceOf(address(manager));
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta delta =
            _swapLimit(true, -int256(budget), budget, true, TickMath.getSqrtPriceAtTick(buyZeroForOne ? -tick : tick));
        uint256 spent = _input(delta, true);
        uint256 fee = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - recipientBefore;
        assertLe(spent, budget);
        assertEq(fee, spent * hook.currentFeeBps() / 10_000);
        assertEq(imd.balanceOf(address(manager)) - poolBefore + fee, spent);
        assertEq(payerBefore - imd.balanceOf(address(this)), spent);
        _assertClean();
    }

    function test_plainTransferNeverCallsHook() public {
        address recipient = makeAddr("transfer-recipient");
        uint256 fees = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 starting = hamster.balanceOf(address(this));
        hamster.transfer(recipient, 7 ether);
        assertEq(hamster.balanceOf(recipient), 7 ether);
        vm.warp(launchedAt + 600);
        hamster.transfer(recipient, 13 ether);
        assertEq(hamster.balanceOf(recipient), 20 ether);
        assertEq(hamster.balanceOf(address(this)), starting - 20 ether);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), fees);
    }

    function test_factoryCanCollectFeesAndWithdrawAllLiquidity() public {
        _swap(true, -int256(100 ether), 100 ether, false);
        _swap(false, -int256(1 ether), 1 ether, false);
        uint256 fees = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta collect = driver.modify(key, ModifyLiquidityParams(-887220, 887220, 0, bytes32(0)), 0, 0);
        assertGe(collect.amount0(), 0);
        assertGe(collect.amount1(), 0);
        assertTrue(collect.amount0() > 0 || collect.amount1() > 0);
        BalanceDelta removed =
            driver.modify(key, ModifyLiquidityParams(-887220, 887220, -int256(LIQUIDITY), bytes32(0)), 0, 0);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), fees);
        _assertClean();
    }

    function _assertExactInputBuy(uint256 gross, uint256 rate, bool prepay) internal {
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 payerBefore = imd.balanceOf(address(this));
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 tokensBefore = hamster.balanceOf(address(this));
        uint256 poolTokensBefore = hamster.balanceOf(address(manager));
        uint256 fee = gross * rate / 10_000;
        BalanceDelta delta = _swap(true, -int256(gross), gross, prepay);
        assertEq(_input(delta, true), gross);
        assertGt(_output(delta, true), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - recipientBefore, fee);
        assertEq(payerBefore - imd.balanceOf(address(this)), gross);
        assertEq(imd.balanceOf(address(manager)) - managerBefore, gross - fee);
        assertEq(hamster.balanceOf(address(this)) - tokensBefore, _output(delta, true));
        assertEq(poolTokensBefore - hamster.balanceOf(address(manager)), _output(delta, true));
        _assertClean();
    }

    function _assertExactOutputBuy(uint256 output, bool prepay) internal {
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 payerBefore = imd.balanceOf(address(this));
        uint256 tokensBefore = hamster.balanceOf(address(this));
        BalanceDelta delta = _swap(true, int256(output), 100 ether, prepay);
        uint256 gross = _input(delta, true);
        uint256 fee = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - recipientBefore;
        uint256 net = imd.balanceOf(address(manager)) - managerBefore;
        assertEq(_output(delta, true), output);
        assertEq(hamster.balanceOf(address(this)) - tokensBefore, output);
        assertEq(payerBefore - imd.balanceOf(address(this)), gross);
        assertEq(net + fee, gross);
        assertEq(fee, gross * hook.currentFeeBps() / 10_000);
        assertEq(fee, net * hook.currentFeeBps() / (10_000 - hook.currentFeeBps()));
        _assertClean();
    }

    function _assertClean() internal view {
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
        assertEq(hamster.balanceOf(address(driver)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(DeploymentConfig.IMD))), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(driver), key.currency0), 0);
        assertEq(manager.currencyDelta(address(driver), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
