# Votium gauge opt-out registry

A registry where a vlCVX holder declares that their vote on a gauge should be **excluded** from
that gauge's Votium reward distribution.

A protocol that votes for its own gauge dilutes the incentive it is paying for. The registry lets
it say so on-chain, per gauge and per epoch, with full history, so Votium and the protocols that
forward Votium rewards can leave those votes out when they compute per-gauge rewards.

The contract is independent of the other Votium contracts in this repository. It reads vlCVX for
epoch numbering and balances, and a Convex gauge registry to validate gauge addresses. The
withheld-weight views also read the gauge-vote platform, the vote helper and the delegation
registry; nothing else in the contract depends on those three.

## Rules

- Many holders can opt out of the same gauge, and one holder can opt out of many gauges.
- Every change takes effect at the **next** vlCVX epoch, never retroactively. An epoch's answer is
  fixed once that epoch begins.
- An opt-out never expires. It stands until the holder opts back in.
- To **add** an opt-out a holder needs a non-zero vlCVX balance of at least `minOptOutBalance()`
  at the next epoch. Opting back in has no balance, registry or pause condition.
- The owner can set or clear an exclusion for any address, from the next epoch
  (`forceOptOut` / `forceOptIn`). This exists for holders who cannot make the call themselves,
  such as vlCVX held in a treasury contract with no generic execute function.
- Lists are cursor-walkable, so a gauge with many opt-outs can be read within any RPC's limits,
  and a count per gauge and epoch lets a caller validate what it read.

## Deployments

