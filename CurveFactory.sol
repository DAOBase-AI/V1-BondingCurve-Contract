// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./Curve.sol";

contract CurveFactory is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    address payable public platform;        // platform commision account
    uint256 public platformRate = 1;        // % of total minting cost as platform commission
    address[] public curves;                // array of created curve address
    mapping(address => address) public curveOwnerMap;   // mapping curve address with corresponding owner address
    mapping(address => EnumerableSet.AddressSet) private userCurves;   // enumerable array of curve owner address
    
    event CurveCreated(address indexed owner, address indexed curveAddr);
    
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
    
    /**
    * @dev creation of bonding curve with formular: f(x)=m*(x^N)+v
    * _creator: creator's commission account
    * _creatorRate: creator's commission rate
    * _initMintPrice: f(1) = m + v, the first PASS minting price
    * _erc20: collateral token(erc20) for miniting PASS on bonding curve, send 0x000...000 to appoint it as ETH instead of erc20 token
    * _m: m, slope of curve
    * _n,_d: _n/_d = N, exponent of the curve
    * _baseUri: base URI for PASS metadata
    */
    function createCurve(address payable _creator, uint256 _creatorRate,
                         uint256 _initMintPrice, address _erc20, uint256 _m,
                         uint256 _n, uint256 _d, string memory _baseUri) public {
        require(_creatorRate <= 50 - platformRate, "Curve: creator's commission rate is too high.");   
        Curve curve = new Curve(_erc20, _initMintPrice, _m, _n, _d, _baseUri);
        curve.setFeeParameters(platform, platformRate, _creator, _creatorRate);
        
        address curveAddr = address(curve);         // get contract address of created curve
        userCurves[msg.sender].add(curveAddr);      // accumulate the number of curves created by a user
        curves.push(curveAddr);                     // add newly created curve address into the array of curve address
        curveOwnerMap[curveAddr] = msg.sender;      // binding created curve address with corresponding owner address
        emit CurveCreated(msg.sender, curveAddr);
    }
    
    // total number of curves created via factory account
    function getCurveTotalNumber() public view returns(uint256) {
        return curves.length;
    }
    
    // total number of curves created by a user
    function getUserCurveNumber(address _userAddr) public view returns(uint256) {
        return userCurves[_userAddr].length();
    }
    
    // get the curve address by user address and index
    function getUserCurve(address _userAddr, uint256 _index) public view returns(address) {
        return userCurves[_userAddr].at(_index);
    }
}
