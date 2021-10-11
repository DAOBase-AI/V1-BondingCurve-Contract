// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ERC1155Ex.sol";
import "./math-utils/AnalyticMath.sol";

// Curve类，通过ERC20铸造NFT
contract Curve {
    using SafeMath for uint256;

    IERC20 public erc20;          // 铸造NFT需要消耗的ERC20
    uint256 public initMintPrice; // 初始铸造价格
    uint256 public initBurnPrice; // 初始销毁价格
    uint256 public n;             // 幂分子
    uint256 public d;             // 幂分母
    bool public bIntPower;        // 幂是否为整数
    uint256 public virtualBalance;  // 虚拟流动性数值
    
    uint256 public reserve;   // 本合约当前拥有的ERC20数量
    
    address payable public platform;   // 平台费收取账号
    uint256 public platformRate;              // 平台费收取比例
    
    address payable public creator;  // B端手续费收取账号
    uint256 public creatorRate;             // B端手续费收取比例

    ERC1155Ex public thePASS;                // ERC1155Ex合约
    
    IAnalyticMath public analyticMath = IAnalyticMath(0x6eC7dE12F63fe9D234B169aca4958D3ad1aA1872);  // 数学方法，可计算幂函数

    event Minted(uint256 indexed tokenId, uint256 indexed cost, uint256 indexed reserveAfterMint, uint256 balance);
    event Burned(uint256 indexed tokenId, uint256 indexed return, uint256 indexed reserveAfterBurn, uint256 balance);

    /*
    构造函数
    _platformCreator: 平台手续费收取账号
    _platformRate: 平台手续费比例
    _bussinessCreator: B端用户设置的手续费收取账号
    _bussinessRate: B端用户收取的手续费比例
    _virtualBalance: 虚拟流动性数量，譬如设置为10，表示铸造第0个NFT时的费用实际是按照第11个NFT的费用进行计价
    _erc20: 表示用户铸造NFT时需要支付哪种ERC20
    _initMintPrice: 铸造NFT的价格系数，即f(x)=m*x^n+m中的m的值
    _n,_d: _n/_d即f(x)=m*x^n+m中n的值
    */
    constructor (address payable _platform, uint256 _platformRate, 
                 address payable _bussinessCreator, uint256 _bussinessRate,
                 uint256 _virtualBalance, address _erc20, uint256 _initMintPrice,
                 uint256 _n, uint256 _d) {
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _createRate;
        
        erc20 = IERC20(_erc20);
        initMintPrice = _initMintPrice;
        initBurnPrice = initMintPrice.mul(100 - _platformRate - _bussinessRate).div(100);
        
        n = _n;
        d = _d;
        bIntPower = _n.div(_d).mul(_d) == _n;
        virtualBalance = _virtualBalance;
        
        reserve = 0;
        thePASS = new ERC1155Ex(); 
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
        uint256 firstPrice = getCurrentCostToMint(1);
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
        erc20.transfer(msg.sender, burnReturn); 

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }
    
    /*
    通过ETH铸造ERC1155，每次铸造都会生成一个独立ID的ERC1155
    _balance: 铸造数量
    _maxPriceFistNFT：本次铸造的第一个NFT的最大允许金额，防止front-running
    返回值: token ID
    */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS) payable public returns (uint256) {    
        require(address(erc20) == address(0), "C: erc20 is NOT null.");    
        uint256 firstPrice = getCurrentCostToMint(1);
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

    function mintNFT(uint256 _balance, uint256 _amount, bool bETH) private returns (uint256) {
        uint256 mintCost = getCurrentCostToMint(_balance);
        require(_amount >= mintCost, "C: Not enough token sent");
        if (bETH) {
            if (_amount.sub(mintCost) > 0)
                payable(msg.sender).transfer(_amount.sub(mintCost));
        } else {
            erc20.transferFrom(msg.sender, address(this), mintCost);
        }

        uint256 tokenId = thePASS.mint(msg.sender, _balance);

        uint256 platformProfit = mintCost.mul(platformRate).div(100);
        uint256 bussinessProfit = mintCost.mul(creatorRate).div(100);
        if (bETH) {
            platform.transfer(platformProfit); 
            creator.transfer(bussinessProfit); 
        } else {
            erc20.transfer(platform, platformProfit); 
            erc20.transfer(creator, bussinessProfit); 
        }
        
        uint256 reserveCut = mintCost.sub(platformProfit).sub(bussinessProfit);
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintCost, reserve, _balance);

        return tokenId; // returns tokenId in case its useful to check it
    }

    /*
    获取一次铸造_balance个NFT的费用
    _balance: 铸造NFT的数量
    */
    function getCurrentCostToMint(uint256 _balance) public view returns (uint256) {
        uint256 curSupply = getCurrentSupply() + virtualBalance;
        uint256 totalCost;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curSupply; i < curSupply + _balance; i++) {
                totalCost = totalCost.add(initMintPrice.add(initMintPrice.mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curSupply; i < curSupply + _balance; i++) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalCost = totalCost.add(initMintPrice.add(initMintPrice.mul(p).div(q)));
            }
        }
        return totalCost;
    }

    /*
    获取一次销毁_balance个NFT的费用
    _balance: 销毁NFT的数量
    */
    function getCurrentReturnToBurn(uint256 _balance) public virtual view returns (uint256) {
        uint256 curSupply = getCurrentSupply() + virtualBalance;
        uint256 curMaxIndex = curSupply - 1;
        uint256 totalReturn;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curMaxIndex; i > curMaxIndex - _balance; i--) {
                totalReturn = totalReturn.add(initBurnPrice.add(initBurnPrice.mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curMaxIndex; i > curMaxIndex - _balance; i--) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalReturn = totalReturn.add(initBurnPrice.add(initBurnPrice.mul(p).div(q)));
            }
        }
        return totalReturn;
    }

    // 获取当前存在的NFT数量
    function getCurrentSupply() public virtual view returns (uint256) {
        return thePASS.totalSupply();
    }
}