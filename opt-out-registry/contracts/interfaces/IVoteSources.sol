// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The gauge-vote platform, which records how each address allocated its vote.
/// @dev Only the read surface is declared. `weights` are out of `max_weight`, currently
///      1,000,000, and sum to it across a voter's gauges.
interface IGaugeVotePlatform {
    function getVote(uint256 _proposalId, address _user)
        external
        view
        returns (
            address[] memory gauges,
            uint256[] memory weights,
            bool voted,
            uint256 baseWeight,
            int256 adjustedWeight
        );

    /// @dev Public array getter: `(startTime, endTime, epoch)`.
    function proposals(uint256 _proposalId) external view returns (uint48, uint48, uint48);

    function proposalCount() external view returns (uint256);

    function max_weight() external view returns (uint256);

    /// @dev The delegation registry this platform was built against.
    function delegation() external view returns (address);

    /// @dev The gauge registry this platform serves. A platform only holds votes for gauges
    ///      its own registry lists, so it is only meaningful to an instance on the same one.
    function gaugeRegistry() external view returns (address);
}

/// @notice The vlCVX delegation registry.
interface IDelegation {
    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address);
}

/// @notice Helper that resolves how much of a delegate's vote each delegator contributed.
/// @dev `_gaugePlatform` is typed as the platform contract upstream, which is an `address` on
///      the wire. Entries are zero for any user not delegating to `_delegate` at that epoch.
interface IGaugeVoteHelper {
    function getContributingWeights(
        uint256 _proposalId,
        address _delegate,
        address[] calldata _users,
        address _gaugePlatform
    ) external view returns (uint256[] memory);

    function delegation() external view returns (address);
}
