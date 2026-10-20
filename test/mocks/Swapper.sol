// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolDriver} from "../helpers/PoolDriver.sol";

/// @dev Prefunded test adapter for the supplied launch-factory fee-collection probe.
///      Test-only: its balances are provided by the harness, not pulled from arbitrary payers.
contract Swapper is PoolDriver {
    constructor(IPoolManager manager_) PoolDriver(manager_) {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (BalanceDelta) {
        require(amount <= uint256(type(int256).max), "test input too large");
        SwapRequest memory request = SwapRequest({
            key: key,
            params: SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            maxInput: amount,
            minOutput: 0,
            prepay: true,
            hookData: ""
        });
        return abi.decode(manager.unlock(abi.encode(uint8(0), abi.encode(request))), (BalanceDelta));
    }
}
