# OptOutRegistry — design rationale

A justification of every function in `contracts/OptOutRegistry.sol`, written to be read
alongside the source.

## The one constraint everything else follows from

`optOutAtEpoch(gauge, epoch)` must keep returning the same answer forever for any epoch that has
already settled. Votium publishes reward calculations from it; if a past epoch's answer can
change, those calculations stop being reproducible.

That single requirement explains most of what follows: why mutations only ever write at the next
epoch, why membership is stored as intervals rather than a live set, why a member who was
genuinely opted out is never removed from the scan list, and why the one removal that does exist
is restricted to members who provably appear in no epoch's answer.

## Constants and immutables

| Name | Why it exists |
| --- | --- |
| `ACTIVE` | Sentinel `endEpoch` for an open interval. Public so integrators can interpret `membershipHistory` output without guessing. |
| `INDEX_MASK` | Low half of a packed `_memberSlots` entry. Private; an implementation detail. |
| `vlCVX` | Immutable. The locker an instance reads epochs and balances from cannot be swapped. |
| `gaugeRegistry` | **Not** immutable — see `setGaugeRegistry`. One deployment per registry rather than one contract holding a registry set, so an instance's lists stay keyed to a single gauge set. |
| `EPOCH_DURATION` | One week, matching the locker's `rewardsDuration`. Used to derive the current epoch arithmetically. |
| `epoch0Date` | Timestamp of vlCVX epoch 0, read once at construction. Lets `_currentEpoch` be arithmetic instead of an external `findEpochId` binary search, worth ~23k on every epoch-taking view. |
| `deployEpoch` | Lower bound for queries. Without it, an epoch from before the contract existed returns an empty list that is indistinguishable from a validated "nobody opted out". |
| `minOptOutBalance` | Anti-spam cost floor, enforced on add only. One of several owner-settable values; the others are `gaugeRegistry`, `optOutsPaused` and the four written by `setVoteSources`. |

## Storage

`_history[gauge][user]` — chronological, non-overlapping `[start, end)` intervals. Intervals
rather than a boolean because the answer must be reconstructible for any past epoch. `startEpoch`
is strictly increasing, which is the precondition the binary search in `_isOptedOutAt` depends
on; it holds because a new interval is only pushed when the tail closed at an epoch strictly
before the one being written.

`_memberSlots[gauge][user]` — 1-based index into `_gaugeMembers[gauge]` in the low 128 bits, into
`_userGauges[user]` in the high 128. Packed into one slot so that tracking membership costs the
same single `SSTORE` a bare boolean would, while still permitting O(1) removal from either array.
Kept explicitly rather than inferred from `_history.length != 0`: the inference would be correct
today, but it silently couples two invariants, and any future path that pushes history without
the membership guard would produce either a duplicate member entry or a missing one — in both
cases breaking `count == sum(walk)`, the guarantee this contract exists to provide.

`_gaugeMembers[gauge]` / `_userGauges[user]` — the scan lists. Grow on a first opt-out; shrink
only via `_pruneMember`.

`_countHistory[gauge]` — running member count, one checkpoint per epoch that changed. Exists so
`optOutCountAtEpoch` is O(log n) rather than a full scan, which is what lets a caller validate a
paginated read cheaply. Grows by at most one entry per epoch, because every write in a given
pending window targets the same epoch and merges in place.

## Mutative functions

### `optOut(address[] gauges)`

Takes an array because a protocol typically opts out of several gauges at once and should pay the
epoch checkpoint and balance read once rather than per gauge.

The balance gate is `balanceAtEpochOf(nextEpoch, msg.sender)`, not `balanceOf`. The pending-lock
carve-out exists only in `balanceOf`, so using it would reject a protocol that locked CVX earlier
the same week — forcing them to wait a full epoch and dilute one round of rewards, which is the
exact outcome this registry exists to prevent. The `balance == 0` check is separate from the
floor check so that a zero balance is still rejected if the floor is ever set to zero.

Batch semantics are all-or-nothing: a duplicate gauge, or one already opted out, reverts the
whole call. Deliberate — silently skipping entries would leave the caller unsure what happened,
and the caller can pre-filter with `isOptedOut`.

### `optIn(address[] gauges)`

Deliberately does **not** consult the gauge registry. A gauge that is later killed or
force-removed must never trap a user in an opt-out.

