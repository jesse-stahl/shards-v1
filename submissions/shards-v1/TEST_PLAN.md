# Shards test plan

This separates what has actually been run from what is still required. Everything in the "run" columns is
builder-declared local evidence reproducible from a clean clone. None of it is an audit, an independent
rebuild, or a deployment receipt.

## Universal prototype evidence

Reproduce from a fresh clone:

```bash
./scripts/bootstrap-deps.sh
forge fmt --check
forge build --sizes --skip test
forge test
```

Result at this revision:

```text
20 test suites, 338 passed, 0 failed, 1 skipped (339 total)
```

The single skip is `ShardV1MainnetForkTest`, which gates itself on `ETHEREUM_RPC_URL` and runs only when an
archive endpoint is supplied. The same four commands run in CI on every push through
`.github/workflows/programmable-evidence.yml`.

| Suite | Tests | Covers |
| --- | ---: | --- |
| `ShardHookBatchV1Test` | 38 | Batch buy, sell, redeem, `MAX_BATCH` bounds, refunds |
| `ShardLaunchFactoryV1Test` | 37 | Deterministic mining, staged failure with full rollback, duplicate launch |
| `ShardHookMarketV1Test` | 31 | Curve behavior across all four swap quadrants |
| `ShardFeeSplitV1Test` | 28 | Three-way split, carried remainders, parity carry to Programmable |
| `ShardHookAttackV1Test` | 28 | Adversarial cases: foreign pools, reentrancy, oversized swaps, price manipulation |
| `ShardHookFeesV1Test` | 27 | Inclusive fee arithmetic in both directions and exactness modes |
| `ShardHookLiquidityV1Test` | 22 | Seeding, permanence, band boundary at tick 22980 |
| `ShardNFTV1Test` | 21 | ids 1–10,000, archive, `tokenURI`, ownership |
| `ShardV1Invariants` | 19 | Property tests, including the 1:1 backing and dust bounds |
| `ShardSwapRouterV1Test` | 13 | Optional router against a pinned pool |
| `ShardLaunchSequenceV1Test` | 10 | Atomic launch ordering |
| `ShardWiringV1Test` | 7 | Cross-contract back-references and consumed one-shot powers |
| `ShardFeeDistributorV1Test`, `ShardFeeDonationV1Test`, `ShardScaffoldV1Test`, `ShardHookExhaustionV1Test`, `ShardTokenV1Test`, `ShardCheckedTransferV1Test`, `ShardArtifactManifestV1Test` | remainder | Accumulator, donations, supply exhaustion, checked transfers, artifact drift |

## Autopilot and reviewer calibration

A reviewer who wants the fastest signal should run, in order: `ShardFeeSplitV1Test` for the fee policy,
`ShardHookAttackV1Test` for the adversarial surface, `ShardV1Invariants` for the backing guarantee, and
`ShardArtifactManifestV1Test` to confirm the published tables describe this exact build.

## Solidity contracts, when declared

solc 0.8.26, cancun, optimizer at 1,000 runs, no via-ir, `bytecode_hash = "none"` and `cbor_metadata = false`
so builds are byte-reproducible. Dependencies are cloned at pinned commits rather than vendored.

`forge build --sizes --skip test` is part of the normal loop, not an afterthought, because `ShardHookV1` sits
111 bytes under EIP-170. The command is scoped to `src` deliberately: test harnesses inherit the hook and add
external entry points, so they exceed the limit by construction and are never deployed. Deployable artifacts
are gated twice — by that command, and again by `ShardArtifactManifestV1Test` against the limits declared in
`spec/shards-v1.json`.

## Custom hook, only when `hook.used` is true

Covered and passing:

- exactly five permission bits, asserted against the mined address mask
- PoolManager callback authentication on every entry point
- non-canonical PoolKey and PoolId rejection at initialisation and on every swap
- inclusive fee in all four direction-and-exactness quadrants
- the `MAX_BATCH` cap measured on the SHARD leg, so it binds any route including a direct pool swap
- hook-initiated swaps charging the fee internally where v4 skips the callback
- CREATE2 determinism and re-mining reproducibility

## Mandatory Programmable fee, for every launch-ready prototype

| Property | Status | Where |
| --- | --- | --- |
| Exactly 1,000 hundredths-of-bip to the immutable owner | Passing | `ShardFeeSplitV1Test` |
| Non-additive: caller spends exactly what they asked | Passing | `ShardHookFeesV1Test` |
| All four swap modes charged on the gross ETH leg | Passing | `ShardHookMarketV1Test`, `ShardHookFeesV1Test` |
| Canonical-pool basis; foreign pools rejected | Passing | `ShardHookAttackV1Test` |
| Owner-only claim, no mutable recipient, no sweep | Passing | `ShardFeeSplitV1Test` |
| No cross-pool netting | Passing | `ShardFeeDistributorV1Test` |
| Non-bypassable, including the hook's own swap paths | Passing | `ShardFeeSplitV1Test` |
| Fragmentation resistance: ten 9-wei fees == one 90-wei fee | Passing | `ShardFeeSplitV1Test` |
| Revert below 1,000 gross quote units | **Not implemented.** Declared divergence; the carry preserves the entitlement instead | — |
| Two independent platform/project remainders | **Not implemented.** One combined operator remainder with a parity carry to Programmable | — |

The last two rows are the declared divergences. They are disclosed in `submission.json` rather than claimed
as passing.

## No-hook proposal path, when `hook.used` is false

Not applicable.

## App or game, when declared

Not applicable. This repository ships no client application.

## Service, keeper, oracle, or indexer, when declared

No keeper, oracle or service exists. The indexing contract is described in `submission.json` but its
implementation lives in a separate repository and is not bound by this application.

## Position custody and locks, when declared

Both positions are seeded inside the launch transaction and permanently locked. `ShardHookLiquidityV1Test`
covers seeding, the band boundary at tick 22980, and the absence of any removal path.

Measured on an Ethereum mainnet fork immediately after the authorized launch call, in-range active liquidity
is **exactly zero**, because the pool initialises at tick 69060 — the upper bound of both ranges. Seeded
position liquidity is `341145878011540414018`. This is a declared open question rather than a defect.

## Product integration cases

Verified on a mainnet fork replay of the full launch-and-buy sequence:

| Case | Result |
| --- | --- |
| Factory deployed through the CREATE2 proxy | Address matched the pinned prediction |
| Mined hook salt and all predicted addresses | Matched byte for byte, including the configuration hash |
| Launch and first buy in the same block | Landed in order, tx index 0 then 1 |
| First 50 pieces | 0.050847 ETH including fee; 4,250,385 gas |
| Fee accrual | 0.1% to builder and 0.1% to Programmable, exact |
| Refund | Unspent ETH returned in the same transaction |
| Factory SHARD balance after launch | Zero |
| `tokenURI` | Renders onchain SVG with correct trait attributes |

## Semantic cases

Buying 50 pieces at launch, selling them back, and redeeming a piece for its ERC-20 unit all preserve the
backing invariant `nft.totalSupply() + hookShardBalance / 1e18 == 10000`, which the invariant suite asserts
across randomized sequences.

## Evidence status

Run and passing: the full local suite, the size gate, the artifact-drift gate, and a mainnet-fork lifecycle
replay.

Still required and not claimed: an independent rebuild, an external audit, static-analysis dispositions
(`slither` is not installed in this environment), deployment evidence, runtime matching, and any maintainer
or provider gate. A local pass is not verification.
