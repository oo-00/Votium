// SPDX-License-Identifier: MIT
// Votium Swapper

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Ownable.sol";

// sushi router interface
interface Sushi {
    function swapExactTokensForTokens(uint256,uint256,address[] calldata,address,uint256) external;
}
// curve pool interface
interface Curve {
	function exchange(int128, int128, uint256, uint256) external returns (uint256);
}
// Convex farm interface
interface Farm {
  function stakeFor(address, uint256) external;
}

contract Swapper is Ownable {
	using SafeERC20 for IERC20;
	Sushi public sushi = Sushi(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // sushi router address
	Curve public curve = Curve(0x9D0464996170c6B9e75eED71c68B99dDEDf279e8); // curve pool address
	address public CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52; 				// CRV address
	address public cvxCRV = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;     // cvxCRV address
	address public stash = 0x6F76c6c2FEfA72baC17D2864e05b93abe7B1441c;			// stash address
	Farm public farm = Farm(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);		// convex farm address

	// transfers CRV from caller
	// swaps
	// stakes on behalf of stash contract (merkle)
	function SwapStake(uint256 amountIn, uint256 minAmountOut, uint8 method) public {
		// using uint instead of bool so that the interface is future proofed for more than 2 paths
		IERC20(CRV).safeTransferFrom(msg.sender, address(this), amountIn);
		if(method == 0) { // use SUSHI to swap
			address[] memory path = new address[](2);
			path[0] = CRV;
			path[1] = cvxCRV;
			IERC20(CRV).approve(address(sushi), amountIn);
			sushi.swapExactTokensForTokens(amountIn,minAmountOut,path,address(this),block.timestamp+1800);
		} else { // use CURVE to swap
			IERC20(CRV).approve(address(curve), amountIn);
			curve.exchange(0,1,amountIn,minAmountOut);
		}
		// stake balance on behalf of stash contract
		uint256 bal = IERC20(cvxCRV).balanceOf(address(this));
		IERC20(cvxCRV).approve(address(farm), bal);
		farm.stakeFor(stash, bal);
	}

	// update stash address
	function updateStash(address _stash) public onlyOwner {
		stash = _stash;
	}
}
