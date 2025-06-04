// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IStrategyBase.sol";

struct QueuedWithdrawal {
    address staker;
    IStrategyBase[] strategies;
    uint256[] shares;
}

struct WithdrawalInfo {
    address staker;
    address operator;
    address withdrawer;
    IStrategyBase strategy;
    uint256 share;
    uint256 nonce;
    uint256 startBlock;
}

struct OperatorInfo {
    address earningsReceiver;
    address delegationApprover;
    uint256 stakerQuitWaitingBlocks;
}

interface IDelegationManagerRead {
    function operatorShares(address operator, IStrategyBase strategy) external view returns (uint256);
    function delegatedTo(address staker) external view returns (address);
    function queryStakerShares(address staker, IStrategyBase strategy) external view returns (uint256);
    function queryOperatorShares(address operator, IStrategyBase[] memory strategies) external view returns (uint256[] memory);
    function queryWithdrawWaitingBlocks(IStrategyBase strategy) external view returns (uint256);
}

interface IDelegationManagerWrite {
    function registerOperator(OperatorInfo calldata operatorInfo, string calldata nodeUrl) external;
    function delegate(address operator, uint256 expiry, bytes memory signature, bytes32 approverSalt) external;
    function delegateWithSignature(address staker, address operator, uint256 stakerExpiry, bytes memory stakerSignature, uint256 approverExpiry, bytes memory approverSignature, bytes32 approverSalt) external;
    function undelegate() external returns (bytes32[] memory);
    function queueWithdrawals(QueuedWithdrawal[] memory queuedWithdraws) external returns (bytes32[] memory);
    function completeQueuedWithdrawals(WithdrawalInfo[] calldata withdrawals, IERC20 token) external;
    function increaseDelegatedShares(address staker, IStrategyBase strategy, uint256 share) external;
    function decreaseDelegatedShares(address staker, IStrategyBase strategy, uint256 share) external;
}

interface IDelegationManager is IDelegationManagerRead, IDelegationManagerWrite {}
