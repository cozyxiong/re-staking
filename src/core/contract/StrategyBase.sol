// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyManager} from "../interface/IStrategyManager.sol";
import {IStrategyBase} from "../interface/IStrategyBase.sol";


interface StrategyBaseEvent {
    event StrategyBaseConfigUpdated(bytes4 setterSelector, string setterSignature, bytes value);
}

contract StrategyBase is Initializable, OwnableUpgradeable, StrategyBaseEvent, IStrategyBase {

    error NotStrategyManager();
    error NotUnderlyingToken();
    error MaxPerDepositExceeded();
    error MaxTotalDepositExceeded();
    error ZeroShares();
    error TotalShareExceeded();
    error DepositLimitsError();

    uint256 internal constant SHARES_OFFSET = 1000;
    uint256 internal constant BALANCE_OFFSET = 1000;

    uint256 public maxPerDeposit;
    uint256 public maxTotalDeposit;
    uint256 public totalShares;

    using SafeERC20 for IERC20;
    IStrategyManager public strategyManager;
    IERC20 public underlyingToken;

    struct Init {
        address owner;
        address underlyingToken;
        address strategyManager;
        uint256 maxPerDeposit;
        uint256 maxTotalDeposit;
    }

    modifier onlyStrategyManager() {
        if (msg.sender != address(strategyManager)) { revert NotStrategyManager(); }
        _;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        _transferOwnership(init.owner);

        underlyingToken = IERC20(init.underlyingToken);
        strategyManager = IStrategyManager(init.strategyManager);

        maxPerDeposit = init.maxPerDeposit;
        maxTotalDeposit = init.maxTotalDeposit;
    }

    function deposit(IERC20 token, uint256 tokenAmount) external virtual override onlyStrategyManager returns (uint256) {
        if (token != underlyingToken) { revert NotUnderlyingToken(); }
        if (tokenAmount > maxPerDeposit) { revert MaxPerDepositExceeded(); }
        if (token.balanceOf(address(this)) > maxTotalDeposit) { revert MaxTotalDepositExceeded(); }

        uint256 virtualShareAmount = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = token.balanceOf(address(this)) + BALANCE_OFFSET - tokenAmount;
        uint256 shares = (tokenAmount * virtualShareAmount) / virtualTokenBalance;
        if (shares == 0) { revert ZeroShares(); }

        totalShares += shares;

        return shares;
    }

    function withdraw(address recipient, IERC20 token, uint256 shareAmount) external virtual override onlyStrategyManager {
        if (token != underlyingToken) { revert NotUnderlyingToken(); }
        if (shareAmount > totalShares) { revert TotalShareExceeded(); }

        uint256 virtualShareAmount = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = token.balanceOf(address(this)) + BALANCE_OFFSET;
        uint256 tokens = (shareAmount * virtualTokenBalance) / virtualShareAmount;
        if (tokens != 0) {
            token.safeTransfer(recipient, tokens);
        }

        totalShares -= shareAmount;
    }

    function setDepositLimits(uint256 _maxPerDeposit, uint256 _maxTotalDeposit) external onlyStrategyManager {
        if (_maxPerDeposit >= _maxTotalDeposit) { revert DepositLimitsError(); }
        maxPerDeposit = _maxPerDeposit;
        maxTotalDeposit = _maxTotalDeposit;
        emit StrategyBaseConfigUpdated(this.setDepositLimits.selector, "setDepositLimits(uint256,uint256)", abi.encode(maxPerDeposit, maxTotalDeposit));
    }

    function querySharesByTokenAmount(uint256 tokenAmount) public view virtual returns (uint256) {
        uint256 virtualShareAmount = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = underlyingToken.balanceOf(address(this)) + BALANCE_OFFSET - tokenAmount;
        return (tokenAmount * virtualShareAmount) / virtualTokenBalance;
    }

    function queryTokensByShareAmount(uint256 shareAmount) public view virtual returns (uint256) {
        uint256 virtualShareAmount = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = underlyingToken.balanceOf(address(this)) + BALANCE_OFFSET;
        return (shareAmount * virtualTokenBalance) / virtualShareAmount;
    }

    function queryShares(address user) public view virtual returns (uint256) {
        return strategyManager.queryStakerStrategyShares(user, IStrategyBase(address(this)));
    }

    function queryTokens(address user) public view virtual returns (uint256) {
        return queryTokensByShareAmount(queryShares(user));
    }

    uint256[100] private __gap;
}















