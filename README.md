# Hamster Hour

An immutable, fixed-supply ERC-20 and a Uniswap v4 buy-fee hook for Ethereum mainnet. The launch deploys **HamsterHourToken** and **AntiSniperHook**. There is no game, betting, lottery, treasury contract, or administrative role.

## Build and check

Foundry and Solidity **0.8.26** are required. All Solidity dependencies are vendored as ordinary files in `lib/`; builds and the local tests need no network. The EVM target is Cancun and `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xaee6dcbfe351acc01006c9255e2c92bb524ad59122b50c91fc1129831aaacfce forge test
forge fmt --check
```

Run the complete suite on Ethereum, including the tests using the deployed PoolManager and actual IMD:

```sh
FOUNDRY_FUZZ_SEED=0xaee6dcbfe351acc01006c9255e2c92bb524ad59122b50c91fc1129831aaacfce \
  forge test --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26234807
```

Another Ethereum archive RPC can replace the public URL. For just the mainnet integration tests, add `--match-path test/MainnetFork.t.sol`. Without `--fork-url`, those tests explicitly skip; local tests do not masquerade as fork evidence. Tests never read or write environment variables.

The fork suite creates a new HAMSTER/IMD pool inside the **actual deployed v4 PoolManager**, with actual IMD transfer code and a newly deployed HAMSTER and mined hook. Only the test wallet's IMD balance is provisioned with a cheatcode. It exercises both directions, both swap modes, exact recipient payouts, the permanent floor, liquidity collection/withdrawal, and a separate rehearsal at the launch's 2,500 IMD opening capitalization. This is a fork rehearsal, not a live deployment.

## Fixed deployment parameters

`src/DeploymentConfig.sol` is the canonical source of the launch constants. The hook constructor rejects any economic argument that differs from it.

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| Token | Hamster Hour / HAMSTER / 18 decimals |
| Supply | 1,000,000,000 HAMSTER = `1000000000000000000000000000` minor units |
| Quote currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| `START_BPS` | 3000 |
| `FLOOR_BPS` | 500 |
| `DECAY_SECONDS` | 600 |
| `FEE_RECIPIENT` | `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823` |
| Pool LP fee | 12500 in v4's millionths units, or 1.25% |
| Tick spacing | 60 |
| Hook permission mask | `0x20cc` = 8396 |

The formula declines by **2.5 percentage points per minute** over ten minutes. This follows the supplied formula and boundary values; the brief's “25 percentage points per minute” is an arithmetic typo.

| Elapsed since launch | Buy fee in basis points | Sell hook fee |
| --- | ---: | ---: |
| 0 seconds | 3000 | 0 |
| 300 seconds | 1750 | 0 |
| 599 seconds | 504 | 0 |
| 600 seconds or any later time | 500 | 0 |

The v4 LP fee is separate and applies in both directions. “Untaxed sell” means **zero hook fee**. Every ordinary HAMSTER transfer and `transferFrom` moves the entire amount and has no fee.

## Token and immutability

`HamsterHourToken()` has no arguments. Its constructor mints the entire supply once to `msg.sender`, which is the launch factory in production. It uses the vendored OpenZeppelin ERC-20 implementation. There is no external mint, burn, owner, pause, blacklist, fee setting, or upgrade function.

The hook's six constructor arguments, in order, are:

1. `IPoolManager manager_`: supplied by the launch as `$poolManager`.
2. `address hamster_`: the freshly deployed HAMSTER, supplied as `$token`.
3. `uint256 startBps_`: `3000`.
4. `uint256 floorBps_`: `500`.
5. `uint256 decaySeconds_`: `600`.
6. `address feeRecipient_`: the literal recipient above.

All are immutable. `poolInitialisedAt` is set to the deployment block timestamp in the constructor. The constructor rejects zero manager, zero token, zero recipient, IMD as the launch token, incorrect economics, and incorrect hook-address flags. It makes no external calls or code-existence checks.

**The factory must deploy the hook and initialize its pool atomically.** `beforeInitialize` accepts only the bound token/IMD pool with the fixed fee, spacing, and hook, and only at the constructor timestamp. A delayed initialization is rejected rather than silently starting trading after the anti-sniper period. The callback cannot reset the timestamp. Atomic deployment also prevents another transaction from choosing the initial price.

The hook contract writes no storage of its own after construction. There is no setter, pause, upgrade, withdrawal, rescue, or sweep. The recipient has no privileged action. Normally the fee is sent as IMD straight from the PoolManager to the recipient during the swap. It never passes through the hook and is not converted to ETH. If the manager does not hold enough IMD at that moment, the fee is minted as an ERC-6909 claim instead (see "Router settlement" below). The only extra entry point is the permissionless `redeem()`, and it can only pay `FEE_RECIPIENT`.

## Swap accounting and rounding

Buy/sell classification follows the **input currency**, independent of whether HAMSTER sorts as currency0 or currency1 and whether the swap is exact input or exact output. The fee never touches HAMSTER.

Let `r` be the current buy rate, `G` the actual gross IMD paid, `P` the IMD paid to the AMM including its LP fee, and `F` the hook fee. All arithmetic uses integer minor units:

```text
F = floor(G * r / 10000)
G = P + F
```

For a fully filled exact-input buy with input budget `A`, `beforeSwap` reserves `floor(A*r/10000)` and lets the AMM spend the remainder. It returns a positive specified-currency delta and pays the same fee via `PoolManager.take`.

