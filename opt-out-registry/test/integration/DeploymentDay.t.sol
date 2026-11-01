// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {GaugeVotePlatform} from "../../reference/GaugeVotePlatform.sol";

interface ICurveRegistry {
    function isRegisteredGauge(address) external view returns (bool);
}

/// What an instance deployed today can and cannot say about a vote already in progress.
///
/// Every mutation takes effect at the *next* epoch, so an opt-out made during the epoch a
/// proposal is being voted in cannot apply to that proposal. This asserts it against a real
/// voter in the live proposal rather than a synthetic one: the holder has already cast a vote
/// worth tens of thousands of vlCVX into a gauge, opts out of that exact gauge, and the
/// instance must still withhold nothing from the vote in flight.
contract DeploymentDayTest is Test {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CURVE_REGISTRY = 0x96b24E0534B0cA31D8523D4be4904747Fd579D95;
    address constant CURVE_PLATFORM = 0x64D9B5AC386B70af9EDCD20A58cE9262D2EAC278;
    address constant VOTE_HELPER = 0x76C484F67898EA978aa874dc7B32e648380FB9b1;
    address constant DELEGATION = 0xb8270eef1319173dE9f5033FED442F638ff1607d;

    uint256 constant WEEK = 604800;
    uint32 constant FIRST_PROPOSAL_EPOCH = 230;

    OptOutRegistry reg;
    address owner = address(0xA11CE);
    uint256 epoch0Date;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        (, uint32 e0) = IvlCVX(VLCVX).epochs(0);
        epoch0Date = uint256(e0);

        // Deployed now, exactly as it would be on the day.
        reg = new OptOutRegistry("curve", owner, VLCVX, CURVE_REGISTRY, 1000e18);
        vm.prank(owner);
        reg.setVoteSources(CURVE_PLATFORM, VOTE_HELPER, DELEGATION, FIRST_PROPOSAL_EPOCH);
    }

    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp - epoch0Date) / WEEK;
    }

    function test_withholdsNothingFromTheVoteAlreadyInProgress() public {
        uint256 current = _currentEpoch();
        uint256 lastId = GaugeVotePlatform(CURVE_PLATFORM).proposalCount() - 1;
        (uint48 start, uint48 end, uint48 propEpoch) =
            GaugeVotePlatform(CURVE_PLATFORM).proposals(lastId);

        console.log("current epoch      ", current);
        console.log("deployEpoch        ", reg.deployEpoch());
        console.log("latest proposal id ", lastId);
        console.log("its epoch          ", uint256(propEpoch));

        // Only meaningful while a proposal for the epoch we deployed in is open. That is the
        // deployment-day condition; at other times there is nothing in flight to ask about.
        if (uint256(propEpoch) != current) {
            console.log("no proposal for the current epoch; nothing in flight");
            vm.skip(true);
        }
        assertLe(uint256(start), block.timestamp, "proposal has not opened");
        assertGe(uint256(end), block.timestamp, "proposal has already closed");

        // A holder who has already voted in it, and the gauge they backed.
        address voter = GaugeVotePlatform(CURVE_PLATFORM).getVoterAtIndex(lastId, 0);
        (address[] memory gauges, uint256[] memory weights,, uint256 baseWeight,) =
            GaugeVotePlatform(CURVE_PLATFORM).getVote(lastId, voter);
        require(gauges.length > 0, "first voter cast no gauge weights");
        address gauge = gauges[0];

        console.log("voter              ", voter);
        console.log("gauge              ", gauge);
        console.log("their weight       ", baseWeight);
        console.log("allocation to gauge", weights[0]);

        assertTrue(ICurveRegistry(CURVE_REGISTRY).isRegisteredGauge(gauge), "gauge not listed");
        assertGt(
            GaugeVotePlatform(CURVE_PLATFORM).gaugeTotal(lastId, gauge),
            0,
            "gauge has no credited weight, so withholding nothing proves nothing"
        );

        // Before anyone has opted out of anything.
        assertEq(reg.withheldWeightAtEpoch(gauge, current), 0, "nonzero before any opt-out");

        // Now the holder opts out of the very gauge they just voted for.
        vm.prank(voter);
        reg.optOut(_oneGauge(gauge));

        // It takes effect next epoch, not this one.
        assertFalse(reg.isOptedOutAtEpoch(gauge, voter, current), "excluded in the current epoch");
        assertTrue(reg.isOptedOutAtEpoch(gauge, voter, current + 1), "not excluded next epoch");

        // So the vote in flight is untouched: nothing is withheld from it.
        assertEq(
            reg.withheldWeightAtEpoch(gauge, current),
            0,
            "withheld weight appeared in the live vote"
        );
        assertEq(reg.optOutCountAtEpoch(gauge, current), 0, "counted in the current epoch");
        assertEq(reg.optOutCountAtEpoch(gauge, current + 1), 1, "not counted next epoch");

        // The exclusion lands on the following epoch, which carries no proposal — proposals
        // run every other epoch — so the first vote it can affect is the one after that.
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.OddEpoch.selector, current + 1));
        reg.withheldWeightAtEpoch(gauge, current + 1);

        console.log("first vote this opt-out can affect: epoch", current + 2);
    }

    function _oneGauge(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }
}
