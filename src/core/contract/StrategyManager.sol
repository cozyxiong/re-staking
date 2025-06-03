// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyBase} from "../interface/IStrategyBase.sol";
import {EIP1271SignatureUtils} from "../libraries/EIP1271SignatureUtils.sol";
import {IDelegationManager} from "../interface/IDelegationManager.sol";
import {IStrategyManager} from "../interface/IStrategyManager.sol";

interface StrategyManagerEvent {
    event StrategyAdded(IStrategyBase strategy, bool thirdPartyTransferForbidden);
    event StrategyRemoved(IStrategyBase strategy);
    event Deposit(address statker, IERC20 token, IStrategyBase strategy, uint256 shares);
}

contract StrategyManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, StrategyManagerEvent, IStrategyManager {

    error InvalidLength();
    error ZeroShares();
    error ThirdPartyTransferForbidden();
    error signatureExpired();
    error NotDelegationManager();
    error ZeroStaker();
    error SharesExceeded();
    error InvalidStrategy();
    error NotStrategyWhitelistManager();

    using SafeERC20 for IERC20;

    mapping(IStrategyBase => bool) public strategyWhitelist;
    mapping(address => mapping(IStrategyBase => uint256)) public stakerStrategyShares;
    mapping(address => IStrategyBase[]) public stakerStrategyList;
    mapping(IStrategyBase => bool) public thirdPartyTransferForbidden;
    mapping(address => uint256) public nonces;
    address public strategyWhitelistManager;
    mapping(bytes32 => bool) public withdrawalRootPending;

    IDelegationManager public delegation;

    struct Init {
        address owner;
        address strategyWhitelistManager;
        address delegation;
    }

    modifier onlyDelegationManager() {
        if (msg.sender != address(delegation)) { revert NotDelegationManager(); }
        _;
    }

    modifier onlyStrategyWhitelistManager() {
        if (msg.sender != strategyWhitelistManager) { revert NotStrategyWhitelistManager(); }
        _;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        _transferOwnership(init.owner);

        strategyWhitelistManager = init.strategyWhitelistManager;

        delegation = IDelegationManager(init.delegation);
    }

    function addStrategies(IStrategyBase[] calldata strategies, bool[] calldata thirdPartyTransferForbiddenValue) external onlyStrategyWhitelistManager {
        if (strategies.length != thirdPartyTransferForbiddenValue.length) { revert InvalidLength(); }
        for (uint256 i = 0; i < strategies.length; i++) {
            strategyWhitelist[strategies[i]] = true;
            thirdPartyTransferForbidden[strategies[i]] = thirdPartyTransferForbiddenValue[i];
            emit StrategyAdded(strategies[i], thirdPartyTransferForbiddenValue[i]);
        }
    }

    function removeStrategies(IStrategyBase[] calldata strategies) external onlyStrategyWhitelistManager {
        for (uint256 i = 0; i < strategies.length; i++) {
            strategyWhitelist[strategies[i]] = false;
            thirdPartyTransferForbidden[strategies[i]] = false;
            emit StrategyRemoved(strategies[i]);
        }
    }

    function depositIntoStrategy(IStrategyBase strategy, IERC20 token, uint256 tokenAmount) public nonReentrant returns (uint256) {
        if (!strategyWhitelist[strategy]) { revert InvalidStrategy(); }

        token.safeTransferFrom(msg.sender, address(strategy), tokenAmount);

        uint256 shares = strategy.deposit(token, tokenAmount);
        if (shares == 0) { revert ZeroShares(); }
        if (stakerStrategyShares[msg.sender][strategy] == 0) {
            stakerStrategyList[msg.sender].push(strategy);
        }
        stakerStrategyShares[msg.sender][strategy] += shares;
        delegation.increaseDelegatedShares(msg.sender, strategy, shares);
        emit Deposit(msg.sender, token, strategy, shares);

        return shares;
    }

    function depositIntoStrategyWithSignature(IStrategyBase strategy, IERC20 token, uint256 tokenAmount, address staker, uint256 expiry, bytes memory signature) external nonReentrant returns (uint256) {
        if (!strategyWhitelist[strategy]) { revert InvalidStrategy(); }
        if (thirdPartyTransferForbidden[strategy]) { revert ThirdPartyTransferForbidden(); }

        _checkSignature(staker, strategy, token, tokenAmount, expiry, signature);

        uint256 shares = depositIntoStrategy(strategy, token, tokenAmount);

        return shares;
    }

    function addShares(address staker, IERC20 token, IStrategyBase strategy, uint256 shares) external onlyDelegationManager {
        if (staker == address(0)) { revert ZeroStaker(); }
        if (shares == 0) { revert ZeroShares(); }
        if (stakerStrategyShares[staker][strategy] == 0) {
            stakerStrategyList[staker].push(strategy);
        }
        stakerStrategyShares[staker][strategy] += shares;
        emit Deposit(staker, token, strategy, shares);
    }

    function removeShares(address staker, IStrategyBase strategy, uint256 shares) external onlyDelegationManager returns (bool) {
        if (staker == address(0)) { revert ZeroStaker(); }
        if (shares == 0) { revert ZeroShares(); }
        if (shares > stakerStrategyShares[staker][strategy]) { revert SharesExceeded(); }
        unchecked { stakerStrategyShares[staker][strategy] -= shares; }
        if (stakerStrategyShares[staker][strategy] == 0) {
            for (uint256 i = 0; i < stakerStrategyList[staker].length; i++) {
                if (stakerStrategyList[staker][i] == strategy) {
                    stakerStrategyList[staker][i] = stakerStrategyList[staker][stakerStrategyList[staker].length - 1];
                    stakerStrategyList[staker].pop();
                    break;
                }
                if (i == stakerStrategyList[staker].length - 1) { revert InvalidStrategy(); }
            }
            return true;
        }
        return false;
    }

    function withdrawTokens(address recipient, IStrategyBase strategy, IERC20 token, uint256 shareAmount) external onlyDelegationManager {
        strategy.withdraw(recipient, token, shareAmount);
    }

    function _checkSignature(address staker, IStrategyBase strategy, IERC20 token, uint256 tokenAmount, uint256 expiry, bytes memory signature) internal {
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
            keccak256("Deposit(address staker,address strategy,address token,uint256 tokenAmount,uint256 nonce,uint256 expiry"),
            staker, strategy, token, tokenAmount, nonce, expiry
        ));
        bytes32 digest = keccak256(abi.encode("\x19\x01", domainSeparator, hashStruct));

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, digest, signature);
    }

    function queryStakerStrategyShares(address staker, IStrategyBase strategy) external view returns (uint256) {
        return stakerStrategyShares[staker][strategy];
    }

    function queryStakerStrategyNumber(address staker) external view returns (uint256) {
        return stakerStrategyList[staker].length;
    }

    function queryStakerShares(address staker) external view returns (IStrategyBase[] memory, uint256[] memory) {
        uint256[] memory shares = new uint256[](stakerStrategyList[staker].length);
        for (uint256 i = 0; i < stakerStrategyList[staker].length; i++) {
            shares[i] = stakerStrategyShares[staker][stakerStrategyList[staker][i]];
        }
        return (stakerStrategyList[staker], shares);
    }
}
















