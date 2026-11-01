# Deployment record

Two instances, one per Convex gauge registry, deployed on Ethereum mainnet on 2026-10-08 in
vlCVX epoch 240. Both are exact matches on Sourcify.

Read [Irreversible](#irreversible) before changing anything.

## Instances

| | Curve | f(x) |
| --- | --- | --- |
| Address | `0x5A5c248B39702E1A35bB854858B4Ae729D9c4405` | `0x42dC5034C0699e98e2e5c0106B913c42810a618e` |
| Deploy transaction | `0xb106168a8665279e034fa286f61ac6f095a4af0cab4e1873ee941b3529d241fb` | `0xd348a129e9bf8c8e986917e9b6cb6687522333cde5cd25c0f5001730181d84f5` |
| Block | 26150305 | 26150336 |
| `name()` | `vlCVX Curve opt-out registry` | `vlCVX FX opt-out registry` |

Constructor arguments, decoded from the deploy transactions:

| Argument | Curve | f(x) |
| --- | --- | --- |
| `_name` | `vlCVX Curve opt-out registry` | `vlCVX FX opt-out registry` |
| `_owner` | `0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D` | `0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D` |
| `_vlCVX` | `0x72a19342e8F1838460eBFCCEf09F6585e32db86E` | `0x72a19342e8F1838460eBFCCEf09F6585e32db86E` |
| `_gaugeRegistry` | `0x96b24E0534B0cA31D8523D4be4904747Fd579D95` | `0xC2F99261d84D1665Df7e50F46813497A737AfB20` |
| `_minOptOutBalance` | `100e18` | `100e18` |

The deploying EOA was the first owner. Ownership is two-step (`Ownable2Step`), so any transfer shows as
`OwnershipTransferStarted` and completes only when the new owner calls `acceptOwnership`. On 2026-10-29
both instances moved to Votium's multisig, `0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3`:

| | Curve | f(x) |
| --- | --- | --- |
| `transferOwnership`, from the EOA | `0x13d9eba81fb1410373240db48144bbfe3d18b901f6c7fb310225347f1f7e02c0` (block 26297523) | `0xb69d7c1b743d882c1ff78a42070988dfa32fb7fc626001142c998b39c872e8ea` (block 26297525) |
| `acceptOwnership`, from the multisig (one transaction for both) | `0xfc84a33c669d7b3897e1ac68f11510b5b97086bc7a2c360f5e9d46ee9b30975d` (block 26299185) | the same |

## Addresses the instances depend on

| | Address |
| --- | --- |
| vlCVX (`CvxLockerV2`) | `0x72a19342e8F1838460eBFCCEf09F6585e32db86E` |
| Curve gauge registry | `0x96b24E0534B0cA31D8523D4be4904747Fd579D95` |
| f(x) gauge registry | `0xC2F99261d84D1665Df7e50F46813497A737AfB20` |
| Curve vote platform | `0x64D9B5AC386B70af9EDCD20A58cE9262D2EAC278` |
| f(x) vote platform | `0xDcEa673B021f1f431E7D0Ec70a63bF8DcB6d44E6` |
| Vote helper | `0x76C484F67898EA978aa874dc7B32e648380FB9b1` |
| Delegation registry | `0xb8270eef1319173dE9f5033FED442F638ff1607d` |

`firstProposalEpoch` is **230** on both platforms.

## Compiler settings

Anything building, verifying or redeploying this contract must match these exactly:

| | |
| --- | --- |
| solc | `0.8.28` |
| optimizer | enabled, **200 runs** |
| evmVersion | `cancun` |
| remappings | none |
| bytecodeHash | `ipfs` |

This is not cosmetic. Measured:

| Build | Runtime size | Against the 24,576 limit |
| --- | --- | --- |
| optimizer on, 200 runs | 15,672 | 8,904 under |
| optimizer off | 26,388 | **1,812 over** |

Unoptimized, the contract does not fit and cannot be deployed. A size warning in Remix or another
IDE means the optimizer is off, which is Remix's default.

Different settings also produce different bytecode, so a build that does not match is not the
artifact that was tested and verified. To reproduce the deployed metadata hash from this folder,
build the contracts alone without Forge's automatic remappings:

```bash
FOUNDRY_AUTO_DETECT_REMAPPINGS=false forge build contracts --out verify-out --cache-path verify-cache
```

The resulting runtime bytecode matches both instances byte for byte outside their immutables.
The `integration` Foundry profile sets `via_ir` only to compile the reference contracts for the
fork tests; it has no bearing on the deployed contract.

## Configuration as deployed

Per instance, as read on-chain:

| Call | Value |
| --- | --- |
| `owner()` | `0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3` (Votium's multisig, since 2026-10-29; the deploying EOA before) |
| `pendingOwner()` | `0x0000000000000000000000000000000000000000` |
| `vlCVX()` | `0x72a1…` |
| `gaugeRegistry()` | the registry for this instance |
| `minOptOutBalance()` | `100e18` |
| `optOutsPaused()` | `false` |
| `deployEpoch()` | `240` |
| `votePlatform()` | the platform for this instance |
| `voteHelper()`, `delegation()` | as in the table above |
| `firstProposalEpoch()` | `230` |
| `maxVoteWeight()` | `1000000` |

The vote sources were set after deployment with `setVoteSources(platform, helper, delegation, 230)`.
The two calls differ in one 20-byte word, the platform; pairing an instance with the other
registry's platform is refused on-chain with `VoteSourcesMismatch`.

A live check: `optOutCountAtEpoch(anyListedGauge, currentEpoch())` returns a count rather than
reverting, and `withheldWeightAtEpoch(anyListedGauge, mostRecentEvenEpoch)` returns a weight
rather than reverting.

## Timing

**`deployEpoch` is a floor on what can be asked, not on what is known.** Epochs before 240 are
refused with `PreDeployEpoch`, but their true answer is that nobody was excluded: the registry did
not exist for anyone to opt out in.

**Parity decides how soon an instance becomes useful.** An opt-out made during epoch `N` takes
effect at `N + 1`, and proposals run on even epochs. Both instances were deployed in epoch 240
(even), so the first effective epoch was 241, which carries no proposal, and the first vote that
could carry exclusions was epoch 242 (proposal 6). A redeployment in an odd epoch reaches a usable
state one epoch sooner.

## Irreversible

- `name`, `vlCVX`, `epoch0Date`, `deployEpoch`: immutable.
- `owner`: changes only through the two-step transfer, or `renounceOwnership()`. The owner can
  `forceOptOut` arbitrary addresses, so the multisig's signers are the protection.
- `renounceOwnership()`: see below.
- A deployed instance cannot be un-deployed. An abandoned one stays live and indistinguishable
  from the real one to anyone reading events, which is why the retirement procedure exists.

Reversible: `gaugeRegistry`, `minOptOutBalance`, `optOutsPaused`, and everything
`setVoteSources` writes. Moving an instance to a different gauge registry clears its vote
sources, which then have to be set again.

## Retiring an instance

Pause first, then renounce:

```
setOptOutsPaused(true)
renounceOwnership()
```

That order matters. Pausing first means a later caller meets `OptOutsArePaused`, which says what
happened; renouncing first loses the ability to set the flag and leaves a less legible refusal.
The result is what a superseded instance should be: every historical epoch still readable,
`optIn` still available since it needs neither owner nor registry, and `optOut` refusing by name.

It cannot be undone, and it is available to whoever holds the owner key.

## Known failure modes

| Symptom | Cause | Action |
| --- | --- | --- |
| `EpochDerivationMismatch` at deploy | Locker not checkpointed across a week boundary | Call `vlCVX.checkpointEpoch()` first, then deploy |
| `VoteSourcesMismatch` | Platform paired with the wrong registry, or a helper built against a different delegation registry | Check the arguments against the instance |
| `NoProposalForEpoch` from a withheld-weight read | No proposal at that epoch, or the schedule has drifted more than `PROPOSAL_SEARCH_WINDOW` (8) ids | Confirm the epoch carries a proposal |
| `VoteSourcesNotSet` | `setVoteSources` has not been called, or was cleared by a registry move | Send the transaction |
