// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./Curve.sol";
//import "./CurveEth.sol";



contract CurveFactory is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    address payable public platform;            //platform commision account
    uint256 public platformRate = 1;      //% of total minting cost as platform commission
    address[] public curves;
    mapping(address => address) public curveOwnerMap;
    mapping(address => EnumerableSet.AddressSet) private userCurves;
    
    constructor() {
    }
    
    // set up the platform commission account
    function setPlatform(address payable _platform) public onlyOwner {
        platform = _platform;
    }

    // set the platform commission rate, only operable by contract owner, _platformRate is in pph
    function setPlatformRate(uint256 _platformRate) public onlyOwner {
        platformRate = _platformRate;
    }
    
    /**@dev build curve
    *_creator: creator set up commission account
    *_creatorRate: creator's commission rate
    *_virtualBalance: Displacement of bonding curve for setting a reasonable initial price
    *_erc20: contribution token, user need to pay ETH if it's zero address
    *_initMintPrice: slope of bonding curve
    *_n,_d: _n/_d = N of f(X) = m*(X^N) + v
    */
    function createCurve(address payable _creator, uint256 _creatorRate,       
                         uint256 _virtualBalance, address _erc20, uint256 _initMintPrice,
                         uint256 _n, uint256 _d) public {
        require(_creatorRate <= 50 - platformRate, "C: creatorRate is too high.");   
        address curve = address(new Curve(platform, platformRate, _creator, _creatorRate, _virtualBalance, _erc20, _initMintPrice, _n, _d));
        userCurves[msg.sender].add(curve);
        curves.push(curve);
        curveOwnerMap[curve] = msg.sender;
    }
    
    // total number of curves created via factory account
    function getCurveTotalNumber() public view returns(uint256) {
        return curves.length;
    }
    
    // total number of curves created by a user
    function getUserCurveNumber(address _userAddr) public view returns(uint256) {
        return userCurves[_userAddr].length();
    }
    
    // Get the curve address by user address and index
    function getUserCurve(address _userAddr, uint256 _index) public view returns(address) {
        return userCurves[_userAddr].at(_index);
    }
}
