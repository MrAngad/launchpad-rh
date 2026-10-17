// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Where a launch stands.
enum Phase {
    /// @dev Trading on the curve.
    Curve,
    /// @dev Trading on the permanent lock, after the curve sold out.
    Graduated
}

/// @notice A launch's live state, for a card. Fixed details are in the factory's and hook's records. An unknown
///         token reverts with `UnknownLaunch`.
struct LaunchState {
    Phase phase;
    /// @dev The pool's price and tick (slot0).
    uint160 sqrtPriceX96;
    int24 tick;
    /// @dev Quote base units per whole token at the pool's price, clamped to the curve's range before
    ///      graduation. Exact, rounded down.
    uint256 price;
    /// @dev The whole supply's value at that price, in quote base units. Computed in one step, not as `price`
    ///      times the supply, so it keeps the precision `price` rounds away.
    uint256 marketCap;
    /// @dev Tokens the curve has sold and still holds. Once graduated: everything it sold, and zero left.
    uint256 tokensSold;
    uint256 tokensLeft;
    /// @dev Quote raised so far, and what the curve raises when sold out; equal once graduated.
    uint256 quoteRaised;
    uint256 raiseTarget;
    /// @dev `quoteRaised` over `raiseTarget`, in basis points.
    uint256 progressBPS;
    /// @dev Fees not yet swept, split as `sweep` will split them.
    uint256 toProtocol;
    uint256 toRecipient;
    /// @dev The live position's liquidity: the curve's before graduation, the lock's after.
    uint128 liquidity;
    /// @dev Uniswap's protocol fee, both directions packed as V4 stores them; usually zero.
    uint24 protocolFee;
    /// @dev The snipe tax a non-exempt buy pays right now, on top of the pool's fee.
    uint256 snipeTaxBPS;
}

/// @title ILaunchQuoter
/// @notice Exact quotes and live state for any launch, by token. Quotes run the real swap and revert, so call them
///         with `eth_call`, from the account that will sign the trade (the snipe tax depends on `tx.origin`). A
///         refused swap reverts with its own reason; a zero order quotes zero.
interface ILaunchQuoter {
    /// @notice An exact-input buy of `quoteIn`, to the unit: tokens out, the quote actually charged (capped at what
    ///         the curve can take), the fee within it, and whether the buy sells the curve out and graduates it.
    function quoteBuy(address token, uint256 quoteIn)
        external
        returns (uint256 tokensOut, uint256 quoteUsed, uint256 fee, bool sellsOut);

    /// @notice An exact-input sell of `tokensIn`, to the unit: quote out after the fee, tokens actually taken, and
    ///         the fee.
    function quoteSell(address token, uint256 tokensIn)
        external
        returns (uint256 quoteOut, uint256 tokensUsed, uint256 fee);

    /// @notice The order that sells the curve out: an exact-output buy of `tokens`, costing `maxQuoteIn` with all
    ///         fees. Send it with `maxQuoteIn` as the input cap. Both are zero once graduated.
    function curveRemaining(address token) external returns (uint256 tokens, uint256 maxQuoteIn);

    /// @notice The PoolManager the quotes run against.
    function poolManager() external view returns (IPoolManager);

    /// @notice The factory whose launches it quotes.
    function factory() external view returns (address);

    /// @notice A launch's live state, for a card.
    function state(address token) external view returns (LaunchState memory);
}
