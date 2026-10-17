// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LAUNCH_SUPPLY} from "../interfaces/ILaunchToken.sol";

/// @title LaunchMath
/// @notice The launchpad's arithmetic: the curve shape, where a raise places it, the fees, the dev buy, and
///         liquidity from amounts.
/// @dev Prices are tokens per quote unit. Every launch has the same shape: `CURVE_SUPPLY` tokens on a curve
///      `CURVE_WIDTH` ticks wide (16x in price), and `RESERVE_SUPPLY` in reserve, the 80/20 split as close as the
///      200-tick grid allows. The width makes the reserve pair exactly with the raise at the graduation price, so
///      only the graduation tick moves with the raise (`gradTickOf`). The derivation is in docs/MECHANICS.md.
///      The liquidity helpers are adapted from Uniswap's v4-periphery LiquidityAmounts (MIT).
library LaunchMath {
    /// @notice A curve on the tick grid: its ticks, its liquidity, and the least it raises when sold out on either
    ///         side of its pool.
    struct Curve {
        int24 startTick;
        int24 gradTick;
        uint128 liquidity;
        uint256 raise;
    }

    /// @notice The smallest raise allowed, in quote units: a guard against typos (11 USD of a 6-decimal
    ///         stablecoin), not a mathematical limit.
    uint256 internal constant MIN_RAISE = 11_000_000;
    /// @notice The largest raise allowed, in quote units: the top raise at `MIN_GRAD_TICK`, far above any real
    ///         asset's supply.
    uint256 internal constant MAX_RAISE = 148_861_950_532_760_754_537_321_072_838_209_056_953;
    /// @notice The lowest graduation tick: the lowest where a whole curve plus the highest normal fee (11%) still
    ///         fits in one V4 order (an int128), so every launch can be bought out in one go.
    int24 internal constant MIN_GRAD_TICK = -273_400;
    /// @notice The shape: the curve's width in ticks (a 4x ratio in sqrt price, rounded to the grid), and the
    ///         supply on the curve and in reserve, which add up to `LAUNCH_SUPPLY`.
    int24 internal constant CURVE_WIDTH = 27_800;
    uint256 internal constant CURVE_SUPPLY = 800_581_148_380_115_266_870_363_802;
    uint256 internal constant RESERVE_SUPPLY = LAUNCH_SUPPLY - CURVE_SUPPLY;

    /// @notice Fees in basis points of the quote side of a swap. The hook fee is 1%: 30% of it (0.3%) goes to the
    ///         protocol and the rest (0.7%) to the creator. A creator can add its own tax, up to 10%.
    uint256 internal constant BPS = 10_000;
    uint16 internal constant HOOK_FEE_BPS = 100;
    uint16 internal constant PROTOCOL_SHARE_BPS = 3_000;
    uint16 internal constant MAX_CREATOR_TAX_BPS = 1_000;

    /// @notice The snipe tax: for `SNIPE_WINDOW` seconds after launch, a buy's total fee is `MAX_TOTAL_FEE_BPS`
    ///         (99%), as on Pons V2.
    uint256 internal constant SNIPE_WINDOW = 3;
    uint256 internal constant MAX_TOTAL_FEE_BPS = 9_900;

    /// @notice The tick spacing of every launch pool, and the lock's full range on that grid, with its prices.
    int24 internal constant LAUNCH_TICK_SPACING = 200;
    /// @notice The ticks one tick-bitmap word spans (256 spacings). V4 ends a swap step at each word's edge.
    int24 internal constant WORD_TICKS = 256 * LAUNCH_TICK_SPACING;
    int24 internal constant LOCK_TICK_LOWER = -887_200;
    int24 internal constant LOCK_TICK_UPPER = 887_200;
    uint160 internal constant LOCK_SQRT_PRICE_LOWER = 4_310_618_292;
    uint160 internal constant LOCK_SQRT_PRICE_UPPER = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;

    /// @notice The raise asked for is under `MIN_RAISE`.
    error RaiseTooLow();

    /// @notice The raise asked for is over `MAX_RAISE`.
    error RaiseTooHigh();

    // ---------------------------------------------------------------------
    // Fees, shared by the hook and the factory.
    // ---------------------------------------------------------------------

    /// @notice What a swap pays outside the snipe window: the fixed hook fee plus the pool's creator tax.
    function totalFeeBPS(uint16 creatorTaxBPS) internal pure returns (uint256) {
        return uint256(HOOK_FEE_BPS) + creatorTaxBPS;
    }

    /// @notice How fees taken at the pool's own rate split: the protocol's share of the hook fee (rounded down), and
    ///         the rest, the creator tax included, to the creator.
    function feeShares(uint256 amount, uint16 creatorTaxBPS)
        internal
        pure
        returns (uint256 protocol, uint256 creator)
    {
        protocol = amount * HOOK_FEE_BPS * PROTOCOL_SHARE_BPS / (totalFeeBPS(creatorTaxBPS) * BPS);
        creator = amount - protocol;
    }

    /// @notice How a pool's pending fees split when `flat` of `amount` splits at the flat `PROTOCOL_SHARE_BPS`
    ///         (snipe surcharges and the graduation's leftover) and the rest at the pool's own rate (`feeShares`).
    ///         Each part rounds the protocol's share down.
    function feeShares(uint256 amount, uint256 flat, uint16 creatorTaxBPS)
        internal
        pure
        returns (uint256 protocol, uint256 creator)
    {
        (protocol,) = feeShares(amount - flat, creatorTaxBPS);
        protocol += flat * PROTOCOL_SHARE_BPS / BPS;
        creator = amount - protocol;
    }

    /// @notice The part of a fee taken at the snipe rate that lies above the pool's own rate, rounded up, so the
    ///         part at the pool's rate is rounded down as `feeShares` would see it.
    function snipeSurcharge(uint256 fee, uint16 creatorTaxBPS) internal pure returns (uint256) {
        return fee - fee * totalFeeBPS(creatorTaxBPS) / MAX_TOTAL_FEE_BPS;
    }

    /// @notice The fee on a gross quote amount (what the pool receives or pays out), rounded up.
    function feeOnGross(uint256 gross, uint256 feeBPS) internal pure returns (uint256) {
        return Math.mulDiv(gross, feeBPS, BPS, Math.Rounding.Ceil);
    }

    /// @notice The fee on a net quote amount (gross minus fee), rounded up: `net * fee / (1 - fee)`.
    function feeOnNet(uint256 net, uint256 feeBPS) internal pure returns (uint256) {
        return Math.mulDiv(net, feeBPS, BPS - feeBPS, Math.Rounding.Ceil);
    }

    /// @notice The hook's fee on an exact-input order: the fee on the order or on the most the pool can take,
    ///         whichever is less.
    function feeOnExactInput(uint256 amountIn, uint256 capacity, uint256 feeBPS) internal pure returns (uint256) {
        return Math.min(feeOnGross(amountIn, feeBPS), feeOnNet(capacity, feeBPS));
    }

    /// @notice The hook's fee on an exact-output order: the fee on the order or on the most the pool can pay,
    ///         whichever is less.
    function feeOnExactOutput(uint256 amountOut, uint256 capacity, uint256 feeBPS) internal pure returns (uint256) {
        return Math.min(feeOnNet(amountOut, feeBPS), feeOnGross(capacity, feeBPS));
    }

    // ---------------------------------------------------------------------
    // Placing the curve: the graduation tick from the raise, then the exact figures.
    // ---------------------------------------------------------------------

    /// @notice The curve that raises at least `raise` when sold out, on either side of its pool.
    function curveFor(uint256 raise) internal pure returns (Curve memory) {
        return curveAt(gradTickOf(raise));
    }

    /// @notice The graduation tick that pairs the reserve with `raise`, rounded down to the grid so the curve
    ///         raises at least that much. If rounding still leaves it a few units short, it steps one tick lower.
    /// @dev The square root is taken at Q128 and shifted to Q96, rounding down like the grid floor.
    function gradTickOf(uint256 raise) internal pure returns (int24 gradTick) {
        if (raise < MIN_RAISE) {
            revert RaiseTooLow();
        }
        if (raise > MAX_RAISE) {
            revert RaiseTooHigh();
        }
        uint160 sqrtGradTarget = SafeCast.toUint160(Math.sqrt(FullMath.mulDiv(RESERVE_SUPPLY, 1 << 128, raise)) << 32);
        gradTick = floorTick(TickMath.getTickAtSqrtPrice(sqrtGradTarget));
        if (curveAt(gradTick).raise < raise) {
            gradTick -= LAUNCH_TICK_SPACING;
        }
    }

    /// @notice The curve that graduates at `gradTick`: its start, liquidity, and least raise on either side.
    function curveAt(int24 gradTick) internal pure returns (Curve memory c) {
        (c.gradTick, c.startTick) = (gradTick, gradTick + CURVE_WIDTH);
        c.liquidity = curveLiquidity(gradTick);
        c.raise = Math.min(raiseOn(gradTick, c.liquidity, true), raiseOn(gradTick, c.liquidity, false));
    }

    /// @notice The curve's liquidity: `CURVE_SUPPLY` tokens over its range, or less if the mirrored pool would need
    ///         more tokens for it after rounding. Either orientation then holds at most `CURVE_SUPPLY`.
    function curveLiquidity(int24 gradTick) internal pure returns (uint128 liquidity) {
        (uint160 sqrtStart, uint160 sqrtGrad) = curvePrices(gradTick, true);
        liquidity = liquidityForAmount1(sqrtGrad, sqrtStart, CURVE_SUPPLY);
        (uint160 lower, uint160 upper) = poolPrices(gradTick, false);
        if (SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, true) > CURVE_SUPPLY) {
            liquidity = liquidityForAmount0(lower, upper, CURVE_SUPPLY);
        }
    }

    /// @notice What the curve raises when sold out on side `quoteIs0`, rounded down as V4 pays out a removal.
    function raiseOn(int24 gradTick, uint128 liquidity, bool quoteIs0) internal pure returns (uint256) {
        (uint160 sqrtStart, uint160 sqrtGrad) = curvePrices(gradTick, quoteIs0);
        return amountDelta(quoteIs0, sqrtGrad, sqrtStart, liquidity, false);
    }

    // ---------------------------------------------------------------------
    // The dev buy and grid ticks.
    // ---------------------------------------------------------------------

    /// @notice What a dev buy spending `quoteIn` (fee included) gets on a fresh curve, to the unit: tokens, quote
    ///         spent and fee. It replays the swap step by step, ending steps at bitmap-word edges and rounding each
    ///         one as V4 does.
    function devBuyFill(int24 gradTick, uint128 liquidity, uint256 quoteIn, uint256 feeBPS, bool quoteIs0)
        internal
        pure
        returns (uint256 tokens, uint256 spent, uint256 fee)
    {
        (uint160 sqrtStart, uint160 sqrtGrad) = curvePrices(gradTick, quoteIs0);
        fee = feeOnExactInput(quoteIn, amountDelta(quoteIs0, sqrtGrad, sqrtStart, liquidity, true), feeBPS);
        uint256 used;
        (tokens, used) = walk(gradTick, liquidity, quoteIn - fee, quoteIs0);
        spent = fee + used;
    }

    /// @notice Replays a buy of up to `amountIn` down a fresh curve, step by step as V4 does. Returns the tokens
    ///         bought and quote used.
    function walk(int24 gradTick, uint128 liquidity, uint256 amountIn, bool quoteIs0)
        internal
        pure
        returns (uint256 tokens, uint256 used)
    {
        (uint160 price, uint160 sqrtGrad) = curvePrices(gradTick, quoteIs0);
        int24 edge = firstWordEdge(gradTick, quoteIs0);
        while (used < amountIn && price != sqrtGrad) {
            uint160 target = stepTarget(edge, gradTick, sqrtGrad, quoteIs0);
            (uint160 next, uint256 stepIn, uint256 out) = swapStep(price, target, liquidity, amountIn - used);
            (price, used, tokens) = (next, used + stepIn, tokens + out);
            edge = quoteIs0 ? edge - WORD_TICKS : edge + WORD_TICKS;
        }
    }

    /// @notice The first bitmap-word edge a buy meets on a fresh curve.
    function firstWordEdge(int24 gradTick, bool quoteIs0) internal pure returns (int24) {
        (int24 tickLower, int24 tickUpper) = poolTicks(gradTick, quoteIs0);
        return quoteIs0
            ? wordFloor(tickUpper - 1)
            : wordFloor(tickLower + LAUNCH_TICK_SPACING) + WORD_TICKS - LAUNCH_TICK_SPACING;
    }

    /// @notice Where a buy's step ends: at word edge `edge`, or at the curve's end once the edge reaches it.
    function stepTarget(int24 edge, int24 gradTick, uint160 sqrtGrad, bool quoteIs0) internal pure returns (uint160) {
        bool past = quoteIs0 ? edge <= gradTick : edge >= -gradTick;
        return past ? sqrtGrad : TickMath.getSqrtPriceAtTick(edge);
    }

    /// @notice One exact-input swap step with no LP fee, as V4's `SwapMath.computeSwapStep`: to `target` if
    ///         `amountIn` covers it, otherwise as far as it goes. Input rounds up, output down.
    function swapStep(uint160 price, uint160 target, uint128 liquidity, uint256 amountIn)
        internal
        pure
        returns (uint160 next, uint256 used, uint256 out)
    {
        bool zeroForOne = price >= target;
        used = amountDelta(zeroForOne, target, price, liquidity, true);
        if (amountIn >= used) {
            next = target;
        } else {
            used = amountIn;
            next = SqrtPriceMath.getNextSqrtPriceFromInput(price, liquidity, amountIn, zeroForOne);
        }
        out = amountDelta(!zeroForOne, next, price, liquidity, false);
    }

    // ---------------------------------------------------------------------
    // Orientation. The quote is currency0 when it sorts below the token (ETH always does). Curves are described in
    // curve space; a pool with the quote as currency1 holds the curve at negated ticks. Pool prices always come
    // from TickMath, never a reciprocal, so every contract compares the same integer.
    // ---------------------------------------------------------------------

    /// @notice The pool's ticks for the curve that graduates at `gradTick`.
    function poolTicks(int24 gradTick, bool quoteIs0) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 startTick = gradTick + CURVE_WIDTH;
        return quoteIs0 ? (gradTick, startTick) : (-startTick, -gradTick);
    }

    /// @notice The pool's prices at the curve's ticks, lower first.
    function poolPrices(int24 gradTick, bool quoteIs0) internal pure returns (uint160 lower, uint160 upper) {
        (int24 tickLower, int24 tickUpper) = poolTicks(gradTick, quoteIs0);
        return (TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper));
    }

    /// @notice The curve's start, where the pool opens, and its end, where it graduates, as pool prices.
    function curvePrices(int24 gradTick, bool quoteIs0) internal pure returns (uint160 sqrtStart, uint160 sqrtGrad) {
        (uint160 lower, uint160 upper) = poolPrices(gradTick, quoteIs0);
        sqrtGrad = curveEnd(lower, upper, quoteIs0);
        sqrtStart = sqrtGrad == lower ? upper : lower;
    }

    /// @notice The end of a curve between pool prices `lower` and `upper`, where a buy sells it out. The hook,
    ///         factory and quoter all use this one rule.
    function curveEnd(uint160 lower, uint160 upper, bool quoteIs0) internal pure returns (uint160) {
        return quoteIs0 ? lower : upper;
    }

    /// @notice Whether a pool price is at or past the curve's end, in a buy's direction.
    function soldOutAt(uint160 sqrtPriceX96, uint160 sqrtGrad, bool quoteIs0) internal pure returns (bool) {
        return quoteIs0 ? sqrtPriceX96 <= sqrtGrad : sqrtPriceX96 >= sqrtGrad;
    }

    /// @notice The amount of currency0 (or currency1) between two pool prices, in either order.
    function amountDelta(bool ofCurrency0, uint160 sqrtA, uint160 sqrtB, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return ofCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp)
            : SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
    }

    /// @notice Splits a pool delta into its quote side and token side.
    function split(BalanceDelta delta, bool quoteIs0) internal pure returns (int128 quote, int128 tokens) {
        return quoteIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
    }

    /// @notice The largest multiple of the tick spacing at or below `tick`, for either sign.
    function floorTick(int24 tick) internal pure returns (int24) {
        return tick - ((tick % LAUNCH_TICK_SPACING) + LAUNCH_TICK_SPACING) % LAUNCH_TICK_SPACING;
    }

    /// @notice The lowest tick of the bitmap word holding `tick`, for either sign.
    function wordFloor(int24 tick) internal pure returns (int24) {
        return tick - ((tick % WORD_TICKS) + WORD_TICKS) % WORD_TICKS;
    }

    // ---------------------------------------------------------------------
    // Liquidity from amounts, over a sorted price range.
    // ---------------------------------------------------------------------

    /// @notice Liquidity for `amount0` of currency0 over [sqrtPriceAX96, sqrtPriceBX96].
    function liquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        return SafeCast.toUint128(FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Liquidity for `amount1` of currency1 over [sqrtPriceAX96, sqrtPriceBX96].
    function liquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        return SafeCast.toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice The most liquidity `amount0` and `amount1` can fund at a price strictly inside the range.
    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        uint128 liquidity0 = liquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
        uint128 liquidity1 = liquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
        return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }
}
