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

No persistent storage is written after construction. There is no setter, pause, upgrade, withdrawal, claim redemption, rescue, or sweep. The recipient has no privileged action. Fee delivery transfers IMD directly from the PoolManager to the recipient, without routing funds through the hook or converting them to ETH.

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

## Router settlement requirement

Immediate payout and ordinary v4 post-swap settlement have a physical constraint: `take(IMD, recipient, fee)` transfers real IMD while the swap is running, before a postpaying router has delivered its input. It succeeds when the manager already holds enough IMD. With insufficient reserves, an otherwise valid buy using that router can revert.

**For buys that must work independently of existing manager reserves, the router must settle its input budget before calling `swap`.** Within the same unlock:

1. Pull only the calling user's approved input budget into the router.
2. Call `manager.sync(IMD)`, transfer that budget to the manager, then call `manager.settle()`.
3. Call `manager.swap(...)`.
4. Close both currency deltas, return output and unused input, and enforce minimum output / maximum input.

`test/helpers/PoolDriver.sol` demonstrates and tests this sequence, including a fresh manager seeded solely with HAMSTER and no IMD or ETH reserves. It is a test integration driver, not a third launch contract. A postpaying router is also tested against funded pools. A negative test records the unfunded postpayment failure; the implementation does not hide it by dropping fees or retaining claims.

Consequently, an unconditional promise that **every** buy through **any** router can never revert is not possible together with mandatory immediate payment and no retained funds. This implementation has no discretionary trading gate; successful buys require normal valid pool inputs, sufficient user funds, slippage limits, v4 delta bounds, and the settlement condition above. Sells never execute the fee-transfer or preview path.

## Deployment and operations

- The launch deployer supplies the real PoolManager and actual HAMSTER address, sorts the currencies, and mines CREATE2 using the factory that actually executes CREATE2. There is no hardcoded production PoolManager.
- `script/PrepareDeployment.s.sol` exposes `run(factory, manager, token, start, attempts)` to return the fixed constructor arguments, salt, and predicted hook address. It does not read the environment, broadcast, deploy, or initialize. Increase the search range if a bounded search finds no salt. Mine off-chain: on-chain searching is unnecessarily expensive.
- Use the exact creation bytecode, compiler settings, constructor encoding and factory for the salt. Check all 14 low address bits against `0x20cc`; checking just the enabled bits is insufficient.
- Deploy the no-argument token, then the hook, then initialize and seed the pool in one factory transaction. Use the launch's price calculation and allocation policy. The 1:1 price in most unit tests is only a fixture. The separate launch-price fork test derives the correct currency-dependent square-root price from 2,500 IMD capitalization and the one-billion-token supply.
- Supply allocation remains the launch factory's responsibility: it initially receives the full supply and applies the launch's 10% distributor / 70% pool / 20% payer-or-treasury allocation. These two contracts do not allocate extra tokens or introduce another recipient.
- Integrators must account for the hook fee and the separate LP fee, use slippage protection, and support prepayment for low-reserve buys. Exact-output integrations must also enforce their desired fill amount if a price limit allows partial execution.
- Verify source and deployed bytecode, publish this repository on GitHub, and record the deployed addresses, pool ID, deployment transaction and immutable timestamp in the launch record. No addresses or transactions are represented here as already deployed. The launch manifest belongs to the separate manifest step; none is supplied here.
- There are **no owner settings or recipient calls after launch**. The fee schedule runs automatically forever.

The hook does not retain swap proceeds. Like any ERC-20 destination, it cannot prevent someone sending it unrelated tokens; unsolicited tokens cannot be recovered because there is deliberately no sweep. The fee is specific to this pool; standard HAMSTER can be traded elsewhere. The fee discourages early buys but is not a guarantee against bots or MEV.

See [SECURITY.md](SECURITY.md) for the review scope and [DEPENDENCIES.md](DEPENDENCIES.md) for dependency pins and licenses.
