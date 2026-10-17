// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILaunchHook} from "./ILaunchHook.sol";
import {ILaunchToken} from "./ILaunchToken.sol";
import {ILaunchQuoter} from "./ILaunchQuoter.sol";
import {IFeeManager} from "./IFeeManager.sol";
import {LaunchMath} from "../libraries/LaunchMath.sol";

/// @title ILaunchFactory
/// @notice Creates and runs every launch: the same 80/20 curve on each quote asset's raise, with the same fees
///         (the fixed hook fee plus the creator's own tax). A launch is identified by its token. In one call the
///         factory deploys the token, creates the pool with the curve in it and makes the creator's dev buy. It
///         holds the reserve and graduates the pool when a buy sells the curve out (`onSoldOut`).
///         The owner is the protocol recipient (two-step `Ownable`). It can set the launch fee and quote assets'
///         raises, approve or withdraw assets, pause new launches, withdraw launch fees and hand the role on.
interface ILaunchFactory {
    /// @notice A quote asset and the raise for launches quoted in it, in its own units (constructor input).
    struct PairTokenRaise {
        address pairToken;
        uint256 raise;
    }

    /// @notice What a creator passes to `create`. As on Pons, it doesn't pin the raise or the launch fee; `create`
    ///         uses whatever is current when it lands.
    struct CreateParams {
        /// @dev Where the creator's share of the fees goes; zero means the creator. Any address is accepted, so
        ///      one that can't receive or move the quote strands the share until a new recipient is set.
        address feeRecipient;
        /// @dev Receives the dev buy and may propose a new fee recipient; zero means the caller. Not verified
        ///      (`LaunchCreated` also records the caller). Can't be the factory or the hook (`InvalidCreator`).
        address creator;
        /// @dev The quote asset: zero for ETH, otherwise an approved ERC-20. Its current raise sets the curve, and
        ///      fees are paid in it.
        address pairToken;
        /// @dev The quote to spend on the creator's dev buy, fee included; zero for none. It can buy the whole
        ///      curve, which graduates the pool at once. Unspent ETH is refunded; an ERC-20 is pulled only for what
        ///      was spent.
        uint256 devBuyQuote;
        /// @dev The minimum tokens the dev buy must deliver (`DevBuySlippage` otherwise). `quote` gives the exact
        ///      figure, and this also guards against a raise changed in between.
        uint256 minDevTokens;
        /// @dev The creator's own fee on every swap, on top of the hook fee; at most `MAX_CREATOR_TAX_BPS`.
        uint16 creatorTaxBPS;
        /// @dev Up to `MAX_SNIPE_EXEMPT` signers whose buys skip the snipe tax, besides the caller and the fee
        ///      recipient. Matched on `tx.origin` and fixed for good. A Safe's owner should list the signer that
        ///      sends its transactions. An ERC-4337 account can't be exempt: its bundler sends them. Never list a
        ///      bundler or a relayer, which would exempt every buy it sends.
        address[] snipeExempt;
        /// @dev Namespaced to the caller; `predict` gives the resulting token address.
        bytes32 salt;
        /// @dev The token's name, symbol, logo, description and socials.
        ILaunchToken.Metadata metadata;
    }

    /// @notice The non-indexed part of `LaunchCreated`. The curve is `LaunchMath.curveAt(gradTick)`.
    struct LaunchCreatedData {
        PoolKey key;
        address feeRecipient;
        /// @dev Who called `create`; the indexed `creator` is who it named.
        address sender;
        /// @dev The creator's tax on top of the fixed hook fee.
        uint16 creatorTaxBPS;
        int24 gradTick;
        /// @dev The most the dev buy could spend; `DevBought` has what it actually bought and paid.
        uint256 devBuyQuote;
        /// @dev The launch fee this launch paid, in wei.
        uint256 launchFee;
        bytes32 salt;
    }

