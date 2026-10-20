// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";

/// @dev Drives the launch-shaped pool: a fresh manager whose only liquidity is HAMSTER, so the
///      manager's IMD comes solely from buys. Postpaying buys exercise the ERC-6909 claim fallback,
///      prepaying buys the immediate path, and anyone may call redeem().
contract ClaimHandler is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager public immutable manager;
    AntiSniperHook public immutable hook;
    PoolDriver public immutable driver;
    IERC20 public immutable imd;
    IERC20 public immutable hamster;
    bool internal immutable buyZeroForOne;
    PoolKey internal key;
    address[3] internal actors;

    /// @dev What the recipient is owed in total: every buy's exact gross * rate / 10000.
    uint256 public ghostFees;
    uint256 public ghostClaimMints;
    uint256 public ghostRedeems;
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
        actors = [makeAddr("actor-a"), makeAddr("actor-b"), makeAddr("actor-c")];
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            imd.approve(address(driver_), type(uint256).max);
            hamster.approve(address(driver_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function owed() public view returns (uint256) {
        return imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) + manager.balanceOf(address(hook), _imdId());
    }

    function buy(uint8 who, bool exactOutput, uint64 raw, bool prepay) external {
        address trader = actors[who % 3];
        uint256 amount = bound(uint256(raw), 1, 1 ether);
        uint256 owedBefore = owed();
        uint256 claimsBefore = manager.balanceOf(address(hook), _imdId());
        uint256 payerBefore = imd.balanceOf(trader);
        uint256 rate = hook.currentFeeBps();
        vm.prank(trader);
        BalanceDelta delta = driver.swap(
            PoolDriver.SwapRequest(
                key,
                SwapParams(
                    buyZeroForOne,
                    exactOutput ? int256(amount) : -int256(amount),
                    buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                exactOutput ? 10 ether : amount,
                0,
                prepay,
                ""
            )
        );
        uint256 gross = uint256(-int256(buyZeroForOne ? delta.amount0() : delta.amount1()));
        assertEq(payerBefore - imd.balanceOf(trader), gross, "trader paid other than the reported gross");
        if (!exactOutput) assertEq(gross, amount, "exact-input buy did not spend its whole budget");
        uint256 fee = gross * rate / 10_000;
        assertEq(owed() - owedBefore, fee, "recipient was not credited exactly the fee");
        if (manager.balanceOf(address(hook), _imdId()) > claimsBefore) ++ghostClaimMints;
        ghostFees += fee;
        ++buys;
    }

    function sell(uint8 who, bool exactOutput, uint64 raw, bool prepay) external {
        // Sells push the price back toward the opening price; there is no liquidity past it.
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (price == PRICE_1_1) return;
        address trader = actors[who % 3];
        uint256 amount = bound(uint256(raw), 1, 1 ether);
        uint256 owedBefore = owed();
        uint256 tokensBefore = hamster.balanceOf(trader);
        uint256 quoteBefore = imd.balanceOf(trader);
        vm.prank(trader);
        BalanceDelta delta = driver.swap(
            PoolDriver.SwapRequest(
                key,
                SwapParams(!buyZeroForOne, exactOutput ? int256(amount) : -int256(amount), PRICE_1_1),
                exactOutput ? 10 ether : amount,
                0,
                prepay,
                ""
            )
        );
        uint256 spent = uint256(-int256(buyZeroForOne ? delta.amount1() : delta.amount0()));
        uint256 received = uint256(int256(buyZeroForOne ? delta.amount0() : delta.amount1()));
        assertEq(tokensBefore - hamster.balanceOf(trader), spent, "sell moved other than the AMM input");
        assertEq(imd.balanceOf(trader) - quoteBefore, received, "sell paid out other than the AMM output");
        assertEq(owed(), owedBefore, "a sell credited the recipient");
        ++sells;
    }

    function redeemAs(uint8 who) external {
        uint256 owedBefore = owed();
        uint256 claimsBefore = manager.balanceOf(address(hook), _imdId());
        uint256 recipientBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        vm.prank(actors[who % 3]);
        uint256 paid = hook.redeem();
        assertEq(owed(), owedBefore, "redeem changed what the recipient is owed");
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - recipientBefore, paid, "redeem paid elsewhere");
        assertEq(claimsBefore - manager.balanceOf(address(hook), _imdId()), paid, "redeem burned other than paid");
        if (paid != 0) ++ghostRedeems;
    }

    function transfer(uint8 from, uint8 to, uint64 raw) external {
        address a = actors[from % 3];
        address b = actors[to % 3];
        uint256 amount = bound(uint256(raw), 0, hamster.balanceOf(a));
        uint256 aBefore = hamster.balanceOf(a);
        uint256 bBefore = hamster.balanceOf(b);
        vm.prank(a);
        hamster.transfer(b, amount);
        if (a != b) {
            assertEq(aBefore - hamster.balanceOf(a), amount, "sender lost other than the amount");
            assertEq(hamster.balanceOf(b) - bBefore, amount, "recipient got other than the amount");
        } else {
            assertEq(hamster.balanceOf(a), aBefore, "self-transfer changed balance");
        }
    }

    function advance(uint32 secondsForward) external {
        vm.warp(block.timestamp + bound(uint256(secondsForward), 0, 400));
        uint256 current = hook.currentFeeBps();
        assertLe(current, lastRate, "rate increased");
        lastRate = current;
    }

    function _imdId() internal pure returns (uint256) {
        return uint256(uint160(DeploymentConfig.IMD));
    }
}

