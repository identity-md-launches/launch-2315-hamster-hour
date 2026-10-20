// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";

contract SwapHandler is Test {
    IPoolManager public immutable manager;
    AntiSniperHook public immutable hook;
    PoolDriver public immutable driver;
    IERC20 public immutable imd;
    IERC20 public immutable hamster;
    PoolKey private key;
    bool private immutable buyZeroForOne;
    uint256 public accruedFees;
    uint256 public buys;
    uint256 public sells;
    uint256 public lastRate = 3000;

    constructor(IPoolManager manager_, AntiSniperHook hook_, PoolDriver driver_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        driver = driver_;
        key = key_;
        imd = IERC20(DeploymentConfig.IMD);
        hamster = IERC20(hook_.hamster());
        buyZeroForOne = DeploymentConfig.IMD < hook_.hamster();
        imd.approve(address(driver_), type(uint256).max);
        hamster.approve(address(driver_), type(uint256).max);
    }

    function trade(bool buy, bool exactOutput, uint80 raw, bool prepay) external {
        uint256 amount = bound(uint256(raw), 100, 1 ether);
        bool z = buy ? buyZeroForOne : !buyZeroForOne;
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta delta = driver.swap(
            PoolDriver.SwapRequest(
                key,
                SwapParams(
                    z,
                    exactOutput ? int256(amount) : -int256(amount),
                    z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                exactOutput ? 10 ether : amount,
                0,
                prepay,
                ""
            )
        );
        uint256 fee = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - recipientBefore;
        if (buy) {
            uint256 gross = uint256(-int256(z ? delta.amount0() : delta.amount1()));
            assertEq(fee, gross * hook.currentFeeBps() / 10_000);
            accruedFees += fee;
            ++buys;
        } else {
            assertEq(fee, 0);
            ++sells;
        }
    }

    function advance(uint16 secondsForward) external {
        vm.warp(block.timestamp + uint256(secondsForward));
        uint256 current = hook.currentFeeBps();
        assertLe(current, lastRate);
        assertGe(current, 500);
        lastRate = current;
    }

    function transferRoundTrip(uint80 raw) external {
        uint256 amount = bound(uint256(raw), 0, 100 ether);
        uint256 balance = hamster.balanceOf(address(this));
        hamster.transfer(address(driver), amount);
        // Test-only recipient impersonation verifies an ordinary return transfer is also untaxed.
        vm.prank(address(driver));
        hamster.transfer(address(this), amount);
        assertEq(hamster.balanceOf(address(this)), balance);
    }
}

contract HookInvariantTest is StdInvariant, HookFixture {
    using TransientStateLibrary for IPoolManager;

    SwapHandler internal handler;
    uint256 internal quoteSupply;
    uint256 internal recipientAtStart;

    function setUp() public {
        manager = new PoolManager(address(this));
        hamster = new HamsterHourToken();
        vm.etch(DeploymentConfig.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = IERC20(DeploymentConfig.IMD);
        deal(DeploymentConfig.IMD, address(this), 10_000_000 ether, true);
        deal(DeploymentConfig.IMD, DeploymentConfig.FEE_RECIPIENT, 0, true);
        _createPool();
        _seed();
        handler = new SwapHandler(manager, hook, driver, key);
        hamster.transfer(address(handler), 1_000_000 ether);
        imd.transfer(address(handler), 1_000_000 ether);
        quoteSupply = _trackedBalance(imd);
        recipientAtStart = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SwapHandler.trade.selector;
        selectors[1] = SwapHandler.advance.selector;
        selectors[2] = SwapHandler.transferRoundTrip.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_noCustodyClaimsOrUnsettledDebt() public view {
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
        assertEq(hamster.balanceOf(address(driver)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(DeploymentConfig.IMD))), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function invariant_conservationAndExactFeeRecipientAccounting() public view {
        assertEq(hamster.totalSupply(), 1_000_000_000 ether);
        assertEq(_trackedBalance(IERC20(address(hamster))), hamster.totalSupply());
        assertEq(_trackedBalance(imd), quoteSupply);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), recipientAtStart + handler.accruedFees());
    }

    function invariant_parametersAndBuyFloorRemainFixed() public view {
        assertEq(hook.START_BPS(), 3000);
        assertEq(hook.FLOOR_BPS(), 500);
        assertEq(hook.DECAY_SECONDS(), 600);
        assertEq(hook.FEE_RECIPIENT(), DeploymentConfig.FEE_RECIPIENT);
        assertEq(hook.poolInitialisedAt(), launchedAt);
        assertEq(hook.feeBps(!buyZeroForOne), 0);
        assertGe(hook.currentFeeBps(), 500);
        assertLe(hook.currentFeeBps(), 3000);
    }

    function _trackedBalance(IERC20 token) private view returns (uint256) {
        return token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(manager))
            + token.balanceOf(DeploymentConfig.FEE_RECIPIENT) + token.balanceOf(address(driver))
            + token.balanceOf(address(hook));
    }
}
