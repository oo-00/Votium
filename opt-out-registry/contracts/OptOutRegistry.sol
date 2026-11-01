// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IvlCVX.sol";
import "./interfaces/IGaugeRegistry.sol";
import "./interfaces/IVoteSources.sol";
import "./dependencies/Ownable2Step.sol";

/// @title OptOutRegistry
/// @notice Lets a vlCVX holder exclude their own vote on a gauge from that gauge's Votium
///         reward distribution, and lets reward calculators read who is excluded.
///
///         Epoch numbers are vlCVX epoch indices. Every change takes effect at the *next*
///         epoch and never retroactively, so an epoch's answer is fixed once that epoch
///         begins. An opt-out does not expire; it stands until the holder opts back in.
///
///         To read the exclusion list for a gauge: `optOutCountAtEpoch` for how many,
///         `optOutAtEpoch` for the list itself, or `optOutAtEpochFrom` when the list is too
///         large to return at once. Query settled epochs — at `currentEpoch() + 1` the answer
///         is still changing.
///
///         `withheldWeightAtEpoch` turns that list into the number a reward calculation
///         needs: how much vlCVX weight to withhold from a gauge, counting both an excluded
///         holder's own vote and the weight its delegate carried for it.
///         `withheldWeightForUsers` does the same over a slice, for gauges too large to read
///         at once. Both read a gauge-vote platform and revert until the owner has pointed
///         them at one; nothing else here depends on those contracts.
///
///         One instance exists per CVX gauge registry, and a gauge is only usable on the
///         instance whose registry lists it. The owner may repoint an instance at a
///         replacement registry, which changes only which gauges a new opt-out may name.
///           Curve  0x96b24E0534B0cA31D8523D4be4904747Fd579D95
///           f(x)   0xC2F99261d84D1665Df7e50F46813497A737AfB20
contract OptOutRegistry is Ownable2Step {
    /// @notice Value of `Membership.endEpoch` while an opt-out is still open.
    uint32 public constant ACTIVE = type(uint32).max;

    /// @dev Low half of a `_memberSlots` entry.
    uint256 private constant INDEX_MASK = type(uint128).max;

    /// @notice How far either side of the derived id a proposal may be searched for.
    /// @dev Covers a schedule shifted by force-ended or skipped proposals. Only reached when
    ///      the derived id does not already report the epoch asked for.
    uint256 public constant PROPOSAL_SEARCH_WINDOW = 8;

    /// @notice Length of a vlCVX epoch.
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice A period `[startEpoch, endEpoch)` during which a user was opted out of a gauge.
    /// @dev `endEpoch == ACTIVE` while still open. Every stored interval covers at least one
    ///      epoch; one withdrawn before it took effect is discarded, not recorded.
    struct Membership {
        uint32 startEpoch;
        uint32 endEpoch;
    }

    /// @notice Running member count for a gauge, recorded at the epoch it changed.
    struct CountCheckpoint {
        uint32 epoch;
        uint32 count;
    }

    /// @notice Label identifying this deployment.
    string public name;

    /// @notice The vlCVX locker this registry reads epochs and voting power from.
    IvlCVX public immutable vlCVX;

    /// @notice Earliest epoch these views will answer for. Queries below it revert
    ///         `PreDeployEpoch` rather than returning a misleading empty list.
    uint32 public immutable deployEpoch;

    /// @notice Timestamp of vlCVX epoch 0. Epoch `i` began at `epoch0Date + i * EPOCH_DURATION`.
    uint32 public immutable epoch0Date;

    /// @notice Minimum vlCVX balance required to add an opt-out, taken at the epoch the
    ///         opt-out takes effect.
    /// @dev Applies to `optOut` only. Raising it never invalidates an existing opt-out and
    ///      never prevents anyone from opting back in.
    uint256 public minOptOutBalance;

    /// @notice The gauge registry deciding which gauges this instance accepts.
    /// @dev Read by `optOut` and `forceOptOut`; every gauge must be listed to be excluded on.
    ///      Neither `optIn`, `forceOptIn` nor any view consults it, so no registry can trap
    ///      anyone in an exclusion.
    IGaugeRegistry public gaugeRegistry;

    /// @notice While true, no new opt-out may be added.
    /// @dev Gates `optOut` alone. `optIn`, `forceOptIn` and every view stay available, and
    ///      existing opt-outs stay in effect.
    bool public optOutsPaused;

    /// @notice The gauge-vote platform read by `withheldWeightAtEpoch`.
    /// @dev Unset until `setVoteSources` is called; the withheld-weight reads revert until it
    ///      is. Nothing else in this contract depends on it.
    IGaugeVotePlatform public votePlatform;

    /// @notice The epoch of proposal 0. Proposals run every other epoch from here.
    uint32 public firstProposalEpoch;

    /// @notice Helper resolving how much of a delegate's vote each delegator contributed.
    IGaugeVoteHelper public voteHelper;

    /// @notice The platform's `max_weight`, the scale gauge weights are expressed in.
    /// @dev Read from the platform when the sources are set rather than assumed.
    uint64 public maxVoteWeight;

    /// @notice The vlCVX delegation registry, read at the proposal's epoch.
    IDelegation public delegation;

    /// @notice gauge => user => the periods that user was opted out, oldest first.
    /// @dev Searched by epoch, so the order matters: starts strictly increasing, intervals
    ///      non-overlapping, and only the last one ever left open.
    mapping(address => mapping(address => Membership[])) internal _history;

    /// @notice gauge => user => packed 1-based positions in the two scan lists.
    /// @dev Low 128 bits index `_gaugeMembers[gauge]`, high 128 index `_userGauges[user]`.
    ///      Zero means not a member. Both lists are always joined and left together.
    mapping(address => mapping(address => uint256)) internal _memberSlots;

    /// @notice gauge => the users whose opt-out history must be scanned for it.
    /// @dev A user who was opted out at any epoch stays here permanently, so that epoch's
    ///      answer remains reproducible. Only an opt-out that never took effect is removed.
    mapping(address => address[]) internal _gaugeMembers;

    /// @notice user => every gauge they have ever opted out of. Same removal rule as above.
    mapping(address => address[]) internal _userGauges;

    /// @notice gauge => exclusion count over time, one checkpoint per epoch that changed.
    /// @dev Searched by epoch, so epochs are strictly increasing. A checkpoint always takes
    ///      its epoch from the same value as the intervals written beside it.
    mapping(address => CountCheckpoint[]) internal _countHistory;

    /// @notice A user's exclusion from a gauge begins at `effectiveEpoch`.
    event OptedOut(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);

    /// @notice A user ended their own exclusion from a gauge, from `effectiveEpoch` onward.
    event OptedIn(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);

    /// @notice The owner ended a user's exclusion from a gauge, from `effectiveEpoch` onward.
    event ForceOptedIn(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);

    /// @notice The owner began a user's exclusion from a gauge, from `effectiveEpoch` onward.
    event ForceOptedOut(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);

    /// @notice The minimum balance required to add an opt-out changed.
    event MinOptOutBalanceSet(uint256 minOptOutBalance);

    /// @notice The gauge registry consulted by `optOut` changed.
    /// @dev Also emitted once at deployment, so an indexer never has to special-case the
    ///      initial value.
    event GaugeRegistrySet(address indexed gaugeRegistry);

    /// @notice New opt-outs were paused or unpaused.
    event OptOutsPausedSet(bool paused);

    /// @notice The vote sources were dropped because the gauge registry moved out from under
    ///         them. The withheld-weight views refuse until they are set again.
    event VoteSourcesCleared();

    /// @notice The contracts read by the withheld-weight views changed.
    event VoteSourcesSet(
        address indexed votePlatform,
        address indexed voteHelper,
        address indexed delegation,
        uint32 firstProposalEpoch
    );

    /// @notice A user's exclusion was withdrawn before taking effect and left no record.
    /// @dev Emitted alongside the `OptedIn` or `ForceOptedIn` that withdrew it.
    event MemberPruned(address indexed gauge, address indexed user, uint32 indexed effectiveEpoch);

    // Reconstructing `membershipHistory` from events: an exclusion and a withdrawal sharing an
    // `effectiveEpoch` never covered an epoch, so nothing is stored for it — drop the pair. The
    // owner paths count too: pair `ForceOptedOut` with `OptedIn` or `ForceOptedIn` as well, and
    // a `MemberPruned` marks the pairs that left no record at all.

    /// @notice `forceOptIn` was given gauge and user arrays of different lengths.
    error ArrayLengthMismatch();

    /// @notice This instance's registry does not list `gauge`, so it cannot be opted out of.
    /// @dev Raised by `optOut` and `forceOptOut`. The paths that end an exclusion never
    ///      consult the registry.
    error GaugeNotRegistered(address gauge);

    /// @notice The caller already has an open opt-out on `gauge`, including earlier in this
    ///         same call if the gauge was listed twice.
    error AlreadyOptedOut(address gauge);

    /// @notice There is no open opt-out on `gauge` to end, for this caller or this user.
    error NotOptedOut(address gauge);

    /// @notice Not enough vlCVX at the epoch the opt-out would take effect.
    /// @dev A zero balance is rejected even when `required` is zero.
    error InsufficientBalance(uint256 balance, uint256 required);

    /// @notice The epoch asked for has not been reached. `maxEpoch` is the highest answerable.
    error FutureEpoch(uint256 epoch, uint256 maxEpoch);

    /// @notice The epoch asked for predates this registry, so it holds no answer for it.
    error PreDeployEpoch(uint256 epoch, uint256 deployEpoch);

    /// @notice A cursor call asked to examine zero entries, which would never make progress.
    error InvalidScanWidth();

    /// @notice Internal consistency check: a count was recorded out of epoch order.
    /// @dev Unreachable in normal operation. Reaching it means a stored invariant has broken.
    error NonMonotonicEpoch();

    /// @notice Internal consistency check: a gauge's count disagreed with its own list.
    /// @dev Unreachable in normal operation. Reaching it means a stored invariant has broken.
    error CountMismatch();

    /// @notice Deployment refused: this contract's epoch arithmetic disagrees with the locker.
    /// @dev Checked once, in the constructor, rather than assumed.
    error EpochDerivationMismatch(uint256 derived, uint256 reported);

    /// @notice The address offered as a gauge registry did not answer as one.
    /// @dev Checked in the constructor and again on every `setGaugeRegistry`.
    error InvalidGaugeRegistry(address gaugeRegistry);

    /// @notice New opt-outs are paused. Opting back in is unaffected.
    error OptOutsArePaused();

    /// @notice The vote-reading sources have not been configured on this instance.
    error VoteSourcesNotSet();

    /// @notice The epoch carries no proposal: proposals run on every other epoch, and this
    ///         one does not share parity with `firstProposalEpoch`.
    error OddEpoch(uint256 epoch);

    /// @notice No proposal covers this epoch: it precedes the first, or none exists yet.
    error NoProposalForEpoch(uint256 epoch);

    /// @notice A platform disagrees about which epoch a proposal covers.
    /// @dev Raised by `setVoteSources` when proposal 0 is not at the epoch given for it. The
    ///      read path does not use this; it refuses with `NoProposalForEpoch` instead.
    error ProposalEpochMismatch(uint256 proposalId, uint256 proposalEpoch, uint256 requestedEpoch);

    /// @notice A supplied address was not excluded from that gauge at that epoch.
    error NotExcluded(address gauge, address user);

    /// @notice A supplied address appeared twice, which would count its vote twice.
    error DuplicateUser(address user);

    /// @notice The helper or the platform was built against a different delegation registry.
    error VoteSourcesMismatch();

    /// @notice The platform reports a weight scale that is zero or too large to store.
    error InvalidVoteWeightScale(uint256 maxWeight);

    /// @param _name Label for this instance
    /// @param _owner Owner, able to call `forceOptOut`, `forceOptIn`, `forceOptInUsers`,
    ///               `setMinOptOutBalance`, `setGaugeRegistry`, `setOptOutsPaused` and
    ///               `setVoteSources`
    /// @param _vlCVX vlCVX locker, read for epoch numbering and voting power
    /// @param _gaugeRegistry Gauge registry that decides which gauges this instance accepts
    /// @param _minOptOutBalance Initial value of `minOptOutBalance`
    constructor(
        string memory _name,
        address _owner,
        address _vlCVX,
        address _gaugeRegistry,
        uint256 _minOptOutBalance
    ) Ownable(_owner) {
        name = _name;
        vlCVX = IvlCVX(_vlCVX);
        _setGaugeRegistry(_gaugeRegistry);

        (, uint32 _epoch0Date) = IvlCVX(_vlCVX).epochs(0);
        epoch0Date = _epoch0Date;

        // Every later read assumes evenly spaced epochs. Checked once, against the locker.
        uint256 derived = (block.timestamp - _epoch0Date) / EPOCH_DURATION;
        uint256 reported = IvlCVX(_vlCVX).findEpochId(block.timestamp);
        if (derived != reported) revert EpochDerivationMismatch(derived, reported);

        deployEpoch = uint32(derived);
        minOptOutBalance = _minOptOutBalance;
        emit MinOptOutBalanceSet(_minOptOutBalance);
    }

    /* ========== MUTATIVE ========== */

    /// @notice Opts the caller out of rewards on each listed gauge, from next epoch onward.
    /// @dev Requires a vlCVX balance that is both non-zero and at least `minOptOutBalance()`,
    ///      taken at the epoch the opt-out takes effect, so a zero balance is rejected even
    ///      when the floor is zero. A lock made earlier in the current epoch already counts.
    ///      Every gauge must be listed by this instance's registry.
    ///
    ///      All-or-nothing: an unlisted gauge, a duplicate, or one the caller is already
    ///      opted out of reverts the whole call. Check `isOptedOut` first to avoid that.
    ///      Reverts `OptOutsArePaused` while the owner has paused new opt-outs.
    /// @param _gauges Gauges to opt out of
    function optOut(address[] calldata _gauges) external {
        if (optOutsPaused) revert OptOutsArePaused();

        uint256 nextEpoch = _nextEpoch();
        _ensureEpochCheckpointed();

        uint256 balance = vlCVX.balanceAtEpochOf(nextEpoch, msg.sender);
        uint256 required = minOptOutBalance;
        if (balance == 0 || balance < required) revert InsufficientBalance(balance, required);

        uint256 len = _gauges.length;
        for (uint256 i; i < len;) {
            _optOut(_gauges[i], msg.sender, nextEpoch, false);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Ends the caller's opt-out on each listed gauge, from next epoch onward.
    /// @dev Never consults the gauge registry, so a gauge later killed or de-listed cannot trap
    ///      the caller. Always available regardless of balance or of `minOptOutBalance`.
    ///
    ///      All-or-nothing: a gauge the caller is not currently opted out of reverts the entire
    ///      call. Withdrawing an opt-out that has not yet taken effect discards it rather than
    ///      recording it, so it appears in no epoch and in no `membershipHistory`; the caller
    ///      also leaves the gauge's scan list entirely if that was their only opt-out on it.
    /// @param _gauges Gauges to opt back in to
    function optIn(address[] calldata _gauges) external {
        // No checkpoint: closing an opt-out reads no locker state, only the epoch number.
        uint256 nextEpoch = _nextEpoch();

        uint256 len = _gauges.length;
        for (uint256 i; i < len;) {
            _close(_gauges[i], msg.sender, nextEpoch, false);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Owner-only: opts one user out across several gauges, from next epoch onward.
    /// @dev For holders that cannot call `optOut` themselves — vlCVX locked in a contract with
    ///      no way to make the call. Ignores `minOptOutBalance` and `optOutsPaused`, but every
    ///      gauge must still be listed by this instance's registry.
    ///
    ///      All-or-nothing: an unlisted gauge, a duplicate, or one the user is already opted
    ///      out of reverts the whole call.
    /// @param _gauges Gauges to exclude the user on
    /// @param _user Address to exclude
    function forceOptOut(address[] calldata _gauges, address _user) external onlyOwner {
        // No checkpoint: no balance is read on this path.
        uint256 nextEpoch = _nextEpoch();

        uint256 len = _gauges.length;
        for (uint256 i; i < len;) {
            _optOut(_gauges[i], _user, nextEpoch, true);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Owner-only: ends one user's exclusion across several gauges, from next epoch on.
    /// @dev The counterpart to `forceOptOut`, for the same holders. Does not shorten a gauge's
    ///      list, since an address opted out at any past epoch stays readable at that epoch —
    ///      unless the exclusion never took effect, which is discarded as `optIn` discards it.
    ///
    ///      All-or-nothing: a gauge the user is not currently opted out of reverts the whole
    ///      call.
    /// @param _gauges Gauges to clear the user from
    /// @param _user Address to clear
    function forceOptIn(address[] calldata _gauges, address _user) external onlyOwner {
        // No checkpoint: closing an opt-out reads no locker state, only the epoch number.
        uint256 nextEpoch = _nextEpoch();

        uint256 len = _gauges.length;
        for (uint256 i; i < len;) {
            _close(_gauges[i], _user, nextEpoch, true);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Owner-only: ends exclusions for index-aligned gauge/user pairs.
    /// @dev For clearing several different holders in one transaction. Use `forceOptIn` when
    ///      acting for a single holder across several gauges, which is the common case.
    ///
    ///      Named apart from `forceOptIn` rather than overloading it: the owner is a multisig,
    ///      and two same-named entries in a transaction builder are easy to pick wrongly.
    ///
    ///      All-or-nothing, and index-aligned: `_gauges[i]` is cleared for `_users[i]`.
    /// @param _gauges Gauges to clear, index-aligned with `_users`
    /// @param _users Addresses to clear, index-aligned with `_gauges`
    function forceOptInUsers(address[] calldata _gauges, address[] calldata _users) external onlyOwner {
        uint256 len = _gauges.length;
        if (len != _users.length) revert ArrayLengthMismatch();

        uint256 nextEpoch = _nextEpoch();

        for (uint256 i; i < len;) {
            _close(_gauges[i], _users[i], nextEpoch, true);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Owner-only: replaces the gauge registry consulted when opting out.
    /// @dev Changes only which gauges a *new* opt-out may name. Existing opt-outs stand, every
    ///      past epoch reads unchanged, and `optIn` is unaffected. Reverts
    ///      `InvalidGaugeRegistry` unless the address answers `isRegisteredGauge`. The
    ///      instance's lists may then span both registries' gauges.
    ///
    ///      To stop new opt-outs without naming a replacement, use `setOptOutsPaused`.
    /// @param _gaugeRegistry The replacement registry
    function setGaugeRegistry(address _gaugeRegistry) external onlyOwner {
        _setGaugeRegistry(_gaugeRegistry);
    }

    /// @notice Owner-only: sets the contracts the withheld-weight views read.
    /// @dev Until this is called those two views revert `VoteSourcesNotSet`; nothing else in
    ///      this contract is affected. Three consistency checks run here rather than on every
    ///      read: the helper must be built against the same delegation registry, the platform
    ///      must agree that proposal 0 sits at `_firstProposalEpoch`, and the weight scale is
    ///      taken from the platform instead of being assumed.
    /// @param _votePlatform Gauge-vote platform
    /// @param _voteHelper Helper resolving delegator contributions
    /// @param _delegation vlCVX delegation registry
    /// @param _firstProposalEpoch vlCVX epoch of proposal 0
    function setVoteSources(
        address _votePlatform,
        address _voteHelper,
        address _delegation,
        uint32 _firstProposalEpoch
    ) external onlyOwner {
        // The helper reads delegations from its own instance while reading votes from the
        // platform passed to it, so all three have to agree on one delegation registry.
        if (IGaugeVoteHelper(_voteHelper).delegation() != _delegation) {
            revert VoteSourcesMismatch();
        }
        if (IGaugeVotePlatform(_votePlatform).delegation() != _delegation) {
            revert VoteSourcesMismatch();
        }
        // The two platforms share a delegation registry, a weight scale and a proposal
        // schedule, so every other check here passes on the wrong one. Only the gauge registry
        // tells them apart — and a crossed pairing holds votes for gauges this instance never
        // sees, so it answers zero for every gauge rather than failing.
        if (IGaugeVotePlatform(_votePlatform).gaugeRegistry() != address(gaugeRegistry)) {
            revert VoteSourcesMismatch();
        }
        if (IGaugeVotePlatform(_votePlatform).proposalCount() == 0) {
            revert NoProposalForEpoch(_firstProposalEpoch);
        }
        (,, uint48 epoch0) = IGaugeVotePlatform(_votePlatform).proposals(0);
        if (uint256(epoch0) != uint256(_firstProposalEpoch)) {
            revert ProposalEpochMismatch(0, uint256(epoch0), uint256(_firstProposalEpoch));
        }

        votePlatform = IGaugeVotePlatform(_votePlatform);
        voteHelper = IGaugeVoteHelper(_voteHelper);
        delegation = IDelegation(_delegation);
        firstProposalEpoch = _firstProposalEpoch;
        // Taken from the platform rather than assumed — but bounded, since zero would make
        // every read divide by zero and anything past uint64 would silently truncate to a
        // different scale.
        uint256 scale = IGaugeVotePlatform(_votePlatform).max_weight();
        if (scale == 0 || scale > type(uint64).max) revert InvalidVoteWeightScale(scale);
        maxVoteWeight = uint64(scale);

        emit VoteSourcesSet(_votePlatform, _voteHelper, _delegation, _firstProposalEpoch);
    }

    /// @notice Owner-only: pauses or unpauses the adding of new opt-outs.
    /// @dev `optOut` reverts `OptOutsArePaused` while set. `optIn`, `forceOptIn` and every
    ///      view keep working, and existing opt-outs stay in effect.
    /// @param _paused True to stop new opt-outs, false to allow them again
    function setOptOutsPaused(bool _paused) external onlyOwner {
        optOutsPaused = _paused;
        emit OptOutsPausedSet(_paused);
    }

    /// @notice Owner-only: sets the vlCVX balance required to add a new opt-out.
    /// @dev Affects future `optOut` calls only. Existing opt-outs stay valid and opting back in
    ///      is never blocked.
    /// @param _minOptOutBalance New minimum, in vlCVX
    function setMinOptOutBalance(uint256 _minOptOutBalance) external onlyOwner {
        minOptOutBalance = _minOptOutBalance;
        emit MinOptOutBalanceSet(_minOptOutBalance);
    }

    /* ========== GAUGE VIEWS ========== */

    /// @notice Whether a user's history is scanned when reading this gauge's exclusion list.
    /// @dev Not the same as "has ever called `optOut`": an opt-out withdrawn before it took
    ///      effect leaves no trace and reads false here.
    /// @param _gauge Gauge to query
    /// @param _user User to query
    /// @return True if the user is in the gauge's scan list
    function isGaugeMember(address _gauge, address _user) external view returns (bool) {
        return _memberSlots[_gauge][_user] != 0;
    }

    /// @notice How many addresses are excluded from a gauge at an epoch.
    /// @dev Cheap no matter how large the gauge's list is, and never reverts for size. Use it
    ///      to confirm a cursor walk returned everything, and to tell a genuinely empty list
    ///      apart from a read that failed.
    /// @param _gauge Gauge to query
    /// @param _epoch Epoch to query
    /// @return Number of addresses excluded at that epoch
    function optOutCountAtEpoch(address _gauge, uint256 _epoch) external view returns (uint256) {
        _validateEpoch(_epoch);
        return _countAt(_gauge, _epoch);
    }

    /// @notice Exclusion counts for several gauges at one epoch, in a single call.
    /// @dev For reward calculators iterating the whole registry to find which gauges have any
    ///      exclusions before fetching lists. The full Curve registry fits in one call. No
    ///      length limit is imposed — the caller sizes the array.
    /// @param _gauges Gauges to query
    /// @param _epoch Epoch to query
    /// @return counts Exclusion count per gauge, index-aligned with `_gauges`
    function optOutCountsAtEpoch(address[] calldata _gauges, uint256 _epoch)
        external
        view
        returns (uint256[] memory counts)
    {
        _validateEpoch(_epoch);

        uint256 len = _gauges.length;
        counts = new uint256[](len);
        for (uint256 i; i < len;) {
            counts[i] = _countAt(_gauges[i], _epoch);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice How many addresses are excluded from a gauge right now.
    /// @param _gauge Gauge to query
    /// @return Number of addresses excluded at the current epoch
    function optOutCount(address _gauge) external view returns (uint256) {
        return _countAt(_gauge, _currentEpoch());
    }

    /// @notice Addresses whose votes should be excluded from a gauge at an epoch.
    /// @dev For gauges small enough to return at once. No size limit: a large one runs out of
    ///      gas, sooner the longer its members' opt-out histories are. Check `gaugeMemberCount`
    ///      first if you need to choose.
    ///
    ///      **A failure means "use `optOutAtEpochFrom`", never "nobody opted out"** — otherwise
    ///      voters who asked to be excluded get paid. `optOutCountAtEpoch` tells the two apart:
    ///      it is O(log n) and cannot fail on a gauge this one chokes on.
    ///
    ///      From a contract, cap the sub-call: `optOutAtEpoch{gas: budget}(...)`. An
    ///      uncapped failure consumes 63/64 of the gas forwarded and takes the caller down
    ///      with it.
    ///
    ///      Query a settled epoch. At `currentEpoch() + 1` the answer is still changing.
    /// @param _gauge Gauge to query
    /// @param _epoch Epoch to query
    /// @return users Addresses excluded at that epoch
    function optOutAtEpoch(address _gauge, uint256 _epoch) external view returns (address[] memory users) {
        _validateEpoch(_epoch);
        return _excludedAt(_gauge, _epoch);
    }

    /// @notice One window of a gauge's exclusion list, for lists too large to return at once.
    /// @dev Call repeatedly, passing back `nextIndex`, until `done` is true.
    ///
    ///      **Loop on `done`, never on an empty result.** A window with no matches returns
    ///      empty with `done` still false; stopping there silently excludes nobody.
    ///      Concatenating every window reproduces `optOutAtEpoch`; check the total against
    ///      `optOutCountAtEpoch`.
    ///
    ///      Cost per call is independent of the gauge's total size — size the walk with
    ///      `gaugeMemberCount` — but not of `_maxScan`, and not flat per entry: a member with
    ///      a longer opt-out history costs more to scan. An over-large `_maxScan` runs out of
    ///      gas rather than reverting by name.
    ///
    ///      A walk may span transactions when `_epoch` is settled. At `currentEpoch() + 1` it
    ///      may not: changes land mid-walk, and the total can match the count while the set
    ///      is wrong.
    /// @param _gauge Gauge to query
    /// @param _epoch Epoch to query
    /// @param _startIndex Index to resume from; 0 to start
    /// @param _maxScan Maximum entries to examine in this call
    /// @return users Addresses found in this window; may be empty while more remain
    /// @return nextIndex Index to pass as `_startIndex` on the next call
    /// @return done True once the end of the list has been reached
    function optOutAtEpochFrom(address _gauge, uint256 _epoch, uint256 _startIndex, uint256 _maxScan)
        external
        view
        returns (address[] memory users, uint256 nextIndex, bool done)
    {
        _validateEpoch(_epoch);
        if (_maxScan == 0) revert InvalidScanWidth();

        address[] storage members = _gaugeMembers[_gauge];
        uint256 memberCount = members.length;
        if (_startIndex >= memberCount) return (new address[](0), memberCount, true);

        // Saturate rather than overflow: a `_maxScan` large enough to wrap means "to the end".
        uint256 end;
        unchecked {
            end = _startIndex + _maxScan;
        }
        if (end < _startIndex || end > memberCount) end = memberCount;

        users = new address[](end - _startIndex);
        uint256 filled;
        for (uint256 i = _startIndex; i < end;) {
            address user = members[i];
            if (_isOptedOutAt(_gauge, user, _epoch)) {
                users[filled] = user;
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Shrink the over-allocated array to the number actually filled.
        assembly {
            mstore(users, filled)
        }

        nextIndex = end;
        done = end == memberCount;
    }

    /// @notice Length of a gauge's scan list, for sizing a cursor walk.
    /// @dev How much work `optOutAtEpoch` has to do, and what to size a cursor walk against.
    ///      Always at least as large as any single epoch's exclusion count, usually larger,
    ///      since addresses that have since opted back in remain in the list.
    /// @param _gauge Gauge to query
    /// @return Number of entries scanned when reading this gauge
    function gaugeMemberCount(address _gauge) external view returns (uint256) {
        return _gaugeMembers[_gauge].length;
    }

    /// @notice Whether one user was excluded from one gauge at an epoch.
    /// @dev Cheap, and unaffected by how large the gauge's list is. Prefer it over fetching a
    ///      whole list to answer a single question.
    /// @param _gauge Gauge to query
    /// @param _user User to query
    /// @param _epoch Epoch to query
    /// @return True if excluded at that epoch
    function isOptedOutAtEpoch(address _gauge, address _user, uint256 _epoch) external view returns (bool) {
        _validateEpoch(_epoch);
        return _isOptedOutAt(_gauge, _user, _epoch);
    }

    /// @notice Whether a user is excluded from a gauge right now.
    /// @param _gauge Gauge to query
    /// @param _user User to query
    /// @return True if excluded at the current epoch
    function isOptedOut(address _gauge, address _user) external view returns (bool) {
        return _isOptedOutAt(_gauge, _user, _currentEpoch());
    }

    /// @notice Every period a user was opted out of a gauge, oldest first.
    /// @dev Opt-outs withdrawn before they took effect are absent — they are discarded rather
    ///      than recorded, so this can be shorter than an events replay suggests.
    /// @param _gauge Gauge to query
    /// @param _user User to query
    /// @return Periods as `[startEpoch, endEpoch)`, the last possibly still open
    function membershipHistory(address _gauge, address _user) external view returns (Membership[] memory) {
        return _history[_gauge][_user];
    }

    /// @notice Every recorded change to a gauge's exclusion count, oldest first.
    /// @dev For indexers reconciling counts without replaying each user's intervals.
    /// @param _gauge Gauge to query
    /// @return Checkpoints in epoch order
    function countHistory(address _gauge) external view returns (CountCheckpoint[] memory) {
        return _countHistory[_gauge];
    }

    /* ========== USER VIEWS ========== */

    /// @notice Gauges a user was excluded from at an epoch.
    /// @dev Mirrors `optOutAtEpoch`: no size limit, so a long list runs out of gas and
    ///      `gaugesForUserAtEpochFrom` is the way through. There is no per-user count to
    ///      validate a walk against; counts are kept per gauge.
    /// @param _user User to query
    /// @param _epoch Epoch to query
    /// @return gauges Gauges the user was excluded from at that epoch
    function gaugesForUserAtEpoch(address _user, uint256 _epoch) external view returns (address[] memory gauges) {
        _validateEpoch(_epoch);

        address[] storage all = _userGauges[_user];
        uint256 total = all.length;

        gauges = new address[](total);
        uint256 filled;
        for (uint256 i; i < total;) {
            address gauge = all[i];
            if (_isOptedOutAt(gauge, _user, _epoch)) {
                gauges[filled] = gauge;
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(gauges, filled)
        }
    }

    /// @notice One window of the gauges a user was excluded from at an epoch.
    /// @dev Call repeatedly, passing back `nextIndex`, until `done` is true. As on the gauge
    ///      side, **loop on `done`, never on an empty result**. Size the walk with
    ///      `userGaugeCount`; an over-large `_maxScan` runs out of gas rather than reverting
    ///      by name.
    /// @param _user User to query
    /// @param _epoch Epoch to query
    /// @param _startIndex Index to resume from; 0 to start
    /// @param _maxScan Maximum entries to examine in this call
    /// @return gauges Gauges found in this window; may be empty while more remain
    /// @return nextIndex Index to pass as `_startIndex` on the next call
    /// @return done True once the end of the list has been reached
    function gaugesForUserAtEpochFrom(address _user, uint256 _epoch, uint256 _startIndex, uint256 _maxScan)
        external
        view
        returns (address[] memory gauges, uint256 nextIndex, bool done)
    {
        _validateEpoch(_epoch);
        if (_maxScan == 0) revert InvalidScanWidth();

        address[] storage all = _userGauges[_user];
        uint256 total = all.length;
        if (_startIndex >= total) return (new address[](0), total, true);

        uint256 end;
        unchecked {
            end = _startIndex + _maxScan;
        }
        if (end < _startIndex || end > total) end = total;

        gauges = new address[](end - _startIndex);
        uint256 filled;
        for (uint256 i = _startIndex; i < end;) {
            address gauge = all[i];
            if (_isOptedOutAt(gauge, _user, _epoch)) {
                gauges[filled] = gauge;
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(gauges, filled)
        }

        nextIndex = end;
        done = end == total;
    }

    /// @notice Length of a user's gauge scan list, for sizing a cursor walk.
    /// @dev Includes gauges the user has since opted back in to.
    /// @param _user User to query
    /// @return Number of entries scanned when reading this user
    function userGaugeCount(address _user) external view returns (uint256) {
        return _userGauges[_user].length;
    }

    /* ========== WITHHELD WEIGHT ========== */

    /// @notice vlCVX weight that should be withheld from a gauge at an epoch.
    /// @dev Sums, over every address excluded from this gauge at `_epoch`: the share of their
    ///      own vote that went to this gauge, plus the share their delegate cast on their
    ///      behalf. Both apply — an address can vote itself and still have delegated weight
    ///      counted through its delegate.
    ///
    ///      Proposals run on alternating epochs, so `_epoch` must be one that carries a
    ///      proposal; odd ones revert `OddEpoch`. The proposal the epoch maps to is checked to
    ///      report that same epoch, so a drifted schedule reverts rather than reading the
    ///      wrong proposal.
    ///
    ///      This gathers the excluded list itself and is the whole-gauge read: it has no size
    ///      limit and runs out of gas on a large gauge, making one platform call per address
    ///      plus one delegation call, plus two more per distinct delegate. Use
    ///      `withheldWeightForUsers` over slices of `optOutAtEpochFrom` when it does not fit.
    ///
    ///      Reverts `VoteSourcesNotSet` until the owner has configured the vote contracts.
    /// @param _gauge Gauge to query
    /// @param _epoch Epoch to query; must carry a proposal
    /// @return vlCVX weight to exclude from this gauge's distribution
    function withheldWeightAtEpoch(address _gauge, uint256 _epoch) external view returns (uint256) {
        _validateEpoch(_epoch);
        return _withheldWeight(_gauge, _epoch, _excludedAt(_gauge, _epoch));
    }

    /// @notice The same total, over a caller-supplied slice of the excluded list.
    /// @dev Every address must actually be excluded from `_gauge` at `_epoch`, and none may
    ///      repeat, or the result would overstate what to withhold. Both are checked.
    ///
    ///      Summing this across slices that partition the excluded list gives the same total
    ///      as `withheldWeightAtEpoch`, with one caveat: a delegate shared across two slices
    ///      is resolved once per slice, and each resolution rounds down separately. Partition
    ///      by delegate, or accept a few wei of drift.
    /// @param _gauge Gauge to query
    /// @param _epoch Epoch to query; must carry a proposal
    /// @param _users Addresses to account for; all must be excluded at that epoch
    /// @return vlCVX weight to exclude for these addresses
    function withheldWeightForUsers(address _gauge, uint256 _epoch, address[] calldata _users)
        external
        view
        returns (uint256)
    {
        _validateEpoch(_epoch);

        uint256 len = _users.length;
        for (uint256 i; i < len;) {
            address user = _users[i];
            if (!_isOptedOutAt(_gauge, user, _epoch)) revert NotExcluded(_gauge, user);
            for (uint256 j; j < i;) {
                if (_users[j] == user) revert DuplicateUser(user);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        return _withheldWeight(_gauge, _epoch, _users);
    }

    /* ========== EPOCH VIEWS ========== */

    /// @notice The epoch now in progress.
    /// @dev Changes made now take effect at `currentEpoch() + 1`. Answers for this epoch and
    ///      earlier are settled; the next epoch's is not.
    /// @return Current vlCVX epoch index
    function currentEpoch() external view returns (uint256) {
        return _currentEpoch();
    }

    /// @notice Number of epochs the vlCVX locker has checkpointed.
    /// @dev Informational. Do **not** use it to bound queries — it lags `currentEpoch()`
    ///      whenever nobody has checkpointed the locker recently. `maxQueryableEpoch()` is the
    ///      bound these views actually enforce.
    /// @return Epoch count reported by the locker
    function epochCount() external view returns (uint256) {
        return vlCVX.epochCount();
    }

    /// @notice Highest epoch these views will answer for.
    /// @dev `currentEpoch() + 1`. That epoch is readable but not yet settled: changes are still
    ///      landing in it. Reward calculations should use settled epochs.
    /// @return Highest epoch accepted by the epoch-taking views
    function maxQueryableEpoch() external view returns (uint256) {
        return _currentEpoch() + 1;
    }

    /* ========== INTERNAL ========== */

    /// @notice The epoch a change made now takes effect at. Monotonic in `block.timestamp`.
    function _nextEpoch() internal view returns (uint256) {
        return _currentEpoch() + 1;
    }

    /// @notice Extends the locker's epoch array to cover `_nextEpoch()`.
    /// @dev A balance read indexes that entry directly and reverts if it is missing. The epoch
    ///      number itself needs no checkpoint, so only the paths reading a balance call this.
    function _ensureEpochCheckpointed() internal {
        vlCVX.checkpointEpoch();
    }

    /// @notice Current epoch, derived from the timestamp rather than read from the locker.
    /// @dev Reverts rather than wrapping if `block.timestamp` ever precedes `epoch0Date`.
    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp - epoch0Date) / EPOCH_DURATION;
    }

    /// @notice Rejects epochs outside the range these views can answer for.
    /// @dev An out-of-range epoch would otherwise return a list and a count that agree with
    ///      each other while describing nothing — a shape no caller-side check can detect.
    function _validateEpoch(uint256 _epoch) internal view {
        if (_epoch < deployEpoch) revert PreDeployEpoch(_epoch, deployEpoch);
        uint256 maxEpoch = _currentEpoch() + 1;
        if (_epoch > maxEpoch) revert FutureEpoch(_epoch, maxEpoch);
    }

    /// @notice Addresses excluded from a gauge at an epoch, without the epoch-range guard.
    function _excludedAt(address _gauge, uint256 _epoch) internal view returns (address[] memory users) {
        address[] storage members = _gaugeMembers[_gauge];
        uint256 memberCount = members.length;

        uint256 count = _countAt(_gauge, _epoch);
        users = new address[](count);

        uint256 filled;
        for (uint256 i; i < memberCount;) {
            address user = members[i];
            if (_isOptedOutAt(_gauge, user, _epoch)) {
                if (filled == count) revert CountMismatch();
                users[filled] = user;
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (filled != count) revert CountMismatch();
    }

    /// @notice The proposal covering an epoch. Only ever returns one that reports that epoch.
    /// @dev The id is derived arithmetically — proposals alternate epochs — and then confirmed
    ///      against the proposal itself, so a wrong one is never read.
    ///
    ///      The derivation can be off, and permanently: `forceEndProposal` zeroes a proposal's
    ///      epoch but leaves its slot, so a replacement created in the same epoch takes the
    ///      next id and every later epoch shifts by one. A skipped epoch shifts the other way.
    ///      Rather than fail from then on, a bounded window either side of the derived id is
    ///      searched. An aligned schedule costs nothing extra; a shifted one self-heals.
    function _proposalIdFor(uint256 _epoch) internal view returns (uint256) {
        IGaugeVotePlatform platform = votePlatform;
        if (address(platform) == address(0)) revert VoteSourcesNotSet();

        uint256 first = firstProposalEpoch;
        if (_epoch < first) revert NoProposalForEpoch(_epoch);
        // Proposals alternate, so only epochs sharing parity with the first one carry one.
        if ((_epoch - first) % 2 != 0) revert OddEpoch(_epoch);

        uint256 count = platform.proposalCount();
        uint256 derived = (_epoch - first) / 2;

        if (derived < count && _proposalEpochAt(platform, derived) == _epoch) return derived;

        for (uint256 step = 1; step <= PROPOSAL_SEARCH_WINDOW;) {
            uint256 above = derived + step;
            if (above < count && _proposalEpochAt(platform, above) == _epoch) return above;
            // Bounded on both sides: the subtraction has to stay non-negative, and the index
            // has to stay inside the array — the real `proposals` getter panics past its end
            // rather than returning zero.
            if (step <= derived) {
                uint256 below = derived - step;
                if (below < count && _proposalEpochAt(platform, below) == _epoch) return below;
            }
            unchecked {
                ++step;
            }
        }
        revert NoProposalForEpoch(_epoch);
    }

    /// @notice A proposal's epoch. Force-ended proposals report zero and so match nothing.
    function _proposalEpochAt(IGaugeVotePlatform _platform, uint256 _id)
        internal
        view
        returns (uint256)
    {
        (,, uint48 proposalEpoch) = _platform.proposals(_id);
        return uint256(proposalEpoch);
    }

    /// @notice One voter's total allocation to a gauge on a proposal.
    /// @dev `gaugeWeight` is out of `maxVoteWeight` and zero when the voter did not name the
    ///      gauge. `baseWeight` is the voter's own weight, ignored on the delegate pass.
    ///
    ///      Every matching entry is summed, because the platform does not deduplicate: a vote
    ///      may name one gauge more than once and each entry is credited to it separately.
    ///      Reading only the first would let an excluded holder keep nearly all of its rewards
    ///      by splitting its allocation across two entries.
    function _voteShare(uint256 _proposalId, address _voter, address _gauge)
        internal
        view
        returns (uint256 gaugeWeight, uint256 baseWeight)
    {
        address[] memory gauges;
        uint256[] memory weights;
        (gauges, weights,, baseWeight,) = votePlatform.getVote(_proposalId, _voter);

        uint256 len = gauges.length;
        for (uint256 i; i < len;) {
            if (gauges[i] == _gauge) gaugeWeight += weights[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Weight to withhold from a gauge for a set of excluded addresses.
    /// @dev Split across several small functions rather than one loop: the combined version
    ///      exceeds the EVM's reachable stack depth.
    function _withheldWeight(address _gauge, uint256 _epoch, address[] memory _users)
        internal
        view
        returns (uint256)
    {
        // Resolved before the empty-list shortcut: otherwise a gauge with nobody excluded
        // answers zero for an unconfigured instance or an epoch carrying no proposal, which
        // are exactly the cases where zero is indistinguishable from a real answer.
        uint256 proposalId = _proposalIdFor(_epoch);
        if (_users.length == 0) return 0;

        return _directWeight(proposalId, _gauge, _users)
            + _delegatedWeight(proposalId, _epoch, _gauge, _users);
    }

    /// @notice What the addresses allocated to the gauge with their own votes.
    function _directWeight(uint256 _proposalId, address _gauge, address[] memory _users)
        internal
        view
        returns (uint256 total)
    {
        uint256 scale = maxVoteWeight;
        uint256 len = _users.length;
        for (uint256 i; i < len;) {
            (uint256 gaugeWeight, uint256 baseWeight) = _voteShare(_proposalId, _users[i], _gauge);
            if (gaugeWeight != 0 && baseWeight != 0) {
                total += (baseWeight * gaugeWeight) / scale;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice What their delegates carried for them, whether or not they also voted.
    /// @dev Grouped by delegate because the helper resolves a batch of delegators in one call
    ///      and the delegate's own allocation is then read once for the whole group.
    function _delegatedWeight(
        uint256 _proposalId,
        uint256 _epoch,
        address _gauge,
        address[] memory _users
    ) internal view returns (uint256 total) {
        uint256 len = _users.length;

        address[] memory delegates = new address[](len);
        for (uint256 i; i < len;) {
            address found = delegation.getDelegateAtEpoch(_users[i], _epoch);
            delegates[i] = found == _users[i] ? address(0) : found;
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < len;) {
            address delegate = delegates[i];
            if (delegate != address(0) && !_seenBefore(delegates, i, delegate)) {
                total += _delegateShare(
                    _proposalId, _gauge, delegate, _groupFor(_users, delegates, i, delegate)
                );
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Whether this delegate was already handled earlier in the list.
    function _seenBefore(address[] memory _delegates, uint256 _upTo, address _delegate)
        internal
        pure
        returns (bool)
    {
        for (uint256 j; j < _upTo;) {
            if (_delegates[j] == _delegate) return true;
            unchecked {
                ++j;
            }
        }
        return false;
    }

    /// @notice The addresses from `_from` onward that delegate to `_delegate`.
    function _groupFor(
        address[] memory _users,
        address[] memory _delegates,
        uint256 _from,
        address _delegate
    ) internal pure returns (address[] memory group) {
        uint256 len = _users.length;

        uint256 size;
        for (uint256 j = _from; j < len;) {
            if (_delegates[j] == _delegate) ++size;
            unchecked {
                ++j;
            }
        }

        group = new address[](size);
        uint256 filled;
        for (uint256 j = _from; j < len;) {
            if (_delegates[j] == _delegate) {
                group[filled] = _users[j];
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @notice One delegate's contribution to a gauge on behalf of the given delegators.
    /// @dev The delegate's own base weight is theirs, not these delegators', so only the
    ///      contributed weight the helper reports is attributed here.
    function _delegateShare(
        uint256 _proposalId,
        address _gauge,
        address _delegate,
        address[] memory _group
    ) internal view returns (uint256) {
        uint256[] memory contributed =
            voteHelper.getContributingWeights(_proposalId, _delegate, _group, address(votePlatform));

        uint256 contributedTotal;
        uint256 len = _group.length;
        for (uint256 j; j < len;) {
            contributedTotal += contributed[j];
            unchecked {
                ++j;
            }
        }
        if (contributedTotal == 0) return 0;

        (uint256 gaugeWeight,) = _voteShare(_proposalId, _delegate, _gauge);
        if (gaugeWeight == 0) return 0;

        return (contributedTotal * gaugeWeight) / maxVoteWeight;
    }

    /// @notice Points this instance at a gauge registry, refusing anything that is not one.
    /// @dev A registry answers `isRegisteredGauge` with 32 bytes; a non-contract returns none,
    ///      and a contract without that selector does not answer at all.
    function _setGaugeRegistry(address _gaugeRegistry) internal {
        (bool answered, bytes memory answer) = _gaugeRegistry.staticcall(
            abi.encodeCall(IGaugeRegistry.isRegisteredGauge, (address(0)))
        );
        if (!answered || answer.length != 32) revert InvalidGaugeRegistry(_gaugeRegistry);

        gaugeRegistry = IGaugeRegistry(_gaugeRegistry);
        emit GaugeRegistrySet(_gaugeRegistry);

        // A platform serves one registry. Repointing to a different one leaves any configured
        // platform paired with a registry this instance no longer uses, which would answer
        // zero for every gauge. Clear it instead, so the withheld-weight reads refuse until
        // they are configured again.
        IGaugeVotePlatform platform = votePlatform;
        if (address(platform) != address(0) && platform.gaugeRegistry() != _gaugeRegistry) {
            votePlatform = IGaugeVotePlatform(address(0));
            voteHelper = IGaugeVoteHelper(address(0));
            delegation = IDelegation(address(0));
            firstProposalEpoch = 0;
            maxVoteWeight = 0;
            emit VoteSourcesCleared();
        }
    }

    /// @notice Records one user's opt-out from one gauge, effective at `_effectiveEpoch`.
    /// @dev `_forced` selects the event only. Every path checks the registry.
    function _optOut(address _gauge, address _user, uint256 _effectiveEpoch, bool _forced) internal {
        if (!gaugeRegistry.isRegisteredGauge(_gauge)) revert GaugeNotRegistered(_gauge);

        Membership[] storage h = _history[_gauge][_user];
        uint256 len = h.length;

        if (len == 0) {
            h.push(Membership({startEpoch: uint32(_effectiveEpoch), endEpoch: ACTIVE}));
        } else {
            Membership storage tail = h[len - 1];
            if (tail.endEpoch == ACTIVE) revert AlreadyOptedOut(_gauge);
            if (tail.endEpoch == uint32(_effectiveEpoch)) {
                // Closed earlier in the same pending window, so nothing took effect. Reopen
                // in place rather than pushing an interval with a duplicate start epoch.
                tail.endEpoch = ACTIVE;
            } else {
                h.push(Membership({startEpoch: uint32(_effectiveEpoch), endEpoch: ACTIVE}));
            }
        }

        if (_memberSlots[_gauge][_user] == 0) {
            _gaugeMembers[_gauge].push(_user);
            _userGauges[_user].push(_gauge);
            _memberSlots[_gauge][_user] =
                (_userGauges[_user].length << 128) | _gaugeMembers[_gauge].length;
        }

        _incCount(_gauge, _effectiveEpoch);

        if (_forced) {
            emit ForceOptedOut(_gauge, _user, uint32(_effectiveEpoch));
        } else {
            emit OptedOut(_gauge, _user, uint32(_effectiveEpoch));
        }
    }

    /// @notice Ends one user's opt-out from one gauge, effective at `_effectiveEpoch`.
    /// @dev Requires an open interval. A repeated call reverts instead of decrementing the
    ///      count twice for one interval.
    function _close(address _gauge, address _user, uint256 _effectiveEpoch, bool _forced) internal {
        Membership[] storage h = _history[_gauge][_user];
        uint256 len = h.length;
        if (len == 0) revert NotOptedOut(_gauge);

        Membership storage tail = h[len - 1];
        if (tail.endEpoch != ACTIVE) revert NotOptedOut(_gauge);

        // Closing at the epoch it starts means it never covered one: discard, do not record.
        bool neverEffective = tail.startEpoch == uint32(_effectiveEpoch);
        if (!neverEffective) {
            tail.endEpoch = uint32(_effectiveEpoch);
        }

        _decCount(_gauge, _effectiveEpoch);

        if (_forced) {
            emit ForceOptedIn(_gauge, _user, uint32(_effectiveEpoch));
        } else {
            emit OptedIn(_gauge, _user, uint32(_effectiveEpoch));
        }

        if (!neverEffective) return;

        // The interval appeared in no epoch's answer and its +1/-1 cancelled on one
        // checkpoint, so discarding it changes no result. Only interval: drop the member from
        // the scan lists too. Otherwise: keep them, since earlier intervals still answer.
        if (len == 1) {
            _pruneMember(_gauge, _user, uint32(_effectiveEpoch));
        } else {
            h.pop();
        }
    }

    /// @notice Removes a member from both scan lists and discards their history.
    /// @dev Valid only for a member whose opt-outs never covered an epoch. Anyone else has to
    ///      stay scannable for the epochs they were excluded at.
    function _pruneMember(address _gauge, address _user, uint32 _effectiveEpoch) internal {
        uint256 slot = _memberSlots[_gauge][_user];

        _removeGaugeMember(_gauge, (slot & INDEX_MASK) - 1);
        _removeUserGauge(_user, (slot >> 128) - 1);

        delete _memberSlots[_gauge][_user];
        delete _history[_gauge][_user];

        emit MemberPruned(_gauge, _user, _effectiveEpoch);
    }

    /// @notice Removes `_index` from a gauge's member list, reindexing the entry moved into it.
    function _removeGaugeMember(address _gauge, uint256 _index) internal {
        address[] storage members = _gaugeMembers[_gauge];
        uint256 last = members.length - 1;

        if (_index != last) {
            address moved = members[last];
            members[_index] = moved;
            uint256 movedSlot = _memberSlots[_gauge][moved];
            _memberSlots[_gauge][moved] = (movedSlot & ~INDEX_MASK) | (_index + 1);
        }
        members.pop();
    }

    /// @notice Removes `_index` from a user's gauge list, reindexing the entry moved into it.
    function _removeUserGauge(address _user, uint256 _index) internal {
        address[] storage gauges = _userGauges[_user];
        uint256 last = gauges.length - 1;

        if (_index != last) {
            address movedGauge = gauges[last];
            gauges[_index] = movedGauge;
            uint256 movedSlot = _memberSlots[movedGauge][_user];
            _memberSlots[movedGauge][_user] = (movedSlot & INDEX_MASK) | ((_index + 1) << 128);
        }
        gauges.pop();
    }

    /// @notice Records a +1 to a gauge's member count at `_epoch`.
    function _incCount(address _gauge, uint256 _epoch) internal {
        CountCheckpoint[] storage cps = _countHistory[_gauge];
        uint256 len = cps.length;

        if (len == 0) {
            cps.push(CountCheckpoint({epoch: uint32(_epoch), count: 1}));
            return;
        }

        CountCheckpoint storage tail = cps[len - 1];
        if (tail.epoch > _epoch) revert NonMonotonicEpoch();

        if (tail.epoch == uint32(_epoch)) {
            tail.count += 1;
        } else {
            cps.push(CountCheckpoint({epoch: uint32(_epoch), count: tail.count + 1}));
        }
    }

    /// @notice Records a -1 to a gauge's member count at `_epoch`.
    function _decCount(address _gauge, uint256 _epoch) internal {
        CountCheckpoint[] storage cps = _countHistory[_gauge];
        uint256 len = cps.length;
        // Unreachable: every decrement follows an increment on the same gauge.
        if (len == 0) revert CountMismatch();

        CountCheckpoint storage tail = cps[len - 1];
        if (tail.epoch > _epoch) revert NonMonotonicEpoch();

        // Underflow here would mean the count had drifted from the list, so it reverts.
        if (tail.epoch == uint32(_epoch)) {
            tail.count -= 1;
        } else {
            cps.push(CountCheckpoint({epoch: uint32(_epoch), count: tail.count - 1}));
        }
    }

    /// @notice Exclusion count for a gauge at an epoch, without the epoch-range guard.
    /// @dev Uses the same predicate as the membership search — the largest entry keyed at or
    ///      below `_epoch`. The two must match, or a count and its list disagree at a boundary.
    function _countAt(address _gauge, uint256 _epoch) internal view returns (uint256) {
        CountCheckpoint[] storage cps = _countHistory[_gauge];
        uint256 lo;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (cps[mid].epoch <= _epoch) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo == 0 ? 0 : cps[lo - 1].count;
    }

    /// @notice Whether a user's history covers `_epoch`, without the epoch-range guard.
    function _isOptedOutAt(address _gauge, address _user, uint256 _epoch) internal view returns (bool) {
        Membership[] storage h = _history[_gauge][_user];
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (h[mid].startEpoch <= _epoch) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return false;
        return _epoch < h[lo - 1].endEpoch;
    }

}
