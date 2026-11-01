// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {GaugeVoteHelper} from "../../reference/GaugeVoteHelper.sol";
import {GaugeVotePlatform} from "../../reference/GaugeVotePlatform.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICurveGaugeRegistry {
    function activeGauges(uint256) external view returns (address);
}

interface IDelegationLike {
    function setDelegate(address _delegate) external;
    function sync(address _user) external;
    function userWeightAtEpochOf(uint256 _epoch, address _user) external view returns (uint256);
    function getSyncSnapshot(address _user, uint256 _epoch) external view returns (uint256, uint256);
    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address);
}

/// End-to-end against the live Convex and Votium contracts on a fork.
///
/// The case this exists for: an address votes for a gauge itself *and* its delegate still
/// carries some of its weight into the same proposal. Both have to be withheld, and neither
/// may be counted twice. Getting there needs a specific sequence — vote, then relock expired
/// locks, then sync the delegation — because only a sync landing *after* the vote produces the
/// delegated increment the helper attributes to the delegate.
contract DelegatedExclusionTest is Test {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant CURVE_REGISTRY = 0x96b24E0534B0cA31D8523D4be4904747Fd579D95;
    address constant PLATFORM = 0x64D9B5AC386B70af9EDCD20A58cE9262D2EAC278;
    address constant DELEGATION = 0xb8270eef1319173dE9f5033FED442F638ff1607d;
    address constant GAUGE = 0xfB18127c1471131468a1AaD4785c19678e521D86;
    /// Convex core: owner of the platform, and an operator by virtue of that.
    address constant PLATFORM_OPERATOR = 0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74;
    /// The deployed helper, not one built here: this is the code production will read.
    address constant VOTE_HELPER = 0x76C484F67898EA978aa874dc7B32e648380FB9b1;

    uint256 constant WEEK = 604800;
    uint256 constant MAX_VOTE_WEIGHT = 1_000_000;
    uint32 constant FIRST_PROPOSAL_EPOCH = 230;
    uint256 constant LOCK = 2000e18;

    OptOutRegistry reg;
    GaugeVoteHelper helper;

    address owner = address(0xA11CE);
    address user = address(0xF00D01);
    address delegate = address(0xF00D02);
    address otherGauge;
    address thirdGauge;

    uint256 epoch0Date;
    address[] bystanders;
    uint256 constant BYSTANDERS = 24;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        (, uint32 e0) = IvlCVX(VLCVX).epochs(0);
        epoch0Date = uint256(e0);

        // A second registered gauge for the delegate's other 50%.
        for (uint256 i; i < 8; ++i) {
            address g = ICurveGaugeRegistry(CURVE_REGISTRY).activeGauges(i);
            if (g == GAUGE) continue;
            if (otherGauge == address(0)) otherGauge = g;
            else if (thirdGauge == address(0)) {
                thirdGauge = g;
                break;
            }
        }
        require(otherGauge != address(0) && thirdGauge != address(0), "need three gauges");

        helper = GaugeVoteHelper(VOTE_HELPER);
        assertEq(address(helper.delegation()), DELEGATION, "helper points elsewhere");

        reg = new OptOutRegistry("t", owner, VLCVX, CURVE_REGISTRY, 1e18);
        vm.prank(owner);
        reg.setVoteSources(PLATFORM, VOTE_HELPER, DELEGATION, FIRST_PROPOSAL_EPOCH);
    }

    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp - epoch0Date) / WEEK;
    }

    /// Land an hour into the given epoch, and bring the locker's epoch array with us.
    function _warpToEpoch(uint256 _epoch) internal {
        vm.warp(epoch0Date + _epoch * WEEK + 1 hours);
        IvlCVX(VLCVX).checkpointEpoch();
    }

    /// A proposal opens at the epoch boundary and runs five days, as they do in production.
    function _createProposal() internal {
        // Anchored on the locker's own epoch zero rather than `block.timestamp / WEEK`. Both
        // should give the same boundary, since `epoch0Date` is a multiple of a week, but the
        // latter returned a stale quotient under the IR pipeline here; this form is exact and
        // matches the epoch numbering the rest of the test uses.
        uint256 start = epoch0Date + _currentEpoch() * WEEK;
        vm.prank(PLATFORM_OPERATOR);
        GaugeVotePlatform(PLATFORM).createProposal(start, start + 5 days);
    }

    /// Start the scenario on an ODD epoch, warping forward one if need be.
    ///
    /// The staggered locks leave exactly one epoch in which the first has expired and the
    /// second has not — `startEpoch + 17` — and the vote has to happen there, so that epoch
    /// must carry a proposal and therefore be even. That only holds when the scenario starts
    /// on an odd epoch. Starting on an even one pushes the vote a further epoch out, by which
    /// time the second lock has expired too and the holder has no weight left.
    ///
    /// Normalising here rather than reading the clock makes the test independent of the week
    /// it runs in; it previously passed only because the epoch it was written in was odd.
    /// It also puts the first proposal this test creates beyond the newest live one, which
    /// `createProposal` requires.
    function _startOnOddEpoch() internal returns (uint256) {
        uint256 e = _currentEpoch();
        if (e % 2 == 0) {
            _warpToEpoch(e + 1);
            return e + 1;
        }
        return e;
    }

    function _vote(address _who, address[] memory _gauges, uint256[] memory _weights) internal {
        vm.prank(_who);
        GaugeVotePlatform(PLATFORM).vote(_who, _gauges, _weights);
    }

    function test_withholdsOwnVoteAndDelegatedWeight() public {
        uint256 startEpoch = _startOnOddEpoch();
        deal(CVX, user, LOCK * 2);

        // 1-3. Lock, delegate, opt out of the gauge.
        vm.startPrank(user);
        IERC20(CVX).approve(VLCVX, type(uint256).max);
        IvlCVX(VLCVX).lock(user, LOCK, 0);
        IDelegationLike(DELEGATION).setDelegate(delegate);
        address[] memory one = new address[](1);
        one[0] = GAUGE;
        reg.optOut(one);
        vm.stopPrank();

        // Bystanders: locked and excluded from the same gauge, but they never vote and never
        // delegate. They add nothing to the total and everything to the cost of reading it,
        // which is what makes them the right shape for measuring the per-address price.
        for (uint256 i; i < BYSTANDERS; ++i) {
            address b = address(uint160(0xB0000 + i));
            bystanders.push(b);
            deal(CVX, b, LOCK);
            vm.startPrank(b);
            IERC20(CVX).approve(VLCVX, type(uint256).max);
            IvlCVX(VLCVX).lock(b, LOCK, 0);
            reg.optOut(one);
            // A third of them are also excluded from the second gauge, giving a shorter list
            // to compare the whole-list read against.
            if (i < 8) {
                address[] memory two_ = new address[](1);
                two_[0] = otherGauge;
                reg.optOut(two_);
            }
            vm.stopPrank();
        }

        // 4. A second lock the following epoch, so one expires before the other.
        _warpToEpoch(startEpoch + 1);
        vm.prank(user);
        IvlCVX(VLCVX).lock(user, LOCK, 0);
        // Delegated weight is checkpointed forward when the delegation is set, so a later
        // lock has to be synced for the delegate to carry it. Without this the recorded
        // weight at the vote epoch stays at what the first lock alone implied.
        IDelegationLike(DELEGATION).sync(user);

        // The proposal to vote in opens once the first lock has expired: 16 epochs after the
        // epoch it began counting in, which is the epoch after it was made.
        uint256 voteEpoch = startEpoch + 1 + 16;
        if (voteEpoch % 2 != 0) voteEpoch += 1;

        // Proposals run every other epoch, and the platform will not open one until the
        // previous has ended, so they have to be created in sequence.
        for (uint256 e = startEpoch + 1; e <= voteEpoch; ++e) {
            if (e % 2 != 0) continue;
            _warpToEpoch(e);
            _createProposal();
        }

        _warpToEpoch(voteEpoch);

        // Only the second lock still counts at the vote epoch.
        uint256 baseAtVote = IvlCVX(VLCVX).balanceAtEpochOf(voteEpoch, user);
        console.log("user weight at vote epoch", baseAtVote);
        assertEq(baseAtVote, LOCK, "one lock should have expired");

        console.log("delegated weight before vote", IDelegationLike(DELEGATION).userWeightAtEpochOf(voteEpoch, user));

        // 5. The user votes their remaining weight entirely into the opted-out gauge. This
        // works despite the expired lock only because the delegated weight already matches:
        // otherwise `vote` calls `syncAtEpoch`, which reverts `ExpiredLocks`.
        uint256[] memory full = new uint256[](1);
        full[0] = MAX_VOTE_WEIGHT;
        _vote(user, one, full);

        // 6-7. Relock the expired lock, then sync. The sync lands *after* the vote, so it
        // records a snapshot the helper diffs into weight carried by the delegate.
        vm.prank(user);
        IvlCVX(VLCVX).processExpiredLocks(true);
        IDelegationLike(DELEGATION).sync(user);

        // The increment is what the delegate carries: the sync raised the recorded weight
        // from one lock to two, and the snapshot remembers where it started.
        (uint256 preSync,) = IDelegationLike(DELEGATION).getSyncSnapshot(user, voteEpoch);
        uint256 afterSync = IDelegationLike(DELEGATION).userWeightAtEpochOf(voteEpoch, user);
        console.log("delegated weight after sync", afterSync);
        assertEq(preSync, LOCK, "snapshot should capture the pre-relock weight");
        assertEq(afterSync, LOCK * 2, "relock should raise the recorded weight");

        // 8. The delegate splits its vote between the opted-out gauge and another.
        address[] memory two = new address[](2);
        two[0] = GAUGE;
        two[1] = otherGauge;
        uint256[] memory half = new uint256[](2);
        half[0] = MAX_VOTE_WEIGHT / 2;
        half[1] = MAX_VOTE_WEIGHT / 2;
        _vote(delegate, two, half);

        // 9. The registry should report both halves of the exclusion.
        uint256 g0 = gasleft();
        uint256 withheld = reg.withheldWeightAtEpoch(GAUGE, voteEpoch);
        uint256 wholeListGas = g0 - gasleft();
        console.log("withheld", withheld);
        console.log("excluded addresses", reg.optOutCountAtEpoch(GAUGE, voteEpoch));
        console.log("withheldWeightAtEpoch gas", wholeListGas);
        // Loose ceiling: catches a structural regression in the read without being brittle
        // about a few percent. 25 addresses currently cost ~600k.
        assertLt(wholeListGas, 1_000_000, "whole-list read got materially dearer");

        uint256 g2 = gasleft();
        reg.withheldWeightAtEpoch(otherGauge, voteEpoch);
        uint256 shortListGas = g2 - gasleft();
        console.log("short list addresses", reg.optOutCountAtEpoch(otherGauge, voteEpoch));
        console.log("short list gas", shortListGas);
        console.log(
            "whole-list marginal per address",
            (wholeListGas - shortListGas)
                / (reg.optOutCountAtEpoch(GAUGE, voteEpoch) - reg.optOutCountAtEpoch(otherGauge, voteEpoch))
        );

        // One delegating, voting address against one plain excluded address: the difference is
        // what resolving a delegate costs.
        address[] memory justUser = new address[](1);
        justUser[0] = user;
        uint256 g3 = gasleft();
        reg.withheldWeightForUsers(GAUGE, voteEpoch, justUser);
        console.log("one delegating voter", g3 - gasleft());

        address[] memory justBystander = new address[](1);
        justBystander[0] = bystanders[0];
        uint256 g4 = gasleft();
        reg.withheldWeightForUsers(GAUGE, voteEpoch, justBystander);
        console.log("one plain address   ", g4 - gasleft());

        // Marginal cost per address, from slices of the same list.
        uint256 prevGas;
        uint256 prevSize;
        for (uint256 k = 1; k <= BYSTANDERS; k = k == 1 ? 8 : k + 8) {
            address[] memory slice = new address[](k);
            for (uint256 i; i < k; ++i) slice[i] = bystanders[i];
            uint256 g1 = gasleft();
            reg.withheldWeightForUsers(GAUGE, voteEpoch, slice);
            uint256 used = g1 - gasleft();
            if (prevSize != 0) {
                console.log("  marginal per address", (used - prevGas) / (k - prevSize));
            }
            console.log("slice", k, "gas", used);
            prevGas = used;
            prevSize = k;
        }
        assertEq(withheld, 3000e18, "expected 2000 direct + 1000 via delegate");

        // The caller-supplied form agrees over the same single-address list.
        address[] memory users = new address[](1);
        users[0] = user;
        assertEq(reg.withheldWeightForUsers(GAUGE, voteEpoch, users), withheld, "slice != whole");

        // And the other gauge withholds nothing: nobody is excluded from it.
        assertEq(reg.withheldWeightAtEpoch(otherGauge, voteEpoch), 0, "other gauge");
    }

    /// The same sixteen-epoch path as above, but with the weight genuinely split on both
    /// sides rather than an all-or-nothing vote.
    ///
    /// The holder puts only part of its own vote on the excluded gauge and the rest elsewhere;
    /// its delegate does the same with the weight it carries. Both express their allocation to
    /// the excluded gauge as **two entries for the same gauge**, which the platform accepts and
    /// credits as the sum — the shape that let an excluded holder keep nearly all its rewards
    /// until `_voteShare` was changed to add every matching entry. That fix is pinned on mocks;
    /// this is the first time it is exercised against the deployed platform.
    ///
    ///   holder   400,000 + 200,000 on the excluded gauge, 400,000 elsewhere
    ///            -> 2,000 * 60%  = 1,200 withheld from its own vote
    ///   delegate 250,000 + 250,000 on the excluded gauge, 500,000 elsewhere
    ///            -> 2,000 carried * 50% = 1,000 withheld through the delegate
    function test_withholdsSplitVotesOnBothSides() public {
        uint256 startEpoch = _startOnOddEpoch();
        deal(CVX, user, LOCK * 2);

        vm.startPrank(user);
        IERC20(CVX).approve(VLCVX, type(uint256).max);
        IvlCVX(VLCVX).lock(user, LOCK, 0);
        IDelegationLike(DELEGATION).setDelegate(delegate);
        address[] memory one = new address[](1);
        one[0] = GAUGE;
        reg.optOut(one);
        vm.stopPrank();

        _warpToEpoch(startEpoch + 1);
        vm.prank(user);
        IvlCVX(VLCVX).lock(user, LOCK, 0);
        IDelegationLike(DELEGATION).sync(user);

        uint256 voteEpoch = startEpoch + 1 + 16;
        if (voteEpoch % 2 != 0) voteEpoch += 1;
        for (uint256 e = startEpoch + 1; e <= voteEpoch; ++e) {
            if (e % 2 != 0) continue;
            _warpToEpoch(e);
            _createProposal();
        }
        _warpToEpoch(voteEpoch);

        assertEq(IvlCVX(VLCVX).balanceAtEpochOf(voteEpoch, user), LOCK, "one lock should expire");

        // The holder's own vote: the excluded gauge named twice, plus a third of the weight
        // on a gauge nobody is excluded from.
        address[] memory ownGauges = new address[](3);
        ownGauges[0] = GAUGE;
        ownGauges[1] = GAUGE;
        ownGauges[2] = otherGauge;
        uint256[] memory ownWeights = new uint256[](3);
        ownWeights[0] = 400_000;
        ownWeights[1] = 200_000;
        ownWeights[2] = 400_000;
        _vote(user, ownGauges, ownWeights);

        // Relock and sync after the vote, which is what hands the increment to the delegate.
        vm.prank(user);
        IvlCVX(VLCVX).processExpiredLocks(true);
        IDelegationLike(DELEGATION).sync(user);

        // The delegate splits too, and also names the excluded gauge twice.
        address[] memory delGauges = new address[](3);
        delGauges[0] = GAUGE;
        delGauges[1] = GAUGE;
        delGauges[2] = thirdGauge;
        uint256[] memory delWeights = new uint256[](3);
        delWeights[0] = 250_000;
        delWeights[1] = 250_000;
        delWeights[2] = 500_000;
        _vote(delegate, delGauges, delWeights);

        uint256 ownShare = (LOCK * 600_000) / MAX_VOTE_WEIGHT; // 1,200
        uint256 viaDelegate = (LOCK * 500_000) / MAX_VOTE_WEIGHT; // 1,000
        uint256 withheld = reg.withheldWeightAtEpoch(GAUGE, voteEpoch);
        console.log("own share   ", ownShare);
        console.log("via delegate", viaDelegate);
        console.log("withheld    ", withheld);

        assertEq(withheld, ownShare + viaDelegate, "split weight on both sides");
        assertEq(withheld, 2200e18, "expected 1200 direct + 1000 via delegate");

        // The gauges the weight went to instead have nobody excluded from them.
        assertEq(reg.withheldWeightAtEpoch(otherGauge, voteEpoch), 0, "holder's other gauge");
        assertEq(reg.withheldWeightAtEpoch(thirdGauge, voteEpoch), 0, "delegate's other gauge");

        // And the platform agrees the excluded gauge really was credited both entries: the
        // holder's full 60% is in its total, not just the first 40%.
        uint256 pid = (voteEpoch - FIRST_PROPOSAL_EPOCH) / 2;
        uint256 credited = GaugeVotePlatform(PLATFORM).gaugeTotal(pid, GAUGE);
        console.log("platform gaugeTotal", credited);
        assertGe(credited, withheld, "platform credited less than we withhold");
    }

    /// Exactly what a force-end does to the id numbering, against the live platform.
    function test_forceEndShiftsTheProposalNumbering() public {
        // The next even epoch after an odd start, which is past the newest live proposal —
        // `createProposal` refuses while the previous one is still running.
        uint256 e = _startOnOddEpoch() + 1;
        _warpToEpoch(e);

        uint256 countBefore = GaugeVotePlatform(PLATFORM).proposalCount();
        _createProposal();
        uint256 id = GaugeVotePlatform(PLATFORM).proposalCount() - 1;
        (,, uint48 epochBefore) = GaugeVotePlatform(PLATFORM).proposals(id);
        console.log("created id", id, "epoch", epochBefore);

        // Only the latest proposal can be force-ended, and only while it is still live.
        vm.prank(PLATFORM_OPERATOR);
        GaugeVotePlatform(PLATFORM).forceEndProposal();
        (uint48 s2, uint48 e2, uint48 ep2) = GaugeVotePlatform(PLATFORM).proposals(id);
        console.log("after forceEnd: start", s2, "end", e2);
        console.log("after forceEnd: epoch", ep2);
        assertEq(GaugeVotePlatform(PLATFORM).proposalCount(), countBefore + 1, "slot is kept");

        // The zeroed endTime means the next create is not blocked by PrevNotEnded.
        _createProposal();
        uint256 newId = GaugeVotePlatform(PLATFORM).proposalCount() - 1;
        (,, uint48 ep3) = GaugeVotePlatform(PLATFORM).proposals(newId);
        console.log("recreated id", newId, "epoch", ep3);

        assertEq(newId, id + 1, "replacement takes the next id");
        assertEq(uint256(ep3), e, "replacement covers the same epoch");
        assertEq(uint256(ep2), 0, "dead slot reports epoch zero");
    }
}
