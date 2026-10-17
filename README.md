# Launchpad RH

A token launchpad on Uniswap V4, live on Robinhood Chain. One factory creates every launch. Each launch is a
fixed-supply ERC-20 and one V4 pool, and the token's bonding curve is itself a V4 position in that pool. One hook,
shared by every launch, takes each pool's fee. When the curve sells out, the pool graduates into permanently locked
full-range liquidity on the same pool, so trading never moves elsewhere.

## How a launch works

1. **Create.** `LaunchFactory.create` deploys the token (1 billion, fixed supply) and creates its pool with the
   curve already in it: 80% of the supply, priced from a start price up to a graduation price 16 times higher. In
   the same call the creator can make a dev buy. The quote asset is ETH or an ERC-20 the protocol has approved,
   each with its own raise.
2. **Trade on the curve.** Anyone buys and sells against the curve through any V4 router. Every swap pays the
   pool's fee in the quote asset.
3. **Graduate.** The buy that takes the curve's last token graduates the pool inside that same swap: the curve
   is removed, and the quote it raised is locked with the remaining 20% of the supply in a full-range position at
   the same price.
4. **Trade on the lock.** The pool trades on, unchanged, against the locked liquidity. Nobody can remove it, the
   factory included.

With ETH's 4.2 ETH raise, 800.6M tokens sell on the curve, and the raise is then locked with the other 199.4M.

## Fees

| Fee | Rate | Paid to |
|---|---|---|
| Hook fee | 1% of every swap's quote side | 30% the protocol, 70% the launch's fee recipient |
| Creator tax | 0–10%, chosen at creation | the launch's fee recipient |
| Snipe tax | a buy's total fee is 99% for the first 3 seconds, unless its signer is exempt (the creator, the fee recipient, and up to 32 accounts the creator lists) | the part above the pool's rate: 30% the protocol, 70% the fee recipient |
| Launch fee | 0.0005 ETH per launch | the protocol |

A launch's fees are fixed for its whole life. Fees accrue in the pool's record on the hook; a keeper sweeps them
into the FeeManager, where each recipient (or anyone on its behalf) claims them. Each launch has its own fee
recipient, set by the creator at launch.

## The hook

- **Permissions:** `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`,
  `beforeDonate`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`.
- **Fees:** taken on the quote side as a return delta (in `beforeSwap` on the specified side, in `afterSwap`
  otherwise). The pool's own LP fee is 0.
- **Liquidity:** only the factory adds liquidity, and the locked position can never be removed.
- **Swaps:** permissionless; no custom swap data (`hookData` is ignored).
- **Pools:** one per launch, created only by the factory; the hook refuses any other pool.
- **Upgrades and ownership:** none. No proxy, no owner on the hook; the factory's owner can change only new
  launches' terms (launch fee, quote assets and their raises, pausing new launches).

## Contracts

| Contract | Role |
|---|---|
| `LaunchFactory` | creates launches, holds the pools' liquidity, graduates them, and holds the protocol's settings |
| `LaunchHook` | the one hook for every launch pool: fees, the snipe tax, the liquidity rules, graduation's trigger |
| `FeeManager` | each launch's fee recipient, sweeps, and claims |
| `LaunchToken` | the fixed-supply ERC-20, with its name, symbol, logo, description and socials |
| `LaunchQuoter` | exact quotes and live state for any launch (called with `eth_call`) |
| `TokenDeployer` | deploys launch tokens for the factory |
| `libraries/LaunchMath` | the curve's shape and the fee arithmetic |
| `interfaces/` | the public interfaces of the contracts above |

## Deployment: Robinhood Chain (4663)

| Contract | Address |
|---|---|
| LaunchFactory | [`0x3FCd286296906a81cE0cbB826184e25ea9e60460`](https://robinhoodchain.blockscout.com/address/0x3FCd286296906a81cE0cbB826184e25ea9e60460) |
| LaunchHook | [`0x41d26f8Fc5582323A68251715C423632C5d76aec`](https://robinhoodchain.blockscout.com/address/0x41d26f8Fc5582323A68251715C423632C5d76aec) |
| LaunchQuoter | [`0x42E46E41c31137D4671BB022453855cA0b48252b`](https://robinhoodchain.blockscout.com/address/0x42E46E41c31137D4671BB022453855cA0b48252b) |
| FeeManager | [`0x882561322Df44f72C23d4fF5308D39E5E1f93b9e`](https://robinhoodchain.blockscout.com/address/0x882561322Df44f72C23d4fF5308D39E5E1f93b9e) |
| TokenDeployer | [`0xacEdC59233B0f5a633E7Cbb8f4BD84888503607a`](https://robinhoodchain.blockscout.com/address/0xacEdC59233B0f5a633E7Cbb8f4BD84888503607a) |
| Uniswap V4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |

Settings: ETH raise 4.2 ETH, launch fee 0.0005 ETH, ETH and 78 ERC-20 quote assets.

## Dependencies

- Uniswap v4-core (`d153b04`)
- OpenZeppelin Contracts v5.1.0
- OpenZeppelin Uniswap Hooks v1.3.0

Compiled with Solidity 0.8.26 (EVM `cancun`, optimizer on, 200 runs); see `foundry.toml` and `remappings.txt`.

## License

MIT.
