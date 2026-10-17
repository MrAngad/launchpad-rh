// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ILaunchQuoter, LaunchState, Phase} from "./interfaces/ILaunchQuoter.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {LAUNCH_SUPPLY} from "./interfaces/ILaunchToken.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";

/// @title LaunchQuoter
/// @notice Answers live questions about any launch, so a front end can render a card in one call. A quote runs
///         the real swap through the real hook, then reverts with the result, like Uniswap's V4 Quoter, except a
///         partial fill (the order that sells the curve out) is reported rather than refused. Quotes aren't
///         views: call them with `eth_call`. Nothing here is on a swap's path.
contract LaunchQuoter is ILaunchQuoter, IUnlockCallback {
    using StateLibrary for IPoolManager;

    /// @dev A launch's pool as a quote sees it: the hook's record plus the PoolManager's slot0.
    struct Pool {
        ILaunchHook hook;
        PoolId poolID;
        ILaunchHook.Pool record;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
    }

    /// @inheritdoc ILaunchQuoter
    IPoolManager public immutable poolManager;

    /// @inheritdoc ILaunchQuoter
    address public immutable factory;

    /// @dev A quote's result, carried out in a revert: the swapper's delta, the hook's fee, and whether the swap
    ///      sold the curve out (and so graduated the pool).
    error QuoteResult(int128 amount0, int128 amount1, uint256 fee, bool sellsOut);

    /// @notice Only the PoolManager may call `unlockCallback`.
    error NotPoolManager();

    /// @param factory_ The factory, deployed next at its predicted address (it checks the pairing).
    constructor(IPoolManager poolManager_, address factory_) {
        poolManager = poolManager_;
        factory = factory_;
    }

    // ---------------------------------------------------------------------
    // External functions.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchQuoter
    function quoteBuy(address token, uint256 quoteIn)
        external
        returns (uint256 tokensOut, uint256 quoteUsed, uint256 fee, bool sellsOut)
    {
        (quoteUsed, tokensOut, fee, sellsOut) = _quote(token, true, -SafeCast.toInt256(quoteIn));
    }

    /// @inheritdoc ILaunchQuoter
    function quoteSell(address token, uint256 tokensIn)
        external
        returns (uint256 quoteOut, uint256 tokensUsed, uint256 fee)
    {
        (tokensUsed, quoteOut, fee,) = _quote(token, false, -SafeCast.toInt256(tokensIn));
    }

    /// @inheritdoc ILaunchQuoter
    /// @dev Runs the real exact-output buy, so the charge is exact whatever the swap's rounding. It asks for the
    ///      curve's tokens rounded up and reports what that delivers; an order for exactly that stops on the
    ///      curve's end, so graduation needs no price pin. With under one token unit left, it names the rounded-up
    ///      order itself, which still sells the curve out.
    function curveRemaining(address token) external returns (uint256 tokens, uint256 maxQuoteIn) {
        Pool memory p = _pool(token);
        if (p.record.graduated) {
            return (0, 0);
        }
        ILaunchHook.Pool memory h = p.record;
        uint160 end = LaunchMath.curveEnd(h.sqrtPriceLower, h.sqrtPriceUpper, h.quoteIs0);
        uint256 asked = LaunchMath.amountDelta(!h.quoteIs0, end, _clamped(p), h.liquidity, true);
        uint256 delivered;
        (maxQuoteIn, delivered,,) = _quote(token, true, SafeCast.toInt256(asked));
        tokens = delivered > 0 ? delivered : asked;
    }

    /// @notice The PoolManager's callback for a quote: runs the swap and reverts with the result. The fee reported
    ///         is the swap's alone, leaving out any leftover quote a graduation added to the pool's fees.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        ILaunchHook hook = ILaunchHook(address(key.hooks));
        ILaunchHook.Pool memory before = hook.pools(key.toId());
        BalanceDelta delta = poolManager.swap(key, params, "");
        ILaunchHook.Pool memory after_ = hook.pools(key.toId());
        bool sellsOut = after_.graduated && !before.graduated;
        uint256 fee = after_.pending - before.pending;
        if (sellsOut) {
            fee -= _graduationDust(before, after_.liquidity);
        }
        revert QuoteResult(delta.amount0(), delta.amount1(), fee, sellsOut);
    }

    // ---------------------------------------------------------------------
    // External views.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchQuoter
    function state(address token) external view returns (LaunchState memory s) {
        Pool memory p = _pool(token);
        ILaunchHook.Pool memory h = p.record;
        if (h.graduated) {
            s.phase = Phase.Graduated;
        }
        s.sqrtPriceX96 = p.sqrtPriceX96;
        s.tick = p.tick;
        s.protocolFee = p.protocolFee;
        s.liquidity = h.liquidity;
        {
            // price within the curve's range (a sell past its start reads as the start), and value the whole
            // supply in one step rather than multiplying the rounded-down price
            uint160 priced = h.graduated ? p.sqrtPriceX96 : _clamped(p);
            s.price = _valueAt(priced, h.quoteIs0, 1e18);
            s.marketCap = _valueAt(priced, h.quoteIs0, LAUNCH_SUPPLY);
        }
        (s.toProtocol, s.toRecipient) = LaunchMath.feeShares(h.pending, h.flatPending, h.creatorTaxBPS);
        // the extra snipe tax a non-exempt buyer pays right now (99% in total inside the window)
        if (block.timestamp - h.launchedAt < LaunchMath.SNIPE_WINDOW) {
            s.snipeTaxBPS = LaunchMath.MAX_TOTAL_FEE_BPS - LaunchMath.totalFeeBPS(h.creatorTaxBPS);
        }

        // measure the target on this pool's own orientation: mirrored, the quote side can round a unit or so off
        // the curve-space raise
        bool q0 = h.quoteIs0;
        int24 gradTick = ILaunchFactory(factory).launches(token).gradTick;
        (uint160 startSqrt, uint160 gradSqrt) = LaunchMath.curvePrices(gradTick, q0);
        uint128 curveLiquidity = LaunchMath.curveLiquidity(gradTick);
        s.raiseTarget = LaunchMath.amountDelta(q0, gradSqrt, startSqrt, curveLiquidity, false);
        // tokens left lie between the price and the curve's end, the quote raised between its start and the
        // price; a graduated curve is read as sold out at its end
        uint160 price = h.graduated ? gradSqrt : _clamped(p);
        s.tokensLeft = LaunchMath.amountDelta(!q0, gradSqrt, price, h.liquidity, false);
        s.tokensSold = LaunchMath.amountDelta(!q0, price, startSqrt, curveLiquidity, false);
        s.quoteRaised = LaunchMath.amountDelta(q0, price, startSqrt, curveLiquidity, false);
        s.progressBPS = Math.mulDiv(s.quoteRaised, LaunchMath.BPS, Math.max(s.raiseTarget, 1));
    }

    // ---------------------------------------------------------------------
    // Internal functions.
    // ---------------------------------------------------------------------

    /// @dev Runs a quote and returns what the swapper pays and gets, the fee, and whether a buy sells the curve
    ///      out. A zero order quotes zero.
    function _quote(address token, bool buy, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut, uint256 fee, bool sellsOut)
    {
        if (amountSpecified == 0) {
            return (0, 0, 0, false);
        }
        (int128 quote, int128 tokens, uint256 fee_, bool sellsOut_) = _swap(token, buy, amountSpecified);
        if (buy) {
            return (uint256(uint128(-quote)), uint256(uint128(tokens)), fee_, sellsOut_);
        }
        return (uint256(uint128(-tokens)), uint256(uint128(quote)), fee_, false);
    }

    /// @dev Runs the swap inside an unlock and decodes the result from the revert. Any other revert (an empty
    ///      fill, an unknown token) is passed on unchanged.
    function _swap(address token, bool buy, int256 amountSpecified)
        internal
        returns (int128 quote, int128 tokens, uint256 fee, bool sellsOut)
    {
        PoolKey memory key = ILaunchFactory(factory).poolKey(token);
        bool quoteIs0 = Currency.unwrap(key.currency1) == token; // read from the key, no extra call
        bool zeroForOne = buy == quoteIs0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory data = abi.encode(key, SwapParams(zeroForOne, amountSpecified, limit));
        try poolManager.unlock(data) {}
        catch (bytes memory reason) {
            if (reason.length == 4 + 4 * 32 && bytes4(reason) == QuoteResult.selector) {
                assembly ("memory-safe") {
                    reason := add(reason, 4)
                }
                int128 amount0;
                int128 amount1;
                (amount0, amount1, fee, sellsOut) = abi.decode(reason, (int128, int128, uint256, bool));
                (quote, tokens) = quoteIs0 ? (amount0, amount1) : (amount1, amount0);
                return (quote, tokens, fee, sellsOut);
            }
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    // ---------------------------------------------------------------------
    // Internal views.
    // ---------------------------------------------------------------------

    /// @dev A launch's pool: slot0 from the PoolManager and the record from the hook.
    function _pool(address token) internal view returns (Pool memory p) {
        PoolKey memory key = ILaunchFactory(factory).poolKey(token);
        p.hook = ILaunchHook(address(key.hooks));
        p.poolID = key.toId();
        (p.sqrtPriceX96, p.tick, p.protocolFee,) = poolManager.getSlot0(p.poolID);
        p.record = p.hook.pools(p.poolID);
    }

    /// @dev The leftover quote a graduation adds to the pool's fees, worked out as the factory does: the curve's
    ///      principal (rounded down) less what the lock took (rounded up). `curve` is the pre-graduation record.
    function _graduationDust(ILaunchHook.Pool memory curve, uint128 lockLiquidity) internal pure returns (uint256) {
        bool q0 = curve.quoteIs0;
        uint256 principal =
            LaunchMath.amountDelta(q0, curve.sqrtPriceLower, curve.sqrtPriceUpper, curve.liquidity, false);
        uint160 end = LaunchMath.curveEnd(curve.sqrtPriceLower, curve.sqrtPriceUpper, q0);
        uint160 far = q0 ? LaunchMath.LOCK_SQRT_PRICE_UPPER : LaunchMath.LOCK_SQRT_PRICE_LOWER;
        return principal - LaunchMath.amountDelta(q0, end, far, lockLiquidity, true);
    }

    /// @dev The price clamped to the curve's range.
    function _clamped(Pool memory p) internal pure returns (uint160) {
        ILaunchHook.Pool memory h = p.record;
        if (p.sqrtPriceX96 > h.sqrtPriceUpper) {
            return h.sqrtPriceUpper;
        }
        if (p.sqrtPriceX96 < h.sqrtPriceLower) {
            return h.sqrtPriceLower;
        }
        return p.sqrtPriceX96;
    }

    /// @dev What `amount` token base units are worth in quote base units at `sqrtPriceX96`, rounded down exactly.
    ///      With the quote as currency0 that is `amount * 2^192 / sqrtP^2`, otherwise `amount * sqrtP^2 / 2^192`,
    ///      each computed in one piece. For `amount` up to `LAUNCH_SUPPLY` (under 2^90) at any valid price, no
    ///      divisor is zero (sqrtP > 2^32) and every intermediate stays under 2^250.
    function _valueAt(uint160 sqrtPriceX96, bool quoteIs0, uint256 amount) internal pure returns (uint256) {
        return quoteIs0
            ? Math.mulDiv(amount, 1 << 192, sqrtPriceX96) / sqrtPriceX96
            : Math.mulDiv(amount * sqrtPriceX96, sqrtPriceX96, 1 << 192);
    }
}
