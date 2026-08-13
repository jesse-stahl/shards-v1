# Shards

A fixed 10,000-piece onchain generative ERC-721 collection, market-made by a Uniswap v4 hook against a
permanently locked single-sided position priced in native ETH.

Every piece is backed 1:1 by an ERC-20 unit held by the hook. Buying takes a piece off the curve, selling
returns it, and the art exists only while a piece is held. Selling a piece back destroys that artwork for good.

Nothing here is deployed. This document describes a candidate design and its evidence; it does not claim an
audit, an approval, a registry acceptance, or a launch authorization.

## Product and architecture decision

The outcome for a collector is that they can always buy and always sell without needing a counterparty. There
is no listing, no bid, no auction and no floor to defend. The curve is the market, it is open the moment the
collection launches, and it cannot be withdrawn.

The decision that shapes everything else is that the market maker, the fee accounting and the NFT inventory
are one contract rather than three. `ShardHookV1` is simultaneously the v4 hook, the ERC-721 inventory owner
and the fee distributor. That is unusual, and it is deliberate: buying a piece is a swap, a mint and a
three-way fee split that must all succeed or all revert. Splitting them across contracts would either
introduce a trusted intermediary or make the operation non-atomic.

The second decision is that liquidity is seeded once from fixed supply and then permanently locked. There is
no LP, no deposit, no withdrawal and no share token. This removes an entire class of risk — there is nobody
whose liquidity can leave — at the cost of the design being irreversible.

The third decision is that there is no administrator. No proxy, no owner, no pause, no upgrade, no rescue.
The only mutable value in the system is the builder's own fee destination, which the builder alone can
rotate and which touches nothing else.

## Design card

| Property | Value |
| --- | --- |
| Supply | 10,000 ERC-721 pieces, ids 1 to 10,000, and 10,000e18 ERC-20 units, both fixed at creation |
| Backing | 1e18 SHARD redeems for exactly one piece, permanently |
| Quote asset | Native ETH, `currency0` |
| Pool | One canonical PoolKey, tick spacing 60, LP fee 0 |
| Liquidity | 3,000e18 full range plus 7,000e18 in a band from tick 22980 to 69060, both permanently locked |
| Start price | Tick 69060, the upper bound of both ranges |
| Fee | 1.00% inclusive on the ETH leg, split 0.80% holders / 0.10% builder / 0.10% Programmable |
| Hook permissions | `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` (mask `0x20cc`) |
| Batch cap | 50 pieces per action, and 50e18 SHARD per third-party swap |
| Art | Fully onchain SVG from a pure renderer, generated per piece |
| Mutability | None, except the builder's own fee destination |

## Why Uniswap v4 and architecture choice

A v3 pool plus a periphery contract cannot express this. The fee has to be inclusive rather than additive in
all four direction-and-exactness quadrants, which requires `beforeSwapReturnDelta` and
`afterSwapReturnDelta`. Native ETH as `currency0` requires v4. And the atomicity of swap-plus-mint-plus-split
requires the logic to sit inside the PoolManager unlock, not around it.

The choice not to compose a second hook is forced: one PoolKey has one hook address. Since the collection
needs custom behavior anyway, the mandatory Programmable fee is integrated into that same single hook rather
than layered on top of it.

The cost of this choice is size. `ShardHookV1` compiles to 24,465 bytes against the EIP-170 limit of 24,576,
leaving 111 bytes of margin. That is the binding constraint on the design and the reason several helpers are
inlined and the renderer lives in its own contract.

## Lifecycle

Token creation, pool initialization and liquidity formation all happen inside one atomic `launch` call on
`ShardLaunchFactoryV1`. The factory deploys the token, mines the hook salt until the address carries exactly
the five declared permission bits, deploys the hook and the NFT by CREATE2, seeds both locked positions and
ends holding zero SHARD. If any step fails the entire launch reverts and no address is occupied.

After that the system is autonomous. Trading, fee accrual and claims need no operator. There is no retirement
phase because nothing can be paused, upgraded, drained or migrated.

## Executable launch plan

The launch is one call to `ShardLaunchFactoryV1.launch(bytes32,bytes32,bytes,LaunchParams)`. The factory
itself is deployed through the canonical Arachnid CREATE2 proxy, so its address depends only on the salt and
the init code and is reproducible by any sender regardless of nonce.

The whole plan is pinned in `releases/shards-v1/mainnet-manifest.json` and was reproduced from a clean clone
on an Ethereum mainnet fork:

```text
factory              0x9442a520e7b31D10177C75A363355C2C29141ac5
renderer             0x090DBD2FaB1a467f90ed82a443eFa9AAb658DE14
SHARD                0x50d17EAaeB52c66E64b918385AbF6523fDAE57CF
hook                 0xbA318baA8649962fD77CC7082d098f2C09Fd60cC
NFT                  0x9fDA98dE1B7061ae02A9Aec7A6f8ed75a8Feb8F3
hook salt            0x…52e1
configuration hash   0xa98b7b95777267181a2b93a33632991e80a49f4a57d94150f8dfbd90421f34c1
```

