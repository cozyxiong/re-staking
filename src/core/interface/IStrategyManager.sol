// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IStrategyBase.sol";

interface IStrategyManagerRead {
    function stakerStrategyShares(address staker, IStrategyBase strategy) external view returns (uint256);
    function thirdPartyTransferForbidden(IStrategyBase strategy) external view returns (bool);
    function queryStakerStrategyShares(address staker, IStrategyBase strategy) external view returns (uint256);
    function queryStakerStrategyNumber(address staker) external view returns (uint256);
    function queryStakerShares(address staker) external view returns (IStrategyBase[] memory, uint256[] memory);
}

interface IStrategyManagerWrite {
    function addStrategies(IStrategyBase[] calldata strategies, bool[] calldata thirdPartyTransferForbiddenValue) external;
    function removeStrategies(IStrategyBase[] calldata strategies) external;
    function depositIntoStrategy(IStrategyBase strategy, IERC20 token, uint256 tokenAmount) external returns (uint256);
    function depositIntoStrategyWithSignature(IStrategyBase strategy, IERC20 token, uint256 tokenAmount, address staker, uint256 expiry, bytes memory signature) external returns (uint256);
    function addShares(address staker, IERC20 token, IStrategyBase strategy, uint256 shares) external;
    function removeShares(address staker, IStrategyBase strategy, uint256 shares) external returns (bool);
    function withdrawTokens(address recipient, IStrategyBase strategy, IERC20 token, uint256 shareAmount) external;
}

interface IStrategyManager is IStrategyManagerRead, IStrategyManagerWrite {}
