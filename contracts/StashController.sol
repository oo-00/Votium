// SPDX-License-Identifier: MIT
// Votium Stash Controller

pragma solidity ^0.8.7;

import "./Ownable.sol";

// contract interface
interface Stash {
  function updateMerkleRoot(address, bytes32) external;
  function transferOwnership(address) external;
  function merkleRoot(address) external view returns (bytes32);
}


contract StashController is Ownable {

	// merkle stash
	Stash public stash = Stash(0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A);

	// freeze roots
	function multiFreeze(address[] calldata _tokens) public onlyOwner {
		for(uint256 i = 0; i<_tokens.length; i++) {
			stash.updateMerkleRoot(_tokens[i], 0);
		}
	}

	// update roots
	function multiSet(address[] calldata _tokens, bytes32[] calldata _roots) public onlyOwner {
		for(uint256 i = 0; i<_tokens.length; i++) {
			require(stash.merkleRoot(_tokens[i]) == 0, "must freeze first");
			stash.updateMerkleRoot(_tokens[i], _roots[i]);
		}
	}

	// Change ownership of stash
	function newController(address _newController) public onlyOwner {
		stash.transferOwnership(_newController);
	}

	// Change stash address
	function newStash(address _newStash) public onlyOwner {
		stash = Stash(_newStash);
	}

	// Fallback executable function
	function execute(address _to, uint256 _value, bytes calldata _data) external onlyOwner returns (bool, bytes memory) {
    (bool success, bytes memory result) = _to.call{value:_value}(_data);
    return (success, result);
  }

}