It also does not checkpoint vlCVX. Closing an opt-out reads no locker state — only the epoch
number, which is arithmetic — so the checkpoint would be pure cost on the one action a user
takes to stop being excluded. It is the reason an opt-in costs the same whether or not it is the
first transaction past a week boundary.

Closing an opt-out that never covered an epoch also prunes the member (see `_close`). This is the
only path that removes from a scan list.

### `forceOptOut` / `forceOptIn(address[] gauges, address user)`, `forceOptInUsers(address[] gauges, address[] users)` — `onlyOwner`

The fallback for a holder who cannot make the call themselves: vlCVX locked in a treasury or
similar contract with no generic execute function. Such a holder can never call `optOut` or
`optIn`, and has no other route.

An on-chain authorization check was considered and rejected. Accepting a call from
`IOwnable(account).owner()` or `.operator()` at depth 1 would cover treasuries that happen to
expose those names, and silently exclude every one that does not — Safes, governance-executed
treasuries, role-based access control, proxies whose `owner()` is the proxy admin rather than
the controlling party. A check that works for an unknown fraction of holders is not a solution,
and the gap it leaves is exactly the gap that motivated the feature. The fallback is operational
instead: the protocol reaches out to Votium.

Both take one holder and several gauges, which is the shape that arises in practice: a protocol
excluding its own vote across the gauges it votes for, not many addresses on one gauge.
`forceOptInUsers` is the index-aligned form for clearing several holders at once, named apart
from `forceOptIn` rather than overloading it, because two same-named entries in a transaction
builder are easy to pick wrongly.

Both ignore `minOptOutBalance` and `optOutsPaused`, which are conditions the public path imposes
and this path exists for cases the public path refuses. The gauge registry still applies: an
exclusion is only meaningful on a gauge that can be voted for, and skipping the check would let
the owner record entries against arbitrary addresses. Both emit distinct events the public path
never emits, so an indexer can always separate owner action from holder action.

`forceOptIn` does not shorten the scan list: an address genuinely opted out at an earlier epoch
must stay findable there. The one exception is an exclusion that never took effect, which is
discarded exactly as the user's own `optIn` would discard it — reachable through `forceOptIn`
now that there is no balance gate, where previously it was not.

All three take an explicit gauge list rather than walking `_userGauges[user]`. A "remove
everywhere" helper would be unbounded, so a user opted out of thousands of gauges could become
permanently unremovable by running out of gas.

**What this gives up.** An earlier version gated `forceOptIn` on the target holding zero voting
power, making "the owner can neither create nor remove an exclusion for an active voter" a real
property. Removing it hands the owner the exclusion set. The trade is argued in
`docs/SECURITY.md`; the short form is that Votium computes the reward distribution regardless,
so the registry was never what stopped an operator from excluding a voter. What survives is
that settled epochs cannot change and every owner action is evented an epoch before it lands.

Removing the balance read also removed the last external call from both paths. `optIn`,
`forceOptIn` and `forceOptOut` now touch nothing outside this contract, so no locker or registry
failure can trap anyone in an exclusion.

### `setMinOptOutBalance(uint256)` — `onlyOwner`

The tuning knob. Enforced on add only, so raising it never invalidates an existing opt-out and
never blocks `optIn` — which also means it is preventive, not curative.

### `setGaugeRegistry(address)` — `onlyOwner`

The registry was immutable at first, on the reasoning that it kept each instance's lists cleanly
keyed to one registry and kept an owner-settable external call out of `optOut`. That traded away
the ability to follow a registry being superseded: the only remedy was a redeployment, which
abandons the accumulated history — and history is the thing this contract exists to preserve,
since a settled epoch's answer has to stay reproducible forever.

Replacing it is narrow by construction. It gates entry only, so it changes which gauges a *new*
opt-out may name and nothing else: no read consults a registry, so no settled epoch can move,
and `optIn` does not consult one either, so a user holding an opt-out under the old registry can
still withdraw it. The address is probed exactly as the constructor probes it, so it cannot be
set to an EOA, the zero address, or a contract without `isRegisteredGauge`.

The cost is ~2.3k on `optOut`: a storage read in place of a value compiled into the bytecode.
`optIn` reads neither the registry nor the pause flag and is unchanged, which is the constraint
that mattered — it is the action a user takes to stop being excluded.

