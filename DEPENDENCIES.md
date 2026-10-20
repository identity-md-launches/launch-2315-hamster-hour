# Vendored Solidity dependencies

All dependencies below are ordinary files, without submodules or package-install steps. Upstream licenses are retained. No binaries, `node_modules`, or dependency repositories' Git metadata are included.

| Directory | Upstream | Exact revision | Included files |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc) | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (npm 1.0.2 gitHead) | Production `src/` and license; upstream test fixtures excluded |
| `lib/forge-std` | [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` (v1.9.7) | `src/` and licenses |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527) | `acd4ff74de833399287ed6b31b4debf6b2b35527` (v5.2.0) | Solidity contracts and license |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pin) | `src/auth/Owned.sol` and license; used by the real test PoolManager |

Upstream Solidity files are unmodified. V4's PoolManager is vendored to execute real core behavior in local tests, not to deploy another production manager or introduce an owner into the token/hook. The token and hook themselves have no owner.

The first three source archives were fetched by exact revision from GitHub codeload. Their SHA-256 digests were:

```text
v4-core:                130e1ae60c10254ecebadd9d963294617081da7fb3f7f5c3b98e3f0db06769a6
forge-std:              a387f7c2a10387f889b0d18b999cfa667a5273ac11cc11e18923022eb8b24bc3
openzeppelin-contracts: 7ca6287b8a0d0db67b5923c047365025e612dbaf58a49cbe74d05aa5213e36f9
```

The test-only Ethereum PoolManager address was cross-checked against [Uniswap's official deployments](https://developers.uniswap.org/docs/protocols/v4/deployments). Code existence, IMD `symbol()` and `decimals()` were checked through Ethereum RPC and are rechecked by the fork suite. Production takes the manager as an explicit constructor argument.
