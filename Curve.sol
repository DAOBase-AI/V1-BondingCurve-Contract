// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ERC1155Ex.sol";
import "./math-utils/AnalyticMath.sol";

// Curve类，通过ERC20铸造NFT
contract Curve {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public erc20;          // 铸造NFT需要消耗的ERC20
    uint256 public m; // 初始铸造价格
    uint256 public n;             // 幂分子
    uint256 public d;             // 幂分母
    uint256 public intPower;         // 幂为整数时的值
    uint256 public virtualBalance;  // 虚拟流动性数值
    
    mapping(uint256 => uint256) public decPowerCache;   // 小数幂计算结果缓存，n => cost
    uint256 public reserve;   // 本合约当前拥有的ERC20数量
    
    address payable public platform;   // 平台费收取账号
    uint256 public platformRate;              // 平台费收取比例
    uint256 public totalPlatformProfit;       // 平台费总收益
    
    address payable public creator;  // B端手续费收取账号
    uint256 public creatorRate;             // B端手续费收取比例
    uint256 public totalCreatorProfit;       // B端手续费总收益

    ERC1155Ex public thePASS;                // ERC1155Ex合约
    
    IAnalyticMath public analyticMath = IAnalyticMath(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8);  // 数学方法，可计算幂函数

    event Minted(uint256 indexed tokenId, uint256 indexed cost, uint256 indexed reserveAfterMint, uint256 balance);
    event Burned(uint256 indexed tokenId, uint256 indexed returnAmount, uint256 indexed reserveAfterBurn, uint256 balance);
    event BatchBurned(uint256[] tokenIds, uint256[] balances, uint256 indexed returnAmount, uint256 indexed reserveAfterBurn);

    /*
    构造函数
    _virtualBalance: 虚拟流动性，即f(x)=m*x^n+v中的v的值
    _erc20: 表示用户铸造NFT时需要支付哪种ERC20，如果此值为0x000...000, 表示用户需要通过支付ETH来铸造NFT
    _m: 铸造NFT的价格系数，即f(x)=m*x^n+v中的m的值
    _n,_d: _n/_d即f(x)=m*x^n+v中n的值
    */
    constructor (address _erc20, uint256 _virtualBalance, uint256 _m,
                 uint256 _n, uint256 _d, string memory _baseUri) {
        erc20 = IERC20(_erc20);
        m = _m;
        
        n = _n;
        d = _d;
        if (_n.div(_d).mul(_d) == _n) {
            intPower = _n.div(_d);
        }
        virtualBalance = _virtualBalance;
        
        reserve = 0;
        thePASS = new ERC1155Ex(_baseUri); 
    }
    
    /* 设置手续费相关参数
    _platformCreator: 平台手续费收取账号
    _platformRate: 平台手续费比例
    _bussinessCreator: B端用户设置的手续费收取账号
    _bussinessRate: B端用户收取的手续费比例
    */
    function setFeeParameters(address payable _platform, uint256 _platformRate, 
                              address payable _creator, uint256 _createRate) public {
        require(platform == address(0) && creator == address(0), "C: fee inited.");
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _createRate;
    }

    /*
    通过ERC20铸造ERC1155，每次铸造都会生成一个独立ID的ERC1155
    _balance: 铸造数量
    _amount: 用户设定的最大可转让金额，当实际所需金额小于此值时，合约只会转实际的金额
    _maxPriceFistNFT：本次铸造的第一个NFT的最大允许金额，防止front-running
    返回值: token ID
    */
    function mint(uint256 _balance, uint256 _amount, uint256 _maxPriceFirstPASS) public returns (uint256) {  
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "C: price is too high.");

        return mintNFT(_balance, _amount, false);
    }

    function mint(uint256 _balance, uint256 _amount) public returns (uint256) {  
        require(address(erc20) != address(0), "C: erc20 is null.");
        
        return mintNFT(_balance, _amount, false);
    }
    
    /*
    用户销毁ERC1155, 获得相应的ERC20
    _tokenId: 待销毁的ERC1155的ID
    _balance: 销毁数量
    */
    function burn(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        
        // checks if allowed to burn
        thePASS.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        erc20.safeTransfer(msg.sender, burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }
    
    function burnBatch(uint256[] memory _tokenIds, uint256[] memory _balances) public {
        require(address(erc20) != address(0), "C: erc20 is null.");
        require(_tokenIds.length == _balances.length, "C: _tokenIds and _balances length mismatch");
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
    
    
    /*
    通过ETH铸造ERC1155，每次铸造都会生成一个独立ID的ERC1155
    _balance: 铸造数量
    _maxPriceFistNFT：本次铸造的第一个NFT的最大允许金额，防止front-running
    返回值: token ID
    */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS) payable public returns (uint256) {    
        require(address(erc20) == address(0), "C: erc20 is NOT null.");    
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(_maxPriceFirstPASS >= firstPrice, "C: price is too high.");

        return mintNFT(_balance, msg.value, true);
    }

    function mintEth(uint256 _balance) payable public returns (uint256) {    
        require(address(erc20) == address(0), "C: erc20 is NOT null.");    
        
        return mintNFT(_balance, msg.value, true);
    }

    /*
    用户销毁ERC1155，获得相应的ETH
    _tokenId: 待销毁的ERC1155的ID
    _balance: 销毁数量
    */
    function burnEth(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) == address(0), "C: erc20 is NOT null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        
        thePASS.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        payable(msg.sender).transfer(burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }

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
    
    /*
    铸造ERC1155的底层函数
    */
    function mintNFT(uint256 _balance, uint256 _amount, bool bETH) private returns (uint256) {
        uint256 mintCost = caculateCurrentCostToMint(_balance);
        require(_amount >= mintCost, "C: Not enough token sent");
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

    /*
    获取一次铸造_balance个NFT的费用，公式f(x)=m*x^n+v
    _balance: 铸造NFT的数量
    */
    function caculateCurrentCostToMint(uint256 _balance) internal returns (uint256) {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(intPower, curStartX, curStartX + _balance - 1);
                totalCost = m.mul(intervalSum).add(virtualBalance.mul(_balance));
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(m.mul(i**intPower).add(virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                if (decPowerCache[i] == 0) {
                    (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                    uint256 cost = virtualBalance.add(m.mul(p).div(q));
                    totalCost = totalCost.add(cost);
                    decPowerCache[i] = cost;
                } else {
                    totalCost = totalCost.add(decPowerCache[i]);
                }
            }
        }
        return totalCost;
    }

    function getCurrentCostToMint(uint256 _balance) public view returns (uint256) {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(intPower, curStartX, curStartX + _balance - 1);
                totalCost = m.mul(intervalSum).add(virtualBalance.mul(_balance));
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(m.mul(i**intPower).add(virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                uint256 cost = virtualBalance.add(m.mul(p).div(q));
                totalCost = totalCost.add(cost);
            }
        }
        return totalCost;
    }

    /*
    获取一次销毁_balance个NFT的费用
    _balance: 销毁NFT的数量
    */
    function getCurrentReturnToBurn(uint256 _balance) public view returns (uint256) {
        uint256 curEndX = getCurrentSupply();
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

    // 获取当前存在的NFT数量
    function getCurrentSupply() public view returns (uint256) {
        return thePASS.totalSupply();
    }

    function caculateIntervalSum(uint256 _power, uint256 _startX, uint256 _endX) view public returns(uint256) {
        return analyticMath.caculateIntPowerSum(_power, _endX).sub(analyticMath.caculateIntPowerSum(_power, _startX - 1));
    }

    function claimTotalProfit(bool bPlatform) public {
        if (address(erc20) == address(0)) {
            if (bPlatform) {
                platform.transfer(totalPlatformProfit); 
            }
            else {
                creator.transfer(totalCreatorProfit); 
            }
        } else {
            if (bPlatform) {
                erc20.safeTransfer(platform, totalPlatformProfit); 
            }
            else {
                erc20.safeTransfer(creator, totalCreatorProfit); 
            }
        }

        if (bPlatform) {
            totalPlatformProfit = 0; 
        }
        else {
            totalCreatorProfit = 0; 
        }
    }
}