To handle partial fills fairly, the hook first previews the reduced net input with a nested manager swap through a **self-only, always-reverting** `quoteInput` call. V4 skips a hook's callbacks when that hook initiates a swap. The intentional internal revert discards all simulated price changes, LP/protocol fees, logs, and transient balances. If the preview reaches the price limit before spending its budget, the hook computes `F = floor(P*r/(10000-r))` from the actual consumed input. The real swap then hits the same limit, and unused budget is refunded by the router. An unfilled buy pays no fee. Tests compare price, output, and LP fee growth with a hook-free control pool to verify the preview leaves no second swap behind.

For exact-output buys, `afterSwap` obtains the actual IMD input from the AMM delta and computes `F = floor(P*r/(10000-r))`. Its positive unspecified-currency delta charges IMD, preserving the output amount. This gross-up is necessary: simply adding 30% of net input would yield only 23.08% of gross input. The formula also applies to a partially filled exact-output request.

Both paths satisfy `F = floor((P+F)*r/10000)` and settle the hook's fee debt to zero before the unlock ends. Both callbacks return zero fee deltas for sells. The LP fee is never overridden.

The **rate** never reaches zero. A fee **amount** smaller than one IMD minor unit rounds down to zero, as integer percentage arithmetic requires. Charging a minimum of one minor unit would overcharge tiny trades and could consume all their input, so no minimum is imposed.

## Router settlement and the claim fallback

Uniswap's V4Router / Universal Router call `swap` first and settle their input afterwards (SETTLE_ALL). So while the swap is running, the trader's IMD has not reached the manager yet. `_payFee` handles both cases, and a buy never reverts for lack of IMD reserves:

- **Manager holds at least the fee in IMD:** `take(IMD, FEE_RECIPIENT, fee)` pays the recipient during the swap. If the hook still holds claims from earlier buys and the remaining reserve covers them, they are burned and paid out to the recipient in the same call.
- **Manager holds less IMD than the fee** (for example a fresh launch pool seeded with HAMSTER only, used through a post-settling router): `mint(hook, IMD id, fee)` records the fee as an ERC-6909 claim. A claim needs no balance. The trader's later settlement backs it, so the buy goes through with exactly the same fee. The claim stays with the hook only until one of two things happens: the next buy that the manager can cover sweeps it automatically, or anyone calls `hook.redeem()`. `redeem()` unlocks the manager, burns the claim (capped at the manager's IMD balance) and takes the IMD to `FEE_RECIPIENT`. It cannot send to anyone else. It has no owner, no parameters and no way to change the amount.

A router that settles before swapping (pull budget, `sync`, transfer, `settle`, then `swap`) always goes down the immediate path. `test/helpers/PoolDriver.sol` covers both orders. `test/Settlement.t.sol` runs both on a fresh manager seeded only with HAMSTER and checks the claim path, its automatic sweep, `redeem()` and the guard on `unlockCallback`.

The fee is paid in IMD, an ERC-20. A recipient contract cannot reject it the way it could reject ETH, so neither path depends on what the recipient does.

## Deployment and operations

- The launch deployer supplies the real PoolManager and actual HAMSTER address, sorts the currencies, and mines CREATE2 using the factory that actually executes CREATE2. There is no hardcoded production PoolManager.
- `script/PrepareDeployment.s.sol` exposes `run(factory, manager, token, start, attempts)` to return the fixed constructor arguments, salt, and predicted hook address. It does not read the environment, broadcast, deploy, or initialize. Increase the search range if a bounded search finds no salt. Mine off-chain: on-chain searching is unnecessarily expensive.
- Use the exact creation bytecode, compiler settings, constructor encoding and factory for the salt. Check all 14 low address bits against `0x20cc`; checking just the enabled bits is insufficient.
- Deploy the no-argument token, then the hook, then initialize and seed the pool in one factory transaction. Use the launch's price calculation and allocation policy. The 1:1 price in most unit tests is only a fixture. The separate launch-price fork test derives the correct currency-dependent square-root price from 2,500 IMD capitalization and the one-billion-token supply.
- Supply allocation remains the launch factory's responsibility: it initially receives the full supply and applies the launch's 10% distributor / 70% pool / 20% payer-or-treasury allocation. These two contracts do not allocate extra tokens or introduce another recipient.
- Integrators must account for the hook fee and the separate LP fee, and use slippage protection. Post-settling routers work; a low-reserve buy through one leaves the fee as a claim until it is swept or `redeem()` is called. Exact-output integrations must also enforce their desired fill amount if a price limit allows partial execution.
- Verify source and deployed bytecode, publish this repository on GitHub, and record the deployed addresses, pool ID, deployment transaction and immutable timestamp in the launch record. No addresses or transactions are represented here as already deployed. The launch manifest belongs to the separate manifest step; none is supplied here.
- There are **no owner settings or recipient calls after launch**. The fee schedule runs automatically forever.

The hook does not retain swap proceeds. Like any ERC-20 destination, it cannot prevent someone sending it unrelated tokens; unsolicited tokens cannot be recovered because there is deliberately no sweep. The fee is specific to this pool; standard HAMSTER can be traded elsewhere. The fee discourages early buys but is not a guarantee against bots or MEV.

Known design limit: the fee applies only to swaps, as the brief defines it. The hook has no liquidity callbacks and never blocks anything. During the decay window, anyone can post a single-sided IMD range next to the price and let untaxed sells fill it. That buys HAMSTER from sellers at the pool price plus the LP fee, with no hook fee. Gating `beforeAddLiquidity` during the window would close this, but it is a scope decision for the requester. It would also have to keep letting the factory seed and collect.

See [SECURITY.md](SECURITY.md) for the review scope and [DEPENDENCIES.md](DEPENDENCIES.md) for dependency pins and licenses.
