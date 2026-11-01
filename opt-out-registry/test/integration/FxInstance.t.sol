// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {GaugeVotePlatform} from "../../reference/GaugeVotePlatform.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

interface IFxRegistry {
    function activeGauges(uint256) external view returns (address);
}

interface IDelegationLike {
    function setDelegate(address _delegate) external;
    function sync(address _user) external;
}

/// The f(x) half of the deployment, against the live contracts.
///
/// Everything here is a second instance of what the Curve test already covers, which is the
/// point: the two instances are separate deployments reading separate platforms, and nothing
/// but the constructor arguments and one owner call distinguishes them. The failure this
/// guards against is subtle — a platform paired with the wrong registry does not revert, it
/// silently reports that nothing should be withheld.
contract FxInstanceTest is Test {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant FX_REGISTRY = 0xC2F99261d84D1665Df7e50F46813497A737AfB20;
    address constant CURVE_REGISTRY = 0x96b24E0534B0cA31D8523D4be4904747Fd579D95;
    address constant FX_PLATFORM = 0xDcEa673B021f1f431E7D0Ec70a63bF8DcB6d44E6;
    address constant CURVE_PLATFORM = 0x64D9B5AC386B70af9EDCD20A58cE9262D2EAC278;
    address constant VOTE_HELPER = 0x76C484F67898EA978aa874dc7B32e648380FB9b1;
    address constant DELEGATION = 0xb8270eef1319173dE9f5033FED442F638ff1607d;
    address constant PLATFORM_OPERATOR = 0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74;

    uint256 constant WEEK = 604800;
    uint256 constant MAX_VOTE_WEIGHT = 1_000_000;
    uint32 constant FIRST_PROPOSAL_EPOCH = 230;
    uint256 constant LOCK = 2000e18;

    OptOutRegistry reg;
    address owner = address(0xA11CE);
    address voter = address(0xF00DFF);
    address fxGauge;
    address fxGaugeB;
    address fxGaugeC;
    address delegate = address(0xF00DFE);
    uint256 epoch0Date;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        (, uint32 e0) = IvlCVX(VLCVX).epochs(0);
        epoch0Date = uint256(e0);

        fxGauge = IFxRegistry(FX_REGISTRY).activeGauges(0);
        fxGaugeB = IFxRegistry(FX_REGISTRY).activeGauges(1);
        fxGaugeC = IFxRegistry(FX_REGISTRY).activeGauges(2);

        reg = new OptOutRegistry("fx", owner, VLCVX, FX_REGISTRY, 1e18);
        vm.prank(owner);
        reg.setVoteSources(FX_PLATFORM, VOTE_HELPER, DELEGATION, FIRST_PROPOSAL_EPOCH);
    }

    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp - epoch0Date) / WEEK;
    }

    function _warpToEpoch(uint256 _epoch) internal {
        vm.warp(epoch0Date + _epoch * WEEK + 1 hours);
        IvlCVX(VLCVX).checkpointEpoch();
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _createProposal() internal {
        uint256 start = epoch0Date + _currentEpoch() * WEEK;
        vm.prank(PLATFORM_OPERATOR);
        GaugeVotePlatform(FX_PLATFORM).createProposal(start, start + 5 days);
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
        GaugeVotePlatform(FX_PLATFORM).vote(_who, _gauges, _weights);
    }

    function _split(address _a, uint256 _wa, address _b, uint256 _wb, address _c, uint256 _wc)
        internal
        pure
        returns (address[] memory gauges, uint256[] memory weights)
    {
        gauges = new address[](3);
        weights = new uint256[](3);
        (gauges[0], weights[0]) = (_a, _wa);
        (gauges[1], weights[1]) = (_b, _wb);
        (gauges[2], weights[2]) = (_c, _wc);
    }

    /// The pairing the contract now refuses, against the real deployed platforms rather than
    /// mocks. Both share a delegation registry, a weight scale and a proposal schedule, so the
    /// gauge registry is the only thing that tells them apart.
    function test_refusesTheCurvePlatformOnAnFxInstance() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesMismatch.selector));
        reg.setVoteSources(CURVE_PLATFORM, VOTE_HELPER, DELEGATION, FIRST_PROPOSAL_EPOCH);

        // And the mirror: the f(x) platform on a Curve instance.
        OptOutRegistry curveInstance =
            new OptOutRegistry("curve", owner, VLCVX, CURVE_REGISTRY, 1e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.VoteSourcesMismatch.selector));
        curveInstance.setVoteSources(FX_PLATFORM, VOTE_HELPER, DELEGATION, FIRST_PROPOSAL_EPOCH);
    }

    /// Moving the registry out from under a configured platform drops the pairing rather than
    /// leaving it answering zero. Verified here against the live platforms.
    function test_movingToTheCurveRegistryClearsTheFxSources() public {
        assertEq(address(reg.votePlatform()), FX_PLATFORM, "configured in setUp");

        vm.prank(owner);
        reg.setGaugeRegistry(CURVE_REGISTRY);

        assertEq(address(reg.votePlatform()), address(0), "stale pairing kept");
        assertEq(reg.maxVoteWeight(), 0, "scale kept");
    }

    /// The whole path on the f(x) side: exclude, vote, and read the weight back.
    function test_withholdsAnFxGaugeVote() public {
        uint256 startEpoch = _startOnOddEpoch();
        deal(CVX, voter, LOCK);

        vm.startPrank(voter);
        IERC20(CVX).approve(VLCVX, type(uint256).max);
        IvlCVX(VLCVX).lock(voter, LOCK, 0);
        reg.optOut(_one(fxGauge));
        vm.stopPrank();

        // The next even epoch carries the next proposal; create it as the operator does.
        uint256 voteEpoch = startEpoch % 2 == 0 ? startEpoch + 2 : startEpoch + 1;
        _warpToEpoch(voteEpoch);
        uint256 start = epoch0Date + voteEpoch * WEEK;
        vm.prank(PLATFORM_OPERATOR);
        GaugeVotePlatform(FX_PLATFORM).createProposal(start, start + 5 days);

        // 70% of the vote to the excluded gauge, 30% to another f(x) gauge.
        address[] memory gauges = new address[](2);
        gauges[0] = fxGauge;
        gauges[1] = fxGaugeB;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 700_000;
        weights[1] = 300_000;
        vm.prank(voter);
        GaugeVotePlatform(FX_PLATFORM).vote(voter, gauges, weights);

        uint256 base = IvlCVX(VLCVX).balanceAtEpochOf(voteEpoch, voter);
        uint256 expected = (base * 700_000) / MAX_VOTE_WEIGHT;
        console.log("fx voter weight", base);
        console.log("withheld       ", reg.withheldWeightAtEpoch(fxGauge, voteEpoch));

        assertEq(base, LOCK, "voter weight at the vote epoch");
        assertEq(reg.withheldWeightAtEpoch(fxGauge, voteEpoch), expected, "excluded gauge");
        // The other gauge has nobody excluded from it, so nothing is withheld there.
        assertEq(reg.withheldWeightAtEpoch(fxGaugeB, voteEpoch), 0, "unexcluded gauge");
    }

    /// The full sixteen-epoch path on the f(x) side: a holder whose vlCVX is split across two
    /// locks, the first of which expires at the vote epoch, voting part of its own weight to a
    /// gauge it is excluded from while its delegate carries the rest.
    ///
    /// Same structure as the Curve scenario, deliberately with different splits so a
    /// copy-paste that quietly read the wrong platform would not produce the right number.
    /// Both sides name the excluded gauge twice, which the platform credits as the sum.
    ///
    ///   holder   300,000 + 300,000 on the excluded gauge, 400,000 elsewhere -> 60% of 2,000
    ///   delegate 400,000 + 200,000 on the excluded gauge, 400,000 elsewhere -> 60% of 2,000
    function test_withholdsSplitVotesOnBothSidesOnFx() public {
        uint256 startEpoch = _startOnOddEpoch();
        deal(CVX, voter, LOCK * 2);

        vm.startPrank(voter);
        IERC20(CVX).approve(VLCVX, type(uint256).max);
        IvlCVX(VLCVX).lock(voter, LOCK, 0);
        IDelegationLike(DELEGATION).setDelegate(delegate);
        reg.optOut(_one(fxGauge));
        vm.stopPrank();

        // A second lock the following epoch, synced so the delegate carries it. Without the
        // sync the delegated weight at the vote epoch reflects only the first lock, which by
        // then has expired.
        _warpToEpoch(startEpoch + 1);
        vm.prank(voter);
        IvlCVX(VLCVX).lock(voter, LOCK, 0);
        IDelegationLike(DELEGATION).sync(voter);

        uint256 voteEpoch = startEpoch + 1 + 16;
        if (voteEpoch % 2 != 0) voteEpoch += 1;
        for (uint256 e = startEpoch + 1; e <= voteEpoch; ++e) {
            if (e % 2 != 0) continue;
            _warpToEpoch(e);
            _createProposal();
        }
        _warpToEpoch(voteEpoch);

        // Only the second lock still counts here; the first expired at this epoch.
        assertEq(IvlCVX(VLCVX).balanceAtEpochOf(voteEpoch, voter), LOCK, "one lock should expire");

        (address[] memory ownGauges, uint256[] memory ownWeights) =
            _split(fxGauge, 300_000, fxGauge, 300_000, fxGaugeB, 400_000);
        _vote(voter, ownGauges, ownWeights);

        // Relock and sync after the vote: that is what hands the increment to the delegate.
        vm.prank(voter);
        IvlCVX(VLCVX).processExpiredLocks(true);
        IDelegationLike(DELEGATION).sync(voter);

        (address[] memory delGauges, uint256[] memory delWeights) =
            _split(fxGauge, 400_000, fxGauge, 200_000, fxGaugeC, 400_000);
        _vote(delegate, delGauges, delWeights);

        uint256 ownShare = (LOCK * 600_000) / MAX_VOTE_WEIGHT; // 1,200
        uint256 viaDelegate = (LOCK * 600_000) / MAX_VOTE_WEIGHT; // 1,200
        uint256 withheld = reg.withheldWeightAtEpoch(fxGauge, voteEpoch);
        console.log("fx own share   ", ownShare);
        console.log("fx via delegate", viaDelegate);
        console.log("fx withheld    ", withheld);

        assertEq(withheld, ownShare + viaDelegate, "split weight on both sides");
        assertEq(withheld, 2400e18, "expected 1200 direct + 1200 via delegate");

        // The gauges the rest of the weight went to have nobody excluded from them.
        assertEq(reg.withheldWeightAtEpoch(fxGaugeB, voteEpoch), 0, "holder's other gauge");
        assertEq(reg.withheldWeightAtEpoch(fxGaugeC, voteEpoch), 0, "delegate's other gauge");

        // The f(x) platform's own accounting for that proposal should agree.
        uint256 pid = (voteEpoch - FIRST_PROPOSAL_EPOCH) / 2;
        uint256 credited = GaugeVotePlatform(FX_PLATFORM).gaugeTotal(pid, fxGauge);
        console.log("fx platform gaugeTotal", credited);
        assertEq(credited, withheld, "platform total != withheld");
    }
}
