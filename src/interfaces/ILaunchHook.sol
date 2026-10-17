// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ILaunchHook
/// @notice The one hook on every launch pool. It takes each swap's fee in the quote asset and holds it as the
///         pool's pending fees until the FeeManager collects them. It keeps the pool's liquidity the factory's,
///         has the factory graduate the pool in the swap that sells its curve out, and then locks it for good.
///         The PoolManager callbacks come from OpenZeppelin's `BaseHook`.
interface ILaunchHook {
    /// @notice One registered pool, packed so a swap after the snipe window reads one slot for its fee and side.
    struct Pool {
        /// @dev The creator's tax, on top of the fixed hook fee and wholly the creator's.
        uint16 creatorTaxBPS;
        /// @dev Set once the lock is in place; from then on the lock is the live position.
        bool graduated;
        /// @dev When the pool was registered, which opens the snipe window. Zero for an unknown pool.
        uint32 launchedAt;
        /// @dev Whether the quote is currency0 (it sorts below the token) or currency1.
        bool quoteIs0;
        /// @dev The curve's bounds in pool prices. They stay the curve's after graduation, when the live
        ///      position is the full-range lock.
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        /// @dev The live position's liquidity: the curve's before graduation, the lock's after.
        uint128 liquidity;
        /// @dev Fees taken and not yet swept. The FeeManager already holds them as claims in the quote.
        uint128 pending;
        /// @dev The part of `pending` that splits at the flat `PROTOCOL_SHARE_BPS` whatever the creator tax: snipe
        ///      surcharges and the graduation's leftover. The rest splits at the pool's own rate.
        uint128 flatPending;
    }

    /// @notice What the factory registers a pool with: its orientation, its curve and its creator tax.
    struct Registration {
        bool quoteIs0;
        int24 gradTick;
        uint128 curveLiquidity;
        uint16 creatorTaxBPS;
    }

    /// @notice Buys signed by `account` pay no snipe tax on the pool.
    event SnipeExempted(PoolId indexed poolID, address indexed account);

    /// @notice Only the factory registers, creates, funds and graduates pools.
    error NotFactory();

    /// @notice Only the FeeManager collects a pool's fees.
    error NotFeeManager();

    /// @notice The creator tax is over `LaunchMath.MAX_CREATOR_TAX_BPS`.
    error CreatorTaxTooHigh();

    /// @notice Liquidity can't be removed, except the curve by its own graduation.
    error LiquidityLocked();

    /// @notice Donations are refused: value enters a pool only through swaps.
    error DonationsLocked();

    /// @notice The swap moved nothing. A price can't be moved for free.
    error EmptyFillRejected();

    /// @notice Records a new pool's side, curve, creator tax and snipe exemptions, and opens its snipe window.
    ///         Factory only, once per pool, before the pool is created.
    function register(PoolKey calldata key, Registration calldata registration, address[] calldata exempt) external;

    /// @notice Marks the pool graduated with the lock as its live position, and adds the graduation's leftover
    ///         quote (`quoteToFees`) to its pending fees, split at the flat protocol share. Factory only.
    function markGraduated(PoolId poolID, uint128 liquidity, uint256 quoteToFees) external;

    /// @notice Zeroes the pool's pending fees and returns how they split between the protocol and the creator,
    ///         and the quote they are in. FeeManager only.
    function collect(PoolKey calldata key)
        external
        returns (uint256 protocolAmount, uint256 creatorAmount, Currency quote);

    /// @notice The factory that deployed the hook and registers its pools.
    function factory() external view returns (address);

    /// @notice The FeeManager that collects the pools' fees.
    function feeManager() external view returns (address);

    /// @notice A pool's record; `launchedAt` is zero for an unknown pool.
    function pools(PoolId poolID) external view returns (Pool memory);

    /// @notice Whether buys signed by `account` (`tx.origin`) skip the pool's snipe tax.
    function snipeExempt(PoolId poolID, address account) external view returns (bool);
}
