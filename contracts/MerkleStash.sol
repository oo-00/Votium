// SPDX-License-Identifier: MIT
// Votium Merkle Stash

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// interfaces with Convex cvxCRV farm
interface Ifarm {
  function getReward() external returns(bool);
  function withdraw(uint256, bool) external returns(bool);
}

// interfaces with Convex CRV->cvxCRV locking contract
interface Locker {
  function deposit(uint256, bool, address) external; // amount, false, address(farm)
}

contract MerkleStash is Ownable {
  using SafeERC20 for IERC20;

  // set up contract interfaces
  IERC20 public cvxCRV = IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);
  IERC20 public CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
  Ifarm public farm = Ifarm(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
  Locker public locker = Locker(0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae);

  // environment variables for updateable merkle
  bytes32 public merkleRoot;
  uint256 public update;
  bool public frozen = true;
  // This is a packed array of booleans.
  mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

  // environment variables for team distribution of farm rewards
  address[] public farmTokens;
  address[] public team;
  uint256[] public weights;
  uint256 public constant DENOMINATOR = 10000; // denominates weights 10000 = 100%

  constructor() {
    // Add initial farm tokens
    farmTokens.push(address(CRV));                               // CRV
    farmTokens.push(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490); // 3crv
    farmTokens.push(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); // CVX
    // Add initial team members and weights
    team.push(0xC8076F60cbDd2EE93D54FCc0ced88095A72f4a2f);
    team.push(0xAdE9e51C9E23d64E538A7A38656B78aB6Bcc349e);
    weights.push(5000);
    weights.push(5000);
  }

  // Taken from sushi's updateable merkle airdrop contract
  function isClaimed(uint256 index) public view returns (bool) {
    uint256 claimedWordIndex = index / 256;
    uint256 claimedBitIndex = index % 256;
    uint256 claimedWord = claimedBitMap[update][claimedWordIndex];
    uint256 mask = (1 << claimedBitIndex);
    return claimedWord & mask == mask;
  }

  function _setClaimed(uint256 index) private {
    uint256 claimedWordIndex = index / 256;
    uint256 claimedBitIndex = index % 256;
    claimedBitMap[update][claimedWordIndex] = claimedBitMap[update][claimedWordIndex] | (1 << claimedBitIndex);
  }

  function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external {
    require(!frozen, 'MerkleDistributor: Claiming is frozen.');
    require(!isClaimed(index), 'MerkleDistributor: Drop already claimed.');

    // Verify the merkle proof.
    bytes32 node = keccak256(abi.encodePacked(index, account, amount));
    require(MerkleProof.verify(merkleProof, merkleRoot, node), 'MerkleDistributor: Invalid proof.');

    // Withdraw from Convex stake
    require(farm.withdraw(amount, false), "Could not withdraw from farm");

    // Mark it claimed and send the cvxCRV.
    _setClaimed(index);
    cvxCRV.safeTransfer(account, amount);

    emit Claimed(index, amount, account, update);
  }

  // MULTI SIG FUNCTIONS //

  function freeze() public onlyOwner {
    frozen = true;
  }

  function unfreeze() public onlyOwner {
    frozen = false;
  }

  function updateMerkleRoot(bytes32 _merkleRoot) public onlyOwner {
    require(frozen, 'MerkleDistributor: Contract not frozen.');

    // Increment the update (simulates the clearing of the claimedBitMap)
    update += 1;
    // Set the new merkle root
    merkleRoot = _merkleRoot;

    emit MerkleRootUpdated(merkleRoot, update);
  }

  // Add farmable token
  function addFarmToken(address _token) public onlyOwner {
    require(_token != address(cvxCRV), "Cannot add cvxCRV to farmed tokens");
    farmTokens.push(_token);
  }
  // Replace farmable token
  function replaceFarmToken(uint256 _index, address _token) public onlyOwner {
    require(_token != address(cvxCRV), "Cannot add cvxCRV to farmed tokens");
    farmTokens[_index] = _token;
  }

  // Add team member with weight
  function addTeam(address _team, uint256 _weight) public onlyOwner {
    team.push(_team);
    weights.push(_weight);
  }
  // Adjust team member address or weight
  function adjustTeam(uint256 _index, address _team, uint256 _weight) public onlyOwner {
    require(team[_index] != address(0), "unassigned index");
    team[_index] = _team;
    weights[_index] = _weight;
  }

  // To claim any potential 3rd party airdrops or assist with contract migration
  function execute(address _to, uint256 _value, bytes calldata _data) external onlyOwner returns (bool, bytes memory) {
    (bool success, bytes memory result) = _to.call{value:_value}(_data);
    return (success, result);
  }

  // claim farmed tokens and distribute to team based on weights
  function claimTeam() public {
    farm.getReward();
    uint256 bal;
    uint256 split;
    IERC20 ft;
    // cycle through farm tokens
    for(uint32 i=0;i<farmTokens.length;i++) {
      ft = IERC20(farmTokens[i]);
      bal = ft.balanceOf(address(this));
      // cycle through team addresses and weights
      for(uint32 n=0;n<team.length;n++) {
        if(weights[n] > 0) {
          split = bal*weights[n]/DENOMINATOR;
          ft.safeTransfer(team[n], split);
        }
      }
    }
  }

  // called by auction contract
  function lockCRV(uint256 _amount) public {
    CRV.safeTransferFrom(msg.sender, address(this), _amount);
    CRV.approve(address(locker), _amount);
    locker.deposit(_amount, false, address(farm));
  }

  event Claimed(uint256 index, uint256 amount, address indexed account, uint256 indexed update);
  event MerkleRootUpdated(bytes32 indexed merkleRoot, uint256 indexed update);
}
