// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../../contracts/OptOutRegistry.sol";
import {MockVlCVX, MockGaugeRegistry} from "./Mocks.sol";
import {MockVotePlatform, MockDelegation, MockVoteHelper} from "./VoteMocks.sol";

/// The withheld-weight reads: how much vlCVX to exclude from a gauge's distribution.
contract WithheldWeightTest is Test {
    OptOutRegistry reg;
    MockVlCVX vl;
    MockGaugeRegistry gr;
    MockVotePlatform platform;
    MockDelegation deleg;
    MockVoteHelper helper;

    address owner = address(0xA11CE);
    address gaugeA = address(0x2001);
    address gaugeB = address(0x2002);
    address alice = address(0x1001);
    address bob = address(0x1002);
    address carol = address(0x1003);
    address dele = address(0xD00D);

    uint256 constant DUR = 7 days;
    uint256 constant SCALE = 1_000_000;
    uint32 constant FIRST_PROPOSAL_EPOCH = 230;
    uint256 constant VOTE_EPOCH = 232; // proposal 1

    function setUp() public {
        vm.warp(1_700_000_000);
        // Deploy well before the proposal epoch, so the epoch-range guard admits it.
        vl = new MockVlCVX(uint32(block.timestamp - 100 * DUR));
        gr = new MockGaugeRegistry();
        reg = new OptOutRegistry("t", owner, address(vl), address(gr), 1);

        platform = new MockVotePlatform();
        platform.addProposal(uint48(FIRST_PROPOSAL_EPOCH)); // id 0
        platform.addProposal(uint48(VOTE_EPOCH)); // id 1

        deleg = new MockDelegation();
        helper = new MockVoteHelper(address(deleg));
        platform.setDelegation(address(deleg));
        platform.setGaugeRegistry(address(gr));

        vm.prank(owner);
        reg.setVoteSources(address(platform), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);

        for (uint256 i; i < 3; ++i) {
            vl.setBal(address(uint160(0x1001 + i)), 100e18);
        }

        // Advance past the proposal epoch so it is settled and readable.
        vm.warp(block.timestamp + DUR * 140);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _weights(uint256 w) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = w;
    }

    /// Opt the user out at an epoch at or before VOTE_EPOCH, so the exclusion covers it.
    function _excludeBefore(address user, address gauge) internal {
        uint256 saved = block.timestamp;
        vm.warp(uint256(vl.e0()) + (VOTE_EPOCH - 1) * DUR);
        vm.prank(user);
        reg.optOut(_one(gauge));
        vm.warp(saved);
    }

    // ------------------------------------------------------------------
    // Epoch to proposal mapping
    // ------------------------------------------------------------------

    function test_rejectsOddEpochsAndUnmappedOnes() public {
        _excludeBefore(alice, gaugeA);

        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.OddEpoch.selector, VOTE_EPOCH + 1));
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH + 1);

        // Even, mapped, but no such proposal exists yet.
        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH + 2)
        );
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH + 2);
    }

    /// The arithmetic mapping is confirmed against the proposal's own epoch, so a proposal
    /// reporting a different one is never read. With no other proposal carrying the epoch,
    /// the read refuses rather than returning another proposal's votes.
    function test_refusesWhenNoProposalCarriesTheEpoch() public {
        _excludeBefore(alice, gaugeA);
        platform.setProposalEpoch(1, uint48(VOTE_EPOCH + 4));

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH)
        );
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
    }

    /// `forceEndProposal` zeroes a proposal's epoch but leaves its slot, so a replacement
    /// created in the same epoch takes the next id and every later epoch shifts. The read
    /// searches a bounded window either side of the derived id, so it survives that.
    function test_survivesAShiftedProposalSchedule() public {
        _excludeBefore(alice, gaugeA);
        platform.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);
        uint256 aligned = reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
        assertEq(aligned, (100e18 * 400_000) / SCALE, "aligned baseline");

        // Force-end proposal 1 and recreate it for the same epoch: its id becomes 2.
        platform.setProposalEpoch(1, 0);
        platform.addProposal(uint48(VOTE_EPOCH));
        platform.setVote(2, alice, _one(gaugeA), _weights(400_000), 100e18);

        assertEq(
            reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), aligned, "shift should be absorbed"
        );

        // A shift of exactly the window still resolves, which pins the bound from below: a
        // window of 1 would fail here, and the refusal test above pins it from above.
        MockVotePlatform edge = new MockVotePlatform();
        edge.setGaugeRegistry(address(gr));
        edge.setDelegation(address(deleg));
        edge.addProposal(uint48(FIRST_PROPOSAL_EPOCH));
        for (uint256 i; i < 8; ++i) {
            edge.addProposal(0);
        }
        edge.addProposal(uint48(VOTE_EPOCH)); // id 9, derived is 1, so shifted by 8
        edge.setVote(9, alice, _one(gaugeA), _weights(400_000), 100e18);
        vm.prank(owner);
        reg.setVoteSources(address(edge), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
        assertEq(
            reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), aligned, "shift of exactly 8 refused"
        );

        // What the search costs: the same read, aligned against shifted by one.
        platform.setProposalEpoch(1, uint48(VOTE_EPOCH));
        uint256 g0 = gasleft();
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
        uint256 alignedGas = g0 - gasleft();

        platform.setProposalEpoch(1, 0);
        g0 = gasleft();
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
        uint256 shiftedGas = g0 - gasleft();

        console.log("aligned read", alignedGas);
        console.log("shifted by 1", shiftedGas);
        console.log("search overhead", shiftedGas - alignedGas);

        // And a shift the other way, where the real id sits below the derived one.
        MockVotePlatform shifted = new MockVotePlatform();
        shifted.setGaugeRegistry(address(gr));
        shifted.setDelegation(address(deleg));
        shifted.addProposal(uint48(FIRST_PROPOSAL_EPOCH));
        shifted.addProposal(uint48(VOTE_EPOCH)); // id 1
        shifted.addProposal(uint48(VOTE_EPOCH + 2));
        shifted.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);
        vm.prank(owner);
        reg.setVoteSources(address(shifted), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH + 2), 0, "no votes there");
    }

    /// Beyond the window it gives up rather than scanning an unbounded array. The bound is
    /// written out here rather than read from the contract: sizing the padding with
    /// `reg.PROPOSAL_SEARCH_WINDOW()` would pass for any value, including 1 or 64.
    function test_refusesAShiftLargerThanTheSearchWindow() public {
        assertEq(reg.PROPOSAL_SEARCH_WINDOW(), 8, "window changed; revisit the shifts below");
        _excludeBefore(alice, gaugeA);

        MockVotePlatform far = new MockVotePlatform();
        far.setGaugeRegistry(address(gr));
        far.setDelegation(address(deleg));
        far.addProposal(uint48(FIRST_PROPOSAL_EPOCH));
        // Nine dead slots: one more than the window can reach.
        for (uint256 i; i < 9; ++i) {
            far.addProposal(0);
        }
        far.addProposal(uint48(VOTE_EPOCH));
        vm.prank(owner);
        reg.setVoteSources(address(far), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH)
        );
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
    }

    function test_revertsUntilSourcesAreSet() public {
        // A locker numbered so the proposal epoch is inside this instance's answerable range;
        // otherwise the epoch guard fires first and hides what is being tested.
        MockVlCVX vl2 = new MockVlCVX(uint32(block.timestamp - (VOTE_EPOCH - 1) * DUR));
        vl2.setBal(alice, 100e18);
        OptOutRegistry fresh = new OptOutRegistry("u", owner, address(vl2), address(gr), 1);

        vm.prank(alice);
        fresh.optOut(_one(gaugeA));

        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesNotSet.selector));
        fresh.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
    }

    // ------------------------------------------------------------------
    // Configuring the sources
    // ------------------------------------------------------------------

    function test_setVoteSourcesIsOwnerOnlyAndChecked() public {
        MockDelegation other = new MockDelegation();
        MockVoteHelper wrongHelper = new MockVoteHelper(address(other));

        // A platform built against a different delegation registry is refused too: the helper
        // resolves delegators from its own registry while reading votes from the platform.
        MockVotePlatform wrongPlatform = new MockVotePlatform();
        wrongPlatform.setGaugeRegistry(address(gr));
        wrongPlatform.setDelegation(address(other));
        wrongPlatform.addProposal(uint48(FIRST_PROPOSAL_EPOCH));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesMismatch.selector));
        reg.setVoteSources(
            address(wrongPlatform), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH
        );

        vm.prank(alice);
        vm.expectRevert();
        reg.setVoteSources(address(platform), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);

        // A helper built against a different delegation registry would silently resolve
        // delegators against the wrong history.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesMismatch.selector));
        reg.setVoteSources(
            address(platform), address(wrongHelper), address(deleg), FIRST_PROPOSAL_EPOCH
        );

        // And the platform has to agree about where proposal 0 sits, or every epoch maps to
        // the wrong proposal.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.ProposalEpochMismatch.selector, 0, FIRST_PROPOSAL_EPOCH, 228
            )
        );
        reg.setVoteSources(address(platform), address(helper), address(deleg), 228);
    }

    /// The two platforms share a delegation registry, a weight scale and a proposal schedule.
    /// Only the gauge registry distinguishes them — and a crossed pairing does not fail, it
    /// reports zero for every gauge, because the platform holds votes for gauges this instance
    /// never sees. The deploy script prints two near-identical calldata payloads back to back,
    /// so a transposition is a realistic operator error with a silent, costly outcome.
    function test_rejectsAPlatformServingAnotherRegistry() public {
        MockGaugeRegistry otherRegistry = new MockGaugeRegistry();
        MockVotePlatform crossed = new MockVotePlatform();
        crossed.setGaugeRegistry(address(otherRegistry));
        crossed.setDelegation(address(deleg));
        crossed.addProposal(uint48(FIRST_PROPOSAL_EPOCH));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesMismatch.selector));
        reg.setVoteSources(address(crossed), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
    }

    /// Repointing the gauge registry leaves a configured platform paired with a registry this
    /// instance no longer uses. Rather than let it answer zero for everything, the sources are
    /// dropped so the reads refuse until they are set again.
    function test_movingTheRegistryClearsTheVoteSources() public {
        assertTrue(address(reg.votePlatform()) != address(0), "configured in setUp");

        MockGaugeRegistry moved = new MockGaugeRegistry();
        vm.expectEmit(false, false, false, false);
        emit OptOutRegistry.VoteSourcesCleared();
        vm.prank(owner);
        reg.setGaugeRegistry(address(moved));

        assertEq(address(reg.votePlatform()), address(0), "platform not cleared");
        assertEq(address(reg.voteHelper()), address(0), "helper not cleared");
        assertEq(address(reg.delegation()), address(0), "delegation not cleared");
        assertEq(reg.maxVoteWeight(), 0, "scale not cleared");
        assertEq(reg.firstProposalEpoch(), 0, "first epoch not cleared");

        _excludeBefore(alice, gaugeA);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesNotSet.selector));
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH);
    }

    /// Moving to a registry the configured platform does serve leaves the pairing alone.
    function test_movingToTheSameRegistryKeepsTheVoteSources() public {
        vm.prank(owner);
        reg.setGaugeRegistry(address(gr));
        assertTrue(address(reg.votePlatform()) != address(0), "cleared unnecessarily");
    }

    function test_setVoteSourcesTakesTheScaleFromThePlatform() public view {
        assertEq(reg.maxVoteWeight(), platform.max_weight(), "scale not read from the platform");
        assertEq(address(reg.votePlatform()), address(platform));
        assertEq(address(reg.voteHelper()), address(helper));
        assertEq(address(reg.delegation()), address(deleg));
        assertEq(reg.firstProposalEpoch(), FIRST_PROPOSAL_EPOCH);
    }

    // ------------------------------------------------------------------
    // The sum itself
    // ------------------------------------------------------------------

    function test_countsTheExcludedAddressesOwnVote() public {
        _excludeBefore(alice, gaugeA);
        // 40% of a 100e18 base weight went to gaugeA.
        platform.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);

        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), (100e18 * 400_000) / SCALE);
        // A gauge they did not name withholds nothing.
        assertEq(reg.withheldWeightAtEpoch(gaugeB, VOTE_EPOCH), 0);
    }

    /// The platform pushes every (gauge, weight) pair verbatim and accumulates each into the
    /// gauge's total, with no deduplication. So naming one gauge twice is a valid vote that
    /// credits it the sum — and reading only the first entry would let an excluded holder keep
    /// nearly all of its rewards by writing its allocation as two entries.
    function test_countsEveryEntryWhenAGaugeIsNamedTwice() public {
        _excludeBefore(alice, gaugeA);

        address[] memory twice = new address[](2);
        twice[0] = gaugeA;
        twice[1] = gaugeA;
        uint256[] memory split = new uint256[](2);
        split[0] = 1;
        split[1] = 999_999;
        platform.setVote(1, alice, twice, split, 100e18);

        assertEq(
            reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 100e18, "split entries must all count"
        );
    }

    function test_ignoresAddressesThatAreNotExcluded() public {
        // bob votes for gaugeA but is not opted out, so none of his weight is withheld.
        platform.setVote(1, bob, _one(gaugeA), _weights(1_000_000), 100e18);
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 0);
    }

    function test_countsWeightCarriedByADelegate() public {
        _excludeBefore(alice, gaugeA);
        // Alice never voted; her delegate did, and half that vote went to gaugeA.
        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 60e18);
        platform.setVote(1, dele, _one(gaugeA), _weights(500_000), 999e18);

        // The delegate's own base weight is theirs, not Alice's: only her contribution counts.
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), (60e18 * 500_000) / SCALE);
    }

    /// The case the two passes exist for: an address votes itself *and* its delegate still
    /// carries some of its weight. Both are withheld.
    function test_countsBothOwnVoteAndDelegatedWeight() public {
        _excludeBefore(alice, gaugeA);
        platform.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);

        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 10e18);
        platform.setVote(1, dele, _one(gaugeA), _weights(250_000), 999e18);

        uint256 own = (100e18 * 400_000) / SCALE;
        uint256 viaDelegate = (10e18 * 250_000) / SCALE;
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), own + viaDelegate);
    }

    function test_addsNothingWhenTheDelegateDidNotVoteForTheGauge() public {
        _excludeBefore(alice, gaugeA);
        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 60e18);
        platform.setVote(1, dele, _one(gaugeB), _weights(1_000_000), 999e18);

        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 0);
    }

    /// Delegators sharing a delegate are resolved as one group, so their contributions are
    /// summed *before* the gauge weight is applied. With weights that do not divide evenly
    /// this differs from rounding each one separately, which is what pins the grouping.
    function test_groupsDelegatorsBeforeApplyingTheGaugeWeight() public {
        _excludeBefore(alice, gaugeA);
        _excludeBefore(bob, gaugeA);

        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        deleg.setDelegate(bob, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 1);
        helper.setContribution(1, dele, bob, 1);
        platform.setVote(1, dele, _one(gaugeA), _weights(600_000), 999e18);

        // Grouped: (1 + 1) * 600000 / 1e6 == 1. Separately: 0 + 0 == 0.
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 1);
    }

    /// Two excluded addresses sharing one delegate must be resolved as ONE group. Without the
    /// already-seen check the delegate is processed once per delegator, and its allocation is
    /// applied to an ever-shrinking tail of the group — over-withholding from real voters.
    /// Uses weights large enough that the arithmetic cannot round the difference away.
    function test_resolvesASharedDelegateOnlyOnce() public {
        _excludeBefore(alice, gaugeA);
        _excludeBefore(bob, gaugeA);

        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        deleg.setDelegate(bob, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 60e18);
        helper.setContribution(1, dele, bob, 60e18);
        platform.setVote(1, dele, _one(gaugeA), _weights(500_000), 999e18);

        // Once: (60 + 60) * 50% = 60. Twice: 60 + (60 * 50%) = 90.
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 60e18, "delegate counted twice");
    }

    /// The scale is read from the platform, not assumed. Every arithmetic path has to use the
    /// stored value — at the default of 1,000,000 a hardcoded constant is indistinguishable.
    function test_usesTheScaleThePlatformReports() public {
        MockVotePlatform tenK = new MockVotePlatform();
        tenK.setGaugeRegistry(address(gr));
        tenK.setDelegation(address(deleg));
        tenK.setMaxWeight(10_000);
        tenK.addProposal(uint48(FIRST_PROPOSAL_EPOCH));
        tenK.addProposal(uint48(VOTE_EPOCH));

        vm.prank(owner);
        reg.setVoteSources(address(tenK), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
        assertEq(reg.maxVoteWeight(), 10_000, "scale not taken from the platform");

        _excludeBefore(alice, gaugeA);
        // 40% of 100e18 on a 10,000 scale. Against a hardcoded 1e6 this would be 0.4e18.
        tenK.setVote(1, alice, _one(gaugeA), _weights(4_000), 100e18);
        assertEq(reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH), 40e18, "direct pass ignored scale");

        // And the delegate pass, which divides by the scale separately.
        deleg.setDelegate(alice, VOTE_EPOCH, dele);
        helper.setContribution(1, dele, alice, 50e18);
        tenK.setVote(1, dele, _one(gaugeA), _weights(2_000), 999e18);
        assertEq(
            reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH),
            40e18 + 10e18,
            "delegate pass ignored scale"
        );
    }

    /// Both entry points carry the same epoch-range guard every other epoch-taking view has.
    function test_honoursTheEpochRangeGuards() public {
        _excludeBefore(alice, gaugeA);
        uint256 belowDeploy = uint256(reg.deployEpoch()) - 2;
        uint256 aboveMax = reg.currentEpoch() + 4;
        address[] memory one_ = _one(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.PreDeployEpoch.selector, belowDeploy, reg.deployEpoch()
            )
        );
        reg.withheldWeightAtEpoch(gaugeA, belowDeploy);

        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.PreDeployEpoch.selector, belowDeploy, reg.deployEpoch()
            )
        );
        reg.withheldWeightForUsers(gaugeA, belowDeploy, one_);

        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.FutureEpoch.selector, aboveMax, reg.maxQueryableEpoch()
            )
        );
        reg.withheldWeightAtEpoch(gaugeA, aboveMax);

        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.FutureEpoch.selector, aboveMax, reg.maxQueryableEpoch()
            )
        );
        reg.withheldWeightForUsers(gaugeA, aboveMax, one_);
    }

    /// An epoch inside the answerable range but before any proposal existed.
    function test_refusesAnEpochBeforeTheFirstProposal() public {
        _excludeBefore(alice, gaugeA);
        uint256 early = FIRST_PROPOSAL_EPOCH - 80; // above deployEpoch, below proposal 0

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, early)
        );
        reg.withheldWeightAtEpoch(gaugeA, early);
    }

    /// When the platform is several cycles behind the epoch asked for, the derived id sits
    /// past the end of the array and the downward probe walks further past it. The real
    /// `proposals` getter panics there, so the bound has to hold — this asks about an epoch
    /// two cycles beyond the last proposal, which is where an unguarded probe indexes
    /// `proposals[count]`.
    function test_refusesAnEpochBeyondTheLastProposalWithoutPanicking() public {
        MockVotePlatform behind = new MockVotePlatform();
        behind.setGaugeRegistry(address(gr));
        behind.setDelegation(address(deleg));
        behind.addProposal(uint48(FIRST_PROPOSAL_EPOCH)); // id 0, epoch 230
        behind.addProposal(uint48(VOTE_EPOCH)); // id 1, epoch 232

        vm.prank(owner);
        reg.setVoteSources(address(behind), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
        _excludeBefore(alice, gaugeA);

        // derived for 234 is 2, one past the end: the upward probe is bounded, the downward
        // one lands on id 1 and is in range.
        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH + 2)
        );
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH + 2);

        // derived for 236 is 3, two past the end: the first downward probe is `proposals[2]`,
        // which does not exist.
        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH + 4)
        );
        reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH + 4);
    }

    /// A platform with no proposals at all cannot be configured against.
    function test_setVoteSourcesRejectsAPlatformWithNoProposals() public {
        MockVotePlatform empty = new MockVotePlatform();
        empty.setGaugeRegistry(address(gr));
        empty.setDelegation(address(deleg));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.NoProposalForEpoch.selector, uint256(FIRST_PROPOSAL_EPOCH)
            )
        );
        reg.setVoteSources(address(empty), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
    }

    // ------------------------------------------------------------------
    // The caller-supplied form
    // ------------------------------------------------------------------

    function test_forUsersMatchesTheSelfGatheredTotal() public {
        _excludeBefore(alice, gaugeA);
        _excludeBefore(bob, gaugeA);
        platform.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);
        platform.setVote(1, bob, _one(gaugeA), _weights(250_000), 80e18);

        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;

        assertEq(
            reg.withheldWeightForUsers(gaugeA, VOTE_EPOCH, both),
            reg.withheldWeightAtEpoch(gaugeA, VOTE_EPOCH),
            "slice total != whole"
        );
    }

    function test_forUsersRejectsAddressesThatAreNotExcluded() public {
        _excludeBefore(alice, gaugeA);

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NotExcluded.selector, gaugeA, carol)
        );
        reg.withheldWeightForUsers(gaugeA, VOTE_EPOCH, _one(carol));
    }

    function test_forUsersRejectsDuplicates() public {
        _excludeBefore(alice, gaugeA);
        platform.setVote(1, alice, _one(gaugeA), _weights(400_000), 100e18);

        address[] memory twice = new address[](2);
        twice[0] = alice;
        twice[1] = alice;

        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.DuplicateUser.selector, alice));
        reg.withheldWeightForUsers(gaugeA, VOTE_EPOCH, twice);

        // And a repeat that is not at index 0, which a check looking only at the first entry
        // would miss. Both addresses have to be excluded for the duplicate to be what refuses.
        _excludeBefore(bob, gaugeA);
        address[] memory late = new address[](3);
        late[0] = alice;
        late[1] = bob;
        late[2] = bob;

        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.DuplicateUser.selector, bob));
        reg.withheldWeightForUsers(gaugeA, VOTE_EPOCH, late);
    }

    function test_emptyGaugeWithholdsNothing() public view {
        assertEq(reg.withheldWeightAtEpoch(gaugeB, VOTE_EPOCH), 0);
    }

    /// A gauge with nobody excluded must still refuse an epoch that carries no proposal, and
    /// an unconfigured instance. Zero on those inputs is indistinguishable from a real answer.
    function test_emptyGaugeStillHonoursTheGuards() public {
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.OddEpoch.selector, VOTE_EPOCH + 1));
        reg.withheldWeightAtEpoch(gaugeB, VOTE_EPOCH + 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.NoProposalForEpoch.selector, VOTE_EPOCH + 2)
        );
        reg.withheldWeightAtEpoch(gaugeB, VOTE_EPOCH + 2);

        OptOutRegistry fresh = new OptOutRegistry("u", owner, address(vl), address(gr), 1);
        // Read the epoch first: `expectRevert` applies to the next call, and an argument that
        // is itself a call would consume it.
        uint256 now_ = fresh.currentEpoch();
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesNotSet.selector));
        fresh.withheldWeightAtEpoch(gaugeB, now_);
    }

    /// The scale is read from the platform, so it has to be usable.
    function test_setVoteSourcesRejectsAnUnusableScale() public {
        MockVotePlatform bad = new MockVotePlatform();
        bad.setGaugeRegistry(address(gr));
        bad.setDelegation(address(deleg));
        bad.addProposal(uint48(FIRST_PROPOSAL_EPOCH));

        bad.setMaxWeight(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.InvalidVoteWeightScale.selector, 0));
        reg.setVoteSources(address(bad), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);

        uint256 tooBig = uint256(type(uint64).max) + 1;
        bad.setMaxWeight(tooBig);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.InvalidVoteWeightScale.selector, tooBig)
        );
        reg.setVoteSources(address(bad), address(helper), address(deleg), FIRST_PROPOSAL_EPOCH);
    }
}

