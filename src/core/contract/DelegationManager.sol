// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP1271SignatureUtils} from "../libraries/EIP1271SignatureUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyManager} from "../interface/IStrategyManager.sol";
import "../interface/IDelegationManager.sol";

interface DelegationManagerEvent {
    event OperatorInfoUpdated(address operator, OperatorInfo operatorInfo);
    event OperatorNodeUrlUpdated(address operator, string metadataURL);
    event OperatorRegistered(address operator, OperatorInfo operatorInfo);
    event StakerDelegated(address staker, address operator);
    event OperatorSharesIncreased(address operator, address staker, IStrategyBase strategy, uint256 share);
    event ForceUndelegated(address staker, address requester);
    event StakerUndelegated(address staker);
    event OperatorSharesDecreased(address operator, address staker, IStrategyBase strategy, uint256 share);
    event WithdrawalQueued(bytes32 withdrawalRoot, WithdrawalInfo withdrawal);
    event WithdrawalCompleted(address staker, address operator, address withdrawer, IStrategyBase strategy, IERC20 token, uint256 share);
    event DelegationManagerConfigChanged(bytes4 setterSelector, string setterSignature, bytes value);
}

contract DelegationManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, DelegationManagerEvent, IDelegationManager {

    error HasRegistered();
    error ZeroEarningReceiver();
    error StakerQuitWaitingBlocksExceeded();
    error StakerQuitWaitingBlocksDecreased();
    error StakerHasDelegated();
    error OperatorNotRegistered();
    error signatureExpired();
    error ApproverSaltHasSpent();
    error ZeroAddress();
    error StakerNotDelegated();
    error OperatorCannotUndelegate();
    error UnauthorizedUndelegate();
    error EmptyStrategies();
    error withdrawerUnauthorized();
    error LengthNotMatched();
    error WithdrawerNotStaker();
    error NotPendingWithdrawal();
    error NotReachedWaitingBlocks();
    error NotWithdrawer();
    error NotStrategyManager();

    uint256 public constant MAX_STAKER_QUIT_WAITING_BLOCKS = 108000;
    uint256 public constant MAX_WITHDRAWAL_WAITING_BLOCKS = 216000;

    mapping(address => OperatorInfo) internal operatorInfos;
    mapping(address => address) public delegatedTo;
    mapping(address => mapping(IStrategyBase => uint256)) public operatorShares;
    mapping(address => mapping(bytes32 => bool)) public delegationApproverSaltIsSpent;
    mapping(address => uint256) public nonces;
    mapping(address => uint256) public stakerQueuedWithdrawalsNumber;
    mapping(bytes32 => bool) public pendingWithdrawals;
    mapping(IStrategyBase => uint256) public strategyWithdrawWaitingBlocks;
    uint256 public minWithdrawWaitingBlocks = 7 days;

    IStrategyManager public strategyManager;

    struct Init {
        address owner;
        address strategyManager;
        IStrategyBase[] strategies;
        uint256[] withdrawWaitingBlocks;
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

        strategyManager = IStrategyManager(strategyManager);

        setStrategyWithdrawWaitingBlocks(init.strategies, init.withdrawWaitingBlocks);
    }

    function registerOperator(OperatorInfo calldata operatorInfo, string calldata nodeUrl) external {
        if (operatorInfos[msg.sender].earningsReceiver != address(0)) { revert HasRegistered(); }

        _setOperatorInfo(msg.sender, operatorInfo);
        emit OperatorNodeUrlUpdated(msg.sender, nodeUrl);

        _delegate(msg.sender, msg.sender, 0, new bytes(0), bytes32(0));
        emit OperatorRegistered(msg.sender, operatorInfo);
    }

    function delegate(address operator, uint256 expiry, bytes memory signature, bytes32 approverSalt) external {
        _delegate(msg.sender, operator, expiry, signature, approverSalt);
    }

    function delegateWithSignature(address staker, address operator, uint256 stakerExpiry, bytes memory stakerSignature, uint256 approverExpiry, bytes memory approverSignature, bytes32 approverSalt) external {
        _checkStakerSignature(staker, operator, stakerExpiry, stakerSignature);
        _delegate(staker, operator, approverExpiry, approverSignature, approverSalt);
    }

    function undelegate() external returns (bytes32[] memory) {
        address staker = msg.sender;
        address operator = delegatedTo[staker];
        if (operator == address(0)) { revert StakerNotDelegated(); }

        if (operatorInfos[staker].earningsReceiver != address(0)) { revert OperatorCannotUndelegate(); }
        delegatedTo[staker] = address(0);
        emit StakerUndelegated(staker);

        (IStrategyBase[] memory strategies, uint256[] memory shares) = strategyManager.queryStakerShares(staker);
        bytes32[] memory withdrawRoots;
        if (strategies.length == 0) {
            withdrawRoots = new bytes32[](0);
        } else {
            withdrawRoots = new bytes32[](strategies.length);
            withdrawRoots = _removeSharesAndQueueWithdrawal(staker, operator, staker, strategies, shares);
        }

        return withdrawRoots;
    }

    function queueWithdrawals(QueuedWithdrawal[] memory queuedWithdraws) external returns (bytes32[] memory) {
        address withdrawer = msg.sender;

        uint256 totalLength;
        for (uint256 i = 0; i < queuedWithdraws.length; i++) {
            totalLength += queuedWithdraws[i].strategies.length;
        }

        bytes32[] memory withdrawRootsList = new bytes32[](totalLength);
        uint256 index;
        for (uint256 i = 0; i < queuedWithdraws.length; i++) {
            if (queuedWithdraws[i].strategies.length != queuedWithdraws[i].shares.length) { revert LengthNotMatched(); }
            if (queuedWithdraws[i].staker == withdrawer) { revert WithdrawerNotStaker(); }

            address operator = delegatedTo[queuedWithdraws[i].staker];
            if (operator == address(0)) { revert StakerNotDelegated(); }
            bytes32[] memory withdrawRoots = new bytes32[](queuedWithdraws[i].strategies.length);
            withdrawRoots = _removeSharesAndQueueWithdrawal(queuedWithdraws[i].staker, operator, withdrawer, queuedWithdraws[i].strategies, queuedWithdraws[i].shares);
            for (uint256 j = 0; j < withdrawRoots.length; j++) {
                withdrawRootsList[index++] == withdrawRoots[j];
            }
        }
        return withdrawRootsList;
    }

    function completeQueuedWithdrawals(WithdrawalInfo[] calldata withdrawals, IERC20 token) external nonReentrant {
        for (uint256 i = 0; i < withdrawals.length; i++) {
            bytes32 withdrawalRoot = keccak256(abi.encode(withdrawals[i]));
            if (!pendingWithdrawals[withdrawalRoot]) { revert NotPendingWithdrawal(); }
            if (withdrawals[i].startBlock + minWithdrawWaitingBlocks > block.number) { revert NotReachedWaitingBlocks(); }
            if (withdrawals[i].startBlock + strategyWithdrawWaitingBlocks[withdrawals[i].strategy] > block.number) { revert NotReachedWaitingBlocks(); }
            if (msg.sender != withdrawals[i].withdrawer) { revert NotWithdrawer(); }

            delete pendingWithdrawals[withdrawalRoot];
            strategyManager.withdrawTokens(msg.sender, withdrawals[i].strategy, token, withdrawals[i].share);
            emit WithdrawalCompleted(withdrawals[i].staker, delegatedTo[withdrawals[i].staker], msg.sender, withdrawals[i].strategy, token, withdrawals[i].share);
        }
    }

    function increaseDelegatedShares(address staker, IStrategyBase strategy, uint256 share) external onlyStrategyManager {
        if (delegatedTo[staker] != address(0)) {
            address operator = delegatedTo[staker];
            operatorShares[operator][strategy] += share;
            emit OperatorSharesIncreased(operator, staker, strategy, share);
        }
    }

    function decreaseDelegatedShares(address staker, IStrategyBase strategy, uint256 share) external onlyStrategyManager {
        if (delegatedTo[staker] != address(0)) {
            address operator = delegatedTo[staker];
            operatorShares[operator][strategy] -= share;
            emit OperatorSharesDecreased(operator, staker, strategy, share);
        }
    }

    function _setOperatorInfo(address operator, OperatorInfo memory operatorInfo) internal {
        if (operatorInfo.earningsReceiver == address(0)) { revert ZeroEarningReceiver(); }
        if (operatorInfo.stakerQuitWaitingBlocks > MAX_STAKER_QUIT_WAITING_BLOCKS) { revert StakerQuitWaitingBlocksExceeded(); }
        if (operatorInfo.stakerQuitWaitingBlocks <= operatorInfos[operator].stakerQuitWaitingBlocks) { revert StakerQuitWaitingBlocksDecreased(); }
        operatorInfos[operator] = operatorInfo;
        emit OperatorInfoUpdated(operator, operatorInfo);
    }

    function _delegate(address staker, address operator, uint256 expiry, bytes memory signature, bytes32 approverSalt) internal {
        if (delegatedTo[staker] != address(0)) { revert StakerHasDelegated(); }
        if (operatorInfos[operator].earningsReceiver == address(0)) { revert OperatorNotRegistered(); }
        if (operatorInfos[operator].delegationApprover != address(0) && operatorInfos[operator].delegationApprover != msg.sender && msg.sender != operator) {
            if (delegationApproverSaltIsSpent[operatorInfos[operator].delegationApprover][approverSalt]) { revert ApproverSaltHasSpent(); }
            delegationApproverSaltIsSpent[operatorInfos[operator].delegationApprover][approverSalt] = true;
            _checkApproverSignature(staker, operator, operatorInfos[operator].delegationApprover, approverSalt, expiry, signature);
        }
        delegatedTo[staker] = operator;
        emit StakerDelegated(staker, operator);
        (IStrategyBase[] memory strategies, uint256[] memory shares) = strategyManager.queryStakerShares(staker);
        for (uint256 i = 0; i < strategies.length; i++) {
            operatorShares[operator][strategies[i]] = shares[i];
            emit OperatorSharesIncreased(operator, staker, strategies[i], shares[i]);
        }
    }

    function _checkApproverSignature(address staker, address operator, address approver, bytes32 salt, uint256 expiry, bytes memory signature) internal view {
        if (expiry >= block.timestamp) { revert signatureExpired(); }
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Layer")),
            uint256(block.chainid),
            address(this)
        ));
        bytes32 hashStruct = keccak256(abi.encode(
            keccak256("DelegationApproval(address staker,address operator,address approver,bytes salt,uint256 expiry)"),
            staker, operator, approver, salt, expiry
        ));
        bytes32 digest = keccak256(abi.encode("\x19\x01", domainSeparator, hashStruct));

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, digest, signature);
    }

    function _checkStakerSignature(address staker, address operator, uint256 expiry, bytes memory signature) internal {
        if (expiry >= block.timestamp) { revert signatureExpired(); }
        uint256 nonce = nonces[staker];
        unchecked { nonces[msg.sender] = nonce + 1; }
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Layer")),
            uint256(block.chainid),
            address(this)
        ));
        bytes32 hashStruct = keccak256(abi.encode(
            keccak256("StakerDelegation(address staker,address operator,uint256 nonce,uint256 expiry)"),
            staker, operator, nonce, expiry
        ));
        bytes32 digest = keccak256(abi.encode("\x19\x01", domainSeparator, hashStruct));

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, digest, signature);
    }

    function _removeSharesAndQueueWithdrawal(address staker, address operator, address withdrawer, IStrategyBase[] memory strategies, uint256[] memory shares) internal returns (bytes32[] memory) {
        if (staker == address(0)) { revert ZeroAddress(); }
        if (strategies.length == 0) { revert EmptyStrategies(); }
        bytes32[] memory withdrawalRoots = new bytes32[](strategies.length);
        uint256 index;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (staker != withdrawer && strategyManager.thirdPartyTransferForbidden(strategies[i])) { revert withdrawerUnauthorized(); }
            operatorShares[operator][strategies[i]] -= shares[i];
            emit OperatorSharesDecreased(operator, staker, strategies[i], shares[i]);
            strategyManager.removeShares(staker, strategies[i], shares[i]);

            uint256 nonce = stakerQueuedWithdrawalsNumber[staker];
            stakerQueuedWithdrawalsNumber[staker]++;
            WithdrawalInfo memory withdrawal = WithdrawalInfo({
                staker: staker,
                operator: operator,
                withdrawer: withdrawer,
                strategy: strategies[i],
                share: shares[i],
                nonce: nonce,
                startBlock: block.number
            });
            bytes32 withdrawalRoot = keccak256(abi.encode(withdrawal));
            pendingWithdrawals[withdrawalRoot] = true;
            withdrawalRoots[index++] = withdrawalRoot;
            emit WithdrawalQueued(withdrawalRoot, withdrawal);
        }

        return withdrawalRoots;
    }

    function setMinWithdrawalWaitingBlocks(uint256 _minWithdrawalWaitingBlocks) public onlyOwner {
        if (_minWithdrawalWaitingBlocks > MAX_WITHDRAWAL_WAITING_BLOCKS) { revert StakerQuitWaitingBlocksExceeded();  }
        minWithdrawWaitingBlocks = _minWithdrawalWaitingBlocks;
        emit DelegationManagerConfigChanged(this.setMinWithdrawalWaitingBlocks.selector, "setMinWithdrawalWaitingBlocks(uint256)", abi.encode(minWithdrawWaitingBlocks));
    }

    function setStrategyWithdrawWaitingBlocks(IStrategyBase[] memory _strategies, uint256[] memory _strategyWithdrawWaitingBlocks) public onlyOwner {
        if (_strategies.length != _strategyWithdrawWaitingBlocks.length) { revert LengthNotMatched(); }
        for (uint256 i = 0; i < _strategies.length; i++) {
            if (_strategyWithdrawWaitingBlocks[i] > MAX_STAKER_QUIT_WAITING_BLOCKS) { revert StakerQuitWaitingBlocksExceeded(); }
            strategyWithdrawWaitingBlocks[_strategies[i]] = _strategyWithdrawWaitingBlocks[i];
            emit DelegationManagerConfigChanged(this.setStrategyWithdrawWaitingBlocks.selector, "setStrategyWithdrawWaitingBlocks(IStrategyBase[],uint256[])", abi.encode(_strategies[i], _strategyWithdrawWaitingBlocks[i]));
        }
    }

    function queryStakerShares(address staker, IStrategyBase strategy) public view returns (uint256) {
        return strategyManager.stakerStrategyShares(staker, strategy);
    }

    function queryOperatorShares(address operator, IStrategyBase[] memory strategies) public view returns (uint256[] memory) {
        uint256[] memory shares = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            shares[i] = operatorShares[operator][strategies[i]];
        }
        return shares;
    }

    function queryWithdrawWaitingBlocks(IStrategyBase strategy) public view returns (uint256) {
        return strategyWithdrawWaitingBlocks[strategy];
    }
}
















