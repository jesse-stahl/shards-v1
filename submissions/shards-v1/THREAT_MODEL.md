# Shards threat model

Scope is the four deployed contracts and the one canonical PoolKey. Anything on an alternative pool, in a
separate product repository, or in a third-party integration is out of scope and inherits none of these
properties.

## Assets and value at risk

| Asset | Where it sits | Who can move it |
| --- | --- | --- |
| Native ETH mid-swap | PoolManager, transiently | Only the hook, inside its own unlock callback |
| Accrued holder fees | Hook balance | Only the holder, through `claim` |
| Accrued builder fees | Hook balance | Only the current builder recipient |
| Accrued Programmable fees | Hook balance | Only `0x4957f4…376c` |
| SHARD backing minted pieces | Hook balance | Nobody. It is inventory, not a balance anyone can withdraw |
| Both liquidity positions | PoolManager, owned by the hook | Nobody, ever. There is no removal path in the code |

The largest single-transaction exposure is bounded by the batch cap: 50 pieces, or 50e18 SHARD on a
third-party swap.

## Trust boundaries

The only external contract the system trusts is the canonical Uniswap v4 PoolManager at
`0x000000000004444c5dc75cB358380D2e3dE08A90`. Every callback authenticates `msg.sender` against that exact
address and reverts `NotPoolManager` otherwise.

Inside the boundary, the hook trusts its own SHARD and NFT contracts, both of which it deployed by CREATE2 at
addresses committed to in the configuration hash. The NFT accepts inventory instructions only from the hook
(`NotNFT` / `NotDeployer` guards), and the renderer is reached only by staticcall, which cannot write state.

There is no oracle, no keeper, no bridge, no signature scheme, no offchain input and no admin key. There is
therefore no path by which a compromised external party can move user value.

## Launch-plan integrity

The factory pins `keccak256` of the hook creation code at construction and refuses to deploy any other bytes.
It mines the hook salt until the resulting address carries exactly the five declared permission bits and
reverts if the mask differs. It commits the whole configuration — addresses, salts, ticks, start price,
renderer and metadata — to a configuration hash readable after the fact as `configurationHashOf(hook)`.

An observer who sees the pending launch can front-run it and sponsor the identical launch themselves. That
creates the same contracts with the same recipients rather than redirecting anything, because the builder and
Programmable destinations are compile-time constants rather than launch inputs. The accepted consequence is
that the launch sender is not guaranteed to be the intended one.

A second launch with the same salts and metadata reverts `AddressOccupied` and cannot alter the first.

## Custom hook boundary, only when `hook.used` is true

Five permission bits are enabled and each is load-bearing:

- `beforeInitialize` is the only thing standing between the collection and a front-runner who initialises the
  canonical pool at a wrong price. It rejects any non-canonical PoolKey and any start price other than the
  pinned one.
- `beforeSwap` charges the inclusive fee when ETH is the specified currency, returning a positive specified
  delta. `beforeSwapReturnDelta` is what allows that delta to be nonzero.
- `afterSwap` charges the fee when ETH is unspecified and its executed amount is only knowable afterwards,
  and enforces the batch cap on the SHARD leg. `afterSwapReturnDelta` allows that deduction.

`beforeSwapReturnDelta` is the highest-risk permission in v4: a hook holding it can consume a swap entirely
and return a no-op. Shards does not do that. Its specified delta is exactly the computed fee, capped at 1% of
the gross ETH leg, and the residual always reaches the AMM. `zeroAmmLeg` is declared `forbidden` on every
quadrant precisely because bypassing the curve is not a behavior this design has.

The hook swaps against its own pool in every user-facing entry point, and v4 skips a hook's own callbacks in
that case. If the fee lived only in the callbacks, every one of those paths would be free. It does not: the
same inclusive rate is applied internally by `_chargeFee` before settlement, which is what
`selfCallPolicy: same-pool-swap-fee-enforced-internally` declares.

## Ordinary no-hook boundary, only when `hook.used` is false

Not applicable. This project uses a hook.

## Value flows and accounting

Two invariants hold outside any single unlock callback:

```text
nft.totalSupply() + hookShardBalance / 1e18 == 10000
hook ETH balance >= builderFeesAccrued + launcherFeesAccrued + unclaimed holder fees
```

The first is what makes a piece redeemable for exactly one unit forever. The second is what makes every
accrued claim payable.

