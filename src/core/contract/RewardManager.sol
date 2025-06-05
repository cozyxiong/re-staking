// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyBase} from "../interface/IStrategyBase.sol";
import {IStrategyManagerRead} from "../interface/IStrategyManager.sol";
import {IDelegationManagerRead} from "../interface/IDelegationManager.sol";

interface RewardManagerEvent {
    event Reward(address strategy, address operator, uint256 stakeReward, uint256 operatorFee);
    event OperatorClaimReward(address operator, uint256 claimAmount);
    event StakerClaimReward(address operator, uint256 claimAmount);
}

contract RewardManager is Initializable, OwnableUpgradeable, RewardManagerEvent {

    error NotPayFeeManager();
    error NotRewardManager();
    error ZeroShares();
    error ZeroReward();
    error RewardBalanceNotEnough();

    address public rewardManager;
    uint256 public stakeRewardPercent;
    mapping(address => mapping(address => uint256)) public strategyStakeRewards;
    mapping(address => uint256) public operatorRewards;

    using SafeERC20 for IERC20;
    IERC20 public rewardToken;
    IDelegationManagerRead public delegationManager;

    struct Init {
        address owner;
        address rewardManager;
        address rewardToken;
        address delegationManager;
        uint256 stakeRewardPercent;
    }

    modifier onlyRewardManager() {
        if (msg.sender != address(rewardManager)) { revert NotRewardManager(); }
        _;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        _transferOwnership(init.owner);

        rewardManager= init.rewardManager;

        rewardToken = IERC20(init.rewardToken);
        delegationManager = IDelegationManagerRead(init.delegationManager);

        stakeRewardPercent = init.stakeRewardPercent;
    }

    function reward(address strategy, address operator, uint256 baseReward) external onlyRewardManager {
        uint256 totalShares = IStrategyBase(strategy).totalShares();
        uint256 operatorShares = delegationManager.operatorShares(operator, IStrategyBase(strategy));
        if (totalShares <= 0 || operatorShares <= 0) { revert ZeroShares(); }

        uint256 totalReward = baseReward * operatorShares / totalShares;
        uint256 stakeReward = totalReward * stakeRewardPercent;
        uint256 operatorReward = totalReward - stakeReward;
        strategyStakeRewards[strategy][operator] = stakeReward;
        operatorRewards[operator] = operatorReward;

        emit Reward(strategy, operator, stakeReward, operatorReward);
    }

    function operatorClaimReward() external returns (bool) {
        uint256 operatorReward = operatorRewards[msg.sender];
        if (operatorReward == 0) { revert ZeroReward(); }
        if (operatorReward > rewardToken.balanceOf(address(this)) ) { revert RewardBalanceNotEnough(); }

        operatorRewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, operatorReward);
        emit OperatorClaimReward(msg.sender, operatorReward);

        return true;
    }

    function stakerClaimReward(address strategy) external returns (bool) {
        address operator = delegationManager.delegatedTo(msg.sender);
        uint256 stakerShares = delegationManager.queryStakerShares(msg.sender, IStrategyBase(strategy));
        uint256 operatorShares = delegationManager.operatorShares(operator, IStrategyBase(strategy));
        if (stakerShares <= 0 || operatorShares <= 0) { revert ZeroShares(); }

        uint256 stakerReward = strategyStakeRewards[strategy][operator] * stakerShares / operatorShares;
        if (stakerReward == 0) { revert ZeroReward(); }
        if (stakerReward > rewardToken.balanceOf(address(this)) ) { revert RewardBalanceNotEnough(); }

        strategyStakeRewards[strategy][operator] -= stakerReward;
        rewardToken.safeTransfer(msg.sender, stakerReward);
        emit StakerClaimReward(msg.sender, stakerReward);

        return true;
    }

    function setStakeRewardPercent(uint256 _stakeRewardPercent) external onlyRewardManager {
        stakeRewardPercent = _stakeRewardPercent;
    }
}
