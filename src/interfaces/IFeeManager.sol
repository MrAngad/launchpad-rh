// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IFeeManager
/// @notice Holds every fee as ERC-6909 claims and tracks each launch's fee recipient. The sweep operator credits a
///         pool's pending fees to the launch's recipient and the protocol recipient; a claim pays them out. A
///         recipient can hand its role on directly. The creator can propose a new one, which anyone may execute
///         after `FEE_RECIPIENT_DELAY` and within `FEE_RECIPIENT_WINDOW`. The protocol recipient has no say over a
///         launch's recipient.
interface IFeeManager {
    /// @notice A proposed fee recipient change, waiting out its delay.
    struct PendingRecipient {
        address to;
        uint40 effectiveAt;
    }

    /// @notice A launch's pending fees were split between its recipients' claimable balances.
    event FeesSwept(address indexed token, uint256 creatorAmount, uint256 protocolAmount);

    /// @notice `amount` of `currency` became claimable by `recipient`.
    event Credited(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice `recipient` was paid `amount` of `currency` from the PoolManager.
    event Claimed(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice The launch's fee recipient changed.
    event FeeRecipientChanged(address indexed token, address indexed previous, address indexed current);

    /// @notice `proposer` proposed `to` as the launch's fee recipient, executable from `effectiveAt` to `expiresAt`.
    event FeeRecipientChangeProposed(
        address indexed token, address indexed to, address indexed proposer, uint256 effectiveAt, uint256 expiresAt
    );

    /// @notice A proposed fee recipient change was cancelled.
    event FeeRecipientChangeCancelled(address indexed token);

    /// @notice The fee sweep operator changed.
    event FeeSweepOperatorUpdated(address indexed operator);

    /// @notice Only the factory registers launches.
    error NotFactory();

    /// @notice Only the fee sweep operator sweeps.
    error NotFeeSweepOperator();

    /// @notice Only the protocol recipient (the factory's owner) sets the fee sweep operator.
    error NotProtocolRecipient();

    /// @notice Only the launch's fee recipient may hand its role on.
    error NotFeeRecipient();

    /// @notice Only the token's creator may propose a fee recipient.
    error NotCreator();

    /// @notice Only the fee recipient or the creator may cancel a proposal.
    error NotFeeRecipientOrCreator();

    /// @notice The launch is not registered.
    error UnknownLaunch();

    /// @notice A fee recipient, or the fee sweep operator, cannot be the zero address.
    error ZeroAddress();

    /// @notice No fee recipient change is proposed.
    error NoPendingChange();

    /// @notice The proposal isn't executable now (before `effectiveAt` or from `expiresAt`).
    error ChangeNotExecutable(uint256 effectiveAt, uint256 expiresAt);

    /// @notice A callback came from anyone but the PoolManager.
    error NotPoolManager();

    /// @notice Records `recipient` as the fee recipient of the launch of `token`. Factory only, once per launch.
    function register(address token, address recipient) external;

    /// @notice Credits the launch's pending fees: the creator's share to its fee recipient, the protocol's share to
    ///         the protocol recipient. Sweep operator only. Changing the recipient also sweeps first.
    function sweep(address token) external returns (uint256 creatorAmount, uint256 protocolAmount);

    /// @notice `sweep` for each of `tokens`, in one call. Sweep operator only. An unknown token reverts the batch.
    function sweepMany(address[] calldata tokens) external;

    /// @notice Sets the sweep operator (not zero). Protocol recipient only.
    function setFeeSweepOperator(address operator) external;

    /// @notice Pays the caller its whole balance of `currency` and returns it; does nothing for a zero balance. A
    ///         quote that taxes transfers taxes the payout.
    function claim(Currency currency) external returns (uint256 amount);

    /// @notice The same, paid to `recipient` and callable by anyone, for recipients that can't make calls.
    function claimFor(address recipient, Currency currency) external returns (uint256 amount);

    /// @notice Hands the fee recipient role to `to` at once, after sweeping earned fees to the current recipient.
    ///         Cancels any proposal. Current recipient only. Any non-zero address is accepted, so one that can't
    ///         receive the quote strands what it's credited.
    function transferFeeRecipient(address token, address to) external;

    /// @notice Proposes `to` as the launch's fee recipient, executable after `FEE_RECIPIENT_DELAY`. Creator only. A
    ///         new proposal replaces the old one and restarts the delay; a creator handover drops it.
    function proposeFeeRecipient(address token, address to) external;

    /// @notice Executes the proposal inside its window, sweeping earned fees to the outgoing recipient first.
    ///         Anyone may call.
    function executeFeeRecipientChange(address token) external;

    /// @notice Cancels the proposal. The fee recipient or the creator.
    function cancelFeeRecipientChange(address token) external;

    /// @notice Drops the caller's pending proposal, if any. A launch token calls it when its creator role moves, so
    ///         a former creator's proposal can't be executed later. Any other caller has none to drop.
    function dropPendingFeeRecipient() external;

    /// @notice The PoolManager the claims are held on.
    function poolManager() external view returns (IPoolManager);

    /// @notice The factory whose launches this manages.
    function factory() external view returns (address);

    /// @notice The account that may sweep, such as a keeper.
    function feeSweepOperator() external view returns (address);

    /// @notice Where the creator's share of a launch's fees goes; zero for an unknown launch.
    function feeRecipientOf(address token) external view returns (address);

    /// @notice The pending fee recipient proposal; `to` is zero if there is none.
    function pendingFeeRecipient(address token)
        external
        view
        returns (address to, uint256 effectiveAt, uint256 expiresAt);

    /// @notice What `recipient` can claim of `currency` (ETH is the zero currency).
    function claimable(address recipient, Currency currency) external view returns (uint256);
}
