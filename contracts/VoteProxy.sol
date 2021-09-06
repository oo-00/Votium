// SPDX-License-Identifier: MIT
// Votium Vote Proxy

pragma solidity ^0.8.7;

import "./Ownable.sol";

interface Iauction {
  function isWinningSignature(bytes32 _hash, bytes memory _signature) external view returns (bool);
}

contract VoteProxy is Ownable {
  Iauction public auctioneer;

  function updateAuctioneer(address _auctioneer) public onlyOwner {
    auctioneer = Iauction(_auctioneer);
  }

  function isValidSignature(bytes32 _hash, bytes calldata _signature) external view returns (bytes4) {
    // Validate signatures
    if (auctioneer.isWinningSignature(_hash, _signature) == true) {
      return 0x1626ba7e;
    } else {
      return 0xffffffff;
    }
  }

  function execute(address _to, uint256 _value, bytes calldata _data) external onlyOwner returns (bool, bytes memory) {
    (bool success, bytes memory result) = _to.call{value:_value}(_data);
    return (success, result);
  }
}
