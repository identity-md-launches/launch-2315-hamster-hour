# Review record

This is an implementation review and executable-test record, not an independent security audit. The supplied v4 security, Ethereum security and address references informed this review. Release still needs the contributor network's independent adversarial review and deployment/source verification.

## Permission and authority review

Enabled v4 permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`: mask `0x20cc`. The initialization callback binds a single pool and the launch timestamp; the two swap callbacks support fees for both amount modes. Every enabled callback authenticates `msg.sender == poolManager`. Construction validates that the implementation's permissions exactly match the address.

There are no liquidity, donation, or other permissions. Liquidity changes and a zero-change fee collect cannot be taxed or blocked by this hook. The implementation has no fallback for disabled selectors.

All contract parameters and the bound pool ID are immutable. No ownership, role, proxy, delegatecall, self-destruct, pause, fee override, price override, rescue, or upgrade entry point is present. Token transfers have no hook call. The fixed recipient receives ERC-20 transfers; its fallback cannot reject them, and it has no privilege.

`sender` and arbitrary `hookData` grant no authority. The router identity does not affect fees. The self-only preview entry point cannot be used by an external caller to trade on behalf of the hook.

## Delta accounting and partial fills

For each successful buy, let the AMM input be `P`, its HAMSTER output be `Q`, and the fee be `F`.

| Participant | IMD effect | HAMSTER effect |
| --- | ---: | ---: |
| Trader | `-(P+F)` | `+Q` |
| PoolManager's real balance | `+P` | `-Q` |
| Fee recipient | `+F` | `0` |
| Hook | `0` | `0` |

`take` initially debits the hook's transient balance by `F`. The positive returned hook delta credits it by exactly `F` and debits the trader. No claim is minted. A completed unlock must have no nonzero deltas.

The critical `beforeSwapReturnDelta` flag is used only to reserve the IMD fee. It is bounded by the current rate, never consumes the entire nonzero input budget, and cannot redirect payment. The partial-fill preview always reverts its nested execution. Its only accepted success signal is the precisely sized `QuotedInput(uint256)` error. Other failures are bubbled rather than interpreted as a quote.

For exact input, a full preview consumes the reduced budget; a partial preview stops at the specified price limit. Reducing the reserved fee increases the real AMM budget, but it still encounters the same price limit and consumes the same amount. The preview is done before any fee transfer. Tests compare final price, tick, output and LP fee growth with a separate pool having no hook. They also check zero-fill fees, price-limit refunds, malformed limits and rollback after a router's slippage failure.

The positive fee rate is permanent. Integer dust may have zero **fee amount**, but cannot change or reset the **rate**. FullMath is used for input multiplication, signed input negation handles `int256.min`, and returned fee deltas use checked int128 casts.

## External calls and reentrancy

The hook calls only itself for the reverting preview and its immutable PoolManager for swaps/takes. It never calls a user-provided address, router, recipient function, oracle, or conversion market. The actual recipient transfer uses the manager's ERC-20 transfer implementation.

There is no mutable hook balance ledger or phase flag to corrupt by reentry. The preview calls the manager as the hook; core deliberately skips that hook's callbacks, avoiding recursive fee charging. Its revert rolls back transient as well as persistent manager state. Both currencies are fixed: ordinary HAMSTER and the specified mainnet IMD. Support for arbitrary fee-on-transfer, rebasing, pausable or callback-bearing currencies is not claimed.

Immediate payout still requires actual IMD to be in the manager before `take`. The prepayment integration requirement and a failing unfunded-postpayment test are explicit in the README. No implementation can transfer absent funds, and no pending claim or fee waiver is substituted.

## Test coverage

- Supply, metadata, untaxed transfer/transferFrom, allowance and balance failures, no admin selectors.
- Exact fee formula, all requested boundaries, maximum timestamp, monotonic decay and permanent floor.
- Both address orderings and both swap modes, including launch-time and late sells.
- Exact balance conservation, recipient payment, hook custody/claim/debt checks and atomic slippage rollback.
- Manager-only callbacks, self-only preview, wrong-pool rejection, invalid constructor arguments and invalid address bits.
- CREATE2 preparation against the actual creation code, empty-chain construction, size/opcode checks.
- Partial fills, no fills, rounding dust, fresh HAMSTER-only liquidity, immediate payment using prepaid input, and negative postpayment behavior.
- Real mainnet PoolManager and IMD integration, including the launch opening-price rehearsal.
- Stateful invariants over randomized buys, sells, time advances and transfer round trips. The handler is targeted explicitly and `fail_on_revert = true`; unexpected failures are not discarded.

The configured invariant run executes 64 sequences of depth 32. Fuzzing uses the assignment's seed supplied at the command line. No test relies on a secret, account, environment variable, timer, live broadcast or test execution order.

Compiler diagnostics about timestamp comparisons describe the explicitly requested clock-based fee policy. There is no timestamp randomness. Casts are guarded by the sign of the input, the bounded nonzero rate, or the exact quote-error length; returned fee deltas use checked casts. The event-order lint flags the preceding self-call preview, whose entire execution reverts before the real payment event is emitted. There is no mutable hook accounting for that call to reenter.

## Verification snapshot

Using Solidity 0.8.26 and the assignment's fuzz seed:

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge build --offline` | Passed with vendored dependencies |
| `forge fmt --check` | Passed |
| `forge test` | 68 passed, 0 failed; 2 fork-only checks explicitly skipped |
| Full suite on Ethereum fork at block `26234807` | 79 passed, 0 failed, 0 skipped |
| Stateful invariant campaign, both local and fork runs | 2,048 calls each, 0 reverts; all three invariants passed |
| Gas report for boundary-time exact-input buys | Passed; test driver `swap` ranged from 243,705 to 295,320 gas in this fixture |

The gas figure includes the integration driver and settlement, depends on state and liquidity, and is not a maximum-gas guarantee for arbitrary tick crossings. Both production contracts are below the EIP-170 size limit and have no unresolved library links.

## Release responsibilities

The launch factory must deploy and initialize atomically with the prepared flags, correct token/manager, policy pool fee/spacing and opening price. The frontend/router must use suitable slippage limits and prepayment when existing manager IMD reserves are insufficient. A positive-rate fee is not bot identification, an MEV defense guarantee, or a restriction on creating other HAMSTER pools.

No Slither/Mythril run, formal verification, independent audit, on-chain deployment, explorer publication or GitHub upload is claimed by this record. Those are distinct from the local and fork tests.
