// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IGaugeRegistry.sol";
import "./SurrogateRegistry.sol";
import "./Delegation.sol";
import "./interface/IvlCVX.sol";
import "./Ownable2Step.sol";

contract GaugeVotePlatform is Ownable2Step {
    string public name;

    error NotStarted();
    error Ended();
    error Mismatch();
    error NoWeight();
    error NotGauge();
    error MaxWeight();
    error PrevNotEnded();
    error BadTime();
    error AlreadyVoted();
    error NotVoteAuth();
    error NotSigner();
    error NotOperator();

    mapping(address => bool) public operators;

    IvlCVX public immutable vlCVX;
    IGaugeRegistry public immutable gaugeRegistry;
    SurrogateRegistry public immutable surrogateRegistry;
    Delegation public immutable delegation;

    uint256 public constant epochDuration = 86400 * 7;

    enum VoteStatus {
        None,
        VotedViaSurrogate,
        Voted
    }

    struct UserInfo {
        uint96 baseWeight;
        int96 adjustedWeight;
        uint48 lastVoteSyncNonce;
        uint8 voteStatus;
        address delegate;
        uint96 totalDelegationWeight;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => address[]) public votedUsers;

    struct Proposal {
        uint48 startTime;
        uint48 endTime;
        uint48 epoch;
    }

    struct GaugeVote {
        address gauge;
        uint32 weight;
    }

    struct GaugeTotalEntry {
        address gauge;
        uint96 totalWeight;
    }

    mapping(uint256 => GaugeTotalEntry[]) internal _gaugeEntries;
    mapping(uint256 => mapping(address => uint256)) internal _gaugeIndex;
    mapping(uint256 => uint256) public voteTotals;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => GaugeVote[])) internal votes;
    uint256 public constant max_weight = 1_000_000;
    uint256 public constant MIN_PROPOSAL_DURATION = 1 days;
    uint256 public constant MAX_PROPOSAL_DURATION = 6 days;
    uint256 private constant WEIGHT_DIVISOR = 1e17;

    mapping(address => bool) public equalizerAccounts;
    uint256 public constant overtime = 10 minutes;

    mapping(uint256 => mapping(address => int96)) public pendingWeightAdjustment;

    /// @notice Returns the current epoch start timestamp
    /// @return Current epoch start time
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochDuration * epochDuration;
    }

    /// @notice Returns the total number of proposals
    /// @return Proposal count
    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    /// @notice Returns the number of voters for a proposal
    /// @param _proposalId Proposal identifier
    /// @return Voter count
    function getVoterCount(uint256 _proposalId) external view returns (uint256) {
        return votedUsers[_proposalId].length;
    }

    /// @notice Returns the voter at a given index for a proposal
    /// @param _proposalId Proposal identifier
    /// @param _index Voter index
    /// @return Voter address
    function getVoterAtIndex(uint256 _proposalId, uint256 _index) external view returns (address) {
        return votedUsers[_proposalId][_index];
    }

    /// @notice Returns the total weight allocated to a gauge
    /// @param _proposalId Proposal identifier
    /// @param _gauge Gauge address
    /// @return Total weight
    function gaugeTotal(uint256 _proposalId, address _gauge) external view returns (uint256) {
        uint256 idx = _gaugeIndex[_proposalId][_gauge];
        if (idx == 0) return 0;
        return _gaugeEntries[_proposalId][idx - 1].totalWeight;
    }

    /// @notice Returns the number of gauges with votes for a proposal
    /// @param _proposalId Proposal identifier
    /// @return Gauge count
    function getGaugeCount(uint256 _proposalId) external view returns (uint256) {
        return _gaugeEntries[_proposalId].length;
    }

    /// @notice Returns a gauge entry by index for a proposal
    /// @param _proposalId Proposal identifier
    /// @param _index Gauge entry index
    /// @return gauge Gauge address
    /// @return totalWeight Total weight allocated
    function getGaugeEntry(uint256 _proposalId, uint256 _index) external view returns (address gauge, uint256 totalWeight) {
        GaugeTotalEntry storage entry = _gaugeEntries[_proposalId][_index];
        gauge = entry.gauge;
        totalWeight = entry.totalWeight;
    }

    /// @notice Returns vote details for a user on a proposal
    /// @param _proposalId Proposal identifier
    /// @param _user User address
    /// @return gauges Array of voted gauges
    /// @return weights Array of weights per gauge
    /// @return voted Whether user has voted
    /// @return baseWeight User's base voting weight
    /// @return adjustedWeight User's adjusted weight
    function getVote(uint256 _proposalId, address _user) public view returns (address[] memory gauges, uint256[] memory weights, bool voted, uint256 baseWeight, int256 adjustedWeight) {
        GaugeVote[] storage userVotes = votes[_proposalId][_user];
        uint256 len = userVotes.length;
        gauges = new address[](len);
        weights = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            gauges[i] = userVotes[i].gauge;
            weights[i] = userVotes[i].weight;
            unchecked { ++i; }
        }
        UserInfo storage u = userInfo[_proposalId][_user];
        voted = u.voteStatus > 0;
        baseWeight = u.baseWeight;
        adjustedWeight = u.adjustedWeight;
    }

    /// @notice Initializes base voting info for an account
    function _initBaseInfo(address _account, uint256 _proposalId) internal {
        UserInfo memory user = userInfo[_proposalId][_account];
        if (user.delegate != address(0)) return;

        uint256 epoch = proposals[_proposalId].epoch;

        uint256 baseWeight = vlCVX.balanceAtEpochOf(epoch, _account);
        address delegate = delegation.getDelegateAtEpoch(_account, epoch);

        if (delegate == address(0)) {
            delegate = _account;
        }

        if (delegate != _account) {
            uint256 delWeight = delegation.userWeightAtEpochOf(epoch, _account);
            uint256 truncatedBase = (baseWeight / WEIGHT_DIVISOR) * WEIGHT_DIVISOR;
            if (truncatedBase != delWeight) {
                delegation.syncAtEpoch(_account, epoch);
            }
        }

        uint256 totalDelWeight = delegation.balanceAtEpochOf(epoch, _account);

        user.baseWeight = uint96(baseWeight);
        user.delegate = delegate;
        user.adjustedWeight += int96(int256(totalDelWeight));
        user.totalDelegationWeight = uint96(totalDelWeight);

        userInfo[_proposalId][_account] = user;

        emit UserWeightChange(_proposalId, _account, baseWeight, user.adjustedWeight);

        if (delegate != _account) {
            UserInfo storage del = userInfo[_proposalId][delegate];

            if (del.voteStatus == 0) {
                del.adjustedWeight -= int96(int256(delegation.userWeightAtEpochOf(epoch, _account)));
            } else {
                uint256 currentDelWeight = delegation.userWeightAtEpochOf(epoch, _account);
                (uint256 snapWeight, uint256 snapNonce) = delegation.getSyncSnapshot(_account, epoch);
                int256 weightToRemove;

                if (snapNonce > 0 && snapNonce <= uint256(del.lastVoteSyncNonce)) {
                    weightToRemove = int256(currentDelWeight);
                } else if (snapNonce > 0) {
                    weightToRemove = int256(snapWeight);
                    int256 diff = int256(currentDelWeight) - int256(snapWeight);
                    if (diff > 0) {
                        pendingWeightAdjustment[_proposalId][delegate] -= int96(diff);
                        emit PendingWeightAdjustment(_proposalId, delegate, -diff);
                    }
                } else {
                    weightToRemove = int256(currentDelWeight);
                }

                GaugeVote[] storage delegateVotes = votes[_proposalId][delegate];
                uint256 len = delegateVotes.length;

                for (uint256 i = 0; i < len;) {
                    _changeGaugeTotal(_proposalId, delegateVotes[i].gauge, -(int256(uint256(delegateVotes[i].weight)) * weightToRemove / int256(max_weight)));
                    unchecked { ++i; }
                }

                voteTotals[_proposalId] -= uint256(weightToRemove);
                del.adjustedWeight -= int96(weightToRemove);
                emit GaugeWeightsUpdated(_proposalId, delegate);
            }

            emit UserWeightChange(_proposalId, delegate, del.baseWeight, del.adjustedWeight);
        }
    }

    /// @notice Casts or updates a gauge vote for an account
    function _vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) internal {
        uint256 proposalId = proposals.length - 1;
        Proposal storage prop = proposals[proposalId];
        if (block.timestamp < prop.startTime) revert NotStarted();
        if (equalizerAccounts[_account]) {
            if (block.timestamp > prop.endTime + overtime) revert Ended();
        } else {
            if (block.timestamp > prop.endTime) revert Ended();
        }
        if (_gauges.length != _weights.length) revert Mismatch();

        _initBaseInfo(_account, proposalId);

        UserInfo storage user = userInfo[proposalId][_account];

        if (user.voteStatus > 0) {
            int256 oldUserWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);

            GaugeVote[] storage oldVotes = votes[proposalId][_account];
            uint256 oldLen = oldVotes.length;
            for (uint256 i = 0; i < oldLen;) {
                _changeGaugeTotal(proposalId, oldVotes[i].gauge, -(int256(uint256(oldVotes[i].weight)) * oldUserWeight / int256(max_weight)));
                unchecked { ++i; }
            }

            uint256 currentBalance = vlCVX.balanceAtEpochOf(prop.epoch, _account);
            uint256 userBaseDiff = currentBalance - user.baseWeight;
            user.baseWeight = uint96(currentBalance);

            uint256 currentDelBal = delegation.balanceAtEpochOf(prop.epoch, _account);
            int256 delDelta = int256(currentDelBal) - int256(uint256(user.totalDelegationWeight));
            user.adjustedWeight += int96(delDelta);
            user.totalDelegationWeight = uint96(currentDelBal);

            if (userBaseDiff > 0 && user.delegate != address(0) && user.delegate != _account) {
                delegation.syncAtEpoch(_account, prop.epoch);
                
                uint256 currentDelWeight = delegation.userWeightAtEpochOf(prop.epoch, _account);
                (uint256 preSyncWeight, uint256 snapNonce) = delegation.getSyncSnapshot(_account, prop.epoch);
                int256 realDiff = int256(currentDelWeight) - int256(preSyncWeight);
                if (realDiff > 0) {
                    UserInfo storage del = userInfo[proposalId][user.delegate];
                    if (del.voteStatus > 0) {
                        if (snapNonce > 0 && snapNonce <= uint256(del.lastVoteSyncNonce)) {
                            GaugeVote[] storage delegateVotes = votes[proposalId][user.delegate];
                            uint256 len = delegateVotes.length;
                            for (uint256 i = 0; i < len;) {
                                _changeGaugeTotal(proposalId, delegateVotes[i].gauge, -(int256(uint256(delegateVotes[i].weight)) * realDiff / int256(max_weight)));
                                unchecked { ++i; }
                            }
                            voteTotals[proposalId] -= uint256(realDiff);
                            del.adjustedWeight -= int96(realDiff);
                        } else {
                            pendingWeightAdjustment[proposalId][user.delegate] -= int96(realDiff);
                            emit PendingWeightAdjustment(proposalId, user.delegate, -realDiff);
                        }
                    } else {
                        del.adjustedWeight -= int96(realDiff);
                    }
                }
            }

            int96 pend = pendingWeightAdjustment[proposalId][_account];
            if (pend != 0) {
                pendingWeightAdjustment[proposalId][_account] = 0;
                user.adjustedWeight += pend;
            }

            int256 newUserWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
            voteTotals[proposalId] = uint256(int256(voteTotals[proposalId]) - oldUserWeight + newUserWeight);

            emit UserWeightChange(proposalId, _account, user.baseWeight, user.adjustedWeight);
        }

        int256 userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        delete votes[proposalId][_account];
        uint256 totalweight;
        for (uint256 i = 0; i < _weights.length; i++) {
            if (_weights[i] == 0) revert NoWeight();
            if (!gaugeRegistry.isRegisteredGauge(_gauges[i])) revert NotGauge();
            votes[proposalId][_account].push(GaugeVote({gauge: _gauges[i], weight: uint32(_weights[i])}));
            totalweight += _weights[i];
        }
        if (totalweight != max_weight) revert MaxWeight();

        for (uint256 i = 0; i < _weights.length; i++) {
            _changeGaugeTotal(proposalId, _gauges[i], int256(_weights[i]) * userWeight / int256(max_weight));
        }
        emit GaugeWeightsUpdated(proposalId, _account);
        emit VoteCast(proposalId, _account, _gauges, _weights);

        user.lastVoteSyncNonce = uint48(delegation.syncNonce());

        if (user.voteStatus == 0) {
            user.voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
            votedUsers[proposalId].push(_account);
            voteTotals[proposalId] += uint256(userWeight);
        }
    }

    /// @notice Updates or inserts the total weight for a gauge
    function _changeGaugeTotal(uint256 _proposalId, address _gauge, int256 _changeValue) internal {
        if (_changeValue == 0) return;
        uint256 idx = _gaugeIndex[_proposalId][_gauge];
        uint256 absVal;
        unchecked {
            absVal = _changeValue > 0 ? uint256(_changeValue) : uint256(-_changeValue);
        }

        if (idx == 0) {
            if (_changeValue > 0) {
                _gaugeEntries[_proposalId].push(GaugeTotalEntry({gauge: _gauge, totalWeight: uint96(absVal)}));
                _gaugeIndex[_proposalId][_gauge] = _gaugeEntries[_proposalId].length;
            } else {
                revert("Negative gauge total");
            }
            return;
        }

        GaugeTotalEntry storage existing = _gaugeEntries[_proposalId][idx - 1];

        if (_changeValue > 0) {
            existing.totalWeight += uint96(absVal);
        } else {
            existing.totalWeight -= uint96(absVal);
        }

        if (existing.totalWeight == 0) {
            GaugeTotalEntry[] storage entries = _gaugeEntries[_proposalId];
            uint256 lastIdx = entries.length;
            if (idx < lastIdx) {
                GaugeTotalEntry storage last = entries[lastIdx - 1];
                existing.gauge = last.gauge;
                existing.totalWeight = last.totalWeight;
                _gaugeIndex[_proposalId][last.gauge] = idx;
            }
            entries.pop();
            _gaugeIndex[_proposalId][_gauge] = 0;
        }
    }

    /// @notice Casts or updates a gauge vote on the latest proposal
    /// @param _account Account to vote for
    /// @param _gauges Array of gauge addresses
    /// @param _weights Array of weights per gauge
    function vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        uint8 vs = userInfo[proposalId][_account].voteStatus;
        if (msg.sender != _account && vs >= uint8(VoteStatus.Voted)) revert NotVoteAuth();

        _vote(_account, _gauges, _weights);

        if (msg.sender == _account && vs == uint8(VoteStatus.VotedViaSurrogate)) {
            userInfo[proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    /// @notice Checks if a proposal is finalized (voting ended + overtime window)
    /// @param _proposalId Proposal identifier
    /// @return True if finalized
    function isFinalized(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime + overtime;
    }

    /// @notice Creates a new gauge proposal
    /// @param _startTime Unix timestamp when voting begins
    /// @param _endTime Unix timestamp when voting ends
    function createProposal(uint256 _startTime, uint256 _endTime) public onlyOperator {
        uint256 pCnt = proposals.length;
        if (pCnt > 0) {
            if (block.timestamp <= proposals[pCnt - 1].endTime + overtime) revert PrevNotEnded();
        }

        if (_endTime <= _startTime) revert BadTime();
        if (_endTime <= block.timestamp) revert BadTime();
        if (_endTime - _startTime < MIN_PROPOSAL_DURATION) revert BadTime();
        if (_endTime - _startTime > MAX_PROPOSAL_DURATION) revert BadTime();

        vlCVX.checkpointEpoch();
        uint256 epoch = vlCVX.epochCount() - 2;

        proposals.push(Proposal({
            startTime: uint48(_startTime),
            endTime: uint48(_endTime),
            epoch: uint48(epoch)
        }));
        emit NewProposal(proposals.length - 1, _startTime, _endTime);
    }

    /// @notice Forces the current proposal to end immediately
    function forceEndProposal() public onlyOperator {
        uint256 proposalId = proposals.length - 1;
        if (proposals[proposalId].startTime == 0) revert NotStarted();
        if (block.timestamp > proposals[proposalId].endTime + overtime) revert Ended();

        proposals[proposalId].startTime = 0;
        proposals[proposalId].endTime = 0;
        proposals[proposalId].epoch = 0;
        emit ForceEndProposal(proposalId);
    }

    /// @notice Sets an operator address
    /// @param _op Operator address
    /// @param _active True to add, false to remove
    function setOperator(address _op, bool _active) external onlyOwner {
        operators[_op] = _active;
        emit OperatorSet(_op, _active);
    }

    /// @notice Sets an equalizer account (gets overtime extension)
    /// @param _eq Account address
    /// @param _active True to enable overtime, false to disable
    function setOvertimeAccount(address _eq, bool _active) external onlyOwner {
        equalizerAccounts[_eq] = _active;
        emit EqualizerAccountSet(_eq, _active);
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && owner() != msg.sender) revert NotOperator();
        _;
    }

    modifier onlyAcceptedSigner(address _account) {
        if (msg.sender != _account && !surrogateRegistry.isSurrogate(msg.sender, _account)) revert NotSigner();
        _;
    }

    event VoteCast(uint256 indexed proposalId, address indexed user, address[] gauges, uint256[] weights);
    event NewProposal(uint256 indexed id, uint256 start, uint256 end);
    event ForceEndProposal(uint256 indexed id);
    event UserWeightChange(uint256 indexed pid, address indexed user, uint256 baseWeight, int256 adjustedWeight);
    event GaugeWeightsUpdated(uint256 indexed pid, address indexed user);
    event PendingWeightAdjustment(uint256 indexed pid, address indexed delegate, int256 diff);
    event OperatorSet(address indexed op, bool active);
    event EqualizerAccountSet(address indexed eq, bool active);

    /// @notice Creates a new GaugeVotePlatform contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _vlCVX Address of the vlCVX contract
    /// @param _gaugeRegistry Address of the gauge registry
    /// @param _surrogateRegistry Address of the SurrogateRegistry
    /// @param _delegation Address of the Delegation contract
    constructor(string memory _name, address _owner, address _vlCVX, address _gaugeRegistry, address _surrogateRegistry, address _delegation)
        Ownable(_owner)
    {
        name = _name;
        operators[_owner] = true;
        vlCVX = IvlCVX(_vlCVX);
        gaugeRegistry = IGaugeRegistry(_gaugeRegistry);
        surrogateRegistry = SurrogateRegistry(_surrogateRegistry);
        delegation = Delegation(_delegation);
    }

    /// @notice Returns the contract version
    /// @return _major Major version
    /// @return _minor Minor version
    /// @return _patch Patch version
    function version() external pure returns (uint256 _major, uint256 _minor, uint256 _patch) {
        _major = 1;
        _minor = 0;
        _patch = 0;
    }
}