An instance's scan lists may then span more than one registry's gauges. That is harmless: lists
are keyed by gauge address, and a reward calculator asks about gauges it already has in hand.

### `setOptOutsPaused(bool)` — `onlyOwner`

The case `setGaugeRegistry` cannot cover: no usable registry to point at. Pointing at a dead or
empty one would work by accident, but says nothing about intent and leaves a reader guessing
whether the address is wrong or deliberate. A flag says it outright, and `optOut` reverts
`OptOutsArePaused` rather than `GaugeNotRegistered` on every gauge.

Deliberately one-sided. It gates `optOut` alone: `optIn`, `forceOptIn` and every read stay
available, so a pause can never trap a user in an exclusion nor hide one from a reward
calculation, and existing opt-outs stay in effect for as long as they stand. The flag packs into
`gaugeRegistry`'s slot, so `optOut` pays one `SLOAD` for both and the flag itself is free.

### `withheldWeightAtEpoch` / `withheldWeightForUsers` — and `setVoteSources`

The registry records *who* is excluded. These answer *how much vlCVX* that removes from a
gauge, which is the number a reward calculation actually needs, by reading the gauge-vote
platform rather than making the consumer join two datasets offchain.

Two entry points for one computation, because the work is unbounded: one platform call and one
delegation call per excluded address, plus a helper call and a platform call per distinct
delegate. `withheldWeightAtEpoch` gathers the list itself and is the convenient form;
`withheldWeightForUsers` takes a slice of it so a caller can stay inside a gas budget. The
sliced form validates that each address really is excluded at that epoch and that none repeats
— a repeat would count a vote twice and overstate what to withhold, which is the one error
shape here that silently produces a plausible wrong answer.

**Both passes apply to every address.** An address that voted itself can still have weight its
delegate carried, and both are withheld. The helper already reports only the incremental part
in that case, so summing the two cannot double count. Skipping the delegate pass for addresses
that voted would have been the natural shortcut and is wrong.

**Grouped by delegate before the gauge weight is applied.** The helper resolves a batch of
delegators in one call, and the delegate's allocation is read once for the group, so the
arithmetic is `sum(contributions) * gaugeWeight / max_weight` rather than a sum of individually
rounded terms. That is both cheaper and more accurate, and it is why slicing the caller-supplied
form across a delegate can differ by a few wei from the whole-list read. Pinned by a test that
would fail under per-user rounding.

**The epoch/proposal mapping is derived, then verified.** Proposals run every other epoch, so
the id is `(epoch - firstProposalEpoch) / 2`. Arithmetic alone would silently read the wrong
proposal if the numbering ever shifted, so the proposal is read back and must report the epoch
that was asked for. This is the same shape as the constructor's `EpochDerivationMismatch` check
against vlCVX: derive for cost, verify for safety.

Two different assumptions sit here, and they are trusted differently on purpose.

*Which epochs carry a proposal* is treated as fixed. Proposals have opened on alternating epochs
for over five years, and a change to that cadence would break far more than this contract, so
an epoch of the wrong parity is refused outright with `OddEpoch` rather than searched for. That
is a cheap check made before any external call.

*Which id a given proposal holds* is not trusted, because it moves for reasons that are
operational rather than structural. `forceEndProposal` zeroes a proposal's `startTime`,
`endTime` and `epoch` but keeps its array slot, and zeroing `endTime` clears the `PrevNotEnded`
guard, so a replacement can be created immediately and is pushed at the next id. A malformed
proposal noticed and recreated within its own epoch therefore shifts every later id by one,
permanently and cumulatively. Confirmed against the live platform in
`test/integration/DelegatedExclusion.t.sol`.

Hence the bounded window either side of the derived id. It matches only a proposal reporting the
epoch asked for — a dead slot reports zero and matches nothing — so a shift is absorbed rather
than becoming permanent breakage, while a wrong proposal is still never read. Measured at 3,351
gas when shifted by one and nothing when aligned, charged once per call rather than per excluded
address.

**Configured rather than constructed.** `setVoteSources` takes all four values together,
because they are interdependent — the helper is built against a specific delegation registry,
and the proposal numbering is a property of the platform. It checks the helper's registry
matches, that the platform agrees about proposal 0, and reads `max_weight` from the platform
instead of hardcoding it. Until it is called the two views revert `VoteSourcesNotSet` and
nothing else is affected; the core registry deploys and works without them.

