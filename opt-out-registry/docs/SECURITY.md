# OptOutRegistry — security review

Reviewed: `contracts/OptOutRegistry.sol` at 15,672 bytes runtime (8,904 under the EIP-170 limit).
Static analysis by Slither 0.11.3 against solc 0.8.28, plus the manual analysis below.

## What is at stake

The registry holds no funds and has no token. What it holds is an **answer**: the list of
addresses whose votes Votium should exclude when distributing incentives for a gauge in a given
epoch. A wrong answer misdirects real money. So the threat model is about corrupting, censoring
or denying that answer, not about draining a balance.

Three failure classes, in descending order of severity:

1. A settled epoch's answer changes, or is wrong. Reward calculations already published stop
   reproducing.
2. The answer becomes unreadable, so a calculator cannot get it at all.
3. Someone is excluded who did not ask to be, or is not excluded when they asked to be.

## Reentrancy: structurally impossible

The contract makes exactly **one** non-static external call anywhere in its surface:

| Call site | Callee | Opcode |
| --- | --- | --- |
| `optOut` → `balanceAtEpochOf` | vlCVX | `STATICCALL` |
| `_optOut` → `isRegisteredGauge` (in loop) | gauge registry | `STATICCALL` |
| `setVoteSources` → `delegation`, `gaugeRegistry`, `proposalCount`, `proposals`, `max_weight` | platform and helper | `STATICCALL` |
| `_proposalIdFor` → `proposalCount`, `proposals` | gauge-vote platform | `STATICCALL` |
| `_setGaugeRegistry` → `isRegisteredGauge` | candidate registry | `STATICCALL` |
| `_voteShare` → `getVote` (in loop) | gauge-vote platform | `STATICCALL` |
| `_delegatedWeight` → `getDelegateAtEpoch` (in loop) | delegation registry | `STATICCALL` |
| `_delegateShare` → `getContributingWeights` (in loop) | vote helper | `STATICCALL` |
| `epochCount()` view | vlCVX | `STATICCALL` |
| `_ensureEpochCheckpointed` → `checkpointEpoch` | vlCVX | `CALL` |

Every `view` call on an interface compiles to `STATICCALL`, which cannot mutate state and so
cannot reenter meaningfully — this covers the call that sits *inside* a loop interleaved with
storage writes, which would otherwise be the exposure. The single `CALL` targets an immutable
address and executes in `optOut` before any of this contract's storage is *written* — only
`optOutsPaused` is read ahead of it.

The three vote-source calls are confined to `withheldWeightAtEpoch` and
`withheldWeightForUsers`. Both are `view`, all three calls are `STATICCALL`, and no other
function in the contract touches those addresses — so a compromised or broken platform, helper
or delegation registry can return a wrong withheld figure, but cannot corrupt an exclusion
record, alter a settled epoch, or block anyone from opting in or out.

**Every path that can *end* an exclusion makes no external call at all.** `optIn`,
`forceOptIn` and `forceOptInUsers` need only the epoch number, which is derived arithmetically,
so nobody can be trapped in an exclusion by a locker that stops working, a registry that
misbehaves, or an owner that vanishes.

`forceOptOut` is **not** in that set: it goes through `_optOut` and consults the registry like
the public path does, so a broken or hostile registry blocks it. That is a liveness limit on a
rescue path, not a safety one — nothing is stranded by it, since the exits stay open.

`gaugeRegistry` is owner-settable rather than immutable, so the `STATICCALL` target is only as
trustworthy as the owner. It is still a `STATICCALL` — `isRegisteredGauge` is `view` in the
interface, so a hostile registry cannot mutate state or reenter. What it could do is refuse
every gauge, accept arbitrary addresses as gauges, or burn the caller's gas. The first two are
owner powers either way (the owner can already pause new opt-outs outright, and could raise
`minOptOutBalance` to block them), and none of them reaches a settled epoch's answer, since no
read consults a registry.

`optIn` makes **no external calls at all**. The exit path therefore cannot be affected by
anything outside this contract — which also means it keeps working if vlCVX ever stops being
maintained.

## Trust assumptions

