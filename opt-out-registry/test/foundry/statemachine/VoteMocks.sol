// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Stand-ins for the gauge-vote platform, the delegation registry and the vote helper.
/// @dev Only the read surface `OptOutRegistry` uses. The real contracts derive these answers
///      from vote and delegation history; here they are set directly, so a test can state the
///      situation it means to check rather than construct it.

contract MockVotePlatform {
    struct Vote {
        address[] gauges;
        uint256[] weights;
        bool voted;
        uint256 baseWeight;
    }

    mapping(uint256 => mapping(address => Vote)) internal votes;

    /// A real array, not a mapping. The deployed platform exposes `Proposal[] public proposals`,
    /// whose getter panics past the end; a mapping would return zeros forever and silently hide
    /// every array-bounds guard in the reader.
    struct Proposal {
        uint48 startTime;
        uint48 endTime;
        uint48 epoch;
    }

    Proposal[] internal props;

    uint256 public max_weight = 1_000_000;

    /// Lets a test offer a scale the registry should refuse.
    function setMaxWeight(uint256 _scale) external {
        max_weight = _scale;
    }

    /// The delegation registry and gauge registry this platform claims to serve.
    address public delegation;
    address public gaugeRegistry;

    function setDelegation(address _delegation) external {
        delegation = _delegation;
    }

    function setGaugeRegistry(address _gaugeRegistry) external {
        gaugeRegistry = _gaugeRegistry;
    }

    function addProposal(uint48 _epoch) external {
        props.push(Proposal({startTime: 0, endTime: 0, epoch: _epoch}));
    }

    function proposalCount() external view returns (uint256) {
        return props.length;
    }

    /// @dev Lets a test point a proposal at the wrong epoch, or zero it as `forceEndProposal`
    ///      does, to exercise the drift guard.
    function setProposalEpoch(uint256 _id, uint48 _epoch) external {
        props[_id].epoch = _epoch;
    }

    function setVote(
        uint256 _proposalId,
        address _user,
        address[] calldata _gauges,
        uint256[] calldata _weights,
        uint256 _baseWeight
    ) external {
        votes[_proposalId][_user] =
            Vote({gauges: _gauges, weights: _weights, voted: true, baseWeight: _baseWeight});
    }

    function proposals(uint256 _id) external view returns (uint48, uint48, uint48) {
        Proposal storage p = props[_id];
        return (p.startTime, p.endTime, p.epoch);
    }

    function getVote(uint256 _proposalId, address _user)
        external
        view
        returns (address[] memory, uint256[] memory, bool, uint256, int256)
    {
        Vote storage v = votes[_proposalId][_user];
        return (v.gauges, v.weights, v.voted, v.baseWeight, int256(0));
    }
}

contract MockDelegation {
    mapping(address => mapping(uint256 => address)) public delegateAt;

    function setDelegate(address _user, uint256 _epoch, address _delegate) external {
        delegateAt[_user][_epoch] = _delegate;
    }

    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address) {
        return delegateAt[_user][_epoch];
    }
}

contract MockVoteHelper {
    address public delegation;
    mapping(uint256 => mapping(address => mapping(address => uint256))) public contribution;

    constructor(address _delegation) {
        delegation = _delegation;
    }

    function setContribution(uint256 _proposalId, address _delegate, address _user, uint256 _weight)
        external
    {
        contribution[_proposalId][_delegate][_user] = _weight;
    }

    function getContributingWeights(
        uint256 _proposalId,
        address _delegate,
        address[] calldata _users,
        address
    ) external view returns (uint256[] memory out) {
        out = new uint256[](_users.length);
        for (uint256 i; i < _users.length; ++i) {
            out[i] = contribution[_proposalId][_delegate][_users[i]];
        }
    }
}