These three dependencies are strictly additive. No exclusion record, no settled epoch and no
opt-in path reads them.

**Repointing them does change what past epochs report, and that is accepted.** The contract's
headline promise — an epoch's answer is fixed once that epoch begins — is about the *exclusion
record*, which no owner action can rewrite. The withheld-weight views are a derived reading of
that record against an external vote platform, so pointing them somewhere else necessarily
changes what they say about every epoch, not just future ones.

It is left that way deliberately. A superseded platform should not happen, and if it does, a
consumer needing historical figures can compute them from the old platform directly, or read
them through a small helper contract deployed for the purpose. Neither is worth carrying a
per-epoch source map in a contract whose value is that it stays simple and its record stays
immutable.

## Read functions

Every epoch-taking view calls `_validateEpoch`. The two convenience wrappers that read the
current epoch (`optOutCount`, `isOptedOut`) skip it, correctly: the current epoch is always
within range by construction.

| Function | Justification |
| --- | --- |
| `optOutCountAtEpoch` | The validation primitive. O(log n), so a caller can cheaply check that a walk returned everything. |
| `optOutCountsAtEpoch` | The same for many gauges at once, with the epoch validated a single time. The shape a reward calculator actually uses: it iterates the whole registry and mostly wants to know which gauges have any exclusions before doing further work. ~970k gas for 300 live gauges, so the full registry fits in one call. |
| `optOutCount` | Current-epoch convenience for UIs. |
| `optOutAtEpoch` | The simple read. Sizes its array from the count and asserts `filled == count` both ways, which turns the count-equals-list invariant into a production check rather than a test-only one. Has no size ceiling: a large gauge runs out of gas, and any failure means the same thing — use the cursor. |
| `optOutAtEpochFrom` | The read that scales, and the only windowed one. Bounds the *scan*, so per-call gas is independent of the gauge's total size — measured at 423,492 gas for `maxScan=50` on gauges of 49, 99 and 199 members, identical to the byte. It is not flat per entry, though: scanning a member costs more the deeper that member's own history, the same effect that made a member-count ceiling insufficient for `optOutAtEpoch`. The caller absorbs that by choosing `maxScan`. |
| `gaugeMemberCount` | Sizes a cursor walk, and tells a caller how much work a whole-list read faces before attempting one. |
| `isOptedOutAtEpoch` / `isOptedOut` | Single-pair lookup, O(log n). Avoids fetching a whole list to answer one question. |
| `membershipHistory` | Auditing. Lets anyone reconstruct a user's full opt-out timeline without replaying events. |
| `countHistory` | Lets an indexer reconcile counts without replaying intervals, and exposes the strictly-increasing-epoch structure the binary search relies on. |
| `gaugesForUserAtEpoch` (+ `...From`, `userGaugeCount`) | Mirror of the gauge side, for user-facing UIs. Runs out of gas on an oversized list, as the gauge side does. A user's list is bounded by the number of gauges that were listed at the times they opted out — not by the 707 listed at deployment, since gauges are added and force-removed over time — but it stays small in practice. |
| `currentEpoch`, `epochCount` | Save integrators a second call to vlCVX and pin which epoch numbering is in use. |
| `maxQueryableEpoch` | Lets a caller discover the guard boundary rather than probing for the revert. |
| `isGaugeMember` | Membership predicate. Named for what it returns rather than for what the caller did: an address whose opt-out was withdrawn before it took effect is pruned and reads false, despite having called `optOut`. |


## Internal functions

