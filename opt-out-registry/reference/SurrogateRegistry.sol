// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


contract SurrogateRegistry {
    string public name;

    /// @notice Creates a new SurrogateRegistry contract
    /// @param _name Contract name identifier
    constructor(string memory _name) {
        name = _name;
    }

    struct Info {
        address surrogate;
        uint32 timestamp;
    }

    mapping(address => Info) public surrogateInfo;

    event SurrogateSet(address indexed account, address indexed surrogate);

    /// @notice Checks if an address is the surrogate for an account
    /// @param _surrogate Address to check
    /// @param _account Account to check against
    /// @return True if surrogate matches account
    function isSurrogate(address _surrogate, address _account) external view returns (bool) {
        return surrogateInfo[_account].surrogate == _surrogate;
    }

    /// @notice Sets the surrogate address for the caller
    /// @param _surrogate Address to set as surrogate
    function setSurrogate(address _surrogate) external {
        surrogateInfo[msg.sender] = Info({
            surrogate: _surrogate,
            timestamp: uint32(block.timestamp)
        });
        emit SurrogateSet(msg.sender, _surrogate);
    }

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
