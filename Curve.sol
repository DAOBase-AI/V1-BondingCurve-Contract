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
    
    address payable public platformCreator;   // 平台费收取账号
    uint256 public platformRate;              // 平台费收取比例
    
    address payable public bussinessCreator;  // B端手续费收取账号
    uint256 public bussinessRate;             // B端手续费收取比例

    ERC1155Ex public neolastics;                // ERC1155Ex合约
    
    IAnalyticMath public analyticMath = IAnalyticMath(0x6eC7dE12F63fe9D234B169aca4958D3ad1aA1872);  // 数学方法，可计算幂函数

    event Minted(uint256 indexed tokenId, uint256 indexed pricePaid, uint256 indexed reserveAfterMint, uint256 balance);
    event Burned(uint256 indexed tokenId, uint256 indexed priceReceived, uint256 indexed reserveAfterBurn, uint256 balance);

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
    constructor (address payable _platformCreator, uint256 _platformRate, 
                 address payable _bussinessCreator, uint256 _bussinessRate,
                 uint256 _virtualBalance, address _erc20, uint256 _initMintPrice,
                 uint256 _n, uint256 _d) {
        platformCreator = _platformCreator;
        platformRate = _platformRate;
        bussinessCreator = _bussinessCreator;
        bussinessRate = _bussinessRate;
        
        erc20 = IERC20(_erc20);
        initMintPrice = _initMintPrice;
        initBurnPrice = initMintPrice.mul(100 - _platformRate - _bussinessRate).div(100);
        
        n = _n;
        d = _d;
        bIntPower = _n.div(_d).mul(_d) == _n;
        virtualBalance = _virtualBalance;
        
        reserve = 0;
        neolastics = new ERC1155Ex(); 
    }

    /*
    通过ERC20铸造ERC1155，每次铸造都会生成一个独立ID的ERC1155
    _balance: 铸造数量
    _amount: 用户设定的最大可转让金额，当实际所需金额小于此值时，合约只会转实际的金额
    _maxPriceFistNFT：本次铸造的第一个NFT的最大允许金额，防止front-running
    返回值: token ID
    */
    function mint(uint256 _balance, uint256 _amount, uint256 _maxPriceFistNFT) public returns (uint256) {  
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 firstPrice = getCurrentPriceToMint(1);
        require(_maxPriceFistNFT >= firstPrice, "C: price is too high.");

        uint256 mintPrice = getCurrentPriceToMint(_balance);
        require(_amount >= mintPrice, "C: Not enough token sent");
        erc20.transferFrom(msg.sender, address(this), mintPrice);

        uint256 tokenId = neolastics.mint(msg.sender, _balance);

        uint256 platformProfit = mintPrice.mul(platformRate).div(100);
        uint256 bussinessProfit = mintPrice.mul(bussinessRate).div(100);
        erc20.transfer(platformCreator, platformProfit); 
        erc20.transfer(bussinessCreator, bussinessProfit); 
        
        uint256 reserveCut = mintPrice.sub(platformProfit).sub(bussinessProfit);
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintPrice, reserve, _balance);

        return tokenId; // returns tokenId in case its useful to check it
    }

    /*
    用户销毁ERC1155, 获得相应的ERC20
    _tokenId: 待销毁的ERC1155的ID
    _balance: 销毁数量
    */
    function burn(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) != address(0), "C: erc20 is null.");
        uint256 burnPrice = getCurrentPriceToBurn(_balance);
        
        // checks if allowed to burn
        neolastics.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnPrice);
        erc20.transfer(msg.sender, burnPrice); 

        emit Burned(_tokenId, burnPrice, reserve, _balance);
    }
    
    /*
    通过ETH铸造ERC1155，每次铸造都会生成一个独立ID的ERC1155
    _balance: 铸造数量
    _maxPriceFistNFT：本次铸造的第一个NFT的最大允许金额，防止front-running
    返回值: token ID
    */
    function mintEth(uint256 _balance, uint256 _maxPriceFistNFT) payable public returns (uint256) {    
        require(address(erc20) == address(0), "C: erc20 is NOT null.");    
        uint256 firstPrice = getCurrentPriceToMint(1);
        require(_maxPriceFistNFT >= firstPrice, "C: price is too high.");

        uint256 mintPrice = getCurrentPriceToMint(_balance);
        require(msg.value >= mintPrice, "C: Not enough token sent");
        if (msg.value.sub(mintPrice) > 0)
            payable(msg.sender).transfer(msg.value.sub(mintPrice));

        uint256 tokenId = neolastics.mint(msg.sender, _balance);

        uint256 platformProfit = mintPrice.mul(platformRate).div(100);
        uint256 bussinessProfit = mintPrice.mul(bussinessRate).div(100);
        platformCreator.transfer(platformProfit); 
        bussinessCreator.transfer(bussinessProfit); 
        
        uint256 reserveCut = mintPrice.sub(platformProfit).sub(bussinessProfit);
        reserve = reserve.add(reserveCut);

        emit Minted(tokenId, mintPrice, reserve, _balance);

        return tokenId; // returns tokenId in case its useful to check it
    }

    /*
    用户销毁ERC1155，获得相应的ETH
    _tokenId: 待销毁的ERC1155的ID
    _balance: 销毁数量
    */
    function burnEth(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) == address(0), "C: erc20 is NOT null.");
        uint256 burnPrice = getCurrentPriceToBurn(_balance);
        
        neolastics.burn(msg.sender, _tokenId, _balance);

        reserve = reserve.sub(burnPrice);
        payable(msg.sender).transfer(burnPrice); 

        emit Burned(_tokenId, burnPrice, reserve, _balance);
    }

    /*
    获取一次铸造_balance个NFT的费用
    _balance: 铸造NFT的数量
    */
    function getCurrentPriceToMint(uint256 _balance) public view returns (uint256) {
        uint256 curSupply = getCurrentSupply() + virtualBalance;
        uint256 totalMintPrice;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curSupply; i < curSupply + _balance; i++) {
                totalMintPrice = totalMintPrice.add(initMintPrice.add(initMintPrice.mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curSupply; i < curSupply + _balance; i++) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalMintPrice = totalMintPrice.add(initMintPrice.add(initMintPrice.mul(p).div(q)));
            }
        }
        return totalMintPrice;
    }

    /*
    获取一次销毁_balance个NFT的费用
    _balance: 销毁NFT的数量
    */
    function getCurrentPriceToBurn(uint256 _balance) public virtual view returns (uint256) {
        uint256 curSupply = getCurrentSupply() + virtualBalance;
        uint256 curMaxIndex = curSupply - 1;
        uint256 totalBurnPrice;
        if (bIntPower) {
            uint256 powerValue = n.div(d);
            for (uint256 i = curMaxIndex; i > curMaxIndex - _balance; i--) {
                totalBurnPrice = totalBurnPrice.add(initBurnPrice.add(initBurnPrice.mul(i**powerValue)));
            }
        } else {
            for (uint256 i = curMaxIndex; i > curMaxIndex - _balance; i--) {
                (uint256 p, uint256 q) = analyticMath.pow(i, 1, n, d);
                totalBurnPrice = totalBurnPrice.add(initBurnPrice.add(initBurnPrice.mul(p).div(q)));
            }
        }
        return totalBurnPrice;
    }

    // 获取当前存在的NFT数量
    function getCurrentSupply() public virtual view returns (uint256) {
        return neolastics.totalSupply();
    }
}