Ethereum mainnet. Both instances are exact matches on [Sourcify](https://sourcify.dev), and the
source in `contracts/` is byte-identical to what was verified.

| Instance | Address | Gauge registry | Vote platform |
| --- | --- | --- | --- |
| Curve | [`0x5A5c248B39702E1A35bB854858B4Ae729D9c4405`](https://etherscan.io/address/0x5A5c248B39702E1A35bB854858B4Ae729D9c4405) | `0x96b24E0534B0cA31D8523D4be4904747Fd579D95` | `0x64D9B5AC386B70af9EDCD20A58cE9262D2EAC278` |
| f(x) | [`0x42dC5034C0699e98e2e5c0106B913c42810a618e`](https://etherscan.io/address/0x42dC5034C0699e98e2e5c0106B913c42810a618e) | `0xC2F99261d84D1665Df7e50F46813497A737AfB20` | `0xDcEa673B021f1f431E7D0Ec70a63bF8DcB6d44E6` |

Both instances, as read on-chain:

| | |
| --- | --- |
| `owner()` | `0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3` (Votium's multisig, since 2026-10-29; before that the deployer EOA `0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D`) |
| `minOptOutBalance()` | `100e18` (100 vlCVX) |
| `deployEpoch()` | 240 (the first epoch the instance answers for) |
| `firstProposalEpoch()` | 230 |
| `voteHelper()` | `0x76C484F67898EA978aa874dc7B32e648380FB9b1` |
| `delegation()` | `0xb8270eef1319173dE9f5033FED442F638ff1607d` |
| `vlCVX()` | `0x72a19342e8F1838460eBFCCEf09F6585e32db86E` |

The two gauge registries are Convex's and share an owner (`0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74`,
Convex core), which is not the owner of these instances. Which gauges are listed is controlled
there, and `optOut` validates against that listing.

`docs/DEPLOYMENT.md` records the deployment: constructor arguments, compiler settings, the move of
ownership from the deployer to the multisig, what is irreversible, and how an instance is retired.

## Epochs

Epoch numbers are **vlCVX epoch indices, used verbatim**. Gauge-vote proposals run every other
epoch, starting at epoch 230, so proposal `p` is epoch `230 + 2p`. An opt-out made during epoch
`N` is effective at `N + 1`, so the first vote it can affect is the next proposal epoch after
that.

## For reward calculators

```solidity
// Counts for every gauge you care about, in one call. The usual starting point: it tells you
// which gauges have any exclusions at all before you fetch a single list.
uint256[] memory counts = registry.optOutCountsAtEpoch(gauges, epoch);

// One gauge, O(log n). Also validates any list below.
uint256 count = registry.optOutCountAtEpoch(gauge, epoch);

// The full list. No size limit: on a large gauge this runs out of gas. Handle any failure by
// falling back to the cursor below, never by treating it as an empty list. The count above is
// how you tell those apart.
address[] memory excluded = registry.optOutAtEpoch(gauge, epoch);

// Windowed form, for a list too large to return in one call. Step `startIndex` forward until
// `done`; concatenating the results reproduces optOutAtEpoch, and the total length equals `count`.
(address[] memory users, uint256 nextIndex, bool done)
    = registry.optOutAtEpochFrom(gauge, epoch, startIndex, maxScan);
```

**Start with the batch count.** A calculator iterating the whole Curve registry (over 700 gauges)
does not want 700 round trips to find which gauges have any exclusions. `optOutCountsAtEpoch`
answers for all of them at once: about 970k gas for 300 live gauges, so the full registry fits in
one `eth_call`.

**Reading a large list.** `optOutAtEpochFrom` bounds the **scan**, not the result, so its
per-call gas does not depend on the gauge's total member count: 423,492 gas for `maxScan = 50` on
gauges of 49, 99 and 199 members. It is not flat per entry, though: scanning a member costs more
the deeper that member's own opt-out history, which you absorb by choosing `maxScan`. Each call
also carries about 21k of fixed overhead, so pick `maxScan` generously.

Walk it by passing back `nextIndex` until `done`, size the walk with `gaugeMemberCount(gauge)`,
and validate the total against `optOutCountAtEpoch`. For a settled epoch that check is sound even
if the list changes between calls (see **Scan-list growth**).

**Two traps.**
- `optOutAtEpochFrom` returns an empty window with `done == false` whenever that window held no
  matches. Loop on `done`, never on emptiness: stopping at the first empty page silently excludes
  nobody.
- Validating against the count only means something across the *whole* walk. Inside a single
  `optOutAtEpoch` call the contract already sizes the array from the count and reverts
  `CountMismatch` unless they agree, so `list.length == count` is true there by construction.

**Query settled epochs.** At `currentEpoch() + 1` a walk can return the right length with the
wrong set, because changes land there while the walk is in flight. Read settled epochs at a
finalized block.

**Epoch range.** Epoch-taking views revert `FutureEpoch` above `currentEpoch() + 1` and
`PreDeployEpoch` below `deployEpoch()`. Without the upper bound a far-future epoch would return a
plausible list *and* an agreeing count; without the lower bound a pre-deployment epoch would look
like a validated "nobody opted out". `maxQueryableEpoch()` returns the current ceiling.
`epochCount()` is informational only; it is not a query bound.

**Indexing.** Every membership event carries `effectiveEpoch` as an indexed topic, so an indexer
can pull "everything effective at epoch N" in one filter:

```solidity
event OptedOut     (address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);
event OptedIn      (address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);
event ForceOptedIn (address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);
event ForceOptedOut(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);
event MemberPruned (address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);
```

`MemberPruned` accompanies the `OptedIn` that withdrew an opt-out before it ever took effect; an
indexer replaying events should drop that pair. The configuration events take effect immediately
and carry no epoch:

```solidity
event MinOptOutBalanceSet(uint256 minOptOutBalance);
event GaugeRegistrySet(address indexed gaugeRegistry);   // also emitted once at deployment
event OptOutsPausedSet(bool paused);
event VoteSourcesSet(address indexed votePlatform, address indexed voteHelper, address indexed delegation, uint32 firstProposalEpoch);
event VoteSourcesCleared();
```

`countHistory(gauge)` exposes the raw count checkpoints for off-chain reconciliation.

## Withheld weight

The registry answers *who* is excluded. These two views answer *how much vlCVX* that removes from
a gauge's vote, by reading the gauge-vote platform directly:

```solidity
uint256 withheld = registry.withheldWeightAtEpoch(gauge, epoch);
uint256 part     = registry.withheldWeightForUsers(gauge, epoch, users);
```

For every excluded address, two things are summed:

- **its own vote:** `baseWeight * weight[gauge] / max_weight`, from the platform's `getVote`
- **weight its delegate carried for it**, whether or not it also voted itself. Delegators are
  grouped by delegate and resolved in one `getContributingWeights` call each, and the total is
  multiplied by the *delegate's* allocation to the gauge. The delegate's own base weight is
  theirs, not the delegators', so it is not counted.

An address can vote itself and still have its delegate carry some of its weight; the helper
reports only the incremental part in that case, so nothing is double counted.

**Epochs must carry a proposal.** `epoch` must share parity with `firstProposalEpoch()`, or the
view reverts `OddEpoch`. The epoch maps to proposal `(epoch - firstProposalEpoch) / 2`, and the
proposal found there must report that same epoch. Proposal ids can shift when a malformed
proposal is force-ended and recreated, so a window of `PROPOSAL_SEARCH_WINDOW` (8) ids either side
is searched, matching only a proposal that reports the epoch asked for. Past the window the read
refuses with `NoProposalForEpoch`.

**Why two functions.** `withheldWeightAtEpoch` gathers the excluded list itself and has no size
limit: one platform call and one delegation call per excluded address, plus two per distinct
delegate, so a large gauge runs out of gas. `withheldWeightForUsers` takes a slice (feed it
windows from `optOutAtEpochFrom`) and checks that every address really is excluded at that epoch
and that none repeats, since a repeat would overstate the total. A delegate spanning two slices
is resolved once per slice and each resolution rounds down separately, so partition by delegate
if you need the totals to agree to the wei.

**Cost**, measured on a fork: about 20k per plain excluded address and 67k per address that
delegated and voted, over about 22k of fixed overhead. `optOutCountAtEpoch` is the cheap way to
decide which form to use.

## For holders

```solidity
registry.optOut(address[] gauges);   // effective next epoch
registry.optIn(address[] gauges);    // effective next epoch
```

Adding an opt-out needs `vlCVX.balanceAtEpochOf(nextEpoch, you) >= minOptOutBalance()`, and a
non-zero balance regardless. `balanceAtEpochOf` rather than `balanceOf` is deliberate: it counts a
lock created *this* week at the next epoch, so a protocol that locks CVX mid-week can opt out
before its first vote ever lands.

A batch is all-or-nothing: a repeated gauge, or one you are already opted out of, reverts the
whole call. `optIn` never consults the gauge registry, so a gauge that is later killed or removed
can never trap you in an opt-out.

If you opt back in before your opt-out ever covered an epoch, the registry discards that interval
rather than leaving a dead entry behind.

## For the owner

```solidity
registry.forceOptOut(address[] gauges, address user);        // one holder, many gauges
registry.forceOptIn(address[] gauges, address user);         // one holder, many gauges
registry.forceOptInUsers(address[] gauges, address[] users); // index-aligned pairs
registry.setMinOptOutBalance(uint256 amount);
registry.setGaugeRegistry(address newRegistry);              // probed; reverts if not a registry
registry.setOptOutsPaused(bool paused);                      // stops new opt-outs; exits stay open
registry.setVoteSources(address platform, address helper, address delegation, uint32 firstProposalEpoch);
```

The force paths ignore `minOptOutBalance` and `optOutsPaused`, which are conditions of the public
path, but **the gauge registry still applies** to `forceOptOut`. They emit their own events,
`ForceOptedOut` and `ForceOptedIn`, which the public path never emits, and they follow the same
next-epoch rule, so no settled epoch can change.

**This means the owner controls the exclusion set.** That is a deliberate trade, argued in
`docs/SECURITY.md`: the registry is an input to Votium's reward calculation, not a constraint on
it, so an operator willing to exclude a voter never needed this contract's cooperation. What
survives is that settled epochs are immutable and every change is evented an epoch before it
takes effect.

`setMinOptOutBalance` is an anti-spam floor, enforced on **add only**: raising it never
invalidates an existing opt-out and never blocks `optIn`. `setOptOutsPaused` gates `optOut`
alone; `optIn`, `forceOptIn` and every read keep working. `setGaugeRegistry` changes only which
gauges a new opt-out may name; moving to a different registry also clears the vote sources,
which then have to be set again.

Ownership is two-step (`Ownable2Step`): `transferOwnership` only nominates, and the transfer
completes when the nominee calls `acceptOwnership`.

**Retiring an instance.** Pause, then `renounceOwnership()`. Every historical epoch stays
readable, `optIn` stays available, and `optOut` refuses with `OptOutsArePaused`. It cannot be
undone.

## Errors

Every revert is a named custom error. The ones a caller can reach:

| Error | Raised by | Means |
| --- | --- | --- |
| `InsufficientBalance` | `optOut` | Balance is zero, or below `minOptOutBalance()` |
| `GaugeNotRegistered` | `optOut`, `forceOptOut` | This instance's registry does not list that gauge |
| `AlreadyOptedOut` | `optOut`, `forceOptOut` | Already excluded there, or the gauge is repeated in one call |
| `NotOptedOut` | `optIn`, `forceOptIn`, `forceOptInUsers` | Not currently excluded there, or the gauge is repeated |
| `OptOutsArePaused` | `optOut` | The owner has paused new opt-outs. Opting back in is unaffected |
| `ArrayLengthMismatch` | `forceOptInUsers` | The gauge and user arrays differ in length |
| `FutureEpoch` | every epoch-taking view | Above `maxQueryableEpoch()` |
| `PreDeployEpoch` | every epoch-taking view | Below `deployEpoch()`; the instance holds no answer for it |
| `InvalidScanWidth` | both cursors | `maxScan` of zero would never make progress |
| `NotExcluded` | `withheldWeightForUsers` | A supplied address was not excluded from that gauge at that epoch |
| `DuplicateUser` | `withheldWeightForUsers` | An address appeared twice, which would count its vote twice |
| `OddEpoch` | the withheld-weight views | The epoch carries no proposal |
| `NoProposalForEpoch` | the withheld-weight views | No proposal covers that epoch within the search window |
| `VoteSourcesNotSet` | the withheld-weight views | `setVoteSources` has not been called on this instance |

Owner-only calls can also raise `InvalidGaugeRegistry`, `VoteSourcesMismatch`,
`InvalidVoteWeightScale` and `ProposalEpochMismatch`, all of which reject a misconfiguration
before it is stored. `EpochDerivationMismatch` can only be raised by the constructor.
`CountMismatch` and `NonMonotonicEpoch` are internal consistency checks; reaching either means
stored state has broken.

## Scan-list growth

Every address in a gauge's scan list costs at least about 7.9k gas on every future read of that
gauge, and more as that address's own history deepens (18.1k at thirty-two intervals), since
scanning it is a binary search over that history.

**An opt-out that never took effect cleans itself up.** Opening and closing inside one pending
window prunes the member as `optIn` closes it. Nothing changes for any epoch, past or present: the
member appeared in no epoch's answer, and its `+1` and `-1` landed on the same count checkpoint.

**An opt-out that did take effect is permanent, deliberately.** Once an address was opted out at
even one epoch, `optOutAtEpoch(gauge, thatEpoch)` must keep naming it, or the registry would stop
reproducing published reward calculations. `optIn` and `forceOptIn` close the interval but never
remove the member, so `forceOptIn` does not reduce read cost.

The defences against someone adding permanent entries on purpose:
- **`minOptOutBalance`** (100 vlCVX on both instances). It is locked capital rather than a cost,
  recoverable after 16 weeks, and it is charged per *address*, not per entry: one funded address
  can take a slot on every gauge in one transaction. Gas, not this floor, bounds an attack spread
  across many gauges. It is checked at add time only, so raising it never evicts existing entries.
- **`optOutAtEpochFrom`**, whose per-call gas does not depend on list size, so the data stays
  retrievable at any scale.
- **Events**, which let an indexer avoid the views entirely.

**Pruning does not weaken a walk at a settled epoch.** A member is only prunable while its single
interval is still pending, so it registered in the current window, and the entry swapped into its
slot did too. That entry's earliest interval starts at the pending epoch, so stepping over it
cannot lose a settled-epoch result. Walking the **pending** epoch carries no such guarantee.

The registry returns *who* to exclude, not vote weights; the withheld-weight views or the
calculator supply the weights.

## Gas

Measured on a mainnet fork against the live locker before deployment:

| Operation | Gas |
| --- | --- |
| First-ever opt-out (new gauge, new user) | ~250k |
| First opt-out on an already-used gauge | ~196k |
| Repeat opt-out (new interval, later epoch) | ~112k |
| Opt-in, closing inside the same pending window (auto-prunes) | ~67k |
| Opt-in, closing in a later epoch | ~63k |
| Surcharge for the first *opt-out* past a week boundary | +~35k |
| `optOutAtEpoch`, per member scanned | 7,914 at one interval, 18,054 at thirty-two |
| `optOutAtEpochFrom(maxScan = 50)` | ~424k, unchanged at 50 / 100 / 200 members |
| `optOutCountsAtEpoch` over 300 live gauges | ~970k, one call |

Only `optOut` can pay the boundary surcharge: it calls `vlCVX.checkpointEpoch()` so that the
locker has the next epoch for its balance read. `optIn` reads no locker state at all.

**If you call the list reads from a contract, cap the sub-call**, for example
`registry.optOutAtEpoch{gas: budget}(gauge, epoch)`. An out-of-gas consumes 63/64 of the gas
forwarded (EIP-150), so in a loop over gauges one oversized gauge would otherwise take the whole
transaction with it. Off-chain `eth_call` has no such exposure.

## A note on `isValidGauge`

The gauge registries expose two validity checks, and the contract uses only `isRegisteredGauge`,
a plain storage read that already returns false for force-removed gauges. `isValidGauge` is
unusable as a gate: it calls `GaugeController.gauge_types()`, which reverts for addresses the
controller does not know, and `is_killed()`, which reverts on older Curve gauges that predate it.
Before deployment, 11 of the first 40 gauges the Curve registry listed made `isValidGauge`
revert. Gating on it would have locked those gauges out.

## Build and test

Foundry only. From the repository root, fetch `forge-std` once:

```bash
git submodule update --init opt-out-registry/lib/forge-std
```

Then, in `opt-out-registry/`:

| Command | What it runs |
| --- | --- |
| `forge build` | The contracts and tests (solc 0.8.28, optimizer 200 runs, cancun) |
| `forge test` | The stateful invariant campaign, its `HandlerSanity` coverage floors, and the state-machine tests (about 2 minutes) |
| `FOUNDRY_PROFILE=integration forge test` | Fork tests against the live Convex contracts, both instances (about 30 seconds) |
| `FOUNDRY_PROFILE=deep forge test` | The invariant campaign at 128 runs × 128 depth. Needs a reliable RPC |

**Forking.** The invariant campaign and the integration tests fork mainnet, defaulting to
`https://ethereum-rpc.publicnode.com`, which needs no key but serves only recent state: it works
from `latest` and cannot pin an older block. Set `FORK_RPC_URL` to an archive provider for longer
or pinned runs. The state-machine tests use mocks and need no RPC.

`DeploymentDay` only runs while a proposal for the current epoch is open; at other times it
skips.

**Reproducing the deployed bytecode.** The verified build has no remappings, while Forge adds one
for `forge-std` by default, and remappings are part of the metadata hash. Build the contracts alone
without them to reproduce the on-chain metadata hash (`…1220780db79c…`) exactly:

```bash
FOUNDRY_AUTO_DETECT_REMAPPINGS=false forge build contracts --out verify-out --cache-path verify-cache
```

### What the tests cover

- **`test/foundry/OptOutRegistry.invariant.t.sol`:** Foundry generates call sequences across the
  holder and owner actions, then checks nine invariants: settled-epoch immutability,
  count-equals-list, cursor-equals-list, batch counts, membership bookkeeping, history
  well-formedness, checkpoint ordering, agreement with a ghost record the handler builds, and
  that no action had an outcome other than the one predicted for it.
- **`test/foundry/HandlerSanity.t.sol`:** asserts directly that each handler action lands, so the
  campaign cannot quietly degrade into one that does nothing and therefore satisfies everything.
- **`test/foundry/statemachine/`:**
  - `Guards`: every rejection path, which the permissive mocks elsewhere leave unreachable.
  - `StorageSlots`: reads the packed membership indices raw and checks they point back
    correctly in both directions after swap-and-pop removals.
  - `WithheldWeight`: the withheld-weight arithmetic, the proposal search window and the
    `setVoteSources` checks.
- **`test/integration/`:**
  - `DelegatedExclusion`: runs the full path against the real vlCVX, Delegation registry,
    `GaugeVotePlatform` and a `GaugeVoteHelper` built from `reference/`, with an address that
    votes itself *and* has weight carried by its delegate, plus a split vote that names the
    same gauge twice.
  - `FxInstance`: the same on the f(x) platform, and the refusal to pair a platform with the
    other instance's registry.
  - `DeploymentDay`: an opt-out made during a live vote cannot affect that vote.

Two traps if you extend the Foundry suite. State written by an `invariant_` function is
discarded, so the frozen-answer record lives in the handler, whose state persists across a run.
And a handler that only records successful calls lets a wrongly reverting call agree with the
ghost on a history in which nothing happened; every action therefore predicts whether it should
succeed, and `invariant_noUnexpectedOutcomes` fails on a contradiction.

## Layout

```
contracts/OptOutRegistry.sol      the registry
contracts/interfaces/             IvlCVX, IGaugeRegistry, IVoteSources
contracts/dependencies/           Ownable, Ownable2Step, Context (vendored OpenZeppelin, unmodified)
reference/                        Convex's verified contracts, used only by the integration tests
test/                             Foundry tests, as above
docs/DESIGN.md                    why each function is the way it is
docs/SECURITY.md                  threat model, owner powers, static analysis, review findings
docs/DEPLOYMENT.md                the deployment record
```
