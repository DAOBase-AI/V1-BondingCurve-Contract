// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Curve.sol";

contract CurveFactory is Ownable {
    uint256 private totalRateLimit = 50;

    address payable public platform; // platform commision account
    uint256 public platformRate = 1; // % of total minting cost as platform commission

    event CurveCreated(
        address indexed owner,
        address indexed curveAddr,
        uint256 _initMintPrice,
        uint256 m,
        uint256 n,
        uint256 d,
    );

    constructor() {}

    // set up the platform commission account and platform commission rate, only operable by contract owner, _platformRate is in pph
    function setPlatformParms(address payable _platform, uint256 _platformRate)
        public
        onlyOwner
    {
        platform = _platform;
        platformRate = _platformRate;
    }

    // set the limit of total commission rate, only operable by contract owner, _totalRateLimit is in pph
    function setTotalRateLimit(uint256 _totalRateLimit) public onlyOwner {
        totalRateLimit = _totalRateLimit;
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
    function createCurve(
        string memory _name,
        string memory _symbol,
        address payable _creator,
        uint256 _creatorRate,
        uint256 _initMintPrice,
        address _erc20,
        uint256 _m,
        uint256 _n,
        uint256 _d,
        string memory _baseUri
    ) public {
        require(
            _creatorRate <= totalRateLimit - platformRate,
            "Curve: creator's commission rate is too high."
        );
        Curve curve = new Curve(
            _name,
            _symbol,
            _baseUri,
            _erc20,
            _initMintPrice,
            _m,
            _n,
            _d
        );
        curve.setFeeParameters(platform, platformRate, _creator, _creatorRate);
        address curveAddr = address(curve); // get contract address of created curve
        emit CurveCreated(msg.sender, curveAddr, _initMintPrice, _m, _n, _d);
    }
}
