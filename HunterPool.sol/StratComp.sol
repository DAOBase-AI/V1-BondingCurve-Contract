// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

interface CERC20Interface {
    function transfer(address dst, uint amount) external returns (bool);
    function transferFrom(address src, address dst, uint amount) external returns (bool);
    function approve(address spender, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function balanceOf(address owner) external view returns (uint);  // 用户持有cToken的数量
    function balanceOfUnderlying(address owner) external returns (uint);  // 用户拥有存款代币的数量
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
    function borrowRatePerBlock() external view returns (uint);
    function supplyRatePerBlock() external view returns (uint);
    function totalBorrowsCurrent() external returns (uint);
    function borrowBalanceCurrent(address account) external returns (uint);
    function borrowBalanceStored(address account) public view returns (uint);
    function exchangeRateCurrent() public returns (uint);
    function exchangeRateStored() public view returns (uint);
    function getCash() external view returns (uint);
    function accrueInterest() public returns (uint);
    function seize(address liquidator, address borrower, uint seizeTokens) external returns (uint);

    function mint(uint mintAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    function repayBorrowBehalf(address borrower, uint repayAmount) external returns (uint);
    function liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) external returns (uint);
    function sweepToken(EIP20NonStandardInterface token) external;
}

interface ClaimCompInterface {
    function compAccrued(address holder) external returns(uint);
    function claimComp(address holder) external;
    function claimComp(address holder, CToken[] memory cTokens) external;
    function claimComp(address[] memory holders, CToken[] memory cTokens, bool borrowers, bool suppliers) external;
}


interface IUniswapRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

// AAVE-Polygon 存款交易： https://polygonscan.com/tx/0x7f4ccdd899f657aaba5b08d4efb17259741c0f4f1d1cadf6aa512cf365f0adad
// AAVE-Polygon 提取wMatic奖励交易：https://polygonscan.com/tx/0x2a9db8465f0239b2f2b315804d9e7940a8b1de91c1c7093512cfdfd1a848b838

// 抵押a1个underlying, 合约获得b1个cToken, 股份比例为s1
// 抵押a2个underlying, 合约获得b2个cToken, 股份比例为s2
// 抵押a3个underlying, 合约获得b3个cToken, 股份比例为s3
// 抵押总量a, cToken总b, 总股份s, A1用户占有的cToken数量为b * s1/s
contract StratComp is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public Comp = 0x8F67854497218043E1f72908FFE38D0Ed7F24721;
    address public ClaimCompContract = 0x6537d6307ca40231939985BCF7D83096Dd1B4C09;    // Comptroller合约地址
                                    
    address public constant MiddleSwapToken = 0xa71EdC38d189767582C38A3145b5873052c3e47a;

    address public constant UniswapRouter = 0xED7d5F38C79115ca12fe6C0041abb22F0A06C300;

    address public constant deadAddr = 0x000000000000000000000000000000000000dEaD; 

    address public cErc20Contract;   // CERC20地址
    
    address public earnedAddress = Comp;   // 挖出的代币地址，即Comp

    address public farmerContract;        
    
    address public wantToken;           

    address public govAddress; 
    bool public onlyGov = true;

    uint256 public lastEarnBlock = 0;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;


    address public BuybackAndBurnedToken;
    // 回购HNB比例
    uint256 public buyBackRate = 200;
    uint256 public constant buyBackRateMax = 10000;
    uint256 public constant buyBackRateUL = 800;

    // 销毁HNB比例
    uint256 public burnedRate = 80;
    uint256 public burnedRateMax = 100;
    uint256 public burnedRateUL = 100;
    uint256 public totalBurnedAmount;


    uint256 public exitFeeRate = 2; 
    uint256 public constant exitFeeRateMax = 10000;
    uint256 public constant exitFeeRateUL = 10; 

    // 开发者基金
    uint256 public devFundFee = 0;
    uint256 public constant devFundFeeMax = 10000; // 100 = 1%
    uint256 public constant devFundFeeUL = 1000;

    address[] public earnedToBABTokenPath;      
    address[] public lhbToWantTokenPath;      
    address public underlyingToken;     

    constructor(
        address _farmerContract,
        address _cErc20Contract,  // CERC20存款地址
        address _buybackAndBurnedToken,
        address _wantToken
    ) public {
        govAddress = msg.sender;
        farmerContract = _hnbFarmAddress;
        BuybackAndBurnedToken = _buybackAndBurnedToken;
        cErc20Contract = _cErc20Contract;
        wantToken = _wantToken;
        underlyingToken = CERC20Interface(cErc20Contract).underlying();
        earnedToBABTokenPath = [Comp, MiddleSwapToken, BuybackAndBurnedToken];
        
        if (MiddleSwapToken != wantToken) {
            lhbToWantTokenPath = [Comp, MiddleSwapToken, wantToken];
        } else {
            lhbToWantTokenPath = [Comp, wantToken];
        }
        
        transferOwnership(farmerContract);
    }

