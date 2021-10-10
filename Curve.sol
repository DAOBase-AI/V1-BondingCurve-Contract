// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ERC1155Ex.sol";
import "./math-utils/AnalyticMath.sol";

/**@dev thePASS Bonding Curve
*PASS is orgnization's erc1155 token on curve  
*Users can mint PASS via deposting erc20 contribution token into curve
*Curve Formula: f(X) = m*[X^（n/d)]+v
*m, slope of bonding curve
*x = totalsupply of PASS 
*f(x) = PASS Price
*N = n/d
*v = virtual balance, Displacement of bonding curve
*/

contract Curve {
    using SafeMath for uint256;

    IERC20 public erc20;             // contribution token on bonding curve
    uint256 public initMintPrice;    // the first PASS minting price on the curve = m + v
    uint256 public initBurnPrice;    // the last PASS burning price on the curve
    uint256 public n;                // power function numerator
    uint256 public d;                // power function denominator
    bool public bIntPower;           // determine if the power is an integer
    uint256 public virtualBalance;   // vitual balance for setting a reasonable initial price
    
    uint256 public reserve;          // reserve of contribution tokens stored in bonding curve AMM pool
    
    address payable public platform; // thePass platform's commission account
    uint256 public platformRate;     // thePass platform's commission rate in pph 
    
    address payable public creator;  // creator's commission account
    uint256 public creatorRate;      // creator's commission rate in pph

    ERC1155Ex public thePASS;        // orgnization's erc1155 based PASSes
    // Mathmatical method for calculating power function
    IAnalyticMath public analyticMath = IAnalyticMath(0x6eC7dE12F63fe9D234B169aca4958D3ad1aA1872); 

    event Minted(uint256 indexed tokenId, uint256 indexed Cost, uint256 indexed reserveAfterMint, uint256 balance);
    event Burned(uint256 indexed tokenId, uint256 indexed Return, uint256 indexed reserveAfterBurn, uint256 balance);

    constructor (address payable _platform, uint256 _platformRate, 
                 address payable _creator, uint256 _creatorRate,
                 uint256 _virtualBalance, address _erc20, uint256 _initMintPrice,
                 uint256 _n, uint256 _d) {
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _creatorRate;
        
        erc20 = IERC20(_erc20);
        initMintPrice = _initMintPrice;
        initBurnPrice = initMintPrice.mul(100 - _platformRate - _creatorRate).div(100);
        
        n = _n;
        d = _d;
        bIntPower = _n.div(_d).mul(_d) == _n;
        virtualBalance = _virtualBalance;
        
        reserve = 0;
        // erc1155 tokens based PASS
        thePASS = new ERC1155Ex();       
    }

    /**@dev Each minting transation with erc20 tokens will produce a PASS/a batch of PASSes with a unique erc1155 token id.
    *_balance: number of PASSes user want to mint.
    *_amount: the maximum deposited amount set by the user. Any difference with the actual amount required will be returned.
    *_maxPriceFirstPASS: the maximum allowed deposited amount for the first minted PASS to prevent front-running with least gas consumption.
    *return: token ID
    */
    function mint(uint256 _balance, uint256 _amount, uint256 _maxPriceFirstPASS) public returns (uint256) {  
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 firstPrice = getCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "C: Price exceeds slippage tolerance.");

        uint256 mintCost = getCurrentCostToMint(_balance);        
        require(_amount >= mintCost, "C: Not enough tokens sent");
        erc20.transferFrom(msg.sender, address(this), mintCost);

        uint256 tokenId = thePASS.mint(msg.sender, _balance);    

        uint256 platformProfit = mintCost.mul(platformRate).div(100);  
        uint256 creatorProfit = mintCost.mul(creatorRate).div(100);    
        erc20.transfer(platform, platformProfit); 
        erc20.transfer(creator, creatorProfit);                         
        // added reserve after subtracting platform and creator's profit
        uint256 reserveCut = mintCost.sub(platformProfit).sub(creatorProfit); 
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintCost, reserve, _balance);
        // returns tokenId in case it's useful to check it
        return tokenId; 
    }

    /**@dev User burn PASS/PASSes to receive corresponding erc20 tokens.
    *_tokenId: the token id of PASS/PASSes to be burned
    *_balance: the number of PASS/PASSes to be burned
    */
    function burn(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);   
        
        // checks if allowed to burn
        thePASS.burn(msg.sender, _tokenId, _balance);        

        reserve = reserve.sub(burnReturn);
        erc20.transfer(msg.sender, burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }
    
    /**@dev Each minting transation with ETH will produce a PASS/a batch of PASSes with a unique erc1155 token id.
    *_balance: number of PASSes user want to mint
    *_maxPriceFirstPASS: the maximum allowed deposited amount for the first minted PASS to prevent front-running with least gas consumption.
    *return: token ID
    */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS) payable public returns (uint256) {    
        require(address(erc20) == address(0), "C: erc20 is NOT null.");    
        uint256 firstPrice = getCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "C: Price exceeds slippage tolerance.");

        uint256 mintCost = getCurrentCostToMint(_balance);
        require(msg.value >= mintCost, "C: Not enough ETH sent");
        if (msg.value.sub(mintCost) > 0)
            payable(msg.sender).transfer(msg.value.sub(mintCost));

        uint256 tokenId = thePASS.mint(msg.sender, _balance);        

        uint256 platformProfit = mintCost.mul(platformRate).div(100);      
        uint256 creatorProfit = mintCost.mul(creatorRate).div(100);    
        platform.transfer(platformProfit);                       
        creator.transfer(creatorProfit);                        
        
        uint256 reserveCut = mintCost.sub(platformProfit).sub(bussinessProfit);
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintCost, reserve, _balance);
        // returns tokenId in case its useful to check it
        return tokenId; 
    }

    /**@dev User burn a PASS/PASSes to receive corresponding ETH.
    *_tokenId: token id of the PASS/PASSes to be burned
    *_balance: number of PASS/PASSes to be burned
    */
    function burnEth(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) == address(0), "C: erc20 is NOT null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        
        thePASS.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        payable(msg.sender).transfer(burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }

    /**@dev Calculate the cost to mint a PASS/a batch of PASSes in one transaction
    *_balance: number of PASS/PASSes to mint
    *f(X) = m*[X^（n/d)]+v, m = initMintPrice-virtualBalance
    */
    function getCurrentCostToMint(uint256 _balance) public view returns (uint256) {
        uint256 curSupply = getCurrentSupply();
        uint256 totalCost;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curSupply + 1; i <= curSupply + _balance; i++) {
                totalCost = totalCost.add(virtualBalance.add((initMintPrice-virtualBalance)).mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curSupply+1; i <= curSupply + _balance; i++) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalCost = totalCost.add(virtualBalance.add((initMintPrice-virtualBalance).mul(p).div(q)));
            }
        }
        return totalCost;
    }

    /**@dev calculate the return from burning a PASS/a batch of PASSes in one transaction
    *_balance: number of PASS/PASSes to be burned
    */
    function getCurrentReturnToBurn(uint256 _balance) public virtual view returns (uint256) {  
        uint256 curSupply = getCurrentSupply();
        uint256 totalReturn;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curSupply; i > curSupply - _balance; i--) {
                totalReturn = totalReturn.add(virtualBalance.add((initMintPrice-virtualBalance).mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curSupply; i > curSupply - _balance; i--) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalReturn = totalReturn.add((virtualBalance.add((initMintPrice-virtualBalance).mul(p).div(q))).mul(100 - _platformRate - _creatorRate).div(100));
            }
        }
        return totalReturn;
    }

    // get number of currently exisiting PASS/PASSes.
    function getCurrentSupply() public virtual view returns (uint256) {
        return thePASS.totalSupply();
    }
}