**vlCVX (`0x72a1…`, immutable).** Source of epoch numbering and voting power. A dishonest locker
could report balances that let anyone opt out, or block everyone. It is Convex's deployed
`CvxLockerV2` and is not upgradeable. The constructor additionally asserts that the arithmetic
epoch derivation agrees with the locker's own `findEpochId`, so a locker whose epochs were not
uniform would fail deployment rather than silently mis-number.

**The gauge registry (`0x96b2…` / `0xC2F9…`, owner-settable), owned by `0xCC07e8BA…` — Convex
core.**
Not the owner of these instances, but **not a new trust party either**: this is the same domain already
relied on for vlCVX's epoch numbering and balances. Gauge listing and the locker are both
Convex's, so the registry adds no counterparty beyond the one the design already depends on.

Convex core can `forceRemove` a gauge, which makes `isRegisteredGauge` return false and blocks
*new* opt-outs on it. Existing opt-outs are unaffected and `optIn` never consults the registry,
so nobody is trapped.

## Owner powers

The owner of both instances is Votium's multisig, `0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3`.
It accepted ownership on 2026-10-29 from `0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D`, the EOA
that deployed them (the transactions are in `DEPLOYMENT.md`). **It controls the exclusion set
outright**, and the guarantee that survives is about *time*, not authority: no owner action can
change an epoch once that epoch has begun.

This is a deliberate widening. Earlier versions gated `forceOptIn` on the target holding zero
voting power, which made "the owner cannot create or remove an exclusion for an active voter" a
real property. It was given up because it left holders unreachable: a protocol whose vlCVX sits
in a treasury contract with no generic execute function can never call `optOut` or `optIn`
itself, and no on-chain check for "who controls that contract" works across treasuries that
share no convention. The honest framing of what was traded is below.

| Power | Reach |
| --- | --- |
| `setMinOptOutBalance` | Set it to `type(uint256).max` and no new opt-out can ever be added. The strongest power the owner has. Reversible **only while the owner still exists** — see below |
| `forceOptIn` | Ends any address's exclusion on any gauge, from the next epoch. No balance, registry or pause condition |
| `forceOptOut` | Begins any address's exclusion, from the next epoch. Ignores `minOptOutBalance` and `optOutsPaused`, but the gauge must still be listed by the registry |
| `forceOptInUsers` | The index-aligned form of `forceOptIn`, for several holders at once. Same reach |
| `setOptOutsPaused` | Stops new opt-outs outright. Reaches nothing else: `optIn`, `forceOptIn` and every read stay live, and existing opt-outs stay in effect. A blunter, clearly-labelled form of the floor knob above, and reversible on the same terms |
| `setGaugeRegistry` | Decides which gauges a new opt-out may name. The owner can refuse every gauge by pointing at an empty registry, or accept arbitrary addresses by pointing at a permissive one. It cannot reach a past epoch, because no read consults a registry. The address is probed, so it cannot be set to something that fails to answer |
| `setVoteSources` | Chooses the contracts the withheld-weight views read. A hostile platform or helper can return any weight, so those two views are only as trustworthy as the owner. They are **additive**: nothing else in this contract reads them, and no exclusion record depends on them |
| `renounceOwnership` | Permanently freezes the floor, the registry, the pause flag and the vote sources, and disables `forceOptOut`, `forceOptIn` and `forceOptInUsers`. Deliberately left callable: paired with `setOptOutsPaused(true)` it is how a superseded instance is retired |

The owner **cannot** alter a settled epoch's answer, prevent a holder who *can* transact from
opting back in, or change which vlCVX the instance reads. Everything it does lands at the next
epoch and is announced by a distinct event — `ForceOptedOut` and `ForceOptedIn` are never
emitted by the public path, so an indexer can separate what the owner did from what holders
did, and any exclusion the owner manufactures is visible before it takes effect.

Why this costs less than it appears: **Votium computes the reward distribution regardless.**
The registry is an input to that calculation, not a constraint on it. An operator willing to
exclude a voter never needed this contract's cooperation. What the registry provides is a
public, auditable, reproducible record — and that survives intact, because settled epochs are
immutable and every change is evented.