| Function | Justification |
| --- | --- |
| `_setGaugeRegistry` | Shared by the constructor and `setGaugeRegistry`, so the two can never validate differently. Probes the candidate with `isRegisteredGauge(address(0))`: a registry answers with 32 bytes, a non-contract returns none, and a contract without the selector does not answer at all. Emits on both paths, so an indexer sees the initial value as an event rather than having to read it |
| `_nextEpoch` | `_currentEpoch() + 1`. The epoch every mutation writes at, derived rather than read back from the locker. Monotonic in `block.timestamp`, which is the precondition `_incCount`/`_decCount` assert. |
| `_ensureEpochCheckpointed` | Calls `checkpointEpoch()` purely so that `epochs[nextEpoch]` exists for `balanceAtEpochOf`. Only `optOut` needs it — it holds the one balance read left — so every other mutation escapes the ~35k boundary surcharge. |
| `_currentEpoch` | `(block.timestamp - epoch0Date) / EPOCH_DURATION`, never `epochCount() - 2` and no longer `findEpochId`. The locker's epoch dates are exactly `epoch0Date + i * EPOCH_DURATION`, since its checkpoint logic can only append `last + rewardsDuration`; the constructor asserts the derivation matches `findEpochId` against the live locker before the deployment is accepted. Besides saving ~23k per view, it is strictly more current — `findEpochId` searches only checkpointed epochs and saturates at the last one in the array when nobody has poked the locker. |
| `_validateEpoch` | Both bounds exist because the count cross-check cannot catch either failure: a far-future epoch returns a plausible list *and* an agreeing count, and a pre-deployment epoch returns an empty list that looks validated. |
| `_optOut` | Holds the "reopen in the same pending window" branch, which is what makes opt-out → opt-in → opt-out within one week a true no-op rather than a source of duplicate intervals or drifted counts. |
| `_close` | Shared by `optIn` and `forceOptIn` with a flag that only selects the event. The logic is genuinely identical and duplicating it would risk the two paths diverging. Requiring an open interval makes a repeated call revert rather than applying a second decrement against one interval, which would drift the count permanently. Also holds the two discard branches described under **Withdrawal before effect**. |
| `_pruneMember` | The only removal. Safe precisely because its caller has established the member appears in no epoch's answer. |
| `_removeGaugeMember` / `_removeUserGauge` | Swap-and-pop with index fixup on the moved entry. Split in two because the two arrays are keyed differently and the packed halves are updated with different masks. |
| `_incCount` / `_decCount` | Split rather than one signed-delta function: a signed delta forces casts between `int` and `uint32` at every call site for no benefit. Both assert epoch monotonicity, which is an unasserted precondition of the binary search otherwise. `count - 1` reverting on underflow is a deliberate tripwire for count-vs-list drift. |
| `_countAt` / `_isOptedOutAt` | Deliberately identical search predicate — largest index whose key is `<= epoch`. If they diverged, the count and the list would disagree at interval boundaries, and the contract's central guarantee would fail exactly where it is hardest to notice. |

## Withdrawal before effect

An interval whose `startEpoch` equals the epoch it is being closed at never covered an epoch. It
appears in no epoch's answer, and its `+1` and `-1` landed on the same count checkpoint and
cancelled, so discarding it changes no query's result — past or present. `_close` therefore
discards it, in one of two ways:

- **It was the member's only interval** → the member is pruned from both scan lists entirely.
  This is what makes the cheapest way to permanently inflate a gauge's read cost — open and
  close an opt-out inside one pending window — clean up after itself with no intervention.
- **Earlier history did take effect** → only the empty interval is popped. The member has to
  stay scannable for those earlier epochs, but the empty interval does not, and leaving it would
  let one be appended every epoch, deepening the binary search in `_isOptedOutAt` for every
  future reader of that gauge.

Together these give `_history` a stronger property than "an empty interval reads as
not-opted-out": empty intervals never persist at all, so no search ever walks one.

## Properties an auditor will want stated

**Duplicate entries in a batch cannot double-count.** A repeated gauge in `optOut` hits
`AlreadyOptedOut` on the second pass, because the first already left the tail open; `optIn` and
`forceOptIn` hit `NotOptedOut` for the mirror reason. Every batch is all-or-nothing, so a
duplicate reverts the call rather than applying twice.

**The registry call inside `_optOut`'s loop is not a reentrancy vector.** `gaugeRegistry` is
owner-settable, so it *can* be repointed at an untrusted callee — the protection is that
`IGaugeRegistry.isRegisteredGauge` is declared `view`, so solc emits `STATICCALL` and any
reentrant mutation reverts on its first `SSTORE`. The same holds for the `vlCVX` view calls and
for all three vote sources. **This rests on the interface declaration**: dropping `view` from
`isRegisteredGauge` would silently remove it. There is also no state the contract reads after
an external call that it did not already write.

## How the guarantee is tested

