// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {FlashLoanVault} from "./FlashLoanVault.sol";
import {CrosschainFlashLoanToken} from "./CrosschainFlashLoanToken.sol";
import {ISuperchainTokenBridge} from "@interop-lib/interfaces/ISuperchainTokenBridge.sol";
import {IL2ToL2CrossDomainMessenger} from "@interop-lib/interfaces/IL2ToL2CrossDomainMessenger.sol";
import {CrossDomainMessageLib} from "@interop-lib/libraries/CrossDomainMessageLib.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title CrosschainFlashLoanBridge
/// @notice A contract that facilitates cross-chain flash loans using FlashLoanVault
/// @dev This contract implements production-ready security features including reentrancy protection,
/// pausable functionality, access control, rate limiting, and circuit breaker.
contract CrosschainFlashLoanBridge is ReentrancyGuard, Pausable, AccessControl {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // The token used for flash loans
    CrosschainFlashLoanToken public immutable token;
    // The vault on this chain
    FlashLoanVault public immutable vault;
    // The bridge for cross-chain transfers
    ISuperchainTokenBridge public constant bridge = ISuperchainTokenBridge(0x4200000000000000000000000000000000000028);
    // The messenger for cross-chain messages
    IL2ToL2CrossDomainMessenger public constant messenger =
        IL2ToL2CrossDomainMessenger(0x4200000000000000000000000000000000000023);
    
    // Fee configuration
    uint256 public immutable flatFee;
    uint256 public maxLoanAmount;
    uint256 public minTimeBetweenLoans;
    
    // Rate limiting
    mapping(address => uint256) public lastLoanTime;
    
    // Circuit breaker
    bool public circuitBreaker;
    
    // Events
    event CrosschainFlashLoanInitiated(
        uint256 indexed destinationChain, 
        address indexed borrower, 
        uint256 amount, 
        uint256 fee
    );
    event CrosschainFlashLoanCompleted(
        uint256 indexed sourceChain, 
        address indexed borrower, 
        uint256 amount
    );
    event CircuitBreakerSet(bool active);
    event MaxLoanAmountUpdated(uint256 newAmount);
    event MinTimeBetweenLoansUpdated(uint256 newTime);
    event FeeUpdated(uint256 newFee);

    // Errors
    error InsufficientFee();
    error TransferFailed();
    error CallFailed();
    error CircuitBreakerActive();
    error AmountExceedsMaximum();
    error RateLimitExceeded();
    error InvalidParameters();
    error UnauthorizedAccess();

    constructor(
        address _token, 
        address _vault, 
        uint256 _flatFee, 
        address _admin,
        uint256 _maxLoanAmount,
        uint256 _minTimeBetweenLoans
    ) {
        if (_token == address(0) || _vault == address(0) || _admin == address(0)) {
            revert InvalidParameters();
        }
        
        token = CrosschainFlashLoanToken(_token);
        vault = FlashLoanVault(_vault);
        flatFee = _flatFee;
        maxLoanAmount = _maxLoanAmount;
        minTimeBetweenLoans = _minTimeBetweenLoans;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    /// @notice Initiates a cross-chain flash loan
    /// @param destinationChain The chain ID where the flash loan will be executed
    /// @param amount The amount to borrow
    /// @param target The contract to call on the destination chain
    /// @param data The calldata to execute on the target contract
    function initiateCrosschainFlashLoan(
        uint256 destinationChain, 
        uint256 amount, 
        address target, 
        bytes calldata data
    ) external payable whenNotPaused nonReentrant returns (bytes32) {
        // Circuit breaker check
        if (circuitBreaker) revert CircuitBreakerActive();
        
        // Input validation
        if (amount == 0 || target == address(0)) revert InvalidParameters();
        if (amount > maxLoanAmount) revert AmountExceedsMaximum();
        
        // Rate limiting
        if (block.timestamp < lastLoanTime[msg.sender] + minTimeBetweenLoans) {
            revert RateLimitExceeded();
        }
        
        // Fee check
        if (msg.value < flatFee) revert InsufficientFee();

        // Update rate limit
        lastLoanTime[msg.sender] = block.timestamp;

        // Send tokens to destination chain
        bytes32 sendERC20MsgHash = bridge.sendERC20(address(token), address(this), amount, destinationChain);

        return messenger.sendMessage(
            destinationChain,
            address(this),
            abi.encodeWithSelector(
                this.executeCrosschainFlashLoan.selector,
                sendERC20MsgHash,
                block.chainid,
                msg.sender,
                amount,
                target,
                data
            )
        );
    }

    /// @notice Executes the flash loan on the destination chain and returns tokens
    function executeCrosschainFlashLoan(
        bytes32 sendERC20MsgHash,
        uint256 sourceChain,
        address borrower,
        uint256 amount,
        address target,
        bytes memory data
    ) external whenNotPaused nonReentrant {
        CrossDomainMessageLib.requireCrossDomainCallback();
        CrossDomainMessageLib.requireMessageSuccess(sendERC20MsgHash);

        // Input validation
        if (amount == 0 || target == address(0)) revert InvalidParameters();
        if (amount > maxLoanAmount) revert AmountExceedsMaximum();

        // give approval to the vault to transfer tokens
        token.approve(address(vault), amount);

        // Create flash loan
        bytes32 loanId = vault.createLoan(address(token), amount, address(this), 1 hours);

        // Execute flash loan
        vault.executeFlashLoan(loanId, target, data);

        // Send tokens back to this contract on source chain
        bridge.sendERC20(
            address(token),
            address(this),
            amount,
            sourceChain
        );

        emit CrosschainFlashLoanCompleted(sourceChain, borrower, amount);
    }

    // Admin functions

    /// @notice Pause the contract
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Set the circuit breaker state
    function setCircuitBreaker(bool _active) external onlyRole(EMERGENCY_ROLE) {
        circuitBreaker = _active;
        emit CircuitBreakerSet(_active);
    }

    /// @notice Update the maximum loan amount
    function setMaxLoanAmount(uint256 _amount) external onlyRole(ADMIN_ROLE) {
        if (_amount == 0) revert InvalidParameters();
        maxLoanAmount = _amount;
        emit MaxLoanAmountUpdated(_amount);
    }

    /// @notice Update the minimum time between loans
    function setMinTimeBetweenLoans(uint256 _time) external onlyRole(ADMIN_ROLE) {
        if (_time == 0) revert InvalidParameters();
        minTimeBetweenLoans = _time;
        emit MinTimeBetweenLoansUpdated(_time);
    }

    /// @notice Withdraw accumulated fees
    function withdrawFees() external onlyRole(ADMIN_ROLE) {
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }
}