    // 从Farm合约中获取新的抵押
    function deposit(uint256 _wantAmt) public onlyOwner whenNotPaused returns (uint256) {
        IERC20(underlyingToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        // 
        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .div(wantLockedTotal);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        _farm();

        return sharesAdded;
    }

    function farm() public nonReentrant {
        _farm();
    }

    function _farm() internal {
        uint256 wantAmt = IERC20(wantToken).balanceOf(address(this));  
        wantLockedTotal = wantLockedTotal.add(wantAmt);
        IERC20(wantToken).safeIncreaseAllowance(cErc20Contract, wantAmt);

        CERC20Interface(cErc20Contract).mint(wantAmt);
    }

    // _wantAmt是实际存入的代币，不是CToken
    function withdraw(uint256 _wantAmt) public onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt <= 0");

        // 1. 从Comp中取出存款
        if (isCompound) {
            CERC20Interface(cErc20Contract).redeemUnderlying(_wantAmt);
        }

        // 2. 计算出用户占有的股份数，从总数中减去
        uint256 wantAmt = IERC20(wantToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        // 3. 将用户提取的want token转给hnb挖矿合约
        uint256 exitFee = _wantAmt.mul(exitFeeRate).div(exitFeeRateMax);
        IERC20(wantToken).safeTransfer(farmerContract, _wantAmt.sub(exitFee));
        IERC20(wantToken).safeTransfer(govAddress, exitFee);

        return sharesRemoved;
    }

    // HNB挖矿合约会调用此接口，提取回购的HNB
    function withdrawBuybackToken() public onlyOwner nonReentrant returns(uint256) {
        uint256 hnbAmount = IERC20(BuybackAndBurnedToken).balanceOf(address(this));
        IERC20(BuybackAndBurnedToken).transfer(farmerContract, hnbAmount);
        return hnbAmount;
    }

    function earn() public whenNotPaused {
        require(isCompound, "!isCompound");
        
        ClaimCompInterface(ClaimCompContract).claimComp(address(this));

        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        if (earnedAmt == 0) return;

        earnedAmt = distributeFees(earnedAmt);      // 收取挖矿奖励费，归开发者基金地址
        earnedAmt = buyBackHNB(earnedAmt);          // 用挖的矿回购HNB
        convertComp(earnedAmt);

        lastEarnBlock = block.number;
        
        _farm();
    }

    // 提取一部分挖矿奖励给治理地址，提取比例默认为0，最高不超过10%
    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0) {
            if (devFundFee > 0) {
                uint256 fee = _earnedAmt.mul(devFundFee).div(devFundFeeMax);
                IERC20(earnedAddress).safeTransfer(govAddress, fee);
                _earnedAmt = _earnedAmt.sub(fee);
            }
        }

        return _earnedAmt;
    }

    // 回购HNB到本合约
    function buyBackHNB(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate <= 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);
        uint256 burnedAmt = buyBackAmt.mul(burnedRate).div(burnedRateMax);

        IERC20(earnedAddress).safeIncreaseAllowance(
            UniswapRouter,
            buyBackAmt
        );

        uint256 preHNBAmount = IERC20(BuybackAndBurnedToken).balanceOf(deadAddr);
        IUniswapRouter(UniswapRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            burnedAmt,
            0,
            earnedToBABTokenPath,
            deadAddr,               // 回购的HNB被打入销毁地址
            now + 60
        );
        uint256 burnedHNBAmount = IERC20(BuybackAndBurnedToken).balanceOf(deadAddr).sub(preHNBAmount);
        totalBurnedAmount = totalBurnedAmount.add(burnedHNBAmount);

        IUniswapRouter(UniswapRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            buyBackAmt.sub(burnedAmt),
            0,
            earnedToBABTokenPath,
            address(this),        
            now + 60
        );

        return _earnedAmt.sub(buyBackAmt);
    }

    function convertComp(uint256 _earnedAmt) internal returns (uint256) {  
        IERC20(earnedAddress).safeIncreaseAllowance(
            UniswapRouter,
            _earnedAmt
        );

        uint256 preHNBAmount = IERC20(BuybackAndBurnedToken).balanceOf(deadAddr);
        IUniswapRouter(UniswapRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _earnedAmt,
            0,
            lhbToWantTokenPath,
            address(this),               
            now + 60
        );
        return 0;
    }

    function pause() public {
        require(msg.sender == govAddress, "Not authorised");
        _pause();
    }

    function unpause() external {
        require(msg.sender == govAddress, "Not authorised");
        _unpause();
    }

    function setExitFeeRate(uint256 _exitFeeRate) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_exitFeeRate < exitFeeRateUL, "!safe - too high");
        exitFeeRate = _exitFeeRate;
    }

    function setControllerFee(uint256 _controllerFee) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_controllerFee <= devFundFeeUL, "too high");
        devFundFee = _controllerFee;
    }

    function setBuyBackHNBRate(uint256 _buyBackHNBRate) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_buyBackHNBRate <= buyBackRateUL, "too high");
        buyBackRate = _buyBackHNBRate;
    }

    function setBurnedHNBRate(uint256 _burnedHNBRate) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_burnedHNBRate <= burnedRateUL, "too high");
        burnedRate = _burnedHNBRate;
    }

    function setGov(address _govAddress) public {
        require(msg.sender == govAddress, "!gov");
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) public {
        require(msg.sender == govAddress, "!gov");
        onlyGov = _onlyGov;
    }
}