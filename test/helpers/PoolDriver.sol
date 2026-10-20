// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Integration test driver, not a launch contract. Pulls exclusively from msg.sender on entry.
///      Can settle the input budget before swapping, so fee payout needs no existing manager reserves.
contract PoolDriver is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    error OnlyManager();
    error Slippage();
    error Reentered();

    IPoolManager public immutable manager;
    bool private entered;

    struct SwapRequest {
        PoolKey key;
        SwapParams params;
        uint256 maxInput;
        uint256 minOutput;
        bool prepay;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier guarded() {
        if (entered) revert Reentered();
        entered = true;
        _;
        entered = false;
    }

    function swap(SwapRequest memory request) external guarded returns (BalanceDelta delta) {
        Currency input = request.params.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.params.zeroForOne ? request.key.currency1 : request.key.currency0;
        IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), request.maxInput);
        delta = abi.decode(manager.unlock(abi.encode(uint8(0), abi.encode(request))), (BalanceDelta));
        int128 inputDelta = request.params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = request.params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 received = uint256(int256(outputDelta));
        if (spent > request.maxInput || received < request.minOutput) revert Slippage();
        IERC20(Currency.unwrap(output)).safeTransfer(msg.sender, received);
        uint256 refund = request.maxInput - spent;
        if (refund != 0) IERC20(Currency.unwrap(input)).safeTransfer(msg.sender, refund);
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, uint256 budget0, uint256 budget1)
        external
        guarded
        returns (BalanceDelta delta)
    {
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        uint256 balance0 = t0.balanceOf(address(this));
        uint256 balance1 = t1.balanceOf(address(this));
        if (budget0 != 0) t0.safeTransferFrom(msg.sender, address(this), budget0);
        if (budget1 != 0) t1.safeTransferFrom(msg.sender, address(this), budget1);
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(key, params))), (BalanceDelta));
        uint256 refund0 = t0.balanceOf(address(this)) - balance0;
        uint256 refund1 = t1.balanceOf(address(this)) - balance1;
        if (refund0 != 0) t0.safeTransfer(msg.sender, refund0);
        if (refund1 != 0) t1.safeTransfer(msg.sender, refund1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        PoolKey memory key;
        BalanceDelta delta;
        if (action == 0) {
            SwapRequest memory request = abi.decode(body, (SwapRequest));
            key = request.key;
            if (request.prepay) {
                _pay(request.params.zeroForOne ? key.currency0 : key.currency1, request.maxInput);
            }
            delta = manager.swap(key, request.params, request.hookData);
        } else {
            ModifyLiquidityParams memory params;
            (key, params) = abi.decode(body, (PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _close(key.currency0);
        _close(key.currency1);
        return abi.encode(delta);
    }

    function _close(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) _pay(currency, uint256(-delta));
        else if (delta > 0) manager.take(currency, address(this), uint256(delta));
    }

    function _pay(Currency currency, uint256 amount) private {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
        manager.settle();
    }
}