The residual risk is real and worth stating: downstream protocols that forward Votium rewards
consume this registry and inherit the trust. A compromised owner key can exclude a large voter
from next epoch onward, and those consumers would honour it. Detection is the mitigation —
the event is public and the effect is one epoch away.

The registry is the one exception to "cannot change what it reads", and it is bounded: it gates
entry only. A hostile registry can stop new opt-outs or let junk addresses in to bloat a
gauge's scan list — both already reachable through `setMinOptOutBalance` — but it cannot alter
what any settled epoch reports, because the read path never asks a registry anything.

**Permanent bricking of the add path is intended, and is how this contract is retired.** Pausing
and then renouncing ownership closes it for good: no new opt-out can ever be added, and no owner
remains to reopen it. That is the desired end state once an instance is superseded. Historical
reads keep working forever, so already-published reward calculations stay reproducible, while a
user or an agent that finds a stale reference is turned away by a named error instead of
quietly writing to an abandoned contract. Exits stay open too — `optIn` needs no owner and no
registry, so nobody is left holding an exclusion they cannot withdraw.

`setOptOutsPaused(true)` is the instrument for that, rather than `setMinOptOutBalance(max)`,
which reaches the same state by a less legible route: a caller sees
`InsufficientBalance(0, 2^256-1)`, which reads as a problem with their own balance, where
`OptOutsArePaused` says what actually happened. Renouncing while pointed at a dead registry is a
third route to the same place and the least legible of all, since every gauge simply reports
`GaugeNotRegistered`.

The security content is that these are all **one-way**, and available to whoever holds the
owner key — a compromised key can retire a live instance, and no one can undo it. The
mitigation is the key, not the contract. What such an attacker still cannot do is alter or erase
a settled epoch's answer, or prevent anyone from opting back in.

Separately, setting the floor *downward* is not reversible in effect — dust-funded addresses can
bloat a gauge's scan list, and raising the floor afterwards evicts nothing.

Keeping `renounceOwnership` callable is deliberate, and retirement is its purpose rather than a
side effect — see **Retirement** in `docs/DESIGN.md`. The order matters: pause, then renounce.

## Economic and ordering properties

**No retroactive exclusion.** Every mutation takes effect at the next epoch, so nobody can opt
out of an epoch after seeing how it turned out, and equally nobody can opt back in to claim
rewards for an epoch they spent excluded. This is the property that makes the registry usable as
a commitment.

**De-registering a killed gauge is permissionless, and that is not a grief vector.**
`setGauge(address)` has no access control, and `_setGauge` de-registers any gauge whose
`isValidGauge` is false — of 707 registered Curve gauges, 7 are currently killed and so
removable by anyone. Since `optOut` reverts the whole batch on an unregistered gauge, this looks
at first like a front-running vector against a batch containing one.

It is not, because a killed gauge cannot receive votes. There is no vote to exclude, so no
reason to opt out of it, and no reason for a reward calculator to read its list either. The only
caller a permissionless removal can inconvenience is one already asking for something without
purpose, and the revert tells them so. Anyone re-listing a gauge the DAO later un-kills is doing
the registry a favour on the same permissionless path.

Balances cannot be drained or reduced by a third party, so nobody can invalidate another user's
existing opt-out.

**Epoch-boundary risk is reorg and inclusion, not timestamp choice.** An earlier version of this
document said a proposer "can shift `block.timestamp` by seconds". That is a pre-merge model and
is wrong: post-merge, block timestamps are slot-derived and validated, not chosen by the
proposer. The real boundary exposure is that a transaction in the last block of epoch E-1 can be
reorged into epoch E, flipping which epoch it takes effect at, and that a proposer can delay
inclusion across a boundary by omitting it. Neither yields the actor a gain — the sender chose to
submit at the boundary — but a consumer should read settled epochs at a finalized block. Slither
flags the timestamp comparisons; weekly epochs make them inherent.

## Griefing

Covered in depth under **Scan-list growth** in the README. In short: an address that stays
genuinely opted out for at least one real epoch becomes a permanent entry in that gauge's scan
list. This is by design — it is what makes a settled epoch's answer reproducible. An opt-out
withdrawn before it takes effect cleans itself up and costs nothing.

