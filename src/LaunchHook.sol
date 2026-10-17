// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Slot0} from "@uniswap/v4-core/src/types/Slot0.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/interfaces/IHookEvents.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";

// The permission flags the hook's address must carry: the bits of `getHookPermissions()`. Deployments mine a salt
// that gives an address with exactly these bits.
uint160 constant LAUNCH_HOOK_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG
);

/// @title LaunchHook
/// @notice The one hook on every launch pool. It charges each swap the pool's fee in the quote asset, keeps the
///         pool's liquidity the factory's and locks it once graduated, and refuses donations and empty fills.
///         The buy that sells a curve out graduates the pool in the same swap. For three seconds after a launch,
///         a buy pays a snipe tax that takes its fee to 99%, unless its signer is exempt.
/// @dev The fee is taken in `beforeSwap` when the quote is the specified amount, and in `afterSwap` otherwise.
///      In `beforeSwap` the fill isn't known yet, so the fee is capped at what the pool can take or pay before
///      the price limit, Uniswap's protocol fee included on a buy (F7). Fees become the FeeManager's claims at
///      once, and the pool's `pending` tracks them until a sweep. See docs/MECHANICS.md.
///
///      The hook's only outside call is `onSoldOut`, made after a sell-out buy's fee is booked. The factory's own
///      swaps (the dev buy and graduation's 1-wei price pin) pay no snipe tax and trigger no graduation here.
///      Exemptions match `tx.origin`, as the hook sees the router rather than the buyer; they only lower a fee.
///      There is no owner and no upgrade path.
///
///      WARNING: the fee belongs to the pool, not the token. A pool for the token elsewhere trades untaxed.
contract LaunchHook is BaseHook, IHookEvents, ILaunchHook {
    using CurrencySettler for Currency;
    using ProtocolFeeLibrary for uint24;

    /// @inheritdoc ILaunchHook
    address public immutable factory;

    /// @inheritdoc ILaunchHook
    address public immutable feeManager;

    mapping(PoolId => Pool) internal _pools;

    /// @inheritdoc ILaunchHook
    mapping(PoolId poolID => mapping(address account => bool)) public snipeExempt;

    constructor(IPoolManager poolManager_, address feeManager_) BaseHook(poolManager_) {
        factory = msg.sender;
        feeManager = feeManager_;
    }

    // ---------------------------------------------------------------------
    // External functions.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchHook
    /// @dev Stores the pool's curve, creator tax and snipe exemptions, and opens the snipe window. The tax ceiling
    ///      is checked here too, so no factory can register a pool above it.
    function register(PoolKey calldata key, Registration calldata r, address[] calldata exempt) external {
        if (msg.sender != factory) {
            revert NotFactory();
        }
        if (r.creatorTaxBPS > LaunchMath.MAX_CREATOR_TAX_BPS) {
            revert CreatorTaxTooHigh();
        }
        PoolId poolID = key.toId();
        // the curve is held in pool space: mirrored when the quote is currency1
        (uint160 sqrtPriceLower, uint160 sqrtPriceUpper) = LaunchMath.poolPrices(r.gradTick, r.quoteIs0);
        _pools[poolID] = Pool({
            creatorTaxBPS: r.creatorTaxBPS,
            graduated: false,
            launchedAt: uint32(block.timestamp), // seconds; good until 2106
            quoteIs0: r.quoteIs0,
            sqrtPriceLower: sqrtPriceLower,
            sqrtPriceUpper: sqrtPriceUpper,
            liquidity: r.curveLiquidity,
            pending: 0,
            flatPending: 0
        });
        for (uint256 i = 0; i < exempt.length; i++) {
            snipeExempt[poolID][exempt[i]] = true; // an account listed twice is announced twice
            emit SnipeExempted(poolID, exempt[i]);
        }
    }

    /// @inheritdoc ILaunchHook
    function markGraduated(PoolId poolID, uint128 liquidity, uint256 quoteToFees) external {
        if (msg.sender != factory) {
            revert NotFactory();
        }
        Pool storage p = _pools[poolID];
        p.graduated = true;
        p.liquidity = liquidity;
        uint128 booked = SafeCast.toUint128(quoteToFees);
        p.pending += booked;
        p.flatPending += booked; // the leftover splits at the flat share, like a snipe surcharge
    }

    /// @inheritdoc ILaunchHook
    /// @dev Moves nothing: the FeeManager holds the claims from the swap that took each fee.
    function collect(PoolKey calldata key)
        external
        returns (uint256 protocolAmount, uint256 creatorAmount, Currency quote)
    {
        if (msg.sender != feeManager) {
            revert NotFeeManager();
        }
        Pool storage p = _pools[key.toId()]; // the FeeManager gets the key from the factory
        uint256 amount = p.pending;
        uint256 flat = p.flatPending;
        p.pending = 0;
        if (flat != 0) {
            p.flatPending = 0;
        }
        (protocolAmount, creatorAmount) = LaunchMath.feeShares(amount, flat, p.creatorTaxBPS);
        quote = _quoteOf(p.quoteIs0, key);
    }

    // ---------------------------------------------------------------------
    // External views.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchHook
    function pools(PoolId poolID) external view returns (Pool memory) {
        return _pools[poolID];
    }

    // ---------------------------------------------------------------------
    // Public views.
    // ---------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Internal functions.
    // ---------------------------------------------------------------------

    /// @dev Takes the fee when the quote is the specified amount. The fill isn't known yet, so the fee is on the
    ///      order, capped at what the pool can fill before the price limit.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolID = key.toId();
        if (!_quoteSpecified(_pools[poolID].quoteIs0, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _takeSpecifiedFee(poolID, sender, key, params);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(fee), 0), 0);
    }

    /// @dev Refuses an empty fill, except the factory's graduation price pin. Takes the fee when the quote is the
    ///      unspecified amount. Then, if this buy sold the curve out, has the factory graduate the pool.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolID = key.toId();
        if (delta == BalanceDeltaLibrary.ZERO_DELTA && sender != factory) {
            revert EmptyFillRejected();
        }
        bool quoteIs0 = _pools[poolID].quoteIs0;
        uint256 fee; // already taken in beforeSwap when the quote was the specified amount
        if (!_quoteSpecified(quoteIs0, params)) {
            fee = _takeUnspecifiedFee(poolID, sender, key, quoteIs0, delta, params);
        }
        // only a buy can sell the curve out, and the factory's own swaps never graduate from here
        if (sender != factory && params.zeroForOne == quoteIs0 && _soldOut(poolID)) {
            ILaunchFactory(factory).onSoldOut(Currency.unwrap(quoteIs0 ? key.currency1 : key.currency0));
        }
        return (IHooks.afterSwap.selector, SafeCast.toInt128(fee));
    }

    /// @dev Takes the fee when the quote is the specified amount, on the order.
    function _takeSpecifiedFee(PoolId poolID, address sender, PoolKey calldata key, SwapParams calldata params)
        internal
        returns (uint256 fee)
    {
        Pool storage s = _pools[poolID];
        uint256 feeBPS;
        (fee, feeBPS) = _specifiedFee(poolID, sender, s, _slot0(poolID), params);
        _takeFee(poolID, _quoteOf(s.quoteIs0, key), s.quoteIs0, sender, fee, feeBPS);
    }

    /// @dev Takes the fee when the quote is the unspecified amount, on what the swap moved.
    function _takeUnspecifiedFee(
        PoolId poolID,
        address sender,
        PoolKey calldata key,
        bool quoteIs0,
        BalanceDelta delta,
        SwapParams calldata params
    ) internal returns (uint256 fee) {
        uint256 feeBPS;
        (fee, feeBPS) = _unspecifiedFee(poolID, sender, quoteIs0, delta, params);
        _takeFee(poolID, _quoteOf(quoteIs0, key), quoteIs0, sender, fee, feeBPS);
    }

    /// @dev Books the fee as the FeeManager's claims and the pool's pending fees; the returned delta settles it. A
    ///      fee at the snipe rate books its surcharge as flat too, so the creator tax doesn't shrink the protocol's
    ///      share of it. `HookFee` is emitted even at zero, so indexers see exactly one per swap.
    function _takeFee(PoolId poolID, Currency quote, bool quoteIs0, address sender, uint256 fee, uint256 feeBPS)
        internal
    {
        quote.take(poolManager, feeManager, fee, true);
        uint128 booked = SafeCast.toUint128(fee);
        _book(poolID, booked, feeBPS);
        if (quoteIs0) {
            emit HookFee(PoolId.unwrap(poolID), sender, booked, 0);
        } else {
            emit HookFee(PoolId.unwrap(poolID), sender, 0, booked);
        }
    }

    /// @dev Adds a fee to the pool's pending fees, and a fee at the snipe rate's surcharge to the flat part too.
    function _book(PoolId poolID, uint128 booked, uint256 feeBPS) internal {
        Pool storage p = _pools[poolID];
        p.pending += booked;
        if (feeBPS == LaunchMath.MAX_TOTAL_FEE_BPS) {
            p.flatPending += uint128(LaunchMath.snipeSurcharge(booked, p.creatorTaxBPS)); // at most `booked`
        }
    }

    // ---------------------------------------------------------------------
    // Internal views.
    // ---------------------------------------------------------------------

    /// @dev Only the factory creates a pool, and it registers each one first.
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != factory) {
            revert NotFactory();
        }
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Only the factory adds liquidity: the curve, then the lock.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != factory) {
            revert NotFactory();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Liquidity leaves a pool once, when the factory removes the curve to graduate. After that it is locked.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        Pool storage p = _pools[key.toId()];
        if (sender != factory || p.graduated) {
            revert LiquidityLocked();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev No donations: the positions never collect fees, so donated value would be stuck.
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert DonationsLocked();
    }

    /// @dev The pool's packed slot0 (price and protocol fee) in one storage read.
    function _slot0(PoolId poolID) internal view returns (Slot0) {
        return Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolID)));
    }

    /// @dev Whether the curve, not yet graduated, is sold out: the price is at or past its end.
    function _soldOut(PoolId poolID) internal view returns (bool) {
        Pool storage s = _pools[poolID];
        if (s.graduated) {
            return false;
        }
        bool quoteIs0 = s.quoteIs0;
        return LaunchMath.soldOutAt(
            _slot0(poolID).sqrtPriceX96(), quoteIs0 ? s.sqrtPriceLower : s.sqrtPriceUpper, quoteIs0
        );
    }

    /// @dev The live position's bounds: the curve before graduation, the full-range lock after.
    function _bounds(Pool memory p) internal pure returns (uint160 lower, uint160 upper) {
        return p.graduated
            ? (LaunchMath.LOCK_SQRT_PRICE_LOWER, LaunchMath.LOCK_SQRT_PRICE_UPPER)
            : (p.sqrtPriceLower, p.sqrtPriceUpper);
    }

    /// @dev The quote the live position moves between the price and the swap's limit, clamped to its bounds.
    ///      Rounded up when the pool takes it (a buy), down when it pays it out.
    function _capacity(Pool memory p, uint160 sqrtPriceX96, bool zeroForOne, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (uint256)
    {
        (uint256 low, uint256 high) = zeroForOne ? (sqrtPriceLimitX96, sqrtPriceX96) : (sqrtPriceX96, sqrtPriceLimitX96);
        (uint160 lower, uint160 upper) = _bounds(p);
        uint160 a = uint160(Math.max(low, lower));
        uint160 b = uint160(Math.min(high, upper));
        return a < b ? LaunchMath.amountDelta(p.quoteIs0, a, b, p.liquidity, zeroForOne == p.quoteIs0) : 0;
    }

    /// @dev The fee when the quote is the specified amount, capped at the fee on what the pool can fill before the
    ///      limit. On a buy that is the capacity plus Uniswap's cut; on a sell, the capacity alone.
    function _specifiedFee(PoolId poolID, address sender, Pool memory p, Slot0 slot0, SwapParams calldata params)
        internal
        view
        returns (uint256 fee, uint256 total)
    {
        total = _feeBPS(poolID, sender, p.launchedAt, p.creatorTaxBPS, params.zeroForOne == p.quoteIs0);
        uint256 capacity = _capacity(p, slot0.sqrtPriceX96(), params.zeroForOne, params.sqrtPriceLimitX96);
        uint256 amount = SignedMath.abs(params.amountSpecified);
        if (params.amountSpecified < 0) {
            capacity = _withProtocolFee(capacity, slot0.protocolFee(), params.zeroForOne);
            return (LaunchMath.feeOnExactInput(amount, capacity, total), total);
        }
        return (LaunchMath.feeOnExactOutput(amount, capacity, total), total);
    }

    /// @dev The input a buy needs to move `capacity` of quote in, counting Uniswap's protocol fee. Rounded up as
    ///      V4's `SwapMath` does; the pool's LP fee is zero, so the swap fee is the protocol fee alone.
    function _withProtocolFee(uint256 capacity, uint24 protocolFee, bool zeroForOne) internal pure returns (uint256) {
        uint256 pips = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        if (pips == 0) {
            return capacity;
        }
        return capacity + FullMath.mulDivRoundingUp(capacity, pips, SwapMath.MAX_SWAP_FEE - pips);
    }

    /// @dev The fee when the quote is the unspecified amount: on what the pool received (a buy) or paid out (a
    ///      sell).
    function _unspecifiedFee(
        PoolId poolID,
        address sender,
        bool quoteIs0,
        BalanceDelta delta,
        SwapParams calldata params
    ) internal view returns (uint256 fee, uint256 total) {
        Pool storage s = _pools[poolID];
        total = _feeBPS(poolID, sender, s.launchedAt, s.creatorTaxBPS, params.zeroForOne == quoteIs0);
        (int128 quoteDelta,) = LaunchMath.split(delta, quoteIs0);
        uint256 poolQuote = SignedMath.abs(quoteDelta);
        if (params.amountSpecified < 0) {
            return (LaunchMath.feeOnGross(poolQuote, total), total);
        }
        return (LaunchMath.feeOnNet(poolQuote, total), total);
    }

    /// @dev The rate a swap pays: 99% for a buy in the snipe window, unless the factory makes it or its signer is
    ///      exempt. Otherwise the pool's own rate.
    function _feeBPS(PoolId poolID, address sender, uint32 launchedAt, uint16 creatorTaxBPS, bool buy)
        internal
        view
        returns (uint256)
    {
        bool sniped = buy && block.timestamp - launchedAt < LaunchMath.SNIPE_WINDOW && sender != factory
            && !snipeExempt[poolID][tx.origin];
        return sniped ? LaunchMath.MAX_TOTAL_FEE_BPS : LaunchMath.totalFeeBPS(creatorTaxBPS);
    }

    /// @dev Whether the quote is the specified amount: true for an exact-input buy or an exact-output sell.
    function _quoteSpecified(bool quoteIs0, SwapParams calldata params) internal pure returns (bool) {
        return (params.zeroForOne == (params.amountSpecified < 0)) == quoteIs0;
    }

    /// @dev The pool's quote currency.
    function _quoteOf(bool quoteIs0, PoolKey calldata key) internal pure returns (Currency) {
        return quoteIs0 ? key.currency0 : key.currency1;
    }
}
