// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./math-utils/AnalyticMath.sol";

/**
* @dev thePASS Bonding Curve - minting NFT through erc20 or eth
* PASS is orgnization's erc1155 token on curve 
* erc20 or eth is collateral token on curve 
* Users can mint PASS via deposting erc20 collateral token into curve
* thePASS Bonding Curve Formula: f(X) = m*(x^N)+v
* f(x) = PASS Price when total supply of PASS is x
* m, slope of bonding curve
* x = total supply of PASS 
* N = n/d
* v = virtual balance, Displacement 
of bonding curve
*/
contract Curve is ERC1155 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Contract name
    string public name;
    // Contract symbol
    string public symbol;
    uint256 public tokenId;

    IERC20 public erc20; // collateral token on bonding curve
    uint256 public m; // slope of bonding curve
    uint256 public n; // numerator of exponent in curve power function
    uint256 public d; // denominator of exponent in curve power function
    uint256 public intPower; // when n/d is integer
    uint256 public virtualBalance; // vitual balance for setting a reasonable initial price

    mapping(uint256 => uint256) public decPowerCache; // cache of power function calculation result when exponent is decimal，n => cost
    uint256 public reserve; // reserve of collateral tokens stored in bonding curve AMM pool

    address payable public platform; // thePass platform's commission account
    uint256 public platformRate; // thePass platform's commission rate in pph

    address payable public creator; // creator's commission account
    uint256 public creatorRate; // creator's commission rate in pph

    IAnalyticMath public analyticMath =
        IAnalyticMath(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8); // Mathmatical method for calculating power function

    event Minted(
        uint256 indexed tokenId,
        uint256 indexed cost,
        uint256 indexed reserveAfterMint,
        uint256 balance,
        uint256 platformProfit
    );
    event Burned(
        uint256 indexed tokenId,
        uint256 indexed returnAmount,
        uint256 indexed reserveAfterBurn,
        uint256 balance
    );
    event BatchBurned(
        uint256[] tokenIds,
        uint256[] balances,
        uint256 indexed returnAmount,
        uint256 indexed reserveAfterBurn
    );
    event Withdraw(address indexed to, uint256 amount);

    /**
     * @dev constrcutor of bonding curve with formular: f(x)=m*(x^N)+v
     * _erc20: collateral token(erc20) for miniting PASS on bonding curve, send 0x000...000 to appoint it as eth instead of erc20 token
     * _initMintPrice: f(1) = m + v, the first PASS minting price
     * _m: m, slope of curve
     * _virtualBalance: v = f(1) - _m, virtual balance, displacement of curve
     * _n,_d: _n/_d = N, exponent of the curve
     * reserve: reserve of collateral tokens stored in bonding curve AMM pool, start with 0
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseUri,
        address _erc20,
        uint256 _initMintPrice,
        uint256 _m,
        uint256 _n,
        uint256 _d
    ) ERC1155(_baseUri) {
        name = _name;
        symbol = _symbol;

        erc20 = IERC20(_erc20);
        m = _m;
        n = _n;

        if (_n.div(_d).mul(_d) == _n) {
            intPower = _n.div(_d);
        } else {
            d = _d;
        }

        virtualBalance = _initMintPrice - _m;
        reserve = 0;
    }

    // @creator commission account and rate initilization
    function setFeeParameters(
        address payable _platform,
        uint256 _platformRate,
        address payable _creator,
        uint256 _createRate
    ) public {
        require(
            platform == address(0) && creator == address(0),
            "Curve: commission account and rate cannot be modified."
        );
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _createRate;
    }

    /**
     * @dev each PASS minting transaction by depositing collateral erc20 tokens will create a new erc1155 token id sequentially
     * _balance: number of PASSes user want to mint
     * _amount: the maximum deposited amount set by the user
     * _maxPriceFistNFT: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
     * return: token id
     */
    function mint(
        uint256 _balance,
        uint256 _amount,
        uint256 _maxPriceFirstPASS
    ) public returns (uint256) {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(
            _maxPriceFirstPASS >= firstPrice,
            "Curve: price exceeds slippage tolerance."
        );

        return _mint(_balance, _amount, false);
    }

    // for small amount of PASS minting, it will be unceessary to check the maximum price for the fist mintable PASS
    function mint(uint256 _balance, uint256 _amount) public returns (uint256) {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");

        return _mint(_balance, _amount, false);
    }

    /**
     * @dev user burn PASS/PASSes to receive corresponding collateral tokens
     * _tokenId: the token id of PASS/PASSes to burn
     * _balance: the number of PASS/PASSes to burn
     */
    function burn(uint256 _tokenId, uint256 _balance) public {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        uint256 burnReturn = getCurrentReturnToBurn(_balance);

        // checks if allowed to burn
        _burn(_msgSender(), _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        erc20.safeTransfer(_msgSender(), burnReturn);

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatch(uint256[] memory _tokenIds, uint256[] memory _balances)
        public
    {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        require(
            _tokenIds.length == _balances.length,
            "Curve: _tokenIds and _balances length mismatch."
        );
        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        // checks if allowed to burn
        _burnBatch(_msgSender(), _tokenIds, _balances);

        reserve = reserve.sub(burnReturn);
        erc20.safeTransfer(_msgSender(), burnReturn);

        emit BatchBurned(_tokenIds, _balances, burnReturn, reserve);
    }

    /**
     * @dev each PASS minting transaction by depositing ETHs will create a new erc1155 token id sequentially
     * _balance: number of PASSes user want to mint
     * _maxPriceFirstPASS: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
     * return: token ID
     */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS)
        public
        payable
        returns (uint256)
    {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(
            _maxPriceFirstPASS >= firstPrice,
            "Curve: price exceeds slippage tolerance."
        );

        return _mint(_balance, msg.value, true);
    }

    function mintEth(uint256 _balance) public payable returns (uint256) {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );

        return _mint(_balance, msg.value, true);
    }

    /**
     * @dev user burn PASS/PASSes to receive corresponding ETHs
     * _tokenId: the token id of PASS/PASSes to burn
     * _balance: the number of PASS/PASSes to burn
     */
    function burnEth(uint256 _tokenId, uint256 _balance) public {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );
        uint256 burnReturn = getCurrentReturnToBurn(_balance);

        _burn(_msgSender(), _tokenId, _balance);

        reserve = reserve.sub(burnReturn);
        payable(_msgSender()).transfer(burnReturn);

        emit Burned(_tokenId, burnReturn, reserve, _balance);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatchETH(
        uint256[] memory _tokenIds,
        uint256[] memory _balances
    ) public {
        require(address(erc20) == address(0), "Curve: erc20 address is null.");
        require(
            _tokenIds.length == _balances.length,
            "Curve: _tokenIds and _balances length mismatch"
        );
        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        _burnBatch(_msgSender(), _tokenIds, _balances);

        reserve = reserve.sub(burnReturn);
        payable(_msgSender()).transfer(burnReturn);

        emit BatchBurned(_tokenIds, _balances, burnReturn, reserve);
    }

    // internal function to mint PASS
    function _mint(
        uint256 _balance,
        uint256 _amount,
        bool bETH
    ) private returns (uint256) {
        uint256 mintCost = caculateCurrentCostToMint(_balance);
        require(_amount >= mintCost, "Curve: not enough token sent");

        uint256 platformProfit = mintCost.mul(platformRate).div(100);
        uint256 creatorProfit = mintCost.mul(creatorRate).div(100);

        tokenId += 1;
        _mint(_msgSender(), tokenId, _balance, "");

        uint256 reserveCut = mintCost.sub(platformProfit).sub(creatorProfit);
        reserve = reserve.add(reserveCut);

        if (bETH) {
            // return overcharge eth
            if (_amount.sub(mintCost) > 0) {
                payable(_msgSender()).transfer(_amount.sub(mintCost));
            }
            if (platformRate > 0) {
                platform.transfer(platformProfit);
            }
        } else {
            erc20.safeTransferFrom(_msgSender(), address(this), mintCost);
            if (platformRate > 0) {
                erc20.safeTransfer(platform, platformProfit);
            }
        }

        emit Minted(tokenId, mintCost, reserve, _balance, platformProfit);

        return tokenId; // returns tokenId in case its useful to check it
    }

    function _getEthBalance() internal view returns (uint256) {
        return address(this).balance;
    }

    function _getErc20Balance() internal view returns (uint256) {
        return IERC20(erc20).balanceOf(address(this));
    }

    /**
     * @dev internal function to calculate the cost of minting _balance PASSes in a transaction
     * _balance: number of PASS/PASSes to mint
     */
    function caculateCurrentCostToMint(uint256 _balance)
        internal
        returns (uint256)
    {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curStartX,
                    curStartX + _balance - 1
                );
                totalCost = m.mul(intervalSum).add(
                    virtualBalance.mul(_balance)
                );
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(
                        m.mul(i**intPower).add(virtualBalance)
                    );
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

    // external view function to query the current cost to mint a PASS/PASSes
    function getCurrentCostToMint(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curStartX,
                    curStartX + _balance - 1
                );
                totalCost = m.mul(intervalSum).add(
                    virtualBalance.mul(_balance)
                );
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost = totalCost.add(
                        m.mul(i**intPower).add(virtualBalance)
                    );
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

    /**
     * @dev calculate the return of burning _balance PASSes in a transaction
     * _balance: number of PASS/PASSes to be burned
     */
    function getCurrentReturnToBurn(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 curEndX = getCurrentSupply();
        _balance = _balance > curEndX ? curEndX : _balance;

        uint256 totalReturn;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curEndX - _balance + 1,
                    curEndX
                );
                totalReturn = m.mul(intervalSum).add(
                    virtualBalance.mul(_balance)
                );
            } else {
                for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                    totalReturn = totalReturn.add(
                        m.mul(i**intPower).add(virtualBalance)
                    );
                }
            }
        } else {
            for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                totalReturn = totalReturn.add(decPowerCache[i]);
            }
        }
        totalReturn = totalReturn.mul(100 - platformRate - creatorRate).div(
            100
        );
        return totalReturn;
    }

    // get current supply of PASS
    function getCurrentSupply() public view returns (uint256) {
        return tokenId;
    }

    // Bernoulli's formula for calculating the sum of intervals between the two reserves
    function caculateIntervalSum(
        uint256 _power,
        uint256 _startX,
        uint256 _endX
    ) public view returns (uint256) {
        return
            analyticMath.caculateIntPowerSum(_power, _endX).sub(
                analyticMath.caculateIntPowerSum(_power, _startX - 1)
            );
    }

    // anyone can withdraw reserve of erc20 tokens/ETH to creator's beneficiary account
    function withdraw() public {
        if (address(erc20) == address(0)) {
            creator.transfer(_getEthBalance() - reserve); // withdraw eth to beneficiary account
            emit Withdraw(creator, _getEthBalance() - reserve);
        } else {
            erc20.safeTransfer(creator, _getErc20Balance() - reserve); // withdraw erc20 tokens to beneficiary account
            emit Withdraw(creator, _getErc20Balance() - reserve);
        }
    }
}
