// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ERC1155Ex.sol";
import "./math-utils/AnalyticMath.sol";

/**
* @dev thePASS Bonding Curve - minting NFT through erc20 or eth
* PASS is orgnization's erc1155 token on curve 
* erc20 or eth is contribution token on curve 
* Users can mint PASS via deposting erc20 contribution token into curve
* Curve Formula: f(X) = m*(x^N)+v
* m, slope of bonding curve
* x = totalsupply of PASS 
* f(x) = PASS Price
* N = n/d
* v = virtual balance, Displacement of bonding curve
*/
contract Curve {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public erc20;             // contribution token on bonding curve
    uint256 public initMintPrice;    // the first PASS minting price on the curve
    uint256 public n;                // numerator of exponent in curve power function
    uint256 public d;                // denominator of exponent in curve power function
    uint256 public intPower;         // when n/d is integer
    uint256 public virtualBalance;   // vitual balance for setting a reasonable initial price
    // cache of power function calculation result when exponent is decimal，n => cost
    mapping(uint256 => uint256) public decPowerCache;   
    uint256 public reserve;          // reserve of contribution tokens stored in bonding curve AMM pool
    
    address payable public platform; // thePass platform's commission account
    uint256 public platformRate;     // thePass platform's commission rate in pph  
    uint256 public totalPlatformProfit;       // thePass platform's total commission profits
    
    address payable public creator;  // creator's commission account
    uint256 public creatorRate;      // creator's commission rate in pph
    uint256 public totalCreatorProfit;       // creator's total commission profits
    // thePASS extened ERC1155 contract
    ERC1155Ex public thePASS;        
    // Mathmatical method for calculating power function
    IAnalyticMath public analyticMath = IAnalyticMath(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8); 

    event Minted(uint256 indexed tokenId, uint256 indexed cost, uint256 indexed reserveAfterMint, uint256 balance);
    event Burned(uint256 indexed tokenId, uint256 indexed returnAmount, uint256 indexed reserveAfterBurn, uint256 balance);
    event BatchBurned(uint256[] tokenIds, uint256[] balances, uint256 indexed returnAmount, uint256 indexed reserveAfterBurn);

    /**
    * @dev constrcutor of bonding curve with formular: f(x)=m*(x^N)+v
    * _virtualBalance: v, virtual balance, displacement of curve
    * _initMintPrice: 铸造NFT的价格系数，即f(x)=m*x^n+v中的m的值
    * _n,_d: _n/_d = N, exponent of the curve
    * _erc20: contribution token(erc20) for miniting PASS on bonding curve, send 0x000...000 to appoint it as eth instead of erc20 token
    * reserve: reserve of contribution tokens stored in bonding curve AMM pool, start with 0
    */
   constructor (address _erc20, uint256 _m, uint256 _initMintPrice,
                 uint256 _n, uint256 _d, string memory _baseUri) {
        erc20 = IERC20(_erc20);
        m = _m;
        n = _n;
        

        if (_n.div(_d).mul(_d) == _n) {
            intPower = _n.div(_d);
        }
        else { d = _d; }

        v = _initMintPrice - _m;
        reserve = 0;
        thePASS = new ERC1155Ex(_baseUri);  // setting the NFT PASS contract as orgnization token with initial baseURI
    }
    
    // @creator commission account and rate initilization
    function setFeeParameters(address payable _platform, uint256 _platformRate, 
                              address payable _creator, uint256 _createRate) public {
        require(platform == address(0) && creator == address(0), "Curve: commission account and rate cannot be modified.");
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _createRate;
    }

    /**
    * @dev each PASS minting transaction by depositing contribution erc20 tokens will create a new erc1155 token id sequentially
    * _balance: number of PASSes user want to mint
    * _amount: the maximum deposited amount set by the user
    * _maxPriceFistNFT: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
    * return: token id
    */
    function mint(uint256 _balance, uint256 _amount, uint256 _maxPriceFirstPASS) public returns (uint256) {  
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        uint256 firstPrice = _getCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "Curve: price exceeds slippage tolerance.");

        return _mint(_balance, _amount, false);
    }
    // for small amount of PASS minting, it will be unceessary to check the maximum price for the fist mintable PASS
    function mint(uint256 _balance, uint256 _amount) public returns (uint256) {  
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        
        return _mint(_balance, _amount, false);
    }
    
   /**
    * @dev user burn PASS/PASSes to receive corresponding contribution tokens
    * _tokenId: the token id of PASS/PASSes to burn
    * _balance: the number of PASS/PASSes to burn
    */
    function burn(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        
        // checks if allowed to burn
        thePASS.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        erc20.safeTransfer(msg.sender, burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }
    // allow user to burn batches of PASSes with a set of token id
    function burnBatch(uint256[] memory _tokenIds, uint256[] memory _balances) public {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        require(_tokenIds.length == _balances.length, "Curve: _tokenIds and _balances length mismatch");
        uint256 totalBalance;
        for(uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }
        
        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);
        
        // checks if allowed to burn
        thePASS.burnBatch(msg.sender, _tokenIds, _balances);

        reserve = reserve.sub(burnReturn);
        erc20.safeTransfer(msg.sender, burnReturn); 

        emit BatchBurned(_tokenIds, _balances, burnReturn, reserve);
    }
    
    
    /**
    * @dev each PASS minting transaction by depositing contribution ETHs will create a new erc1155 token id sequentially
    * _balance: number of PASSes user want to mint
    * _maxPriceFirstPASS: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
    * return: token ID
    */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS) payable public returns (uint256) {    
        require(address(erc20) == address(0), "Curve: erc20 address is NOT null.");    
        uint256 firstPrice = _getCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "Curve: price is too high.");

        return _mint(_balance, msg.value, true);
    }

    function mintEth(uint256 _balance) payable public returns (uint256) {    
        require(address(erc20) == address(0), "Curve: erc20 address is NOT null.");    
        
        return _mint(_balance, msg.value, true);
    }

    /**
    * @dev user burn PASS/PASSes to receive corresponding contribution ETHs
    * _tokenId: the token id of PASS/PASSes to burn
    * _balance: the number of PASS/PASSes to burn
    */
    function burnEth(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) == address(0), "Curve: erc20 address is NOT null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        
        thePASS.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        payable(msg.sender).transfer(burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }
    // allow user to burn batches of PASSes with a set of token id
    function burnBatchETH(uint256[] memory _tokenIds, uint256[] memory _balances) public {
        require(address(erc20) == address(0), "C: erc20 is null.");
        require(_tokenIds.length == _balances.length, "C: _tokenIds and _balances length mismatch");
        uint256 totalBalance;
        for(uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        thePASS.burnBatch(msg.sender, _tokenIds, _balances);

        reserve = reserve.sub(burnReturn);
        payable(msg.sender).transfer(burnReturn); 

        emit BatchBurned(_tokenIds, _balances, burnReturn, reserve);
    }

    // internal function to mint PASS
    function _mint(uint256 _balance, uint256 _amount, bool bETH) private returns (uint256) {
        uint256 mintCost = _getCurrentCostToMint(_balance);
        require(_amount >= mintCost, "Curve: not enough tokens sent.");
        // For eth, any excess amount will be returned. For erc20, only required amount will be transferred
        if (bETH) {
            if (_amount.sub(mintCost) > 0)
                payable(msg.sender).transfer(_amount.sub(mintCost));
        } else {
            erc20.safeTransferFrom(msg.sender, address(this), mintCost);
        }

        uint256 tokenId = thePASS.mint(msg.sender, _balance);

        uint256 platformProfit = mintCost.mul(platformRate).div(100);
        uint256 creatorProfit = mintCost.mul(creatorRate).div(100);

        totalPlatformProfit = totalPlatformProfit.add(platformProfit);
        totalCreatorProfit = totalCreatorProfit.add(creatorProfit);
        
        uint256 reserveCut = mintCost.sub(platformProfit).sub(creatorProfit);
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintCost, reserve, _balance);

        return tokenId; // returns tokenId in case its useful to check it
    }

    /**
    * @dev internal function to calculate the cost of minting _balance PASSes in a transaction
    * _balance: number of PASS/PASSes to mint
    */
    function _getCurrentCostToMint(uint256 _balance) internal returns (uint256) {
        uint256 curStartX = getCurrentSupply() + 1;     // fist PASS to mint
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                // for intergal n from 1 ~ 10, using Bernoulli's formula to make calculation gas consumption manageable
                uint256 intervalSum = caculateIntervalSum(intPower, curStartX, curStartX + _balance - 1);
                totalCost = m.mul(intervalSum).add(virtualBalance.mul(_balance));
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(m.mul(i**intPower).add(virtualBalance));
                }
            }
        } else {
            // calculation method for decimal n
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                if (decPowerCache[i] == 0) {
                    (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                    uint256 cost = virtualBalance.add(m.mul(p).div(q));
                    totalCost = totalCost.add(cost);
                    // cache each caculated f(x) to save next-time calculation gas consumption
                    decPowerCache[i] = cost;        
                } else {
                    totalCost = totalCost.add(decPowerCache[i]);
                }
            }
        }
        return totalCost;
    }

    // external view function to query the current cost to mint a PASS/PASSes
    function getCurrentCostToMint(uint256 _balance) public view returns (uint256) {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(intPower, curStartX, curStartX + _balance - 1);
                totalCost = initMintPrice.mul(intervalSum).add(virtualBalance.mul(_balance));
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(initMintPrice.mul(i**intPower).add(virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                uint256 cost = virtualBalance.add(initMintPrice.mul(p).div(q));
                totalCost = totalCost.add(cost);
            }
        }
        return totalCost;
    }

    /**
    * @dev calculate the return of burning _balance PASSes in a transaction
    * _balance: number of PASS/PASSes to be burned
    */
    function getCurrentReturnToBurn(uint256 _balance) public view returns (uint256) {
        uint256 curEndX = getCurrentSupply();
        // required burning balance cannot exceed current supply
        _balance = _balance > curEndX ? curEndX : _balance;           

        uint256 totalReturn;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(intPower, curEndX - _balance + 1, curEndX);
                totalReturn = m.mul(intervalSum).add(virtualBalance.mul(_balance));
            } else {
                for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                    totalReturn = totalReturn.add(m.mul(i**intPower).add(virtualBalance));
                }
            }
        } else {
            for (uint256 i = curEndX; i > curEndX - _balance; i--) {                
                totalReturn = totalReturn.add(decPowerCache[i]);
            }
        }
        totalReturn = totalReturn.mul(100 - platformRate - creatorRate).div(100);
        return totalReturn;
    }

    // get current supply of PASS
    function getCurrentSupply() public view returns (uint256) {
        return thePASS.totalSupply();
    }
    // Bernoulli's formula for calculating the sum of intervals between the two reserves
    function caculateIntervalSum(uint256 _power, uint256 _startX, uint256 _endX) public view returns(uint256) {
        return analyticMath.caculateIntPowerSum(_power, _endX).sub(analyticMath.caculateIntPowerSum(_power, _startX - 1));
    }
    // only thePASS platform and creator can claim their corresponding commission profits
    function claimTotalProfit(bool bPlatform) public {
        if (address(erc20) == address(0)) {
            if (bPlatform) {
                platform.transfer(totalPlatformProfit); 
                totalPlatformProfit = 0;
            }
            else {
                creator.transfer(totalCreatorProfit); 
                totalCreatorProfit = 0; 
            }
        } else {
            if (bPlatform) {
                erc20.safeTransfer(platform, totalPlatformProfit);
                totalPlatformProfit = 0; 
            }
            else {
                erc20.safeTransfer(creator, totalCreatorProfit); 
                totalCreatorProfit = 0; 
            }
        }
    }
}
