// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./utils/OwnableUpgradeable.sol";
import "./math-utils/interfaces/IAnalyticMath.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/aave/IWETHGateway.sol";
import "./interfaces/aave/IAaveIncentivesController.sol";
import "./interfaces/aave/IAaveProtocolDataProvider.sol";

/**
 * @dev thePASS Bonding Curve - minting NFT through erc20 or eth
 * PASS is orgnization's erc1155 token on curve
 * erc20 or eth is collateral token on curve
 * Users can mint PASS via deposting erc20 collateral token into curve
 * thePASS Bonding Curve Formula: f(X) = m*(x^N)+v
 * f(x) = PASS Price when total supply of PASS is x
 * m, slope of bonding curve
 * x = total supply of PASS
 * N = n/d, represented by intPower when N is integer
 * v = virtual balance, Displacement of bonding curve
 */
contract CurvePolygon is
    Initializable,
    OwnableUpgradeable,
    ERC1155BurnableUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Mathmatical method for calculating power function
    IAnalyticMath public constant ANALYTICMATH = IAnalyticMath(0xd4D19A91b0af5093E5CEEE658617AadbE1E1A999); // prettier-ignore

    ILendingPoolAddressesProvider public constant AAVE_PROVIDER = ILendingPoolAddressesProvider(0xd05e3E715d945B59290df0ae8eF85c1BdB684744); // prettier-ignore
    IWETHGateway public constant WETHGATEWAY = IWETHGateway(0xbEadf48d62aCC944a06EEaE0A9054A90E5A7dc97); // prettier-ignore
    IAaveIncentivesController public constant AAVE_CREDITS_PROVIDER = IAaveIncentivesController(0x357D51124f59836DeD84c8a1730D72B749d8BC23); // prettier-ignore

    string public name; // Contract name
    string public symbol; // Contract symbol
    string public baseUri;

    // token id counter. For erc721 contract, PASS serial number = token id
    CountersUpgradeable.Counter private tokenIdTracker;

    uint256 public totalSupply; // total supply of erc1155 tokens

    IERC20Upgradeable public erc20; // collateral token on bonding curve
    uint256 public m; // slope of bonding curve
    uint256 public n; // numerator of exponent in curve power function
    uint256 public d; // denominator of exponent in curve power function
    uint256 public intPower; // when n/d is integer
    uint256 public virtualBalance; // vitual balance for setting a reasonable initial price

    mapping(uint256 => uint256) public decPowerCache; // cache of power function calculation result when exponent is decimal，n => cost
    uint256 public reserve; // reserve of collateral tokens stored in bonding curve AMM pool

    address payable public platform; // thePass platform's commission account
    uint256 public platformRate; // thePass platform's commission rate in pph

    address payable public receivingAddress; // receivingAddress's commission account
    uint256 public creatorRate; // receivingAddress's commission rate in pph
    bool public depositAave;

    event Minted(
        uint256 indexed tokenId,
        uint256 indexed cost,
        uint256 indexed reserveAfterMint,
        uint256 balance,
        uint256 platformProfit,
        uint256 creatorProfit
    );
    event Burned(
        address indexed account,
        uint256 indexed tokenId,
        uint256 balance,
        uint256 returnAmount,
        uint256 reserveAfterBurn
    );
    event BatchBurned(
        address indexed account,
        uint256[] tokenIds,
        uint256[] balances,
        uint256 returnAmount,
        uint256 reserveAfterBurn
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
    function initialize(
        string[] memory infos, //[0]: _name,[1]: _symbol,[2]: _baseUri
        address[] memory addrs, //[0] _platform, [1]: _receivingAddress, [2]: _erc20 [3]: _timelock
        uint256[] memory parms //[0]_platformRate, [1]: _creatorRate, [2]: _initMintPrice, [3]: _m, [4]: _n, [5]: _d
    ) public virtual initializer {
        __Ownable_init(addrs[3]);
        __ERC1155_init(infos[2]);
        __ERC1155Burnable_init();

        tokenIdTracker = CountersUpgradeable.Counter({_value: 1});

        _setBasicInfo(infos[0], infos[1], infos[2], addrs[2]);
        _setFeeParameters(
            payable(addrs[0]),
            parms[0],
            payable(addrs[1]),
            parms[1]
        );
        _setCurveParms(parms[2], parms[3], parms[4], parms[5]);

        checkAaveStatus(addrs[2]) ? depositAave = true : depositAave = false;
    }

    // @receivingAddress commission account and rate initilization
    function _setFeeParameters(
        address payable _platform,
        uint256 _platformRate,
        address payable _receivingAddress,
        uint256 _createRate
    ) internal {
        require(_platform != address(0), "Curve: platform address is zero");
        require(
            _receivingAddress != address(0),
            "Curve: receivingAddress address is zero"
        );

        platform = _platform;
        platformRate = _platformRate;
        receivingAddress = _receivingAddress;
        creatorRate = _createRate;
    }

    // only contract admin can change beneficiary account
    function changeBeneficiary(address payable _newAddress) public onlyOwner {
        require(_newAddress != address(0), "Curve: new address is zero");

        receivingAddress = _newAddress;
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
    function burn(
        address _account,
        uint256 _tokenId,
        uint256 _balance
    ) public override {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");

        // checks if allowed to burn
        super._burn(_account, _tokenId, _balance);

        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        totalSupply -= _balance;
        reserve = reserve - burnReturn;

        depositAave
            ? _withdrawAave(_account, burnReturn, false)
            : erc20.safeTransfer(_account, burnReturn);

        emit Burned(_account, _tokenId, _balance, burnReturn, reserve);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatch(
        address _account,
        uint256[] memory _tokenIds,
        uint256[] memory _balances
    ) public override {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");

        // checks if allowed to burn
        super._burnBatch(_account, _tokenIds, _balances);

        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        reserve = reserve - burnReturn;
        totalSupply = totalSupply - totalBalance;

        depositAave
            ? _withdrawAave(_account, burnReturn, false)
            : erc20.safeTransfer(_account, burnReturn);

        emit BatchBurned(_account, _tokenIds, _balances, burnReturn, reserve);
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
    function burnEth(
        address _account,
        uint256 _tokenId,
        uint256 _balance
    ) public {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );
        super._burn(_account, _tokenId, _balance);

        uint256 burnReturn = getCurrentReturnToBurn(_balance);

        totalSupply -= _balance;

        reserve = reserve - burnReturn;

        depositAave
            ? _withdrawAave(_account, burnReturn, true)
            : payable(_account).transfer(burnReturn);

        emit Burned(_account, _tokenId, _balance, burnReturn, reserve);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatchETH(
        address _account,
        uint256[] memory _tokenIds,
        uint256[] memory _balances
    ) public {
        require(address(erc20) == address(0), "Curve: erc20 address is null.");
        super._burnBatch(_account, _tokenIds, _balances);

        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        reserve = reserve - burnReturn;
        totalSupply = totalSupply - totalBalance;

        depositAave
            ? _withdrawAave(_account, burnReturn, true)
            : payable(_account).transfer(burnReturn);

        emit BatchBurned(_account, _tokenIds, _balances, burnReturn, reserve);
    }

    function uri(uint256 _tokenId)
        public
        view
        override
        returns (string memory)
    {
        return string(abi.encodePacked(baseUri, toString(_tokenId)));
    }

    // get current supply of PASS
    function getCurrentSupply() public view returns (uint256) {
        return totalSupply;
    }

    function getCreatorProfits() public view returns (uint256) {
        return
            depositAave
                ? getUnderlyingAssetBalance() - reserve
                : (address(erc20) == address(0))
                ? erc20.balanceOf(address(this)) - reserve
                : address(this).balance - reserve;
    }

    // internal function to mint PASS
    function _mint(
        uint256 _balance,
        uint256 _amount,
        bool bETH
    ) private returns (uint256 tokenId) {
        uint256 mintCost = caculateCurrentCostToMint(_balance);
        require(_amount >= mintCost, "Curve: not enough token sent");

        address account = _msgSender();

        uint256 platformProfit = (mintCost * platformRate) / 100;
        uint256 creatorProfit = (mintCost * creatorRate) / 100;

        tokenId = tokenIdTracker.current(); // accumulate the token id
        tokenIdTracker.increment(); // automate token id increment

        totalSupply += _balance;
        _mint(account, tokenId, _balance, "");

        uint256 reserveCut = mintCost - platformProfit - creatorProfit;
        reserve = reserve + reserveCut;

        if (bETH) {
            // return overcharge eth
            if (_amount - (mintCost) > 0) {
                payable(account).transfer(_amount - (mintCost));
            }
            if (platformRate > 0) {
                platform.transfer(platformProfit);
            }
        } else {
            erc20.safeTransferFrom(account, address(this), mintCost);
            if (platformRate > 0) {
                erc20.safeTransfer(platform, platformProfit);
            }
        }

        if (depositAave) {
            _depositAave(mintCost - platformProfit, bETH);
        }

        emit Minted(
            tokenId,
            mintCost,
            reserve,
            _balance,
            platformProfit,
            creatorProfit
        );

        return tokenId; // returns tokenId in case its useful to check it
    }

    function getUnderlyingAssetBalance() internal view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(AAVE_PROVIDER.getLendingPool());

        if (address(erc20) == address(0)) {
            address weth = WETHGATEWAY.getWETHAddress();

            IERC20Upgradeable aWETH = IERC20Upgradeable(
                lendingPool.getReserveData(weth).aTokenAddress
            );

            return aWETH.balanceOf(address(this));
        } else {
            IERC20Upgradeable aToken = IERC20Upgradeable(
                lendingPool.getReserveData(address(erc20)).aTokenAddress
            );
            return aToken.balanceOf(address(this));
        }
    }

    function getRewardsBalance() public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(AAVE_PROVIDER.getLendingPool());

        address[] memory assets = new address[](1);

        assets[0] = lendingPool
            .getReserveData(WETHGATEWAY.getWETHAddress())
            .aTokenAddress;

        return AAVE_CREDITS_PROVIDER.getRewardsBalance(assets, address(this));
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
                totalCost = m * intervalSum + (virtualBalance * _balance);
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost =
                        totalCost +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                if (decPowerCache[i] == 0) {
                    (uint256 p, uint256 q) = ANALYTICMATH.pow(i, 1, n, d);
                    uint256 cost = virtualBalance + ((m * p) / q);
                    totalCost = totalCost + cost;
                    decPowerCache[i] = cost;
                } else {
                    totalCost = totalCost + decPowerCache[i];
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
                totalCost = m * (intervalSum) + (virtualBalance * _balance);
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost =
                        totalCost +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                (uint256 p, uint256 q) = ANALYTICMATH.pow(i, 1, n, d);
                uint256 cost = virtualBalance + ((m * p) / q);
                totalCost = totalCost + (cost);
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
                totalReturn = m * intervalSum + (virtualBalance * (_balance));
            } else {
                for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                    totalReturn =
                        totalReturn +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                totalReturn = totalReturn + decPowerCache[i];
            }
        }
        totalReturn = (totalReturn * (100 - platformRate - creatorRate)) / 100;
        return totalReturn;
    }

    // Bernoulli's formula for calculating the sum of intervals between the two reserves
    function caculateIntervalSum(
        uint256 _power,
        uint256 _startX,
        uint256 _endX
    ) public pure returns (uint256) {
        return
            ANALYTICMATH.caculateIntPowerSum(_power, _endX) -
            ANALYTICMATH.caculateIntPowerSum(_power, _startX - 1);
    }

    // anyone can withdraw reserve of erc20 tokens/ETH to receivingAddress's beneficiary account
    function withdraw() public {
        uint256 creatorBalance = getCreatorProfits();
        address to = receivingAddress;
        bool bETH = address(erc20) == address(0);

        if (depositAave) {
            // withdraw eth to beneficiary account or withdraw erc20 tokens to beneficiary account
            _withdrawAave(to, creatorBalance, bETH);
        } else {
            bETH
                ? receivingAddress.transfer(creatorBalance)
                : erc20.safeTransfer(receivingAddress, creatorBalance);
        }

        emit Withdraw(to, creatorBalance);
    }

    function _setBasicInfo(
        string memory _name,
        string memory _symbol,
        string memory _baseUri,
        address _erc20
    ) internal {
        name = _name;
        symbol = _symbol;
        baseUri = _baseUri;
        erc20 = IERC20Upgradeable(_erc20);
    }

    function _setCurveParms(
        uint256 _initMintPrice,
        uint256 _m,
        uint256 _n,
        uint256 _d
    ) internal {
        m = _m;
        n = _n;
        if ((_n / _d) * _d == _n) {
            intPower = _n / _d;
        } else {
            d = _d;
        }

        virtualBalance = _initMintPrice - _m;
        reserve = 0;
    }

    function _depositAave(uint256 _amount, bool bETH) private {
        address provider = AAVE_PROVIDER.getLendingPool();

        if (bETH) {
            // After deposit msg.sender receives the aToken
            WETHGATEWAY.depositETH{value: _amount}(provider, address(this), 0);
        } else {
            // Approve LendingPool to spend contracts funds
            if (erc20.allowance(address(this), provider) == 0) {
                erc20.approve(provider, type(uint256).max);
            }

            // Deposit on onBehalf of Curve address
            ILendingPool(provider).deposit(
                address(erc20),
                _amount,
                address(this),
                0
            );
        }
    }

    function _withdrawAave(
        address _to,
        uint256 _amount,
        bool bETH
    ) private {
        address provider = AAVE_PROVIDER.getLendingPool();
        address gatewayAddress = address(WETHGATEWAY);

        address aWETHAddress = ILendingPool(provider)
            .getReserveData(WETHGATEWAY.getWETHAddress())
            .aTokenAddress;

        if (bETH) {
            IERC20Upgradeable aWETH = IERC20Upgradeable(aWETHAddress);

            // Approve gatewayAddress to spend aWETH
            if (aWETH.allowance(address(this), gatewayAddress) == 0) {
                aWETH.approve(gatewayAddress, type(uint256).max);
            }

            // Withdrawn amount will be send to to address
            IWETHGateway(gatewayAddress).withdrawETH(provider, _amount, _to);
        } else {
            // Withdraw on onBehalf of msg.sender
            ILendingPool(provider).withdraw(address(erc20), _amount, _to);
        }

        if (_to == receivingAddress) {
            address[] memory assets = new address[](1);
            assets[0] = aWETHAddress;

            AAVE_CREDITS_PROVIDER.claimRewards(assets, type(uint256).max, _to);
        }
    }

    function checkAaveStatus(address asset) internal view returns (bool res) {
        if (asset == address(0)) {
            asset = WETHGATEWAY.getWETHAddress();
        }
        IAaveProtocolDataProvider aaveProtocolDataProvider = IAaveProtocolDataProvider(
                AAVE_PROVIDER.getAddress(
                    0x0100000000000000000000000000000000000000000000000000000000000000
                )
            );
        (, , , , , , , , bool isActive, bool isFrozen) = aaveProtocolDataProvider // prettier-ignore
            .getReserveConfigurationData(asset);

        if (isActive && !isFrozen) return true;
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
