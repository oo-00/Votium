// SPDX-License-Identifier: MIT
// Votium Merkle Stash

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract MerkleStash is Ownable {
  using SafeERC20 for IERC20;

  IERC20 public token;

  // environment variables for updateable merkle
  bytes32 public merkleRoot;
  uint256 public update;
  bool public frozen = true;
  // This is a packed array of booleans.
  mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;


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

    _setClaimed(index);
    token.safeTransfer(account, amount);

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

	function setToken(address _token) public onlyOwner {
		require(address(token) == address(0), "set");
		token = IERC20(_token);
	}

	// EVENTS //

  event Claimed(uint256 index, uint256 amount, address indexed account, uint256 indexed update);
  event MerkleRootUpdated(bytes32 indexed merkleRoot, uint256 indexed update);
}
