// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Delegation.sol";
import "./GaugeVotePlatform.sol";

contract GaugeVoteHelper {
    string public name;
    Delegation public immutable delegation;

    /// @notice Creates a new GaugeVoteHelper contract
    /// @param _name Contract name identifier
    /// @param _delegation Address of the Delegation contract
    constructor(string memory _name, address _delegation) {
        name = _name;
        delegation = Delegation(_delegation);
    }

    /// @notice Computes contributing weights for users delegating to a given delegate
    /// @param _proposalId Proposal identifier
    /// @param _delegate Delegate address to check delegation against
    /// @param _users Array of user addresses to compute weights for
    /// @param _gaugePlatform GaugeVotePlatform contract reference
    /// @return weights Array of contributing weights for each user
    function getContributingWeights(
        uint256 _proposalId,
        address _delegate,
        address[] calldata _users,
        GaugeVotePlatform _gaugePlatform
    ) external view returns (uint256[] memory) {
        uint256 len = _users.length;
        uint256[] memory weights = new uint256[](len);

        (,, uint48 propEpoch) = _gaugePlatform.proposals(_proposalId);
        (,, uint48 delLastVoteSyncNonce, uint8 delVoteStatus,,) = _gaugePlatform.userInfo(_proposalId, _delegate);

        for (uint256 i; i < len;) {
            address user = _users[i];

            address userDelegate = delegation.getDelegateAtEpoch(user, uint256(propEpoch));
            if (userDelegate != _delegate) {
                unchecked { ++i; }
                continue;
            }

            uint256 packedWeight = delegation.userWeightAtEpochOf(uint256(propEpoch), user);
            (uint256 preSyncWeight, uint256 snapNonce) = delegation.getSyncSnapshot(user, uint256(propEpoch));
            (,, uint48 userLastVoteSyncNonce, uint8 userVoteStatus,,) = _gaugePlatform.userInfo(_proposalId, user);

            if (userVoteStatus > 0) {
                if (
                    snapNonce > uint256(userLastVoteSyncNonce)
                        && snapNonce <= uint256(delLastVoteSyncNonce)
                        && packedWeight > preSyncWeight
                ) {
                    weights[i] = packedWeight - preSyncWeight;
                }
            } else {
                if (delVoteStatus == 0 || snapNonce == 0 || snapNonce <= uint256(delLastVoteSyncNonce)) {
                    weights[i] = packedWeight;
                } else {
                    weights[i] = preSyncWeight;
                }
            }

            unchecked { ++i; }
        }

        return weights;
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
