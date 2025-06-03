// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategyBaseRead {
    function totalShares() external view returns (uint256);
    function querySharesByTokenAmount(uint256 tokenAmount) external view returns (uint256);
    function queryTokensByShareAmount(uint256 shareAmount) external view returns (uint256);
    function queryShares(address user) external view returns (uint256);
    function queryTokens(address user) external view returns (uint256);
}

interface IStrategyBaseWrite {
    function deposit(IERC20 token, uint256 tokenAmount) external returns (uint256);
    function withdraw(address recipient, IERC20 token, uint256 shareAmount) external;
    function setDepositLimits(uint256 _maxPerDeposit, uint256 _maxTotalDeposit) external;
}

interface IStrategyBase is IStrategyBaseRead, IStrategyBaseWrite {}