Every one of those values is valid only for this exact source revision. Any source change re-mines all of
them. `test/ShardArtifactManifestV1.t.sol` fails the build if the published size and hash tables drift from
what the repository actually compiles, which is how a previous drift was caught.

The launch call carries no native value. Measured launch gas on a mainnet fork is 8,924,445.

## Assets, pool behavior, optional callbacks, and integration

`ShardTokenV1` is a fixed-supply ERC-20 with no mint, burn, pause, blocklist or transfer hook. `ShardNFTV1`
is an ERC-721 over ids 1 to 10,000 whose `tokenURI` is generated onchain by a pure renderer reached through a
staticcall.

The pool admits exactly one PoolKey. `_beforeInitialize` rejects any other currency pair, fee or tick
spacing, and `_guardPool` rejects any other PoolId on every swap. Alternative pools may exist and inherit
none of this behavior.

`hookData` is unused on every callback and no caller identity is decoded from it, so a quote and its
execution traverse identical bytes.

This repository ships no JavaScript swap client. `ShardSwapRouterV1` and `ShardFeeForwarderV1` are optional
Solidity helpers that the factory does not deploy.

## Product integration plan

Buy and redeem are indistinguishable from the ERC-721 `Transfer` event alone, because both move a piece out
of the NFT contract. An indexer must correlate each `Transfer` with the PoolManager `Swap` in the same
transaction to tell them apart.

`claimable()` under-reports for a holder who has never interacted, and `claim()` reverts `NothingToClaim` in
that state, so accrued fees are computed offchain from `FeeDistributed` and `Transfer` history rather than
read directly.

Any product surface built on this is a separate repository and is not bound by this application.

## Fees, recipients, and settlement

A flat 1.00% inclusive charge on the native-ETH leg of every successful swap of the canonical PoolKey. It is
never additive: a caller who asks to spend 1 ETH spends 1 ETH.

| Share | Destination | Mutability |
| --- | --- | --- |
| 0.80% | ERC-721 holders, through a per-piece accumulator with a holder-called `claim` | Not mutable |
| 0.10% | Builder, a compile-time constant on the factory | Rotatable by the current builder only |
| 0.10% | Programmable, `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c` | Immutable |

ETH is the specified currency exactly when `zeroForOne == exactIn`. That single fact determines which
callback charges the fee, and it lands precisely on the policy's `currency0` quadrant table:

| Quadrant | Charged in |
| --- | --- |
| zeroForOne exact input | `beforeSwap` |
| zeroForOne exact output | `afterSwap` |
| oneForZero exact input | `afterSwap` |
| oneForZero exact output | `beforeSwap` |

Both the outer fee and the internal split carry sub-wei remainders across calls, so the total is invariant to
how the volume is chopped up. Ten 9-wei fees accrue exactly what one 90-wei fee accrues.

Uniswap v4 skips a hook's own callbacks when the hook is the swapper, so `buyNFT`, `buyMany`, `buyMax`,
`sellNFT`, `sellMany` and `redeem` charge the identical fee internally rather than relying on a callback that
will not fire.

Claims are pull-only and separately authorized. Each path zeroes only the caller's own accrued balance before
transferring and is reentrancy-guarded. There is no sweep, no rescue and no netting between balances.

## Semantic examples

Buying the first 50 pieces at launch costs 0.050847 ETH including the fee, measured on a mainnet fork. Of
that, 50,847,164,162,969 wei accrued to Programmable and the identical amount to the builder — exactly 0.1%
each — with the remainder streamed to holders. The buyer's unspent ETH was refunded in the same transaction
and the factory ended holding zero SHARD.

A third-party swap that tries to move more than 50e18 SHARD reverts `SwapTooLarge`, measured on the SHARD leg
so one check covers all four quadrants.

## Fact provenance

Contract sizes and code hashes come from `forge build --sizes --skip test` and are asserted against
`spec/shards-v1.json` and the release manifest by `test/ShardArtifactManifestV1.t.sol`. Address predictions
come from re-running the mining path against a deployed factory. Gas figures, fee accrual and the zero
initial liquidity figure come from an Ethereum mainnet fork replay of the exact launch call.

## Open decisions

Three questions are raised for maintainer review rather than resolved here, and each is recorded in
`submission.json` under `disclosures`:

1. The fee remainder is one combined operator remainder with a parity carry to Programmable rather than two
   independent remainders. Does that satisfy policy 1.1.0?
2. There is no revert below 1,000 wei of gross quote volume. The carry preserves the entitlement instead of
   flooring it. Is that an acceptable substitute?
3. In-range liquidity is exactly zero at the initialization tick, because the pool deliberately opens at the
   upper bound of both locked ranges. Which value should the launch executor verify?

A fourth item is disclosed but not open: piece rarity is derived from block data at mint time and is
grindable by a determined proposer. Commit-reveal is the known fix and is deferred past this version.
