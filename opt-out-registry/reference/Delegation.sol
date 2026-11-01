// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IvlCVX.sol";
import "./Ownable2Step.sol";

contract Delegation is Ownable2Step {
    string public name;
    IvlCVX public immutable vlCVX;
    uint32 public immutable epoch0Date;
    uint256 public constant FILL_EPOCHS = 16;
    uint256 public constant WEIGHT_DIVISOR = 1e17;
    uint256 public constant EPOCHS_PER_ENTRY = 8;
    uint256 public constant REWARDS_DURATION = 86400 * 7;
    uint256 public constant LOCK_DURATION = REWARDS_DURATION * 16;

    struct EpochWeightingEntry {
        uint32 w0;
        uint32 w1;
        uint32 w2;
        uint32 w3;
        uint32 w4;
        uint32 w5;
        uint32 w6;
        uint32 w7;
    }

    struct SetDelegateRecord {
        address delegate;
        uint32 startingEpoch;
    }

    struct SyncSnapshot {
        uint96 syncNonce;
        uint32 preSyncWeight;
        uint96 timestamp;
    }

    error NoDelegate();
    error SelfDelegation();
    error ExpiredLocks();
    error InitializationClosed();
    error ArrayLengthMismatch();

    event UserLocksGasLimitSet(uint256 userLocksGasLimit);

    bool public initializationComplete;

    uint256 public syncNonce;

    uint256 public userLocksGasLimit = 10_000;

    mapping(address => SetDelegateRecord[]) public delegateHistory;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public userEpochWeights;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public delegateEpochWeights;
    mapping(address => uint256) public syncedUserEpoch;
    mapping(address => mapping(uint256 => SyncSnapshot)) public syncSnapshots;

    /// @notice Creates a new Delegation contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _vlCVX Address of the vlCVX contract
    constructor(string memory _name, address _owner, address _vlCVX) Ownable(_owner) {
        name = _name;
        vlCVX = IvlCVX(_vlCVX);
        (, epoch0Date) = vlCVX.epochs(0);
    }

    /// @notice Seeds initial delegate assignments for multiple users
    /// @param _users Array of user addresses
    /// @param _delegates Array of delegate addresses
    function seedDelegates(address[] calldata _users, address[] calldata _delegates) external onlyOwner {
        if (initializationComplete) revert InitializationClosed();
        uint256 len = _users.length;
        if (len != _delegates.length) revert ArrayLengthMismatch();

        vlCVX.checkpointEpoch();
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 gasLimit = userLocksGasLimit;

        for (uint256 i = 0; i < len;) {
            address user = _users[i];
            address delegate = _delegates[i];
            if (delegate == address(0)) revert NoDelegate();
            if (delegate == user) revert SelfDelegation();

            SetDelegateRecord[] storage history = delegateHistory[user];
            if (history.length != 0) {
                unchecked { ++i; }
                continue;
            }

            history.push(SetDelegateRecord({delegate: delegate, startingEpoch: uint32(nextEpoch)}));
            (uint112 locked, , uint32 nextUnlockIndex) = vlCVX.balances(user);
            if (locked > 0) {
                try vlCVX.userLocks{gas: gasLimit}(user, nextUnlockIndex) returns (
                    uint112 firstAmount, uint112, uint32 firstUnlockTime
                ) {
                    if (firstAmount > 0 && firstUnlockTime > block.timestamp) {
                        _syncUser(user, delegate, nextEpoch, FILL_EPOCHS);
                    }
                } catch {}
            }
            emit DelegateSet(user, delegate);
            unchecked { ++i; }
        }
    }

    /// @notice Marks initialization as complete, preventing further seeding
    function completeInitialization() external onlyOwner {
        initializationComplete = true;
        emit InitializationComplete();
    }

    /// @notice Sets gas forwarded to vlCVX userLocks probes
    function setUserLocksGasLimit(uint256 _userLocksGasLimit) external onlyOwner {
        userLocksGasLimit = _userLocksGasLimit;
        emit UserLocksGasLimitSet(_userLocksGasLimit);
    }

    /// @notice Sets or changes a delegate for the caller
    /// @param _delegate Delegate address to assign
    function setDelegate(address _delegate) external {
        if (_delegate == msg.sender) revert SelfDelegation();
        vlCVX.checkpointEpoch();
        uint256 nextEpoch = vlCVX.epochCount() - 1;

        SetDelegateRecord[] storage history = delegateHistory[msg.sender];
        address oldDelegate;
        uint256 len = history.length;

        if (len == 0) {
            history.push(SetDelegateRecord({
                delegate: _delegate,
                startingEpoch: uint32(nextEpoch)
            }));
        } else {
            SetDelegateRecord storage tail = history[len - 1];
            oldDelegate = tail.delegate;

            if (tail.startingEpoch == uint32(nextEpoch)) {
                tail.delegate = _delegate;
            } else {
                history.push(SetDelegateRecord({
                    delegate: _delegate,
                    startingEpoch: uint32(nextEpoch)
                }));
            }
        }

        if (oldDelegate != address(0) && oldDelegate != _delegate) {
            _removeUser(msg.sender, oldDelegate);
        }

        if (_delegate != address(0)) {
            _syncUser(msg.sender, _delegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
        }

        emit DelegateSet(msg.sender, _delegate);
    }

    /// @notice Syncs a user's weight for future epochs
    /// @param _user User address to sync
    function sync(address _user) external {
        vlCVX.checkpointEpoch();
        uint256 currentEpoch = vlCVX.epochCount() - 2;

        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        if (len == 0) return;

        address currentDelegate = _getDelegateAtEpoch(history, currentEpoch);
        address futureDelegate = history[len - 1].delegate;

        uint256 offset = currentEpoch & 7;
        uint256 entryIdx = currentEpoch >> 3;
        EpochWeightingEntry memory entry = userEpochWeights[_user][entryIdx];
        uint256 prePacked;
        assembly {
            prePacked := mload(add(entry, mul(offset, 32)))
        }

        if (currentDelegate != address(0)) {
            if (currentDelegate == futureDelegate) {
                _syncUser(_user, currentDelegate, currentEpoch, FILL_EPOCHS + 1);
            } else {
                _syncUser(_user, currentDelegate, currentEpoch, 1);
                if (futureDelegate != address(0)) {
                    _syncUser(_user, futureDelegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
                }
            }
        } else if (futureDelegate != address(0)) {
            _syncUser(_user, futureDelegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
        }

        entry = userEpochWeights[_user][entryIdx];
        uint256 postPacked;
        assembly {
            postPacked := mload(add(entry, mul(offset, 32)))
        }

        if (postPacked != prePacked) {
            syncSnapshots[_user][currentEpoch] = SyncSnapshot({
                preSyncWeight: uint32(prePacked),
                syncNonce: uint96(++syncNonce),
                timestamp: uint96(block.timestamp)
            });
        }
    }

    /// @notice Syncs a user's weight at a specific epoch
    /// @param _user User address to sync
    /// @param _epoch Epoch to sync at
    function syncAtEpoch(address _user, uint256 _epoch) external {
        if (_epoch >= vlCVX.epochCount() - 1) return;

        (uint112 _locked, , uint32 nextUnlockIndex) = vlCVX.balances(_user);
        if (_locked > 0) {
            (uint112 firstAmount, , uint32 firstUnlockTime) =
                vlCVX.userLocks{gas: userLocksGasLimit}(_user, nextUnlockIndex);
            if (firstAmount > 0 && firstUnlockTime <= block.timestamp) revert ExpiredLocks();
        }

        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        if (len == 0) return;

        address delegate = _getDelegateAtEpoch(history, _epoch);
        if (delegate == address(0)) return;

        uint256 offset = _epoch & 7;
        uint256 entryIdx = _epoch >> 3;
        EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
        uint256 prePacked;
        assembly {
            prePacked := mload(add(userEntry, mul(offset, 32)))
        }

        if (syncSnapshots[_user][_epoch].syncNonce != 0) return;

        uint256 newWeight = vlCVX.balanceAtEpochOf(_epoch, _user);
        uint256 newPacked = newWeight / WEIGHT_DIVISOR;

        syncSnapshots[_user][_epoch] = SyncSnapshot({
            preSyncWeight: uint32(prePacked),
            syncNonce: uint96(++syncNonce),
            timestamp: uint96(block.timestamp)
        });

        if (newPacked == prePacked) return;

        EpochWeightingEntry memory delegateEntry = delegateEpochWeights[delegate][entryIdx];
        unchecked {
            uint256 delta = newPacked - prePacked;
            assembly {
                mstore(add(delegateEntry, mul(offset, 32)), add(mload(add(delegateEntry, mul(offset, 32))), delta))
            }
        }
        assembly {
            mstore(add(userEntry, mul(offset, 32)), newPacked)
        }

        userEpochWeights[_user][entryIdx] = userEntry;
        delegateEpochWeights[delegate][entryIdx] = delegateEntry;

        emit Synced(_user, delegate);
    }

    /// @notice Returns the delegate for a user at a given epoch
    /// @param _user User address
    /// @param _epoch Epoch to query
    /// @return Delegate address at that epoch
    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address) {
        SetDelegateRecord[] storage history = delegateHistory[_user];
        return _getDelegateAtEpoch(history, _epoch);
    }

    /// @notice Finds the delegate for a user at a given epoch from history
    function _getDelegateAtEpoch(SetDelegateRecord[] storage history, uint256 _epoch) internal view returns (address) {
        uint256 len = history.length;
        for (uint256 i = len; i > 0;) {
            unchecked { --i; }
            if (history[i].startingEpoch <= _epoch) {
                return history[i].delegate;
            }
        }
        return address(0);
    }

    /// @notice Syncs a user's weight to a delegate across a range of epochs
    function _syncUser(address _user, address _delegate, uint256 _startEpoch, uint256 _numEpochs) internal {
        uint256 endEpoch;
        unchecked { endEpoch = _startEpoch + _numEpochs; }

        (uint112 _locked, , uint32 nextUnlockIndex) = vlCVX.balances(_user);
        uint256 gasLimit = userLocksGasLimit;

        uint256[17] memory epochWeights;

        if (_locked > 0) {
            for (uint256 i = nextUnlockIndex; i < nextUnlockIndex + 17;) {
                uint112 lockBoosted;
                uint32 unlockTime;
                try vlCVX.userLocks{gas: gasLimit}(_user, i) returns (
                    uint112 _amount, uint112 _boosted, uint32 _lockUnlockTime
                ) {
                    if (_amount > 0 && _lockUnlockTime <= block.timestamp) revert ExpiredLocks();
                    lockBoosted = _boosted;
                    unlockTime = _lockUnlockTime;
                } catch {
                    break;
                }

                uint256 _lockBoosted = uint256(lockBoosted);
                uint256 _unlockTime = uint256(unlockTime);
                uint256 lockEpochTime = _unlockTime - LOCK_DURATION;

                uint256 firstContrib = (lockEpochTime - uint256(epoch0Date)) / REWARDS_DURATION;
                uint256 lastContrib = (_unlockTime - uint256(epoch0Date)) / REWARDS_DURATION - 1;

                if (lastContrib < _startEpoch) {
                    unchecked { ++i; }
                    continue;
                }
                if (firstContrib >= endEpoch) break;

                uint256 eStart = firstContrib > _startEpoch ? firstContrib : _startEpoch;
                uint256 eEnd = lastContrib < endEpoch - 1 ? lastContrib : endEpoch - 1;

                for (uint256 e = eStart; e <= eEnd;) {
                    epochWeights[e - _startEpoch] += _lockBoosted;
                    unchecked { ++e; }
                }

                unchecked { ++i; }
            }
        }

        uint256 startEntry = _startEpoch >> 3;
        uint256 endEntry = (endEpoch - 1) >> 3;

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry;) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[_delegate][entryIdx];

            uint256 entryStartEpoch;
            uint256 entryEndEpoch;
            unchecked {
                entryStartEpoch = entryIdx << 3;
                entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;
            }

            uint256 loopStart = _startEpoch > entryStartEpoch ? _startEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd;) {
                uint256 newWeight = epochWeights[epoch - _startEpoch];
                uint256 offset = epoch & 7;
                uint256 oldWeightPacked;
                uint256 delegateSlot;
                assembly {
                    oldWeightPacked := mload(add(userEntry, mul(offset, 32)))
                    delegateSlot := add(delegateEntry, mul(offset, 32))
                }
                uint256 newWeightPacked = newWeight / WEIGHT_DIVISOR;
                unchecked {
                    uint256 delta = newWeightPacked - oldWeightPacked;
                    assembly {
                        mstore(delegateSlot, add(mload(delegateSlot), delta))
                    }
                }
                assembly {
                    mstore(add(userEntry, mul(offset, 32)), newWeightPacked)
                }
                unchecked { ++epoch; }
            }

            userEpochWeights[_user][entryIdx] = userEntry;
            delegateEpochWeights[_delegate][entryIdx] = delegateEntry;
            unchecked { ++entryIdx; }
        }

        syncedUserEpoch[_user] = endEpoch;

        emit Synced(_user, _delegate);
    }

    /// @notice Removes a user's weight from a delegate's totals
    function _removeUser(address _user, address _delegate) internal {
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = syncedUserEpoch[_user];

        if (endEpoch <= nextEpoch) {
            syncedUserEpoch[_user] = 0;
            return;
        }

        uint256 startEntry = nextEpoch >> 3;
        uint256 endEntry = (endEpoch - 1) >> 3;

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry;) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[_delegate][entryIdx];

            uint256 entryStartEpoch;
            uint256 entryEndEpoch;
            unchecked {
                entryStartEpoch = entryIdx << 3;
                entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;
            }

            uint256 loopStart = nextEpoch > entryStartEpoch ? nextEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd;) {
                uint256 offset = epoch & 7;
                uint256 weight;
                uint256 delegateSlot;
                assembly {
                    weight := mload(add(userEntry, mul(offset, 32)))
                    delegateSlot := add(delegateEntry, mul(offset, 32))
                }
                assembly {
                    mstore(delegateSlot, sub(mload(delegateSlot), weight))
                }
                assembly {
                    mstore(add(userEntry, mul(offset, 32)), 0)
                }
                unchecked { ++epoch; }
            }

            delegateEpochWeights[_delegate][entryIdx] = delegateEntry;
            userEpochWeights[_user][entryIdx] = userEntry;
            unchecked { ++entryIdx; }
        }

        syncedUserEpoch[_user] = 0;
    }

    /// @notice Returns the current weight of a delegate
    /// @param _delegate Delegate address
    /// @return Current delegated weight
    function balanceOf(address _delegate) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return _readMemWeight(delegateEpochWeights[_delegate][currentEpoch >> 3], currentEpoch & 7);
    }

    /// @notice Returns a delegate's weight at a specific epoch
    /// @param _epoch Epoch to query
    /// @param _delegate Delegate address
    /// @return Delegated weight at that epoch
    function balanceAtEpochOf(uint256 _epoch, address _delegate) external view returns (uint256) {
        return _readMemWeight(delegateEpochWeights[_delegate][_epoch >> 3], _epoch & 7);
    }

    /// @notice Returns a user's own weight at the current epoch
    /// @param _user User address
    /// @return User's weight
    function getUserWeight(address _user) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return _readMemWeight(userEpochWeights[_user][currentEpoch >> 3], currentEpoch & 7);
    }

    /// @notice Returns a user's weight at a specific epoch
    /// @param _epoch Epoch to query
    /// @param _user User address
    /// @return User's weight at that epoch
    function userWeightAtEpochOf(uint256 _epoch, address _user) external view returns (uint256) {
        return _readMemWeight(userEpochWeights[_user][_epoch >> 3], _epoch & 7);
    }

    /// @notice Returns the sync snapshot for a user at an epoch
    /// @param _user User address
    /// @param _epoch Epoch to query
    /// @return preSyncWeight Weight before sync
    /// @return snapshotNonce Monotonic nonce at time of snapshot
    function getSyncSnapshot(address _user, uint256 _epoch) external view returns (uint256 preSyncWeight, uint256 snapshotNonce) {
        SyncSnapshot memory snap = syncSnapshots[_user][_epoch];
        return (uint256(snap.preSyncWeight) * WEIGHT_DIVISOR, uint256(snap.syncNonce));
    }

    /// @notice Reads a packed weight from an epoch weighting entry
    function _readMemWeight(EpochWeightingEntry memory entry, uint256 offset) internal pure returns (uint256) {
        uint256 raw;
        assembly {
            raw := mload(add(entry, mul(offset, 32)))
        }
        return raw * WEIGHT_DIVISOR;
    }

    /// @notice Returns the current epoch count from vlCVX
    /// @return Current epoch count
    function epochCount() external view returns (uint256) {
        return vlCVX.epochCount();
    }

    event DelegateSet(address indexed user, address indexed delegate);
    event Synced(address indexed user, address indexed delegate);
    event InitializationComplete();

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
