// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IvlCVX {
    struct Reward {
        bool useBoost;
        uint40 periodFinish;
        uint208 rewardRate;
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }

    struct Balances {
        uint112 locked;
        uint112 boosted;
        uint32 nextUnlockIndex;
    }

    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }

    struct EarnedData {
        address token;
        uint256 amount;
    }

    struct Epoch {
        uint224 supply;
        uint32 date;
    }

    /* ========== STATE VARIABLES ========== */

    function stakingToken() external view returns (address);
    function cvxCrv() external view returns (address);
    function rewardTokens(uint256 index) external view returns (address);
    function rewardsDuration() external view returns (uint256);
    function lockDuration() external view returns (uint256);
    function rewardDistributors(address _rewardsToken, address _distributor) external view returns (bool);
    function userRewardPerTokenPaid(address _user, address _rewardsToken) external view returns (uint256);
    function rewards(address _user, address _rewardsToken) external view returns (uint256);
    function lockedSupply() external view returns (uint256);
    function boostedSupply() external view returns (uint256);
    function epochs(uint256 index) external view returns (uint224 supply, uint32 date);
    function balances(address _user) external view returns (uint112 locked, uint112 boosted, uint32 nextUnlockIndex);
    function userLocks(address _user, uint256 index) external view returns (uint112 amount, uint112 boosted, uint32 unlockTime);
    function boostPayment() external view returns (address);
    function maximumBoostPayment() external view returns (uint256);
    function boostRate() external view returns (uint256);
    function nextMaximumBoostPayment() external view returns (uint256);
    function nextBoostRate() external view returns (uint256);
    function denominator() external view returns (uint256);
    function minimumStake() external view returns (uint256);
    function maximumStake() external view returns (uint256);
    function stakingProxy() external view returns (address);
    function cvxcrvStaking() external view returns (address);
    function stakeOffsetOnLock() external view returns (uint256);
    function kickRewardPerEpoch() external view returns (uint256);
    function kickRewardEpochDelay() external view returns (uint256);
    function isShutdown() external view returns (bool);

    /* ========== ERC20-LIKE INTERFACE ========== */

    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function version() external view returns (uint256);

    /* ========== ADMIN CONFIGURATION ========== */

    function addReward(address _rewardsToken, address _distributor, bool _useBoost) external;
    function approveRewardDistributor(address _rewardsToken, address _distributor, bool _approved) external;
    function setStakingContract(address _staking) external;
    function setStakeLimits(uint256 _minimum, uint256 _maximum) external;
    function setBoost(uint256 _max, uint256 _rate, address _receivingAddress) external;
    function setKickIncentive(uint256 _rate, uint256 _delay) external;
    function shutdown() external;
    function setApprovals() external;

    /* ========== VIEWS ========== */

    function lastTimeRewardApplicable(address _rewardsToken) external view returns (uint256);
    function rewardPerToken(address _rewardsToken) external view returns (uint256);
    function getRewardForDuration(address _rewardsToken) external view returns (uint256);
    function claimableRewards(address _account) external view returns (EarnedData[] memory userRewards);
    function rewardWeightOf(address _user) external view returns (uint256 amount);
    function lockedBalanceOf(address _user) external view returns (uint256 amount);
    function balanceOf(address _user) external view returns (uint256 amount);
    function balanceAtEpochOf(uint256 _epoch, address _user) external view returns (uint256 amount);
    function pendingLockOf(address _user) external view returns (uint256 amount);
    function pendingLockAtEpochOf(uint256 _epoch, address _user) external view returns (uint256 amount);
    function totalSupply() external view returns (uint256 supply);
    function totalSupplyAtEpoch(uint256 _epoch) external view returns (uint256 supply);
    function findEpochId(uint256 _time) external view returns (uint256 epoch);
    function lockedBalances(address _user) external view returns (uint256 total, uint256 unlockable, uint256 locked, LockedBalance[] memory lockData);
    function epochCount() external view returns (uint256);

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external;
    function lock(address _account, uint256 _amount, uint256 _spendRatio) external;
    function withdrawExpiredLocksTo(address _withdrawTo) external;
    function processExpiredLocks(bool _relock) external;
    function kickExpiredLocks(address _account) external;
    function getReward(address _account, bool _stake) external;
    function getReward(address _account) external;

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(address _rewardsToken, uint256 _reward) external;
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external;

    /* ========== EVENTS ========== */

    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(address indexed _user, uint256 indexed _epoch, uint256 _paidAmount, uint256 _lockedAmount, uint256 _boostedAmount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(address indexed _user, address indexed _kicked, uint256 _reward);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _reward);
    event Recovered(address _token, uint256 _amount);
}
