// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {AntiSniperHook} from "../../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../../src/DeploymentConfig.sol";
import {HookSalt} from "../../src/libraries/HookSalt.sol";
import {PoolDriver} from "./PoolDriver.sol";

abstract contract HookFixture is Test {
    uint160 internal constant PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;
    IPoolManager internal manager;
    HamsterHourToken internal hamster;
    IERC20 internal imd;
    AntiSniperHook internal hook;
    PoolDriver internal driver;
    PoolKey internal key;
    uint256 internal launchedAt;
    bool internal buyZeroForOne;

    function _deployHook(IPoolManager manager_, address token) internal returns (AntiSniperHook deployed) {
        bytes memory code = abi.encodePacked(
            type(AntiSniperHook).creationCode,
            abi.encode(
                manager_,
                token,
                DeploymentConfig.START_BPS,
                DeploymentConfig.FLOOR_BPS,
                DeploymentConfig.DECAY_SECONDS,
                DeploymentConfig.FEE_RECIPIENT
            )
        );
        (address predicted, bytes32 salt) = HookSalt.find(address(this), keccak256(code), 0, 200_000);
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        assertEq(at, predicted, "mined hook deployment failed");
        deployed = AntiSniperHook(at);
    }

    function _createPool() internal {
        _createPoolAtPrice(PRICE_1_1);
    }

    function _createPoolAtPrice(uint160 price) internal {
        hook = _deployHook(manager, address(hamster));
        launchedAt = block.timestamp;
        buyZeroForOne = DeploymentConfig.IMD < address(hamster);
        (address a, address b) =
            buyZeroForOne ? (DeploymentConfig.IMD, address(hamster)) : (address(hamster), DeploymentConfig.IMD);
        key = PoolKey(
            Currency.wrap(a),
            Currency.wrap(b),
            DeploymentConfig.POOL_FEE,
            DeploymentConfig.TICK_SPACING,
            IHooks(address(hook))
        );
        manager.initialize(key, price);
        driver = new PoolDriver(manager);
        hamster.approve(address(driver), type(uint256).max);
        imd.approve(address(driver), type(uint256).max);
    }

    function _seed() internal {
        driver.modify(key, ModifyLiquidityParams(-887220, 887220, int256(LIQUIDITY), bytes32(0)), LIQUIDITY, LIQUIDITY);
    }

    function _swap(bool buy, int256 specified, uint256 maxInput, bool prepay) internal returns (BalanceDelta) {
        bool z = buy ? buyZeroForOne : !buyZeroForOne;
        return
            _swapLimit(buy, specified, maxInput, prepay, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swapLimit(bool buy, int256 specified, uint256 maxInput, bool prepay, uint160 limit)
        internal
        returns (BalanceDelta)
    {
        return driver.swap(
            PoolDriver.SwapRequest({
                key: key,
                params: SwapParams(buy ? buyZeroForOne : !buyZeroForOne, specified, limit),
                maxInput: maxInput,
                minOutput: 0,
                prepay: prepay,
                hookData: ""
            })
        );
    }

    function _input(BalanceDelta delta, bool buy) internal view returns (uint256) {
        bool z = buy ? buyZeroForOne : !buyZeroForOne;
        return uint256(-int256(z ? delta.amount0() : delta.amount1()));
    }

    function _output(BalanceDelta delta, bool buy) internal view returns (uint256) {
        bool z = buy ? buyZeroForOne : !buyZeroForOne;
        return uint256(int256(z ? delta.amount1() : delta.amount0()));
    }
}