Every path writes effects before interactions and carries `nonReentrant`. ERC-20 transfer return values are
checked and revert `TokenTransferFailed` rather than being ignored. Hook-initiated actions revert
`PartialFillNotSupported` instead of settling a partial fill.

Sub-wei remainders are carried rather than discarded, in `feeCarryIn`, `feeCarryOut`, `operatorFeeRemainder`,
`operatorSplitParity`, `dustScaled` and `releasedDustScaled`. `releasedDustScaled` has to be separate from
`dustScaled`; folding them breaks the invariant that dust never exceeds circulating supply, which a test
enforces.

## Dynamic fees and recipients

The rate is not dynamic. It is the immutable constant `FEE_BPS`, and the LP fee is a separate immutable zero
that belongs to liquidity providers and is excluded from this split.

`operatorSplitParity` carries the odd wei to Programmable rather than the builder, so the platform share can
never be rounded below the builder share. The builder can rotate only its own future destination, emits
`BuilderFeeRecipientChanged` when it does, and cannot touch accrued Programmable fees, accrued holder fees,
liquidity or inventory.

Donations bypass the split entirely and go straight to holders, because a gift to holders is not swap volume.

## Attack and failure scenarios

| Scenario | Outcome |
| --- | --- |
| Foreign pool routes a fee in the wrong currency into the accumulator | Blocked by `_guardPool`; this would otherwise permanently brick `claim` for real holders |
| Swap the pool directly to dodge the batch cap, then redeem | Blocked: the cap is measured on the SHARD leg inside `afterSwap`, so it binds any route |
| Drain liquidity | No code path exists in any contract |
| Reenter during a claim or refund | `nonReentrant` plus effects-before-interactions on every path |
| Grind rarity by choosing the mint block | Possible, and disclosed. See Known limitations |
| Partial fill after the fee was charged on the requested size | Possible for third-party swaps, and disclosed. See Known limitations |
| PoolManager unavailable | The market is inert. Nobody can extract value and the 1:1 backing is unaffected |

## Dependency identity

One onchain dependency, identified by address and by the fact that every callback authenticates against it.
Address identity is not source identity: this application binds the canonical mainnet PoolManager address and
relies on Uniswap's published deployment for the source behind it.

## Product and data boundaries

The indexer reconstructs state from `ShardLaunched`, `Initialised`, `FeeDistributed`, `Claimed`,
`LauncherFeesClaimed`, `BuilderFeesClaimed` and ERC-721 `Transfer`, at a finality depth of 12 blocks, and
verifies the result against confirmed contract reads. A divergence from the 1:1 backing invariant halts the
indexer rather than serving inconsistent state.

Buy and redeem cannot be told apart from `Transfer` alone and must be correlated with the PoolManager `Swap`
in the same transaction. Any consumer that skips that correlation will misreport volume.

## Authorities and recovery

Two authorities exist and neither can affect a user position:

| Authority | Power | Cannot |
| --- | --- | --- |
| Builder recipient | Rotate its own future 0.10% destination; claim its own accrued balance | Touch any other balance, liquidity, inventory, or block a holder from selling |
| Programmable recipient | Claim its own accrued 0.10% balance | Anything else; the address is a compile-time constant |

Recovery is disclosure, not intervention. There is no pause, no upgrade, no admin and no rescue. If a defect
is found after launch it cannot be patched. That is the deliberate trade for having nobody who can withdraw
user value, and it is the single most important thing a reviewer should weigh.

## Known limitations

1. **Rarity is grindable.** The seed is derived from block data, recipient and a nonce at mint time. A
   proposer who controls block contents can influence outcomes. Commit-reveal is the known fix and is
   deferred past this version. Soft launch only.
2. **Partial fills overcharge relative to executed size.** When ETH is the specified currency the fee is
   charged in `beforeSwap` on the requested amount. A third-party swap that stops at its price limit pays
   that fee against a smaller executed amount — measured at 7,655 bps on a 1 ETH request that filled
   0.013 ETH. It cannot be corrected in `afterSwap`. The hook's own entry points are unaffected because they
   revert rather than accept a partial fill.
3. **111 bytes of EIP-170 margin.** Any future addition to the hook is likely to be impossible without
   removing something else.
4. **Irreversible by construction.** No upgrade, no pause, no recovery.