    /// @notice A launch's record. The pool key, orientation and curve all follow from it and the token address.
    struct LaunchRecord {
        /// @dev The quote asset: ETH (the zero address) or an approved ERC-20.
        Currency pairToken;
        /// @dev Where the curve ends and the pool graduates, in curve space (tokens per quote).
        int24 gradTick;
        /// @dev Whether the quote is currency0 (it sorts below the token; ETH always does). Buys are
        ///      `zeroForOne` exactly when this is true.
        bool quoteIs0;
        /// @dev Whether the factory created this launch.
        bool created;
        /// @dev Whether the pool has graduated. Mirrors the hook's record, set in the same call.
        bool graduated;
    }

    /// @notice A launch was created, registered and seeded.
    event LaunchCreated(address indexed token, PoolId indexed poolID, address indexed creator, LaunchCreatedData data);

    /// @notice The launch's pool was created with the curve in it.
    event Seeded(address indexed token, uint128 liquidity, uint256 tokens);

    /// @notice The creator's dev buy got `tokens` for `quote`, fee included.
    event DevBought(address indexed token, address indexed creator, uint256 tokens, uint256 quote);

    /// @notice The pool graduated: quote and reserve locked full-range, leftover quote added to the pool's fees,
    ///         leftover tokens burned.
    event Graduated(
        address indexed token,
        uint128 liquidity,
        uint256 quoteLocked,
        uint256 tokensLocked,
        uint256 quoteToFees,
        uint256 tokensBurned
    );

    /// @notice The launch fee for future launches changed.
    event LaunchFeeUpdated(uint256 launchFee);

    /// @notice New launches were paused, or resumed.
    event LaunchesPausedUpdated(bool paused);

    /// @notice The launch fees held by the factory were paid to `to`.
    event LaunchFeesWithdrawn(address indexed to, uint256 amount);

    /// @notice New launches quoted in `pairToken` will raise `raise` and graduate at `gradTick`.
    event RaiseSet(address indexed pairToken, uint256 raise, int24 gradTick);

    /// @notice `pairToken` was approved or withdrawn as a quote asset for new launches.
    event PairTokenApprovalSet(address indexed pairToken, bool approved);

    /// @notice The TokenDeployer, the FeeManager or the quoter was not built for this factory and its PoolManager.
    error DeployerMismatch();

    /// @notice The launch fee is over `MAX_LAUNCH_FEE`.
    error LaunchFeeTooHigh();

    /// @notice The quote asset is not approved for new launches.
    error PairTokenNotApproved();

    /// @notice The quote token has no code.
    error PairTokenNotAContract();

    /// @notice The quote token has no raise set.
    error PairTokenEconomicsNotSet();

    /// @notice More snipe-tax exemptions than `MAX_SNIPE_EXEMPT` were listed.
    error TooManySnipeExemptions();

    /// @notice The creator can't be the factory or the hook: neither could ever use the role or claim its fees.
    error InvalidCreator();

    /// @notice The protocol recipient role cannot be renounced.
    error RenounceDisabled();

    /// @notice The launch fees cannot be paid to the zero address.
    error ZeroAddress();

    /// @notice `create` was sent less ETH than the launch fee.
    error LaunchFeeUnpaid(uint256 required, uint256 sent);

    /// @notice New launches are paused; live ones trade on.
    error LaunchesPaused();

    /// @notice The dev buy delivered fewer tokens than `minDevTokens`.
    error DevBuySlippage(uint256 tokens, uint256 minTokens);

    /// @notice The factory did not create a launch for this token.
    error UnknownLaunch();

    /// @notice An ETH launch was sent less than its dev buy (on top of the launch fee).
    error InsufficientQuote(uint256 needed, uint256 sent);

    /// @notice The caller refused the refund of unspent ETH.
    error ETHRefundFailed();

    /// @notice A callback came from anyone but the PoolManager.
    error NotPoolManager();

    /// @notice Only the hook may report a sold-out curve.
    error NotHook();

    /// @notice Creates a launch. `msg.value` pays the launch fee in ETH, whatever the quote asset. An ETH launch also
    ///         sends `devBuyQuote`; for an ERC-20 the caller approves the factory for it instead. Whatever the dev
    ///         buy doesn't spend is refunded (or never pulled), and a dev buy of the whole curve graduates the pool
    ///         at once. Uses the raise and launch fee current when it lands; `minDevTokens` guards the dev buy.
    ///         Non-reentrant. Reverts, in this order: `LaunchesPaused`, `LaunchFeeUnpaid`, `CreatorTaxTooHigh`,
    ///         `TooManySnipeExemptions`, `InvalidCreator`, `InsufficientQuote`, `PairTokenNotApproved`, the token's
    ///         metadata checks (or `FailedDeployment` if the address is taken), `DevBuySlippage`, a failed ERC-20
    ///         pull, then `ETHRefundFailed`.
    function create(CreateParams calldata p) external payable returns (address token, PoolId poolID);

