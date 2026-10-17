// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";

import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";

/// @title FeeManager
/// @notice Holds every fee as ERC-6909 claims on the PoolManager and tracks who may claim them. A sweep credits a
///         pool's pending fees to the launch's fee recipient and the protocol recipient; each then claims its
///         balance. A launch's recipient can be changed after a delay. Modelled on Pons V2.
/// @dev No owner of its own: the factory's owner, read live, sets the sweep operator. A sweep only credits; a
///      claim zeroes the balance before paying, inside an unlock that can't nest, so re-entering finds nothing.
///      Anyone can claim on a recipient's behalf (`claimFor`), so a recipient that can't make calls still gets
///      paid.
contract FeeManager is IFeeManager, IUnlockCallback {
    using CurrencySettler for Currency;

    /// @notice How long a proposed fee recipient waits before it can be executed.
    uint256 public constant FEE_RECIPIENT_DELAY = 3 days;

    /// @notice How long a proposal stays executable after its delay.
    uint256 public constant FEE_RECIPIENT_WINDOW = 7 days;

    /// @inheritdoc IFeeManager
    IPoolManager public immutable poolManager;

    /// @inheritdoc IFeeManager
    address public immutable factory;

    /// @inheritdoc IFeeManager
    address public feeSweepOperator;

    /// @inheritdoc IFeeManager
    mapping(address token => address) public feeRecipientOf;

    mapping(address token => PendingRecipient) internal _pending;

    /// @inheritdoc IFeeManager
    mapping(address recipient => mapping(Currency currency => uint256)) public claimable;

    /// @param factory_ The factory, deployed next at its predicted address (it checks the pairing).
    /// @param operator_ The first fee sweep operator, usually the protocol recipient. Not zero.
    constructor(IPoolManager poolManager_, address factory_, address operator_) {
        if (operator_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        factory = factory_;
        feeSweepOperator = operator_;
    }

    // ---------------------------------------------------------------------
    // External functions.
    // ---------------------------------------------------------------------

    /// @inheritdoc IFeeManager
    function register(address token, address recipient) external {
        if (msg.sender != factory) {
            revert NotFactory();
        }
        feeRecipientOf[token] = recipient; // never zero: the factory defaults it to the creator
        emit FeeRecipientChanged(token, address(0), recipient);
    }

    /// @inheritdoc IFeeManager
    function sweep(address token) external returns (uint256 creatorAmount, uint256 protocolAmount) {
        if (msg.sender != feeSweepOperator) {
            revert NotFeeSweepOperator();
        }
        return _sweep(token);
    }

    /// @inheritdoc IFeeManager
    function sweepMany(address[] calldata tokens) external {
        if (msg.sender != feeSweepOperator) {
            revert NotFeeSweepOperator();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _sweep(tokens[i]);
        }
    }

    /// @inheritdoc IFeeManager
    function setFeeSweepOperator(address operator) external {
        if (msg.sender != _protocolRecipient()) {
            revert NotProtocolRecipient();
        }
        if (operator == address(0)) {
            revert ZeroAddress();
        }
        feeSweepOperator = operator;
        emit FeeSweepOperatorUpdated(operator);
    }

    /// @inheritdoc IFeeManager
    function claim(Currency currency) external returns (uint256 amount) {
        return _claim(msg.sender, currency);
    }

    /// @inheritdoc IFeeManager
    function claimFor(address recipient, Currency currency) external returns (uint256 amount) {
        return _claim(recipient, currency);
    }

    /// @notice The PoolManager's callback for a claim: burns the claims and pays the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        (address to, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, to, amount, false);
        return "";
    }

    /// @inheritdoc IFeeManager
    function transferFeeRecipient(address token, address to) external {
        address current = feeRecipientOf[token];
        if (msg.sender != current) {
            revert NotFeeRecipient();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        _setRecipient(token, to);
    }

    /// @inheritdoc IFeeManager
    function proposeFeeRecipient(address token, address to) external {
        if (feeRecipientOf[token] == address(0)) {
            revert UnknownLaunch();
        }
        if (msg.sender != ILaunchToken(token).creator()) {
            revert NotCreator();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 effectiveAt = block.timestamp + FEE_RECIPIENT_DELAY; // fits a uint40 for millennia
        _pending[token] = PendingRecipient({to: to, effectiveAt: uint40(effectiveAt)});
        emit FeeRecipientChangeProposed(token, to, msg.sender, effectiveAt, effectiveAt + FEE_RECIPIENT_WINDOW);
    }

    /// @inheritdoc IFeeManager
    function executeFeeRecipientChange(address token) external {
        PendingRecipient memory p = _pending[token];
        if (p.to == address(0)) {
            revert NoPendingChange();
        }
        uint256 expiresAt = p.effectiveAt + FEE_RECIPIENT_WINDOW;
        if (block.timestamp < p.effectiveAt || block.timestamp >= expiresAt) {
            revert ChangeNotExecutable(p.effectiveAt, expiresAt);
        }
        _setRecipient(token, p.to); // proposals are never zero
    }

    /// @inheritdoc IFeeManager
    function cancelFeeRecipientChange(address token) external {
        if (_pending[token].to == address(0)) {
            revert NoPendingChange();
        }
        if (msg.sender != feeRecipientOf[token] && msg.sender != ILaunchToken(token).creator()) {
            revert NotFeeRecipientOrCreator();
        }
        delete _pending[token];
        emit FeeRecipientChangeCancelled(token);
    }

    /// @inheritdoc IFeeManager
    /// @dev Keyed by the caller, so a caller can only drop a proposal for a token at its own address.
    function dropPendingFeeRecipient() external {
        if (_pending[msg.sender].to == address(0)) {
            return;
        }
        delete _pending[msg.sender];
        emit FeeRecipientChangeCancelled(msg.sender);
    }

    // ---------------------------------------------------------------------
    // External views.
    // ---------------------------------------------------------------------

    /// @inheritdoc IFeeManager
    function pendingFeeRecipient(address token)
        external
        view
        returns (address to, uint256 effectiveAt, uint256 expiresAt)
    {
        PendingRecipient memory p = _pending[token];
        if (p.to == address(0)) {
            return (address(0), 0, 0);
        }
        return (p.to, p.effectiveAt, p.effectiveAt + FEE_RECIPIENT_WINDOW);
    }

    // ---------------------------------------------------------------------
    // Internal functions.
    // ---------------------------------------------------------------------

    /// @dev Pays `recipient` its whole balance of `currency`, zeroing it first.
    function _claim(address recipient, Currency currency) internal returns (uint256 amount) {
        amount = claimable[recipient][currency];
        if (amount == 0) {
            return 0;
        }
        claimable[recipient][currency] = 0;
        poolManager.unlock(abi.encode(recipient, currency, amount));
        emit Claimed(recipient, currency, amount);
    }

    /// @dev Credits the launch's pending fees to its current fee recipient and the protocol recipient.
    function _sweep(address token) internal returns (uint256 creatorAmount, uint256 protocolAmount) {
        ILaunchFactory f = ILaunchFactory(factory);
        PoolKey memory key = f.poolKey(token); // reverts for an unknown token
        Currency quote;
        (protocolAmount, creatorAmount, quote) = ILaunchHook(address(key.hooks)).collect(key);
        _credit(feeRecipientOf[token], quote, creatorAmount);
        _credit(f.protocolRecipient(), quote, protocolAmount);
        emit FeesSwept(token, creatorAmount, protocolAmount);
    }

    /// @dev Adds `amount` to what `to` may claim; zero amounts emit nothing.
    function _credit(address to, Currency currency, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        claimable[to][currency] += amount;
        emit Credited(to, currency, amount);
    }

    /// @dev Makes `to` the launch's fee recipient and drops any pending proposal. Sweeps first, so fees already
    ///      earned go to the outgoing recipient.
    function _setRecipient(address token, address to) internal {
        _sweep(token);
        emit FeeRecipientChanged(token, feeRecipientOf[token], to);
        feeRecipientOf[token] = to;
        delete _pending[token];
    }

    // ---------------------------------------------------------------------
    // Internal views.
    // ---------------------------------------------------------------------

    /// @dev The protocol recipient: the factory's owner, read live so an ownership handover applies here too.
    function _protocolRecipient() internal view returns (address) {
        return ILaunchFactory(factory).protocolRecipient();
    }
}
