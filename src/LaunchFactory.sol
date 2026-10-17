// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {ILaunchQuoter} from "./interfaces/ILaunchQuoter.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {TokenDeployer} from "./TokenDeployer.sol";
import {LaunchHook} from "./LaunchHook.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";

/// @title LaunchFactory
/// @notice Creates and runs every launch: the same 80/20 curve on each quote asset's raise, with the same fixed
///         fees. It deploys the hook once, then for each launch deploys the token, creates the pool with the curve
///         in it, makes the creator's dev buy and holds the reserve. The buy that sells a curve out graduates it
///         into a locked full-range position. The owner is the protocol recipient and the only privileged role:
///         it sets the launch fee and quote assets' raises, pauses new launches and withdraws launch fees. It
///         can't touch a live launch's curve or fees, can't move tokens, and can't renounce the role.
/// @dev The curve is a single-sided V4 position. When the quote sorts above the token, the pool holds it
///      mirrored at negated ticks (`LaunchMath.poolTicks`). See docs/MECHANICS.md.
///
///      Custody: between calls the factory holds only each launch's reserve tokens and the launch fees in ETH.
///      Any other ETH a creator sends is spent on the dev buy or refunded in the same call.
contract LaunchFactory is ILaunchFactory, IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /// @notice The highest launch fee allowed: 20 times Pons's 0.0005 ETH.
    uint64 public constant MAX_LAUNCH_FEE = 0.01 ether;

    /// @notice The most snipe-tax exemptions a creator may list, besides the caller and the fee recipient.
    uint256 public constant MAX_SNIPE_EXEMPT = 32;

    /// @inheritdoc ILaunchFactory
    IPoolManager public immutable poolManager;

    /// @inheritdoc ILaunchFactory
    ILaunchHook public immutable hook;

    /// @inheritdoc ILaunchFactory
    ILaunchQuoter public immutable quoter;

    /// @inheritdoc ILaunchFactory
    IFeeManager public immutable feeManager;

    /// @notice Deploys the tokens at the addresses `predict` returns.
    TokenDeployer public immutable tokenDeployer;

    /// @dev A quote asset's raise, its graduation tick and whether it's approved, packed in one slot. Withdrawing
    ///      approval keeps the raise; a zero raise means none was ever set.
    struct QuoteAsset {
        uint128 raise;
        int24 gradTick;
        bool approved;
    }

    /// @dev The dev buy's terms: who pays, who gets the tokens, the quote to spend, the minimum tokens, and the ETH
    ///      sent on top of the launch fee.
    struct Seed {
        address payer;
        address creator;
        uint256 devBuyQuote;
        uint256 minDevTokens;
        uint256 budget;
    }

    /// @dev A launch's pool and curve, worked out from its record and its token's address.
    struct Ctx {
        PoolKey key;
        PoolId poolID;
        Currency pairToken;
        Currency token;
        bool quoteIs0;
        int24 gradTick;
        uint160 sqrtStart;
        uint160 sqrtGrad;
        uint128 curveLiquidity;
    }

    // `launchFee` and `launchesPaused` share a slot, since `create` reads both.

    /// @inheritdoc ILaunchFactory
    uint64 public launchFee;

    /// @inheritdoc ILaunchFactory
    bool public launchesPaused;

    address[] internal _tokens;
    mapping(address pairToken => QuoteAsset) internal _quoteAssets;
    mapping(address token => LaunchRecord) internal _launches;

    /// @param hookSalt A CREATE2 salt, mined offline, that gives the hook an address with its permission flags.
    /// @param tokenDeployer_ The TokenDeployer deployed for this factory's predicted address.
    /// @param feeManager_ The FeeManager deployed for this factory's predicted address.
    /// @param quoter_ The quoter deployed for this factory's predicted address.
    /// @param quoteAssets Quote assets approved from the start, each with its raise (ETH as the zero address).
    ///                    Checked as `setRaise` checks them.
    constructor(
        IPoolManager poolManager_,
        bytes32 hookSalt,
        TokenDeployer tokenDeployer_,
        IFeeManager feeManager_,
        ILaunchQuoter quoter_,
        address protocolRecipient_,
        uint64 launchFee_,
        PairTokenRaise[] memory quoteAssets
    ) Ownable(protocolRecipient_) {
        _setLaunchFee(launchFee_);
        for (uint256 i = 0; i < quoteAssets.length; i++) {
            _setRaise(quoteAssets[i].pairToken, quoteAssets[i].raise);
            _setApproved(quoteAssets[i].pairToken, true);
        }
        if (
            feeManager_.factory() != address(this) || quoter_.factory() != address(this)
                || tokenDeployer_.factory() != address(this) || feeManager_.poolManager() != poolManager_
                || quoter_.poolManager() != poolManager_
        ) {
            revert DeployerMismatch();
        }
        poolManager = poolManager_;
        tokenDeployer = tokenDeployer_;
        feeManager = feeManager_;
        quoter = quoter_;
        hook = new LaunchHook{salt: hookSalt}(poolManager_, address(feeManager_));
    }

    // ---------------------------------------------------------------------
    // External functions.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchFactory
    /// @dev Non-reentrant: the refund calls the caller, and a quote token's transfer may call anyone.
    function create(CreateParams calldata p) external payable nonReentrant returns (address token, PoolId poolID) {
        if (launchesPaused) {
            revert LaunchesPaused();
        }
        // check every term that can fail before deploying the token
        uint64 fee = launchFee;
        if (msg.value < fee) {
            revert LaunchFeeUnpaid(fee, msg.value);
        }
        if (p.creatorTaxBPS > LaunchMath.MAX_CREATOR_TAX_BPS) {
            revert ILaunchHook.CreatorTaxTooHigh();
        }
        if (p.snipeExempt.length > MAX_SNIPE_EXEMPT) {
            revert TooManySnipeExemptions();
        }
        Seed memory s = Seed({
            payer: msg.sender,
            creator: _creatorOf(p, msg.sender),
            devBuyQuote: p.devBuyQuote,
            minDevTokens: p.minDevTokens,
            budget: msg.value - fee
        });
        // only a creator named explicitly can be one of these; a defaulted creator is the caller
        if (s.creator == address(this) || s.creator == address(hook)) {
            revert InvalidCreator();
        }
        if (p.pairToken == address(0) && s.devBuyQuote > s.budget) {
            revert InsufficientQuote(s.devBuyQuote, s.budget);
        }
        int24 gradTick = _gradTickOf(p.pairToken);
        token = address(tokenDeployer.deploy(_salt(msg.sender, p.salt), p.metadata, s.creator));
        LaunchRecord memory r = LaunchRecord({
            pairToken: Currency.wrap(p.pairToken),
            gradTick: gradTick,
            quoteIs0: p.pairToken < token,
            created: true,
            graduated: false
        });
        _launches[token] = r;
        _tokens.push(token);
        Ctx memory c = _context(r, token); // worked out once, for both registration and seeding
        poolID = c.poolID;
        _register(c, p, s);
        uint256 spent = abi.decode(poolManager.unlock(abi.encode(c, s)), (uint256));
        uint256 refund = s.budget - spent;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) {
                revert ETHRefundFailed();
            }
        }
    }

    /// @inheritdoc ILaunchFactory
    /// @dev Called by the hook in the buy that sold the curve out, so the graduation settles inside the buyer's
    ///      unlock. Shares `create`'s reentrancy guard, so nothing graduates inside a `create` but its own dev buy.
    function onSoldOut(address token) external nonReentrant {
        if (msg.sender != address(hook)) {
            revert NotHook();
        }
        _graduate(_context(_launches[token], token));
    }

    /// @notice The PoolManager's callback for `create`: seeds the pool and makes the dev buy.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        (Ctx memory c, Seed memory s) = abi.decode(data, (Ctx, Seed));
        return abi.encode(_seed(c, s));
    }

    /// @inheritdoc ILaunchFactory
    function setLaunchFee(uint64 launchFee_) external onlyOwner {
        _setLaunchFee(launchFee_);
    }

    /// @inheritdoc ILaunchFactory
    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        emit LaunchesPausedUpdated(paused);
    }

    /// @inheritdoc ILaunchFactory
    /// @dev The factory has no `receive()` and keeps no creator ETH past `create`, so its balance is launch fees.
    function withdrawLaunchFees(address payable to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        amount = address(this).balance;
        Address.sendValue(to, amount);
        emit LaunchFeesWithdrawn(to, amount);
    }

    /// @inheritdoc ILaunchFactory
    function setRaise(address pairToken, uint256 raise) external onlyOwner {
        _setRaise(pairToken, raise);
    }

    /// @inheritdoc ILaunchFactory
    function setApproved(address pairToken, bool approved) external onlyOwner {
        _setApproved(pairToken, approved);
    }

    // ---------------------------------------------------------------------
    // External views.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchFactory
    function quote(address sender, CreateParams calldata p)
        external
        view
        returns (LaunchMath.Curve memory curve, uint256 devTokens, uint256 devSpent, uint256 devFee)
    {
        if (p.creatorTaxBPS > LaunchMath.MAX_CREATOR_TAX_BPS) {
            revert ILaunchHook.CreatorTaxTooHigh(); // as `create` would
        }
        curve = LaunchMath.curveAt(_gradTickOf(p.pairToken));
        // the quote's side of the pool depends on the token address `create` would deploy
        bool quoteIs0 = p.pairToken < _predict(sender, p);
        uint256 feeBPS = LaunchMath.totalFeeBPS(p.creatorTaxBPS);
        (devTokens, devSpent, devFee) =
            LaunchMath.devBuyFill(curve.gradTick, curve.liquidity, p.devBuyQuote, feeBPS, quoteIs0);
    }

    /// @inheritdoc ILaunchFactory
    function predict(address sender, CreateParams calldata p) external view returns (address) {
        return _predict(sender, p);
    }

    /// @inheritdoc ILaunchFactory
    function count() external view returns (uint256) {
        return _tokens.length;
    }

    /// @inheritdoc ILaunchFactory
    function launchesFrom(uint256 index, uint256 limit) external view returns (address[] memory list) {
        uint256 total = _tokens.length;
        uint256 n = index < total ? Math.min(limit, total - index) : 0; // no `index + limit`, so it can't overflow
        list = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            list[i] = _tokens[index + i];
        }
    }

    /// @inheritdoc ILaunchFactory
    function launches(address token) external view returns (LaunchRecord memory) {
        return _launches[token];
    }

    /// @inheritdoc ILaunchFactory
    function poolKey(address token) external view returns (PoolKey memory) {
        LaunchRecord memory r = _launches[token];
        if (!r.created) {
            revert UnknownLaunch();
        }
        return _key(r, token);
    }

    /// @inheritdoc ILaunchFactory
    function raiseOf(address pairToken) external view returns (uint256) {
        return _quoteAssets[pairToken].raise;
    }

    /// @inheritdoc ILaunchFactory
    function isPairTokenApproved(address pairToken) external view returns (bool) {
        return _quoteAssets[pairToken].approved;
    }

    // ---------------------------------------------------------------------
    // Public views.
    // ---------------------------------------------------------------------

    /// @inheritdoc ILaunchFactory
    function protocolRecipient() public view returns (address) {
        return owner();
    }

    /// @notice Disabled: a zero protocol recipient would strand every pool's protocol share.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internal functions.
    // ---------------------------------------------------------------------

    /// @dev Registers the pool with the hook and the fee recipient with the FeeManager, then emits
    ///      `LaunchCreated`.
    function _register(Ctx memory c, CreateParams calldata p, Seed memory s) internal {
        address token = Currency.unwrap(c.token);
        address feeRecipient = p.feeRecipient == address(0) ? s.creator : p.feeRecipient;
        hook.register(
            c.key,
            ILaunchHook.Registration({
                quoteIs0: c.quoteIs0,
                gradTick: c.gradTick,
                curveLiquidity: c.curveLiquidity,
                creatorTaxBPS: p.creatorTaxBPS
            }),
            _snipeExempt(p, feeRecipient)
        );
        feeManager.register(token, feeRecipient);
        emit LaunchCreated(
            token,
            c.poolID,
            s.creator,
            LaunchCreatedData({
                key: c.key,
                feeRecipient: feeRecipient,
                sender: msg.sender,
                creatorTaxBPS: p.creatorTaxBPS,
                gradTick: c.gradTick,
                devBuyQuote: s.devBuyQuote,
                launchFee: launchFee,
                salt: p.salt
            })
        );
    }

    /// @dev Creates the pool at the curve's start with the curve already in it, then makes the dev buy, if any.
    ///      Returns the ETH the dev buy spent (an ERC-20 dev buy is paid by the payer).
    function _seed(Ctx memory c, Seed memory s) internal returns (uint256 spent) {
        poolManager.initialize(c.key, c.sqrtStart);
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(c.key, _curveRange(c, int256(uint256(c.curveLiquidity))), "");
        (, int128 tokenDelta) = LaunchMath.split(delta, c.quoteIs0);
        uint256 tokens = SafeCast.toUint256(-int256(tokenDelta));
        c.token.settle(poolManager, address(this), tokens, false);
        emit Seeded(Currency.unwrap(c.token), c.curveLiquidity, tokens);
        if (s.devBuyQuote > 0) {
            spent = _devBuy(c, s);
        }
    }

    /// @dev The dev buy: an exact input of `devBuyQuote`, limited at the curve's end so it never overshoots. It pays
    ///      the pool's normal fee, never the snipe tax. If it buys the whole curve, the pool graduates right away.
    ///      Returns the ETH spent.
    function _devBuy(Ctx memory c, Seed memory s) internal returns (uint256 spent) {
        // a buy moves the price toward the curve's end: down when the quote is currency0, up otherwise
        BalanceDelta bought = poolManager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.quoteIs0,
                // any amount past int256 already buys the whole curve, so clamp it (as `quote` does)
                amountSpecified: -int256(Math.min(s.devBuyQuote, uint256(type(int256).max))),
                sqrtPriceLimitX96: c.sqrtGrad
            }),
            ""
        );
        (int128 quoteDelta, int128 tokenDelta) = LaunchMath.split(bought, c.quoteIs0);
        uint256 owed = SafeCast.toUint256(-int256(quoteDelta)); // at most `devBuyQuote`, fee included
        uint256 tokens = SafeCast.toUint256(int256(tokenDelta));
        if (tokens < s.minDevTokens) {
            revert DevBuySlippage(tokens, s.minDevTokens);
        }
        if (c.pairToken.isAddressZero()) {
            c.pairToken.settle(poolManager, address(this), owed, false);
            spent = owed;
        } else {
            c.pairToken.settle(poolManager, s.payer, owed, false);
        }
        c.token.take(poolManager, s.creator, tokens, false);
        emit DevBought(Currency.unwrap(c.token), s.creator, tokens, owed);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(c.poolID);
        if (LaunchMath.soldOutAt(sqrtPriceX96, c.sqrtGrad, c.quoteIs0)) {
            _graduate(c);
        }
    }

    /// @dev Graduates a sold-out curve: pins the price at the curve's end, removes the curve, and locks its quote
    ///      with the reserve in a full-range position. Leftover quote becomes the pool's fees; leftover tokens are
    ///      burned.
    function _graduate(Ctx memory c) internal {
        {
            // With no liquidity past the curve's end, the sell-out may have left the price at the buyer's
            // limit. A 1-wei sell back moves nothing but pins the price at the end, where the lock is priced.
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(c.poolID);
            if (sqrtPriceX96 != c.sqrtGrad) {
                poolManager.swap(
                    c.key, SwapParams({zeroForOne: !c.quoteIs0, amountSpecified: -1, sqrtPriceLimitX96: c.sqrtGrad}), ""
                );
            }
        }
        _launches[Currency.unwrap(c.token)].graduated = true;

        // Remove the curve. Its principal is the raised quote; with no LP fee or donations, it earned nothing.
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(c.key, _curveRange(c, -int256(uint256(c.curveLiquidity))), "");
        (int128 quoteDelta,) = LaunchMath.split(delta, c.quoteIs0);

        // Lock the quote with the reserve at the graduation price. The liquidity rounds down, so the amounts the
        // PoolManager charges (rounded up) never exceed what we have.
        (uint128 liquidity, uint256 reserve) = _lockLiquidity(c, SafeCast.toUint256(int256(quoteDelta)));
        (BalanceDelta lockDelta,) = poolManager.modifyLiquidity(
            c.key,
            ModifyLiquidityParams({
                tickLower: LaunchMath.LOCK_TICK_LOWER,
                tickUpper: LaunchMath.LOCK_TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );

        // Leftover quote becomes the pool's pending fees; tokens the lock didn't take are burned.
        (int128 quoteLockDelta, int128 tokenLockDelta) = LaunchMath.split(lockDelta, c.quoteIs0);
        uint256 tokensLocked = SafeCast.toUint256(-int256(tokenLockDelta));
        c.token.settle(poolManager, address(this), tokensLocked, false);
        uint256 quoteToFees = SafeCast.toUint256(poolManager.currencyDelta(address(this), c.pairToken));
        c.pairToken.take(poolManager, address(feeManager), quoteToFees, true); // as claims, like any fee
        uint256 burned = reserve - tokensLocked;
        ILaunchToken(Currency.unwrap(c.token)).burn(burned);

        hook.markGraduated(c.poolID, liquidity, quoteToFees);
        emit Graduated(
            Currency.unwrap(c.token),
            liquidity,
            SafeCast.toUint256(-int256(quoteLockDelta)),
            tokensLocked,
            quoteToFees,
            burned
        );
    }

    function _setLaunchFee(uint64 launchFee_) internal {
        if (launchFee_ > MAX_LAUNCH_FEE) {
            revert LaunchFeeTooHigh();
        }
        launchFee = launchFee_;
        emit LaunchFeeUpdated(launchFee_);
    }

    /// @dev Places the raise's curve (reverting if it's out of range) and stores it with its graduation tick. The
    ///      asset's approval is left as it was. An ERC-20 must have code.
    function _setRaise(address pairToken, uint256 raise) internal {
        _checkHasCode(pairToken);
        int24 gradTick = LaunchMath.curveFor(raise).gradTick;
        _quoteAssets[pairToken] = QuoteAsset({
            raise: SafeCast.toUint128(raise),
            gradTick: gradTick,
            approved: _quoteAssets[pairToken].approved
        });
        emit RaiseSet(pairToken, raise, gradTick);
    }

    /// @dev Approving needs a raise and, for an ERC-20, code. Withdrawing needs neither and keeps the raise.
    function _setApproved(address pairToken, bool approved) internal {
        if (approved) {
            if (_quoteAssets[pairToken].raise == 0) {
                revert PairTokenEconomicsNotSet();
            }
            _checkHasCode(pairToken);
        }
        _quoteAssets[pairToken].approved = approved;
        emit PairTokenApprovalSet(pairToken, approved);
    }

    // ---------------------------------------------------------------------
    // Internal views.
    // ---------------------------------------------------------------------

    /// @dev A quote asset other than ETH (the zero address) must be a contract.
    function _checkHasCode(address pairToken) internal view {
        if (pairToken != address(0) && pairToken.code.length == 0) {
            revert PairTokenNotAContract();
        }
    }

    /// @dev The graduation tick for a new launch quoted in `pairToken`. The asset must be approved.
    function _gradTickOf(address pairToken) internal view returns (int24) {
        QuoteAsset memory asset = _quoteAssets[pairToken];
        if (!asset.approved) {
            revert PairTokenNotApproved();
        }
        return asset.gradTick;
    }

    /// @dev A launch's pool and curve, worked out from its record.
    function _context(LaunchRecord memory r, address token) internal view returns (Ctx memory c) {
        c.pairToken = r.pairToken;
        c.token = Currency.wrap(token);
        c.gradTick = r.gradTick;
        c.quoteIs0 = r.quoteIs0;
        c.key = _key(r, token);
        c.poolID = c.key.toId();
        (c.sqrtStart, c.sqrtGrad) = LaunchMath.curvePrices(r.gradTick, r.quoteIs0);
        c.curveLiquidity = LaunchMath.curveLiquidity(r.gradTick);
    }

    /// @dev A launch's pool key: quote and token sorted by address, LP fee 0, tick spacing 200.
    function _key(LaunchRecord memory r, address token) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) =
            r.quoteIs0 ? (r.pairToken, Currency.wrap(token)) : (Currency.wrap(token), r.pairToken);
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0, // the hook charges the fee; the pool's own LP fee is zero
            tickSpacing: LaunchMath.LAUNCH_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The lock's liquidity for `quoteAmount` of quote and all the launch's reserve tokens, at the graduation
    ///      price. Also returns the reserve.
    function _lockLiquidity(Ctx memory c, uint256 quoteAmount)
        internal
        view
        returns (uint128 liquidity, uint256 reserve)
    {
        reserve = ILaunchToken(Currency.unwrap(c.token)).balanceOf(address(this));
        (uint256 amount0, uint256 amount1) = c.quoteIs0 ? (quoteAmount, reserve) : (reserve, quoteAmount);
        liquidity = LaunchMath.liquidityForAmounts(
            c.sqrtGrad, LaunchMath.LOCK_SQRT_PRICE_LOWER, LaunchMath.LOCK_SQRT_PRICE_UPPER, amount0, amount1
        );
    }

    /// @dev The accounts exempt from the snipe tax: the caller of `create`, the fee recipient and the creator's
    ///      list. The hook matches `tx.origin`, so a caller only counts if it signed the transaction itself: a Safe
    ///      should list its signer, and no ERC-4337 account can be exempt (its bundler signs).
    function _snipeExempt(CreateParams calldata p, address feeRecipient)
        internal
        view
        returns (address[] memory list)
    {
        uint256 n = p.snipeExempt.length; // `create` already capped this at `MAX_SNIPE_EXEMPT`
        list = new address[](n + 2);
        (list[0], list[1]) = (msg.sender, feeRecipient);
        for (uint256 i = 0; i < n; i++) {
            list[i + 2] = p.snipeExempt[i];
        }
    }

    /// @dev The curve position's parameters, adding or removing `liquidityDelta`.
    function _curveRange(Ctx memory c, int256 liquidityDelta) internal pure returns (ModifyLiquidityParams memory) {
        (int24 tickLower, int24 tickUpper) = LaunchMath.poolTicks(c.gradTick, c.quoteIs0);
        return
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0});
    }

    /// @dev The token address `create(p)` yields when `sender` calls it.
    function _predict(address sender, CreateParams calldata p) internal view returns (address) {
        return tokenDeployer.predict(_salt(sender, p.salt), p.metadata, _creatorOf(p, sender));
    }

    /// @dev The token's CREATE2 salt, namespaced to the caller so nobody else can take a quoted address.
    function _salt(address sender, bytes32 salt) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(sender, salt));
    }

    function _creatorOf(CreateParams calldata p, address sender) internal pure returns (address) {
        return p.creator == address(0) ? sender : p.creator;
    }
}