    /// @notice Graduates `token`'s launch inside the swap that sold its curve out, moving the raised quote and the
    ///         reserve into a locked full-range position. Hook only, from `afterSwap`, so the buyer pays for it and
    ///         a pool never rests sold out.
    function onSoldOut(address token) external;

    /// @notice Sets the ETH every future `create` pays, at most `MAX_LAUNCH_FEE`. Protocol recipient only.
    function setLaunchFee(uint64 launchFee_) external;

    /// @notice Pauses or resumes new launches; live ones keep trading. Protocol recipient only.
    function setLaunchesPaused(bool paused) external;

    /// @notice Sends the collected launch fees to `to` (not zero) and returns the amount. Protocol recipient only.
    function withdrawLaunchFees(address payable to) external returns (uint256 amount);

    /// @notice Sets the raise for new launches quoted in `pairToken` (zero for ETH). Doesn't change approval or
    ///         existing launches. Reverts outside `MIN_RAISE`..`MAX_RAISE` or for an ERC-20 with no code. Protocol
    ///         recipient only.
    function setRaise(address pairToken, uint256 raise) external;

    /// @notice Approves or withdraws `pairToken` (zero for ETH) as a quote asset for new launches. Approving needs a
    ///         raise; withdrawing keeps it. Existing launches are unaffected. Protocol recipient only.
    function setApproved(address pairToken, bool approved) external;

    /// @notice The Uniswap V4 PoolManager every launch's pool lives in.
    function poolManager() external view returns (IPoolManager);

    /// @notice The hook on every launch pool, deployed by the factory.
    function hook() external view returns (ILaunchHook);

    /// @notice The quoter: exact quotes and live state for every launch.
    function quoter() external view returns (ILaunchQuoter);

    /// @notice The FeeManager: fee recipients and their claimable fees.
    function feeManager() external view returns (IFeeManager);

    /// @notice Who receives the protocol's share of fees: the factory's owner, handed on in two steps.
    function protocolRecipient() external view returns (address);

    /// @notice The ETH fee `create` charges, whatever the quote asset.
    function launchFee() external view returns (uint64);

    /// @notice Whether new launches are paused.
    function launchesPaused() external view returns (bool);

    /// @notice The raise set for `pairToken` (zero for ETH), approved or not; zero if never set.
    function raiseOf(address pairToken) external view returns (uint256);

    /// @notice Whether new launches may be quoted in `pairToken` (zero for ETH).
    function isPairTokenApproved(address pairToken) external view returns (bool);

    /// @notice What `create(p)` by `sender` would do right now, to the unit: the curve, and the dev buy's tokens,
    ///         spend and fee. Reverts as `create` would for a bad tax or an unapproved asset. Uses current terms, so
    ///         a later change to the raise or fee changes the result. To buy the whole curve, quote more than it
    ///         costs and send `devSpent`.
    function quote(address sender, CreateParams calldata p)
        external
        view
        returns (LaunchMath.Curve memory curve, uint256 devTokens, uint256 devSpent, uint256 devFee);

    /// @notice The token address `create(p)` yields when `sender` calls it.
    function predict(address sender, CreateParams calldata p) external view returns (address token);

    /// @notice How many launches the factory has created.
    function count() external view returns (uint256);

    /// @notice Up to `limit` launches' tokens from `index`, oldest first.
    function launchesFrom(uint256 index, uint256 limit) external view returns (address[] memory);

    /// @notice The launch of `token`; `created` is false for a token the factory did not launch.
    function launches(address token) external view returns (LaunchRecord memory);

    /// @notice The launch's pool key. Reverts for a token the factory didn't launch.
    function poolKey(address token) external view returns (PoolKey memory);
}
