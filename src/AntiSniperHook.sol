// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

/// @notice Immutable IMD-input fee for one HAMSTER/IMD pool.
/// @dev Implements only the enabled IHooks callbacks. No fallback, owner, balances, or setters.
///      ERC-6909 IMD claims exist only when the manager cannot cover a fee mid-swap; they are
///      redeemable solely to FEE_RECIPIENT, by anyone, and are swept by the next covered buy.
contract AntiSniperHook is IUnlockCallback {
    using SafeCast for uint256;

    error OnlyPoolManager();
    error ZeroAddress();
    error InvalidToken();
    error InvalidConfiguration();
    error WrongPool();
    error InitializationMustBeAtomic();
    error OnlySelf();
    error QuotedInput(uint256 amount);
    error UnexpectedQuoteSuccess();

    IPoolManager public immutable poolManager;
    address public immutable hamster;
    PoolId public immutable poolId;
    uint256 public immutable START_BPS;
    uint256 public immutable FLOOR_BPS;
    uint256 public immutable DECAY_SECONDS;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable poolInitialisedAt;

    /// @notice A buy fee was charged: paid to FEE_RECIPIENT now, or held as an IMD claim for it.
    event BuyFeePaid(address indexed sender, uint256 feeBps, uint256 feeAmount);
    /// @notice The manager held too little IMD mid-swap, so the fee was minted as a claim for FEE_RECIPIENT.
    event FeeClaimMinted(uint256 amount);
    /// @notice Held claims were burned and paid out to FEE_RECIPIENT.
    event FeeClaimRedeemed(uint256 amount);

    /// @param manager_ The launch chain's PoolManager, supplied by the deployer.
    /// @param hamster_ The token deployed immediately before this hook.
    /// @dev The four economic arguments MUST equal DeploymentConfig. No external calls in construction.
    constructor(
        IPoolManager manager_,
        address hamster_,
        uint256 startBps_,
        uint256 floorBps_,
        uint256 decaySeconds_,
        address feeRecipient_
    ) {
        if (address(manager_) == address(0) || hamster_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (hamster_ == DeploymentConfig.IMD) revert InvalidToken();
        if (
            startBps_ != DeploymentConfig.START_BPS || floorBps_ != DeploymentConfig.FLOOR_BPS
                || decaySeconds_ != DeploymentConfig.DECAY_SECONDS || feeRecipient_ != DeploymentConfig.FEE_RECIPIENT
        ) revert InvalidConfiguration();

        poolManager = manager_;
        hamster = hamster_;
        START_BPS = startBps_;
        FLOOR_BPS = floorBps_;
        DECAY_SECONDS = decaySeconds_;
        FEE_RECIPIENT = feeRecipient_;
        // Deployment and initialize must share a transaction (and therefore this timestamp).
        poolInitialisedAt = block.timestamp;
        (address c0, address c1) =
            hamster_ < DeploymentConfig.IMD ? (hamster_, DeploymentConfig.IMD) : (DeploymentConfig.IMD, hamster_);
        PoolKey memory key = PoolKey(
            Currency.wrap(c0),
            Currency.wrap(c1),
            DeploymentConfig.POOL_FEE,
            DeploymentConfig.TICK_SPACING,
            IHooks(address(this))
        );
        poolId = key.toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Current buy rate. Uses integer truncation exactly as in the launch formula.
    function currentFeeBps() public view returns (uint256) {
        uint256 start = poolInitialisedAt;
        // Also makes pre-deployment historical simulations safe; chain time cannot go backwards.
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed >= DECAY_SECONDS) return FLOOR_BPS;
        return FLOOR_BPS + (START_BPS - FLOOR_BPS) * (DECAY_SECONDS - elapsed) / DECAY_SECONDS;
    }

    /// @notice A sell has zero hook fee regardless of elapsed time or amount specification.
    function feeBps(bool zeroForOne) external view returns (uint256) {
        return _isBuy(zeroForOne) ? currentFeeBps() : 0;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        if (block.timestamp != poolInitialisedAt) revert InitializationMustBeAtomic();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Exact input: preview the net budget so a price-limited fill is taxed only on spent input.
    ///      The preview always reverts internally, rolling back all of its pool accounting.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!_isBuy(params.zeroForOne) || params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Safe even for int256.min; FullMath avoids intermediate multiplication overflow.
        uint256 gross = uint256(-(params.amountSpecified + 1)) + 1;
        uint256 rate = currentFeeBps();
        uint256 fee = FullMath.mulDiv(gross, rate, DeploymentConfig.BPS);
        if (fee != 0) {
            uint256 netBudget = gross - fee;
            // rate >= 500, so even for int256.min the reduced net budget fits int256.
            uint256 consumed =
                _previewInput(key, SwapParams(params.zeroForOne, -int256(netBudget), params.sqrtPriceLimitX96));
            if (consumed < netBudget) {
                fee = FullMath.mulDiv(consumed, rate, DeploymentConfig.BPS - rate);
            }
        }
        int128 feeDelta = fee.toInt128();
        _payFee(sender, rate, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeDelta, 0), 0);
    }

    /// @dev Self-call boundary for a reverting swap simulation. V4 skips a hook's callbacks when
    ///      that hook itself calls swap. The revert undoes price, LP fees, events and transient deltas.
    ///      Cannot be used as a router or to bypass the fee: only this contract can call it and it
    ///      ALWAYS reverts, including on a successful simulation.
    function quoteInput(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        revert QuotedInput(input < 0 ? uint256(-int256(input)) : 0);
    }

    /// @dev Exact output: IMD is unspecified. Gross up the actual AMM input, including its LP fee.
    ///      F = floor(net * r / (10000-r)); gross = net+F and F = floor(gross*r/10000).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        if (!_isBuy(params.zeroForOne) || params.amountSpecified <= 0) return (IHooks.afterSwap.selector, 0);

        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (input >= 0) return (IHooks.afterSwap.selector, 0);
        uint256 rate = currentFeeBps();
        uint256 fee = FullMath.mulDiv(uint256(-int256(input)), rate, DeploymentConfig.BPS - rate);
        int128 feeDelta = fee.toInt128();
        _payFee(sender, rate, fee);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    function _isBuy(bool zeroForOne) private view returns (bool) {
        return zeroForOne == (DeploymentConfig.IMD < hamster);
    }

    function _previewInput(PoolKey calldata key, SwapParams memory params) private returns (uint256 consumed) {
        try this.quoteInput(key, params) {
            revert UnexpectedQuoteSuccess();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == QuotedInput.selector) {
                assembly ("memory-safe") {
                    consumed := mload(add(reason, 36))
                }
            } else {
                // Preserve core errors, e.g. invalid price limits, without converting them to a fee.
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    /// @notice Pays any held IMD claims to FEE_RECIPIENT, up to the IMD the manager holds. Anyone may call.
    function redeem() external returns (uint256 amount) {
        amount = abi.decode(poolManager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 claims = poolManager.balanceOf(address(this), _imdId());
        uint256 available = _managerImd();
        uint256 amount = claims < available ? claims : available;
        if (amount != 0) _redeem(amount);
        return abi.encode(amount);
    }

    function _payFee(address sender, uint256 rate, uint256 fee) private {
        if (fee == 0) return; // Integer dust does not trigger a token transfer.
        emit BuyFeePaid(sender, rate, fee);
        // Balances never pass through this contract. The returned hook delta cancels this debt.
        // A postpaying router has not delivered its input yet, so take only IMD the manager holds;
        // otherwise mint a claim, which needs no balance, so the buy never reverts on reserves.
        uint256 available = _managerImd();
        if (available < fee) {
            poolManager.mint(address(this), _imdId(), fee);
            emit FeeClaimMinted(fee);
            return;
        }
        poolManager.take(Currency.wrap(DeploymentConfig.IMD), FEE_RECIPIENT, fee);
        uint256 claims = poolManager.balanceOf(address(this), _imdId());
        if (claims != 0 && available - fee >= claims) _redeem(claims);
    }

    /// @dev Burn credits the hook what take debits: net zero delta for the hook.
    function _redeem(uint256 amount) private {
        poolManager.burn(address(this), _imdId(), amount);
        poolManager.take(Currency.wrap(DeploymentConfig.IMD), FEE_RECIPIENT, amount);
        emit FeeClaimRedeemed(amount);
    }

    function _imdId() private pure returns (uint256) {
        return CurrencyLibrary.toId(Currency.wrap(DeploymentConfig.IMD));
    }

    /// @dev A failing or malformed balance read counts as zero, so it falls back to a claim.
    function _managerImd() private view returns (uint256 available) {
        (bool ok, bytes memory data) =
            DeploymentConfig.IMD.staticcall(abi.encodeWithSelector(IERC20Balance.balanceOf.selector, poolManager));
        if (ok && data.length >= 32) available = abi.decode(data, (uint256));
    }
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}
