// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./Curve.sol";

contract CurveFactory is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    address payable public platform;
    uint256 public platformRate = 1;
    address[] public curves;
    mapping(address => address) public curveOwnerMap;
    mapping(address => EnumerableSet.AddressSet) private userCurves;
    
    constructor() {
    }
    
    // 设置平台手续费收取账号
    function setPlatform(address payable _platform) public onlyOwner {
        platform = _platform;
    }

    // 设置平台手续费比例，只能由owner操作
    // _platformRate: 百分比，1表示1%
    function setPlatformRate(uint256 _platformRate) public onlyOwner {
        platformRate = _platformRate;
    }
    
    // 创建curve
    // _creator: B端用户设置的手续费收取账号
    // _creatorRate: B端用户收取的手续费比例
    // _virtualBalance: 虚拟流动性，即f(x)=m*x^n+v中的v的值
    // _erc20: 表示用户铸造NFT时需要支付哪种ERC20，如果此值为0x000...000, 表示用户需要通过支付ETH来铸造NFT
    // _initMintPrice: 铸造NFT的价格系数，即f(x)=m*x^n+v中的m的值
    // _n,_d: _n/_d即f(x)=m*x^n+v中n的值
    function createCurve(address payable _creator, uint256 _creatorRate,
                         uint256 _virtualBalance, address _erc20, uint256 _initMintPrice,
                         uint256 _n, uint256 _d, string memory _baseUri) public {
        require(_creatorRate <= 50 - platformRate, "C: bussinessRate is too high.");   
        Curve curve = new Curve(_erc20, _virtualBalance, _initMintPrice, _n, _d, _baseUri);
        curve.setFeeParameters(platform, platformRate, _creator, _creatorRate);
        
        address curveAddr = address(curve);
        userCurves[msg.sender].add(curveAddr);
        curves.push(curveAddr);
        curveOwnerMap[curveAddr] = msg.sender;
    }
    
    // 获取已经创建好的curve总数
    function getCurveTotalNumber() public view returns(uint256) {
        return curves.length;
    }
    
    // 获取某个用户已经创建好的curve总数
    function getUserCurveNumber(address _userAddr) public view returns(uint256) {
        return userCurves[_userAddr].length();
    }
    
    // 通过用户地址和序号获取curve地址
    function getUserCurve(address _userAddr, uint256 _index) public view returns(address) {
        return userCurves[_userAddr].at(_index);
    }
}