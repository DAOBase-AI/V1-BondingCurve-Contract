// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;


import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 
import "@openzeppelin/contracts/utils/math/SafeMath.sol"; 

contract ERC20Test is ERC20, Ownable {
    using SafeMath for uint256;
    
    uint256 private constant maxSupply = 100000000 * 1e18;     // the total supply

    constructor() public ERC20("Tether USD", "USDT") {
    }

    // mint with max supply
    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if (_amount.add(totalSupply()) > maxSupply) {
            return false;
        }
        _mint(_to, _amount);
        return true;
    }
}
