# Shards V1

A fixed 10,000-piece on-chain generative ERC-721 collection, market-made by a Uniswap v4 hook against a
permanently locked single-sided position priced in native ETH.

Every piece is backed 1:1 by an ERC-20 unit held by the hook. Buying takes a piece off the curve, selling
returns it, and the art exists only while a piece is held — selling it back destroys that artwork for good.

## Status

Design and review only. Nothing here is deployed, and this repository does not claim an audit, an approval,
a registry acceptance, or a launch authorization. `releases/shards-v1/mainnet-manifest.json` records a
*predicted* CREATE2 plan, not addresses that exist on any chain.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `ShardLaunchFactoryV1` | Deploys and wires a collection atomically from hash-pinned hook code. Its constructor also deploys the shared renderer. |
| `ShardHookV1` | The v4 hook: market, fee accounting and NFT inventory in one. |
| `ShardNFTV1` | ERC-721, ids 1–10,000, fully on-chain SVG, with an internal archive for unsold pieces. |
| `ShardTokenV1` | Fixed-supply ERC-20. 1e18 of it redeems for exactly one piece. |
| `ShardFeeDistributorV1` | Per-piece fee accumulator the hook inherits. |
| `GeometricRendererV1` | Pure on-chain SVG renderer. One shared instance per factory; a launch may nominate a different one. |
| `ShardSwapRouterV1` | Optional plain ETH↔token router, pinned to a single pool. Not deployed by the factory. |
| `ShardFeeForwarderV1` | Optional forwarder for senders that can only push plain ETH. Not deployed by the factory. |

## Hook permissions

Address flag mask `0x20cc` — exactly `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`
and `afterSwapReturnDelta`. The factory mines the hook salt and refuses to deploy if the resulting address
carries any other combination.

## Economics

A flat **1.00% inclusive** fee on the native-ETH leg of every swap, never additive. It splits three ways:

| Share | Destination |
| --- | --- |
| 0.80% | NFT holders, streamed through an internal per-piece accumulator with a holder-called `claim` path |
| 0.10% | Builder, a compile-time constant on the factory, rotatable afterwards only by the current builder |
| 0.10% | Programmable, a compile-time constant that no launch, builder or administrator can redirect |

Both the outer fee and the internal split carry sub-wei remainders across calls, so the total is invariant to
how the volume is chopped up rather than being lost to per-swap flooring.

## Curve

Two permanently locked single-sided positions seeded with the whole supply: 3,000 units full-range, which is
what makes the collection undrainable, and 7,000 units in a concentrated band that keeps prices affordable
through the bulk of the collection. Liquidity is never withdrawable.

## Build

Dependencies are cloned at pinned commits rather than vendored:

```bash
./scripts/bootstrap-deps.sh
forge build --sizes --skip test
forge test
```

`solc 0.8.26`, `cancun`, optimizer at 1,000 runs, no via-ir. `ShardHookV1` runs close to the EIP-170 limit,
so the size command is part of the normal loop rather than an afterthought.

The size gate is scoped to `src` with `--skip test` because that is where the limit actually applies. The
test harnesses inherit `ShardHookV1` and add external entry points on top of it, so with the hook itself
within about a hundred bytes of the limit, any harness necessarily exceeds it — `FeeHookHarness` and
`FeeSplitHarness` both do. They are never deployed to a chain, so that is not a defect to trim away; an
unscoped command would simply fail forever and stop being read. Deployable artifacts are still gated twice:
this command fails if anything in `src` exceeds the limit, and `test/ShardArtifactManifestV1.t.sol` asserts
every production artifact against the limits declared in `spec/shards-v1.json`.

The Ethereum-fork suite is skipped unless an archive endpoint is supplied:

```bash
ETHEREUM_RPC_URL=<archive-node> forge test --match-contract ShardV1MainnetForkTest
```

## Further reading

- `docs/SHARDS_LAUNCH_RUNBOOK.md` — the reproducible predict → mine → simulate → broadcast procedure
- `spec/shards-v1.json` — the machine-readable model specification
- `releases/shards-v1/mainnet-manifest.json` — the pinned candidate plan and its evidence