The claim that carries everything — *a settled epoch's answer never changes* — is not provable
by inspection, so it is pinned by a Foundry stateful campaign (`test/foundry/`). Foundry generates
its own call sequences, so it reaches orderings nobody wrote down, and shrinks a failure to a
minimal reproduction. Its invariants cover settled immutability, count-equals-list,
cursor-equals-list, membership bookkeeping, history well-formedness, checkpoint ordering and
ghost agreement, and the handler predicts the outcome of every action, so a guard firing when it
should not, or failing to fire, is a failure rather than something absorbed silently.

Two Foundry behaviours shaped that suite and are worth knowing before extending it. State
written by an `invariant_` function is discarded, so a ghost accumulated there re-initialises on
every evaluation and silently compares nothing — the frozen-answer record therefore lives in the
handler, whose state does persist across a run. And a coverage assertion fits in neither place:
in an `invariant_` function it is evaluated after every call and fires on the first no-op, and in
`afterInvariant` it is defeated by shrinking, which minimises to a sequence that trivially
satisfies it. `HandlerSanity` pins coverage directly instead.

### Casts

Epoch numbers are stored as `uint32` and cast on write. Overflow would take roughly 82 million
years of weekly epochs, and `ACTIVE` — `type(uint32).max` — only becomes ambiguous at the same
horizon. Foundry's linter flags these casts; they are left unguarded deliberately rather than
spending a check on an unreachable condition.

## Rationale moved out of the contract

The contract's comments describe what each function is for and when not to use it. The reasoning
behind the design lives here instead. Points that used to sit in NatSpec and are worth keeping:

**Why the list reads have no size or gas limit.** Cost per member scanned is not constant: it
is a binary search over that member's own interval history, measured at +2,028 gas per doubling
of their interval count — 7,914 at one interval, 18,054 at thirty-two. Two gauges with equal
member counts can cost very different amounts to read, so a member-count ceiling cannot bound
the work, and any fixed value is wrong for one of them.

Two guards were tried and both removed. A member ceiling was predictable but refused gauges a
caller's RPC could have served. An in-loop gas budget adapted to the real cost but rejected
reads inside the caller's own limit, varied with how much gas they supplied, added an error and
a mutable counter to the hot loop, and shipped a bug of its own by measuring gas remaining
instead of gas spent.

Both bought the same thing: a named revert instead of an out-of-gas. That is a distinction
without a difference — either way the caller's next move is the cursor, and a consumer that
treats either as an empty list is broken regardless. What separates "no exclusions" from "the
read failed" is `optOutCountAtEpoch`, which is O(log n), has no size limit, and cannot fail on a
gauge the list read chokes on.

**Why the cursor is safe to walk across transactions at a settled epoch.** Entries are only
appended, except by `_pruneMember`, which can only remove a member whose single interval is still
pending. `_gaugeMembers` is ordered by the window in which each entry registered, and swap-and-pop
preserves that ordering because the removed index and the tail replacing it both belong to the
current window. So a prunable member registered in the current window, the tail swapped into its
slot did too, that entry's earliest interval starts at the pending epoch, and stepping over it
cannot lose a settled-epoch result.

**Why `list.length == optOutCountAtEpoch()` is not a meaningful test.** `optOutAtEpoch` sizes its
array from the count and reverts `CountMismatch` unless they agree, so the equality holds by
construction and can only fail by reverting. The accounting has to be checked against an
independently derived count, which is what the Foundry ghost does.

## Retirement: why `renounceOwnership` stays callable

`renounceOwnership` is inherited from OpenZeppelin `Ownable` and left callable on purpose. It is
the retirement mechanism rather than a loose end.

An instance that is superseded should not merely be abandoned. Left with a live owner it is an
attractive nuisance: a stale address that still accepts writes, which a user or an agent can
find and use in good faith while the real accounting has moved elsewhere. Pausing new opt-outs
and then renouncing closes that off permanently, and the resulting contract is exactly what a
retired one should be — every historical epoch still readable, so already-published reward
calculations stay reproducible; `optIn` still available, since it needs neither owner nor
registry, so nobody is stranded holding an exclusion; and `optOut` refusing with a named error
that says why.

Renouncing freezes the floor, the registry and the pause flag wherever they stand, and disables
`forceOptIn`. For a retired instance none of that is a loss. It should be done in that order —
pause first, then renounce — so the refusal a later caller meets is `OptOutsArePaused` rather
than an opaque balance or registry error.
