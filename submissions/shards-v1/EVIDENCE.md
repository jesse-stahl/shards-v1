# Evidence

What has actually been produced, by whom, and what it does not prove.

## Authority and package provenance

| Item | Value |
| --- | --- |
| Source repository | `jesse-stahl/shards-v1`, public, numeric id `1329073878` |
| Builder | `jesse-stahl`, immutable GitHub user id `155705664` |
| Package generator | Hookbuilder `v0.5.1`, commit `547482adf6ed0ed19e9cd4d0e884abd70e143229` |
| Submission standard | `1.6.0` |
| Intake target | `0xprogrammable/submit-launch`, `main` |
| License | MIT for all first-party source in `src/` |

Hookbuilder v0.5.1 is used deliberately rather than the newer v0.6.0, because submit-launch 1.4.0 vendors and
pins that exact release and requires `standardVersion` to be exactly `1.6.0`.

This is a fresh application. The earlier request in `0xprogrammable/hookbuilder` was merged at commit
`279dd2fc2ea8c488943ca4e60ca889cb00bab40e`, and submit-launch records no continuing entry for it.

## Tool coverage and independence

| Tool | Version | Used for |
| --- | --- | --- |
| solc | 0.8.26, cancun, 1,000 runs, no via-ir | Build |
| Foundry | forge / cast / anvil 1.7.1 | Build, test, fork replay |
| Node | 24 | Package validation |
| Git | 2.50.1 | Exact-object source binding |
| slither | not installed | Static analysis — **not run** |

Every tool above was run by the builder on the builder's own machine. None of this is independent. No
external auditor, sandbox, or reviewer has executed any of it.

## Run-scoped manifest and attestation

Build outputs are pinned twice. `spec/shards-v1.json` and `releases/shards-v1/mainnet-manifest.json` publish a
size and hash for every deployed artifact, and `test/ShardArtifactManifestV1.t.sol` rereads both files on
every test run and compares them against `vm.getCode` / `vm.getDeployedCode`. A source change that moves one
byte fails the suite until the tables are regenerated.

That test exists because the tables did drift once: the factory grew by more than two kilobytes while the
published figure stayed stale. The gate was added so it cannot happen silently again.

Current sizes:

| Contract | Runtime | Margin to EIP-170 |
| --- | ---: | ---: |
| `ShardHookV1` | 24,465 | 111 |
| `ShardLaunchFactoryV1` | 20,730 | 3,846 |
| `GeometricRendererV1` | 16,777 | 7,799 |
| `ShardNFTV1` | 7,318 | 17,258 |
| `ShardTokenV1` | 1,875 | 22,701 |

Hook creation-code hash: `0x3fbdbc069ee5bfcb1ded77a8d4e550f1bb0692a488b6eb5d23dac090fbca0716`.

## Launch-admission self-check

Predicted verdict: **CHANGES REQUIRED**.

Applicant-controlled items remain open, so this cannot be `PLATFORM PENDING`. The outstanding items are the
evidence artifacts listed under Prototype evidence below, plus the four markdown-and-JSON declarations that
review must rule on. None of these strings creates an acceptance record or a launch permit.

Two findings will not clear and are not defects to fix:

- `BEFORE_SWAP_RETURN_DELTA_CRITICAL` — the permission is genuinely held and genuinely powerful. The
  mitigation is that the delta is exactly the capped fee and `zeroAmmLeg` is `forbidden` everywhere.
- `NOVEL_PROJECT_CATEGORY_REQUIRES_ARCHITECTURE_REVIEW` — category `other`. Shards is not a closed launch
  type, and architecture review is the correct destination.

## Prototype evidence

Produced and reproducible:

| Evidence | Result |
| --- | --- |
| Full local suite | 338 passed, 0 failed, 1 skipped, 20 suites |
| Size gate | Every deployable artifact under EIP-170 |
| Artifact-drift gate | Published tables match the compiled build |
| Reproducible build from clean clone | Byte-identical hashes |
| CI on the exact revision | `.github/workflows/programmable-evidence.yml`, run `31731109297` green |
| Mainnet-fork factory deploy | Address matched the pinned prediction exactly |
| Mainnet-fork mine | Salts, addresses and configuration hash matched byte for byte |
| Mainnet-fork launch | 8,924,445 gas; factory left holding zero SHARD |
| Mainnet-fork first 50 buy | 0.050847 ETH, 4,250,385 gas, refund correct, 0.1% each to builder and Programmable |
| Post-launch in-range liquidity | Exactly zero at tick 69060, by design |

Still missing, and not claimed:

- one compiler build-info artifact (`forge build --build-info` emits 25 MB against a 2 MB per-file transport
  cap, which is unresolved)
- `gate-status.json` and `review-target.json`
- a structured test-evidence artifact
- the fee-conformance manifest, which itself needs the build-info above
- public project and token logo resources
- a workflow run id bound to the exact reviewed commit (see Change-impact below)
- a structured PoolManager deployment-evidence record

## Change-impact and decision-rendering check

Two items block completion and appear to be pipeline issues rather than project issues. Both are raised for
maintainer attention.

**The workflow run-id fixed point.** `validateActionsRun` requires the declared run's `head_sha` and
`head_commit.tree_id` to equal the bound commit, and `prepare-pr` binds `HEAD`. But the run id is declared
inside `submission.json`, which is part of that commit. Push a commit, get run R; add R and you have made a
new commit that R no longer describes. With the shipped `on: [push]` template this never converges. The
documented fallback is that missing run evidence yields `tooling-blocked` rather than a rejection.

**Build-info exceeds the transport cap.** A prototype with declared Solidity source must bind exactly one
compiler build-info artifact. `forge build --build-info` produces a single 25 MB file for this project, while
`prepare-pr` hard-caps declared source at 2 MB per file and 20 MB per repository. `out/` is also gitignored,
so the artifact would have to be copied into the submission tree to be bound at all.

Both look like they affect every prototype applicant with a non-trivial dependency graph, not only this one.

## Accepted-model integration evidence

None. No acceptance record exists, so there is no accepted model version, commit, submission hash or review
target to integrate against. No launch bundle has been generated and no deployment has been authorized,
signed or executed.

## Release gate ledger

| # | Gate | Owner | State |
| --- | --- | --- | --- |
| 1 | Source review | Maintainer | Not started |
| 2 | Security review | Maintainer | Not started |
| 3 | Maintainer acceptance | Maintainer | Not started |
| 4 | Platform implementation review | Programmable | Not started |
| 5 | Deployment authorization | Programmable | Not started |
| 6 | Deployment execution | Programmable | Not started |
| 7 | Source verification | Programmable | Not started |
| 8 | Runtime matching | Programmable | Not started |
| 9 | Lifecycle verification | Programmable | Not started |
| 10 | Monitoring readiness | Programmable | Not started |
| 11 | Routing, indexing and discovery | External | Not started |
| 12 | Product activation and availability | Programmable | Not started |

No gate here is satisfied by a green check, a passing local run, a merged pull request or a maintainer
comment. One gate never grants authority for the next.
