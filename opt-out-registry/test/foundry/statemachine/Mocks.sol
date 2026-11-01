// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal stand-ins for vlCVX and a gauge registry, used only by the state-machine
///         tests in this directory.
/// @dev Everything else in this repository runs against the live mainnet contracts on a fork,
///      deliberately, so that the real epoch machinery and the real `balanceAtEpochOf`
///      semantics are what get tested. These tests are the exception, and need to be.
///
///      They enumerate *every* action sequence to a given depth — thousands of sequences, each
///      snapshotted and reverted — to prove the internal state machine has no reachable bad
///      state. That is not something a fork can carry: each step would be a real lock and a
///      real epoch, and the enumeration would take days. It is also not what these tests are
///      about. They check the interval and count bookkeeping, which does not depend on how
///      vlCVX computes a balance, only on epochs advancing and a balance gating entry.
///
///      Integration with the real locker stays the job of the fork suites, which remain the
///      authority on anything these mocks simplify.

contract MockVlCVX {
    uint32 public immutable e0;
    uint256 public constant DUR = 7 days;
    mapping(address => uint256) public bal;
    uint256 public checkpointed;

    constructor(uint32 _e0) {
        e0 = _e0;
        checkpointed = 1;
    }

    function setBal(address u, uint256 v) external {
        bal[u] = v;
    }

    function epochs(uint256 i) external view returns (uint224, uint32) {
        return (0, uint32(uint256(e0) + i * DUR));
    }

    function findEpochId(uint256 t) external view returns (uint256) {
        return (t - e0) / DUR;
    }

    function balanceAtEpochOf(uint256, address u) external view returns (uint256) {
        return bal[u];
    }

    function checkpointEpoch() external {
        uint256 want = (block.timestamp - e0) / DUR + 2;
        if (want > checkpointed) checkpointed = want;
    }

    function epochCount() external view returns (uint256) {
        return checkpointed;
    }
}

contract MockGaugeRegistry {
    mapping(address => bool) public banned;

    function setBanned(address g, bool b) external {
        banned[g] = b;
    }

    function isRegisteredGauge(address g) external view returns (bool) {
        return !banned[g];
    }
}
