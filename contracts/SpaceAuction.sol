// SPDX-License-Identifier: MIT
// Votium Space Auction

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Ownable.sol";

interface Swap {
  function SwapStake(uint256, uint256, uint8) external; // in, out, method
}
interface Stash {
  function lockCRV(uint256) external;
}


contract SpaceAuction is Ownable {

  using SafeERC20 for IERC20;

  /* ========== STATE VARIABLES ========== */

  Swap public swapper;    // interface with sushi/curve swap contract
  address public stash;   // interface with merkle stash contract

  struct Bids {
    address owner;        // bidder
    uint256 maxPerVote;   // max paid per 1 vote
    uint256 maxTotal;     // max paid total
    bool invalid;         // becomes invalid if at the end of the auction, the bidder's snapshot vote does not match their registered hash
  }

  struct ProposalData {
    uint256 deadline;     // set to 2 hours before snapshot voting ends
    uint256 winningBid;   // not set until proposal status is at least 1. Is not final until 2
    uint256 power;        // number of votes cast on behalf of the winner. Is not final until 2
    uint8 status;
      // 0 = open auction (or no auction, if deadline = 0)
      // 1 = winner selected
      // 2 = winning hash confirmed to be valid
      // 3 = closed with vote confirmation
      // 4 = no winner/no vote confirmation
      // Any user can force status 4 if deadline is more than 6 hours old and team has not verified final vote count
    Bids[] bids; // array of 'Bids' struct found above
  }

  struct Bidders {
    bytes32 msgHash;
    uint256 balance;
    uint256 bidId;
  }

  mapping(bytes32 => mapping(address => Bidders)) public bidder;        // maps proposal id + address to Bidders
  mapping(bytes32 => ProposalData) public proposal;                     // maps proposal id to ProposalData
  bytes32[] public proposals;                                           // public registry of proposal ids

  mapping(address => bool) public approvedTeam;                         // for team functions that do not require multi-sig security

  address public platform = 0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3; // Team multi-sig address

  uint256 public slashFee = 300;                                        // 3% initial slash fee
  uint256 public constant DENOMINATOR = 10000;                          // denominates Ratio as % with 2 decimals (100 = 1%)

  mapping(bytes32 => bool) public winningHashes;                        // tells vote proxy contract if a vote is valid

  IERC20 public CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

  /* ========== CONSTRUCTOR ========== */

  constructor(address _swapper, address _stash) {
    swapper = Swap(_swapper);        // sets swap contract address to interface
    stash = _stash;                  // sets merkle stash address without interface
    approvedTeam[msg.sender] = true; // adds deployer address to approved team functions
  }

  /* ========== OWNER FUNCTIONS ========== */

  // Update swapper contract
  function updateSwapper(address _swapper) public onlyOwner {
    swapper = Swap(_swapper);
  }
  // Update stash contract
  function updateStash(address _stash) public onlyOwner {
    stash = _stash;
  }
  // Lever for changing fees
  function setFees(uint256 _slash) public onlyOwner {
    require(_slash < 1000, "!<1000");  // Allowable range of 0 to 10% for slash
    slashFee = _slash;
  }
  // add or remove address from team functions
  function modifyTeam(address _member, bool _approval) public onlyOwner {
    approvedTeam[_member] = _approval;
  }
  // approve a vote msg hash in case snapshot is down during the timestamped window for the user submitted hash
  function emergencyValidation(bytes32 _hash) public onlyOwner {
    winningHashes[_hash] = true;
  }
  /* ========== APPROVED TEAM FUNCTIONS ======= */

  // begin auction
  function initiateAuction(bytes32 _proposal, uint256 _deadline) public onlyTeam {
    require(proposal[_proposal].deadline == 0, "exists");
    proposal[_proposal].deadline = _deadline;
    proposals.push(_proposal);
  }

  // select winner of auction
  function selectWinner(bytes32 _proposal, uint256 _votes) public onlyTeam {
    require(proposal[_proposal].deadline < block.timestamp, "Auction has not ended");
    require(proposal[_proposal].status < 2, "!<2");
    (uint256 w, bool hasWinner) = winnerIf(_proposal, _votes);
    require(hasWinner == true, "No qualifying bids");
    proposal[_proposal].winningBid = w;
    proposal[_proposal].power = _votes;
    proposal[_proposal].status = 1;
  }

  // confirm a registered hash belongs to a valid vote to prevent arbitrary msgs from be signed on behalf of the vote contract
  function confirmWinner(bytes32 _proposal) public onlyTeam {
    require(proposal[_proposal].status == 1, "!1");
    bytes32 _hash = bidder[_proposal][proposal[_proposal].bids[proposal[_proposal].winningBid].owner].msgHash;
    winningHashes[_hash] = true;
    proposal[_proposal].status = 2;
  }

  // used to slash bid trolls who register a msg hash that does not correspond with their snapshot vote
  // can also be used in an emergency either by the request of Curve team or Convex team, if a winning bidder
  // is beleived to be a malicious party acting against the best interest of any of the respective platforms
  // _slash should only 'true' if the bid is completely invalid
  function invalidateWinner(bytes32 _proposal, bool _slash) public onlyTeam {
    require(proposal[_proposal].status == 1, "!1"); // Can only invalidate if the winner has not been confirmed
    uint256 w = proposal[_proposal].winningBid;
    require(proposal[_proposal].bids[w].invalid == false, "already invalidated"); // prevents double slashing
    proposal[_proposal].bids[w].invalid = true;
    if(_slash == true) {
      uint256 slashed = bidder[_proposal][proposal[_proposal].bids[w].owner].balance*slashFee/DENOMINATOR; // calculate slashed amount
      bidder[_proposal][proposal[_proposal].bids[w].owner].balance -= slashed;  // remove slashed amount from user balance
      CRV.safeTransfer(platform, slashed); // send slashed amount to platform multi-sig
    }
  }

  // finalize an auction with number of confirmed votes after proposal ends
  function finalize(bytes32 _proposal, uint256 _votes, uint256 _minOut, uint8 _method) public onlyTeam {
    require(proposal[_proposal].status == 2, "!2"); // Can only finalize if winner confirmed
    if(_votes == 0) {
      proposal[_proposal].status = 4; // finalize with no winner
    } else {
      // calculate paid total based on final number of votes received
      Bids memory currentBid = proposal[_proposal].bids[proposal[_proposal].winningBid];
      uint256 paidTotal = currentBid.maxTotal;
      uint256 paidPer = paidTotal/_votes;
      if(paidPer > currentBid.maxPerVote) {
        paidPer = currentBid.maxPerVote;
        paidTotal = paidPer*_votes;
      }
      bidder[_proposal][currentBid.owner].balance -= paidTotal; // removed paid total from winner balance
      if(_minOut == 0) {
        // call stash to lock->stake directly
        CRV.approve(stash, paidTotal);
        Stash(stash).lockCRV(paidTotal);
      } else {
        // call swapper to swap and stake on behalf of stash
        CRV.approve(address(swapper), paidTotal);
        swapper.SwapStake(paidTotal, _minOut, _method);
      }
      proposal[_proposal].status = 3; // set status to finalized with winner
    }
  }

  /* ========== VIEWS ========== */

  // length of proposals registery
  function proposalsLength() public view returns (uint256) {
    return proposals.length;
  }

  // length of bids array in a proposal
  function bidsInProposal(bytes32 _proposal) public view returns (uint256) {
    return proposal[_proposal].bids.length;
  }

  // view specific bid in a given proposal
  function viewBid(bytes32 _proposal, uint256 _bid) public view returns (Bids memory bid) {
    bid = proposal[_proposal].bids[_bid];
  }

  // called by vote proxy contract as part of EIP1271 contract signing
  function isWinningSignature(bytes32 _hash, bytes memory _signature) public view returns (bool) {
    return winningHashes[_hash];
  }

  // Calculates winner of a proposal based on reported voting power
  function winnerIf(bytes32 _proposal, uint256 _votes) public view returns (uint256 winningId, bool hasWinner) {
    require(_votes > 0, "!>0"); // cannot calculate winner of zero votes
    uint256 paidPer;
    uint256 highest;
    // cycle through all bids in proposal
    for(uint256 i=0;i<proposal[_proposal].bids.length;i++) {
      // ignore invalidated bids
      if(proposal[_proposal].bids[i].invalid == false) {
        paidPer = proposal[_proposal].bids[i].maxTotal/_votes; // assume max total is paid
        // if max payment exceeds max per vote allowance, revert to max per vote
        if(paidPer > proposal[_proposal].bids[i].maxPerVote) { paidPer = proposal[_proposal].bids[i].maxPerVote; }
        if(paidPer > highest) {
          winningId = i;
          highest = paidPer;
        }
      }
    }
    // verify a winner has been selected
    if(highest > 0) { hasWinner = true; }
  }

  /* ========== PUBLIC FUNCTIONS ========== */

  // if an auction is not finalized 30 hours after deadline, any user can force status 4 (no winner)
  function forceNoWinner(bytes32 _proposal) public {
    require(proposal[_proposal].deadline+30 hours < block.timestamp, "<30hrs");
    require(proposal[_proposal].status < 3, "final");
    proposal[_proposal].status = 4;
  }

  // register a vote hash to attach to a proposal
  function registerHash(bytes32 _proposal, bytes32 _hash) public {
    require(proposal[_proposal].deadline > block.timestamp, "expired");
    bidder[_proposal][msg.sender].msgHash = _hash;
  }

  // place bid
  function placeBid(bytes32 _proposal, uint256 _maxPerVote, uint256 _maxTotal) public {
    require(_maxTotal > 0, "Cannot bid 0");
    require(_maxPerVote > 0, "Cannot bid 0");
    require(proposal[_proposal].deadline > block.timestamp, "expired");
    require(bidder[_proposal][msg.sender].balance == 0, "Already bid");
    require(bidder[_proposal][msg.sender].msgHash != keccak256(""), "No hash");
    // transfer funds to this contract
    CRV.safeTransferFrom(msg.sender, address(this), _maxTotal);
    // form bid entry
    Bids memory currentEntry;
    currentEntry.owner = msg.sender;
    currentEntry.maxPerVote = _maxPerVote;
    currentEntry.maxTotal = _maxTotal;
    proposal[_proposal].bids.push(currentEntry);
    bidder[_proposal][msg.sender].bidId = proposal[_proposal].bids.length-1;
    bidder[_proposal][msg.sender].balance = _maxTotal;
  }

  // increase a current bid
  function increaseBid(bytes32 _proposal, uint256 bidId, uint256 _maxPerVote, uint256 _maxTotal) public {
    require(proposal[_proposal].deadline > block.timestamp, "expired");
    require(proposal[_proposal].bids[bidId].owner == msg.sender, "!owner");
    // if maxPerVote is greater than original, perform adjustment
    if(_maxPerVote > proposal[_proposal].bids[bidId].maxPerVote) {
      proposal[_proposal].bids[bidId].maxPerVote = _maxPerVote;
    }
    // if maxTotal is greater than original, perform adjustment
    if(_maxTotal > proposal[_proposal].bids[bidId].maxTotal) {
      uint256 increase = _maxTotal-proposal[_proposal].bids[bidId].maxTotal;
      CRV.safeTransferFrom(msg.sender, address(this), increase);
      proposal[_proposal].bids[bidId].maxTotal += increase;
      bidder[_proposal][msg.sender].balance += increase;
    }
  }

  // roll a balance from a finalized auction into a bid for an active auction
  function rollBalance(bytes32 _proposalA, bytes32 _proposalB, uint256 _maxPerVote) public {
    require(proposal[_proposalB].deadline > block.timestamp, "Invalid B"); // Can only roll into active auction
    require(proposal[_proposalA].status > 2, "Invalid A");  // Can only roll out of finalized auction
    require(bidder[_proposalB][msg.sender].balance == 0, "Already bid"); // Address cannot have two bids
    require(bidder[_proposalB][msg.sender].msgHash != keccak256(""), "No hash"); // Address must first register a vote hash
    require(_maxPerVote > 0, "bid 0"); // Cannot bid 0
    require(bidder[_proposalA][msg.sender].balance > 0, "0 balance"); // No balance to transfer

    uint256 bal = bidder[_proposalA][msg.sender].balance; // store original auction balance
    bidder[_proposalA][msg.sender].balance = 0; // set original auction balance to 0
    // form bid entry
    Bids memory currentEntry;
    currentEntry.owner = msg.sender;
    currentEntry.maxPerVote = _maxPerVote;
    currentEntry.maxTotal = bal;
    proposal[_proposalB].bids.push(currentEntry);
    bidder[_proposalB][msg.sender].balance = bal; // set user balance of new auction
  }

  // withdraw from finalized auction
  function withdraw(bytes32 _proposal) public {
    require(proposal[_proposal].status > 2, "not final");
    uint256 bal = bidder[_proposal][msg.sender].balance; // store balance
    if(bal > 0) {
      bidder[_proposal][msg.sender].balance = 0; // set balance to 0
      CRV.safeTransfer(msg.sender, bal); // send stored balance to user
    }
  }

  /* ========== MODIFIERS ========== */

  modifier onlyTeam() {
    require(approvedTeam[msg.sender] == true, "Team only");
    _;
  }
}
