// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFixture} from "./helpers/HookFixture.sol";

/// @notice Exercises the flash-accounting balance constraint of immediate ERC-20 fee delivery.
contract SettlementTest is HookFixture {
    function setUp() public {
        manager = new PoolManager(address(this));
        hamster = new HamsterHourToken();
        MockERC20 mock = new MockERC20("IMD", "IMD", 0);
        vm.etch(DeploymentConfig.IMD, address(mock).code);
        MockERC20(DeploymentConfig.IMD).mint(address(this), 2_000_000 ether);
        imd = IERC20(DeploymentConfig.IMD);
        deal(DeploymentConfig.IMD, DeploymentConfig.FEE_RECIPIENT, 0);
        deal(DeploymentConfig.IMD, address(manager), 0);
        vm.deal(address(manager), 0);
        _createPool();
        // Entire position is HAMSTER; no input quote currency is deposited in the manager.
        int24 lower = buyZeroForOne ? int24(-120) : int24(60);
        int24 upper = buyZeroForOne ? int24(-60) : int24(120);
        driver.modify(key, ModifyLiquidityParams(lower, upper, int256(LIQUIDITY), bytes32(0)), LIQUIDITY, LIQUIDITY);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
    }

    function test_tokenOnlySeedExactInputPaysRecipientImmediately() public {
        uint256 payer = imd.balanceOf(address(this));
        BalanceDelta d = _swap(true, -int256(10 ether), 10 ether, true);
        assertEq(_input(d, true), 10 ether);
        assertGt(_output(d, true), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), 3 ether);
        assertEq(imd.balanceOf(address(manager)), 7 ether);
        assertEq(imd.balanceOf(address(this)), payer - 10 ether);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
    }

    function test_tokenOnlySeedExactOutputPaysRecipientImmediately() public {
        BalanceDelta d = _swap(true, int256(10 ether), 100 ether, true);
        uint256 gross = _input(d, true);
        assertEq(_output(d, true), 10 ether);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), gross * 3000 / 10_000);
        assertEq(imd.balanceOf(address(manager)) + imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), gross);
        assertEq(imd.balanceOf(address(driver)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_unfundedPostpayCannotPayFeeAndRevertsAtomically() public {
        // Documents the integration constraint, rather than silently replacing immediate fees with claims.
        uint256 payer = imd.balanceOf(address(this));
        vm.expectRevert();
        _swap(true, -int256(10 ether), 10 ether, false);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), 0);
        assertEq(imd.balanceOf(address(this)), payer);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
    }

    function test_sellAtLaunchNeverAttemptsToPayRecipient() public {
        // No IMD liquidity is available yet: core returns no fill, the hook still charges nothing.
        BalanceDelta d = _swap(false, -int256(1 ether), 1 ether, false);
        assertEq(_input(d, false), 0);
        assertEq(_output(d, false), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), 0);
    }

    function test_largePrepaidBuyWithPriceLimitDoesNotDependOnManagerBalance() public {
        BalanceDelta d = _swapLimit(
            true,
            -int256(1_000_000 ether),
            1_000_000 ether,
            true,
            TickMath.getSqrtPriceAtTick(buyZeroForOne ? int24(-90) : int24(90))
        );
        assertLt(_input(d, true), 1_000_000 ether);
        assertGt(_output(d, true), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), _input(d, true) * 3000 / 10_000);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
    }
}