contract ClaimInvariantTest is StdInvariant, HookFixture {
    using TransientStateLibrary for IPoolManager;

    ClaimHandler internal handler;
    uint256 internal quoteSupply;

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        hamster = new HamsterHourToken();
        vm.etch(DeploymentConfig.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = IERC20(DeploymentConfig.IMD);
        MockERC20(DeploymentConfig.IMD).mint(address(this), 2_000_000 ether);
        deal(DeploymentConfig.IMD, DeploymentConfig.FEE_RECIPIENT, 0);
        _createPool();
        int24 lower = buyZeroForOne ? int24(-120) : int24(60);
        int24 upper = buyZeroForOne ? int24(-60) : int24(120);
        driver.modify(key, ModifyLiquidityParams(lower, upper, int256(LIQUIDITY), bytes32(0)), LIQUIDITY, LIQUIDITY);
        assertEq(imd.balanceOf(address(manager)), 0, "seed must be HAMSTER only");

        handler = new ClaimHandler(manager, hook, driver, key);
        for (uint256 i; i < 3; ++i) {
            imd.transfer(handler.actor(i), 1_000 ether);
            hamster.transfer(handler.actor(i), 1_000 ether);
        }
        quoteSupply = imd.totalSupply();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = ClaimHandler.buy.selector;
        selectors[1] = ClaimHandler.sell.selector;
        selectors[2] = ClaimHandler.redeemAs.selector;
        selectors[3] = ClaimHandler.transfer.selector;
        selectors[4] = ClaimHandler.advance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_recipientIsOwedExactlyEveryBuyFee() public view {
        assertEq(handler.owed(), handler.ghostFees());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_claimsAreAlwaysBackedByManagerIMD() public view {
        assertGe(
            imd.balanceOf(address(manager)), manager.balanceOf(address(hook), uint256(uint160(DeploymentConfig.IMD)))
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_hookHoldsNoTokensAndNoDebtSurvives() public view {
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(hamster)))), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
        assertEq(hamster.balanceOf(address(driver)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_suppliesConservedAcrossParticipants() public view {
        assertEq(hamster.totalSupply(), DeploymentConfig.SUPPLY);
        assertEq(imd.totalSupply(), quoteSupply);
        assertEq(_tracked(IERC20(address(hamster))), DeploymentConfig.SUPPLY);
        assertEq(_tracked(imd), quoteSupply);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_parametersFixedRateBoundedSellsFree() public view {
        assertEq(hook.START_BPS(), 3000);
        assertEq(hook.FLOOR_BPS(), 500);
        assertEq(hook.DECAY_SECONDS(), 600);
        assertEq(hook.FEE_RECIPIENT(), DeploymentConfig.FEE_RECIPIENT);
        assertEq(hook.poolInitialisedAt(), launchedAt);
        uint256 rate = hook.currentFeeBps();
        assertGe(rate, 500);
        assertLe(rate, 3000);
        assertEq(hook.feeBps(buyZeroForOne), rate);
        assertEq(hook.feeBps(!buyZeroForOne), 0);
    }

    /// @dev Non-vacuity: the handler's own actions reach the claim mint, the sweep-free redeem and a taxed sell-back.
    function test_handlerReachesClaimMintRedeemAndUntaxedSell() public {
        handler.buy(0, false, 1 ether, false);
        assertEq(handler.ghostClaimMints(), 1, "postpay buy on an IMD-empty manager must mint a claim");
        assertEq(handler.ghostFees(), 0.3 ether);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), 0);
        handler.redeemAs(1);
        assertEq(handler.ghostRedeems(), 1);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), 0.3 ether);
        handler.sell(2, false, 0.1 ether, false);
        assertEq(handler.sells(), 1);
        assertEq(handler.owed(), 0.3 ether);
    }

    function _tracked(IERC20 token) internal view returns (uint256 sum) {
        sum = token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(hook))
            + token.balanceOf(address(driver)) + token.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.actor(i));
        }
    }
}