Two corrections to earlier drafts. First, the per-member read cost of ~7.9k is **not constant**:
it is a binary search over that member's own interval history and rises to ~18.1k at
thirty-two intervals, so two gauges of equal size can cost very different amounts to read. The
contract imposes no ceiling on a whole-list read: a member-count limit and an in-loop gas budget
were both tried and removed, since neither could bound the actual work for that reason, and both
refused reads an RPC would have served. `optOutCountAtEpoch` is what tells a consumer "no
exclusions" from "the read failed", and it has no size limit.

For an **off-chain** caller a named revert and an out-of-gas do mean the same thing — use the
cursor. For an on-chain caller they do not: EIP-150 leaves an out-of-gas consuming 63/64 of the
gas forwarded, so an uncapped `optOutAtEpoch` inside a loop over gauges fails the whole
transaction instead of falling through to the cursor. Such callers must cap the sub-call, which
the NatSpec now says.

Second, `minOptOutBalance` is a **capital-lockup requirement, not a cost**: it is recoverable in
full after 16 weeks and earns rewards throughout, so for any entity that already locks vlCVX the
marginal cost is gas alone. It is also charged per *address*, not per entry — one funded address
can take a permanent slot on every gauge in a single transaction. Multiplying the floor by a
target entry count is correct arithmetic but overstates the economic barrier; the broad attack
is bounded by gas, not by that floor. The figure is also denominated in *boosted*
vlCVX, a unit Convex's multisig can change via `setBoost` (bounded at 3x).

## The most likely real-world failure is on the consumer side

Nothing above is as likely to cause a loss as a calculator integrating carelessly.

1. **`optOutAtEpoch` has no size limit and runs out of gas on a large gauge.** A consumer that
   treats that failure as "no exclusions" would pay rewards to voters who asked to be excluded.
   Check `optOutCountAtEpoch`, and fall back to `optOutAtEpochFrom`.
2. **Query settled epochs, not the pending one.** At `currentEpoch + 1` a cursor walk can return
   the right *length* with the wrong *set*, because mutations land there while the walk is in
   flight, and the count cross-check will not catch it. Settled epochs are immune; this is proven
   by test and argued in `DESIGN.md`.
3. **Validate the walk.** Compare the concatenated length against `optOutCountAtEpoch`.
4. **`epochCount()` is not a query bound.** Use `maxQueryableEpoch()`.

## Static analysis triage

Slither reported 95 results, no high severity. Triaged:

| Finding | Assessment |
| --- | --- |
| `_countHistory` never initialized | False positive. It is a mapping; mappings need no initialization |
| 5 × "dangerous strict equality" | False positives. Every one compares **epoch indices**, which are exact integers this contract assigns — not token balances. The detector targets `balanceOf(x) == n` patterns. `balance == 0` is a deliberate extra guard so a zero balance is rejected even when the floor is zero |
| 8 × "uninitialized local variable" | False positives. `lo`, `filled`, `size`, `contributedTotal` and friends rely on Solidity's zero default, which is the intent |
| Unused return on `epochs(0)`, `proposals(id)`, `getVote` | Deliberate. Each is a destructuring that takes the fields needed and discards the rest; there is no call whose failure is being swallowed |
| "External calls inside a loop" in the withheld-weight path | Inherent, and the reason those reads come in two forms. `getVote`, `getDelegateAtEpoch` and `getContributingWeights` are per-address or per-delegate by nature. All are `STATICCALL` from `view` functions, so there is no reentrancy surface; the cost is the caller's, and `withheldWeightForUsers` exists so it can be bounded |
| "External calls inside a loop" in `_optOut` | The registry check, one per gauge in a batch. `STATICCALL`, and the loop writes only this contract's storage |
| 3 × inline assembly | `mstore(arr, filled)` to shrink an over-allocated memory array. `filled` is incremented at most once per loop iteration over the allocated range, so it only ever shrinks. Standard idiom |
| Dead code in `Context.sol` | Vendored OpenZeppelin, left unmodified on purpose |
| Naming convention `_gauge` etc. | Matches Votium's house style |
| `block.timestamp` comparisons | See **Economic and ordering properties** above |
| Low-level call in `_setGaugeRegistry` | Deliberate. A `staticcall` is the only way to ask an unknown address whether it answers `isRegisteredGauge` without reverting on one that does not. It is `staticcall`, so it cannot mutate state or reenter, and the result is checked for both success and a 32-byte return before the address is accepted |
| `_owner` shadows `Ownable._owner` | Constructor parameter against a private inherited variable. No solc warning, no ambiguity at the use site; left as-is rather than churn a name that appears in the ABI |
| Pragma allows versions with known bugs | Actionable; fixed — see below |

