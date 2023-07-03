// SPDX-License-Identifier: MIT
// Votium

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./Ownable.sol";

contract Votium is Ownable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // relevant time constraints
    uint256 epochDuration = 86400 * 14; // 2 weeks
    uint256 roundDuration = 86400 * 5; // 5 days
    uint256 deadlineDuration = 60 * 60 * 6; // 6 hours

    mapping(address => bool) public tokenAllowed; // token allow list
    mapping(address => bool) public approvedTeam; // for team functions that do not require multi-sig security

    address public feeAddress; // address to receive platform fees
    uint256 public platformFee = 400; // 4%
    uint256 public constant DENOMINATOR = 10000; // denominates weights 10000 = 100%
    address public distributor; // address of distributor contract

    bool public requireAllowlist = true; // begin with erc20 allow list in effect

    struct Incentive {
        address token;
        uint256 amount;
        uint256 maxPerVote;
        uint256 distributed;
        uint256 recycled;
        address depositor;
    }

    mapping(uint256 => address[]) public roundGauges; // round => gauge array
    mapping(uint256 => mapping(address => bool)) public inRoundGauges; // round => gauge => bool
    mapping(uint256 => mapping(address => Incentive[])) public incentives; // round => gauge => incentive array
    mapping(uint256 => mapping(address => uint256)) public votesReceived; // round => gauge => votes

    mapping(address => uint256) public virtualBalance; // token => amount

    uint256 public lastRoundProcessed; // last round that was processed by multi-sig

    mapping(address => uint256) public toTransfer; // token => amount
    address[] public toTransferList; // list of tokens to transfer

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _approved,
        address _approved2,
        address _feeAddress,
        address _distributor
    ) {
        approvedTeam[_approved] = true;
        approvedTeam[_approved2] = true;
        feeAddress = _feeAddress;
        distributor = _distributor;
        lastRoundProcessed = (block.timestamp / epochDuration) - 1348;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    function gaugesLength(uint256 _round) public view returns (uint256) {
        return roundGauges[_round].length;
    }

    function incentivesLength(
        uint256 _round,
        address _gauge
    ) public view returns (uint256) {
        return incentives[_round][_gauge].length;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp / epochDuration) * epochDuration;
    }

    // Display current or next active round
    function activeRound() public view returns (uint256) {
        if (
            block.timestamp < currentEpoch() + roundDuration - deadlineDuration
        ) {
            return currentEpoch() / epochDuration - 1348; // 1348 is the votium genesis round
        } else {
            return currentEpoch() / epochDuration - 1347;
        }
    }

    // Deposit vote incentive for a single gauge in a single round
    function depositIncentive(
        address _token,
        uint256 _amount,
        uint256 _round,
        address _gauge,
        uint256 _maxPerVote
    ) public {
        require(_round >= activeRound(), "!roundEnded");
        require(_round <= activeRound() + 6, "!farFuture");
        uint256 rewardTotal = _takeDeposit(_token, _amount, 1);
        Incentive memory incentive = Incentive({
            token: _token,
            amount: rewardTotal,
            maxPerVote: _maxPerVote,
            distributed: 0,
            recycled: 0,
            depositor: msg.sender
        });
        incentives[_round][_gauge].push(incentive);
        if (!inRoundGauges[_round][_gauge]) {
            roundGauges[_round].push(_gauge);
            inRoundGauges[_round][_gauge] = true;
        }
        emit NewIncentive(
            _token,
            rewardTotal,
            _round,
            _gauge,
            _maxPerVote,
            false
        );
    }

    // evenly split deposit across a single gauge in multiple rounds
    function depositSplitRounds(
        address _token,
        uint256 _amount,
        uint256 _numRounds,
        address _gauge,
        uint256 _maxPerVote
    ) public {
        require(_numRounds < 8, "!farFuture");
        require(_numRounds > 1, "!numRounds");
        uint256 rewardTotal = _takeDeposit(_token, _amount, _numRounds);
        require(rewardTotal / _numRounds > 0, "!rewardTotal");
        uint256 round = activeRound();
        for (uint256 i = 0; i < _numRounds; i++) {
            Incentive memory incentive = Incentive({
                token: _token,
                amount: rewardTotal / _numRounds,
                maxPerVote: _maxPerVote,
                distributed: 0,
                recycled: 0,
                depositor: msg.sender
            });
            incentives[round + i][_gauge].push(incentive);
            if (!inRoundGauges[round + i][_gauge]) {
                roundGauges[round + i].push(_gauge);
                inRoundGauges[round + i][_gauge] = true;
            }
            emit NewIncentive(
                _token,
                rewardTotal / _numRounds,
                round + i,
                _gauge,
                _maxPerVote,
                false
            );
        }
    }

    // evenly split deposit across multiple gauges in a single round
    function depositSplitGauges(
        address _token,
        uint256 _amount,
        uint256 _round,
        address[] calldata _gauges,
        uint256 _maxPerVote
    ) public {
        require(_round >= activeRound(), "!roundEnded");
        require(_round <= activeRound() + 6, "!farFuture");
        require(_gauges.length > 1, "!gauges");
        uint256 rewardTotal = _takeDeposit(_token, _amount, _gauges.length);
        require(rewardTotal / _gauges.length > 0, "!rewardTotal");
        for (uint256 i = 0; i < _gauges.length; i++) {
            Incentive memory incentive = Incentive({
                token: _token,
                amount: rewardTotal / _gauges.length,
                maxPerVote: _maxPerVote,
                distributed: 0,
                recycled: 0,
                depositor: msg.sender
            });
            incentives[_round][_gauges[i]].push(incentive);
            if (!inRoundGauges[_round][_gauges[i]]) {
                roundGauges[_round].push(_gauges[i]);
                inRoundGauges[_round][_gauges[i]] = true;
            }
            emit NewIncentive(
                _token,
                rewardTotal / _gauges.length,
                _round,
                _gauges[i],
                _maxPerVote,
                false
            );
        }
    }

    // evenly split deposit across multiple gauges in multiple rounds
    function depositSplitGaugesRounds(
        address _token,
        uint256 _amount,
        uint256 _numRounds,
        address[] calldata _gauges,
        uint256 _maxPerVote
    ) public {
        require(_numRounds < 8, "!farFuture");
        require(_numRounds > 1, "!numRounds");
        require(_gauges.length > 1, "!gauges");
        uint256 rewardTotal = _takeDeposit(_token, _amount, _numRounds * _gauges.length);
        require(rewardTotal / (_numRounds * _gauges.length) > 0, "!rewardTotal");
        uint256 round = activeRound();
        for (uint256 i = 0; i < _numRounds; i++) {
            for (uint256 j = 0; j < _gauges.length; j++) {
                Incentive memory incentive = Incentive({
                    token: _token,
                    amount: rewardTotal / (_numRounds * _gauges.length),
                    maxPerVote: _maxPerVote,
                    distributed: 0,
                    recycled: 0,
                    depositor: msg.sender
                });
                incentives[round + i][_gauges[j]].push(incentive);
                if (!inRoundGauges[round + i][_gauges[j]]) {
                    roundGauges[round + i].push(_gauges[j]);
                    inRoundGauges[round + i][_gauges[j]] = true;
                }
                emit NewIncentive(
                    _token,
                    rewardTotal / (_numRounds * _gauges.length),
                    round + i,
                    _gauges[j],
                    _maxPerVote,
                    false
                );
            }
        }
    }

    // deposit same token to multiple gauges with different amounts in a single round
    function depositUnevenSplitGauges(
        address _token,
        uint256 _round,
        address[] calldata _gauges,
        uint256[] calldata _amounts,
        uint256 _maxPerVote
    ) public {
        require(_gauges.length == _amounts.length, "!length");
        require(_round >= activeRound(), "!roundEnded");
        require(_round <= activeRound() + 6, "!farFuture");
        uint256 totalDeposit = 0;
        for (uint256 i = 0; i < _gauges.length; i++) {
            require(_amounts[i] > 0, "!amount");
            totalDeposit += _amounts[i];
        }
        _takeDeposit(_token, totalDeposit, 1);
        for (uint256 i = 0; i < _gauges.length; i++) {
            Incentive memory incentive = Incentive({
                token: _token,
                amount: (_amounts[i] * (DENOMINATOR - platformFee)) /
                    DENOMINATOR,
                maxPerVote: _maxPerVote,
                distributed: 0,
                recycled: 0,
                depositor: msg.sender
            });
            incentives[_round][_gauges[i]].push(incentive);
            if (!inRoundGauges[_round][_gauges[i]]) {
                roundGauges[_round].push(_gauges[i]);
                inRoundGauges[_round][_gauges[i]] = true;
            }
            emit NewIncentive(
                _token,
                (_amounts[i] * (DENOMINATOR - platformFee)) / DENOMINATOR,
                _round,
                _gauges[i],
                _maxPerVote,
                false
            );
        }
    }

    // function for depositor to withdraw unprocessed incentives
    // this should only happen if a gauge does not exist or is killed before the round ends
    // fees are not returned
    function withdrawUnprocessed(
        uint256 _round,
        address _gauge,
        uint256 _incentive
    ) public {
        require(
            _round <= lastRoundProcessed || _round + 3 < activeRound(),
            "!roundNotProcessed"
        ); // allow 3 rounds for processing before withdraw can be forced
        require(
            incentives[_round][_gauge][_incentive].depositor == msg.sender,
            "!depositor"
        );
        require(
            incentives[_round][_gauge][_incentive].distributed == 0,
            "!distributed"
        );
        require(
            incentives[_round][_gauge][_incentive].recycled == 0,
            "!recycled"
        );
        uint256 amount = incentives[_round][_gauge][_incentive].amount;
        incentives[_round][_gauge][_incentive].amount = 0;
        IERC20(incentives[_round][_gauge][_incentive].token).safeTransfer(
            msg.sender,
            (amount *
                IERC20(incentives[_round][_gauge][_incentive].token).balanceOf(
                    address(this)
                )) /
                virtualBalance[incentives[_round][_gauge][_incentive].token]
        );
        virtualBalance[incentives[_round][_gauge][_incentive].token] -= amount;
        emit WithdrawUnprocessed(_round, _gauge, _incentive, amount);
    }

    // function for depositor to recycle unprocessed incentives instead of withdrawing (maybe gauge was not active yet or was killed and revived)
    function recycleUnprocessed(
        uint256 _round,
        address _gauge,
        uint256 _incentive
    ) public {
        require(_round <= lastRoundProcessed, "!roundNotProcessed");
        require(
            incentives[_round][_gauge][_incentive].depositor == msg.sender ||
                msg.sender == owner(),
            "!auth"
        );
        require(
            incentives[_round][_gauge][_incentive].distributed == 0,
            "!distributed"
        );
        require(
            incentives[_round][_gauge][_incentive].recycled == 0,
            "!recycled"
        );
        Incentive memory original = incentives[_round][_gauge][_incentive];
        incentives[_round][_gauge][_incentive].recycled = original.amount;
        _recycleReward(
            original.token,
            original.amount,
            _gauge,
            original.maxPerVote,
            original.depositor
        );
    }

    /* ========== APPROVED TEAM FUNCTIONS ========== */

    // transfer stored rewards to distributor (to rescue tokens sent directly to contract)
    // does not change virtual balance
    function rescueToDistributor(address _token) public onlyTeam {
        uint256 bal = IERC20(_token).balanceOf(address(this)) -
            virtualBalance[_token];
        require(bal > 0, "!balance");
        IERC20(_token).safeTransfer(distributor, bal);
    }

    // allow/deny token
    function allowToken(address _token, bool _allow) public onlyTeam {
        tokenAllowed[_token] = _allow;
        emit TokenAllow(_token, _allow);
    }

    // allow/deny multiple tokens
    function allowTokens(
        address[] memory _tokens,
        bool _allow
    ) public onlyTeam {
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenAllowed[_tokens[i]] = _allow;
            emit TokenAllow(_tokens[i], _allow);
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // rewards are recycled automatically if processed without consuming entire reward (maxPerVote)
    function _recycleReward(
        address _token,
        uint256 _amount,
        address _gauge,
        uint256 _maxPerVote,
        address _depositor
    ) internal {
        uint256 _round = activeRound();
        Incentive memory incentive = Incentive({
            token: _token,
            amount: _amount,
            maxPerVote: _maxPerVote,
            distributed: 0,
            recycled: 0,
            depositor: _depositor
        });
        incentives[_round][_gauge].push(incentive);
        emit NewIncentive(_token, _amount, _round, _gauge, _maxPerVote, true);
    }

    // take deposit and send fees to feeAddress, return rewardTotal
    function _takeDeposit(
        address _token,
        uint256 _amount,
        uint256 _split
    ) internal returns (uint256) {
        if (requireAllowlist == true) {
            require(tokenAllowed[_token] == true, "!allowlist");
        }
        require(_amount / _split > 0, "!zero");
        uint256 fee = (_amount * platformFee) / DENOMINATOR;
        uint256 rewardTotal = _amount - fee;
        IERC20(_token).safeTransferFrom(msg.sender, feeAddress, fee);
        IERC20(_token).safeTransferFrom(msg.sender, address(this), rewardTotal);
        virtualBalance[_token] += (rewardTotal / _split) * _split; // prevent rounding errors
        return rewardTotal;
    }

    /* ========== MUTLI-SIG FUNCTIONS ========== */

    // submit vote totals and transfer rewards to distributor
    function endRound(
        uint256 _round,
        address[] memory _gauges,
        uint256[] memory _totals
    ) public onlyOwner {
        require(_gauges.length == _totals.length, "!gauges/totals");
        require(_round < activeRound(), "!activeRound");
        require(_round - 1 == lastRoundProcessed, "!lastRoundProcessed");
        for (uint256 i = 0; i < _gauges.length; i++) {
            require(votesReceived[_round][_gauges[i]] == 0, "!duplicate");
            votesReceived[_round][_gauges[i]] = _totals[i];
            for (
                uint256 n = 0;
                n < incentives[_round][_gauges[i]].length;
                n++
            ) {
                Incentive storage incentive = incentives[_round][_gauges[i]][n];
                uint256 reward;
                if (incentive.maxPerVote > 0) {
                    reward = incentive.maxPerVote * _totals[i];
                    if (reward > incentive.amount) {
                        reward = incentive.amount;
                    } else {
                        // recycle unused reward
                        _recycleReward(
                            incentive.token,
                            incentive.amount - reward,
                            _gauges[i],
                            incentive.maxPerVote,
                            incentive.depositor
                        );
                        incentives[_round][_gauges[i]][n].recycled =
                            incentive.amount -
                            reward;
                    }
                    incentives[_round][_gauges[i]][n].distributed = reward;
                } else {
                    reward = incentive.amount;
                    incentives[_round][_gauges[i]][n].distributed = reward;
                }
                toTransfer[incentive.token] += reward;
                toTransferList.push(incentive.token);
            }
        }
        lastRoundProcessed = _round;
        for (uint256 i = 0; i < toTransferList.length; i++) {
            IERC20(toTransferList[i]).safeTransfer(
                distributor,
                (toTransfer[toTransferList[i]] *
                    IERC20(toTransferList[i]).balanceOf(address(this))) /
                    virtualBalance[toTransferList[i]]
            );
            virtualBalance[toTransferList[i]] -= toTransfer[toTransferList[i]];
            toTransfer[toTransferList[i]] = 0;
        }
        delete toTransferList;
    }

    // toggle whitelist requirement
    function setAllowlistRequired(bool _requireAllowlist) public onlyOwner {
        requireAllowlist = _requireAllowlist;
        emit AllowlistRequirement(_requireAllowlist);
    }

    // update fee address
    function updateFeeAddress(address _feeAddress) public onlyOwner {
        feeAddress = _feeAddress;
    }

    // update fee amount
    function updateFeeAmount(uint256 _feeAmount) public onlyOwner {
        require(_feeAmount < 400, "max fee"); // Max fee 4%
        platformFee = _feeAmount;
        emit UpdatedFee(_feeAmount);
    }

    // add or remove address from team functions
    function modifyTeam(address _member, bool _approval) public onlyOwner {
        approvedTeam[_member] = _approval;
        emit ModifiedTeam(_member, _approval);
    }

    // update token distributor address
    function updateDistributor(address _distributor) public onlyOwner {
        distributor = _distributor;
        emit UpdatedDistributor(distributor);
    }

    // Fallback executable function
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value: _value}(_data);
        return (success, result);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyTeam() {
        require(approvedTeam[msg.sender] == true, "Team only");
        _;
    }

    /* ========== EVENTS ========== */

    event NewIncentive(
        address _token,
        uint256 _amount,
        uint256 _round,
        address _gauge,
        uint256 _maxPerVote,
        bool _recycled
    );
    event TokenAllow(address _token, bool _allow);
    event AllowlistRequirement(bool _requireAllowlist);
    event UpdatedFee(uint256 _feeAmount);
    event ModifiedTeam(address _member, bool _approval);
    event UpdatedDistributor(address _distributor);
    event WithdrawUnprocessed(
        uint256 _round,
        address _gauge,
        uint256 _incentive,
        uint256 _amount
    );
}