### The one actionable static finding — resolved

`pragma solidity ^0.8.20` admitted 0.8.20, which carries `VerbatimInvalidDeduplication`,
`FullInlinerNonExpressionSplitArgumentEvaluationOrder` and `MissingSideEffectsOnSelectorAccess`.
All three are fixed by 0.8.23 and the build pins 0.8.28, so the deployed bytecode was
never affected; the exposure was only that someone recompiling from source with an older
permitted compiler would be.

`OptOutRegistry.sol`, `IGaugeRegistry.sol`, `IvlCVX.sol` and `IVoteSources.sol` declare `pragma solidity
0.8.28;` exactly, matching the pinned build. That also resolves the separate "two pragma
versions" finding, which came from `IvlCVX.sol` still carrying `^0.8.13` inherited from the
reference copy.

The three vendored OpenZeppelin files under `contracts/dependencies/` keep their original
`^0.8.20` and are the only remaining source of this warning. They are left byte-identical to
upstream on purpose: editing a vendored dependency to silence a lint costs more in auditability
than the lint is worth, and the contracts compile at 0.8.28 regardless.

## Independent audit

Four agents audited this in parallel, each given the contract and told to treat its comments as
unverified claims rather than evidence. None received this document's conclusions, to avoid
getting them handed back.

**No exploitable contract defect was found**, and the state machine was attacked hard: exhaustive
enumeration of every action sequence to the configured depth, storage-level
verification of the packed `_memberSlots` indices in both directions across 18,000 mutations, and
live-fork testing of every dependency assumption. Settled-epoch immutability, the count/list
accounting, membership bookkeeping, and pagination-under-prune all held.

Findings that changed this document or the code are folded in above.

**Resolved since: anyone could block `forceOptIn` on an address for ~1 wei.**
`vlCVX.lock(address _account, …)` credits an arbitrary account, so a third party could donate a
dust lock to a powerless address, push `balanceAtEpochOf` off zero and defeat the `!= 0` gate
for 16 epochs, renewably. Reproduced on a fork, and accepted at the time. Removing the balance
gate removed the vector with it — there is no longer a condition on the target to grief.

One further trust issue is **accepted, not fixed**:

**The gauge registry owner can irreversibly block opting out of a gauge.** `forceRemove` is
owner-only and `_setGauge` refuses to re-add a force-removed gauge, so no permissionless path
undoes it. One auditor suggested `0xcc07E8Ba…` might be the Votium operator, which would have
put that switch in the hands of the party running reward distribution. **It is Convex core** —
the same trust domain as vlCVX itself, so this adds no counterparty the design did not already
depend on. Recorded because the auditor's reading was wrong and someone else may reach for it.

**Not covered here:** there is no migration path if vlCVX V2 is ever superseded. `vlCVX` is
immutable with no setter — the gauge registry and the vote sources can be repointed, the locker
cannot. After a shutdown, balances decay to zero within 16 epochs and `optOut` becomes
permanently uncallable while existing opt-outs stand forever. Redeploy is the answer, and
consumers would need to be pointed at the new instance.

## Summary

No high-severity issues, and the four independent agent reviews found no exploitable contract
defect. No
reentrancy exposure, by construction rather than by guard. The owner can deny new opt-outs —
permanently, by pausing and then renouncing, which is also the intended way to retire a
superseded instance — but cannot corrupt or forge an answer, cannot alter a settled epoch, and
cannot stop anyone opting back in.

The external trust surface is narrower than it first appears: both the locker and the gauge
registries are Convex's, so the only counterparties are Convex and the owner of these
instances. The most likely path to real loss is not a contract defect at all but a consumer
mishandling a failed list read — any of them means "use the cursor", never "nobody opted out" — or reading the pending epoch.
