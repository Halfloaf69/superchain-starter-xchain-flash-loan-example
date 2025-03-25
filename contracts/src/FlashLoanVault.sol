// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title FlashLoanVault
/// @notice A vault that provides flash loans where borrowing and repayment must occur in the same block,
/// or the funds can be reclaimed after a timeout
/// @dev This contract implements production-ready security features including reentrancy protection,
/// pausable functionality, and access control.
contract FlashLoanVault is ReentrancyGuard, Pausable, AccessControl {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    struct Loan {
        address token;
        uint256 amount;
        address owner;
        address borrower;
        uint256 timeout;
        bool isActive;
        uint256 createdAt;
    }

    // Loan ID => Loan details
    mapping(bytes32 => Loan) public loans;
    
    // Token => Total active loans
    mapping(address => uint256) public totalActiveLoans;
    
    // Token => Maximum active loans
    mapping(address => uint256) public maxActiveLoans;
    
    // Token => Maximum loan amount
    mapping(address => uint256) public maxLoanAmounts;

    // Events
    event LoanCreated(
        bytes32 indexed loanId, 
        address indexed token, 
        uint256 amount, 
        address owner, 
        address borrower, 
        uint256 timeout
    );
    event LoanRepaid(bytes32 indexed loanId, address indexed repayer);
    event LoanClaimed(bytes32 indexed loanId, address indexed borrower);
    event LoanReclaimed(bytes32 indexed loanId, address indexed reclaimer);
    event MaxActiveLoansUpdated(address indexed token, uint256 newMax);
    event MaxLoanAmountUpdated(address indexed token, uint256 newMax);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // Errors
    error LoanNotActive();
    error NotAuthorized();
    error TransferFailed();
    error CallFailed();
    error TimeoutNotElapsed();
    error InsufficientBalance();
    error MaxLoansExceeded();
    error AmountExceedsMaximum();
    error InvalidParameters();
    error TokenNotSupported();

    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidParameters();
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    /// @notice Create a new flash loan
    /// @param token The token to be loaned
    /// @param amount The amount to be loaned
    /// @param borrower The address that can claim the loan
    /// @param timeout The duration after which the loan can be reclaimed
    /// @return loanId The unique identifier for this loan
    function createLoan(
        address token, 
        uint256 amount, 
        address borrower, 
        uint256 timeout
    ) external whenNotPaused nonReentrant returns (bytes32 loanId) {
        // Input validation
        if (token == address(0) || borrower == address(0)) revert InvalidParameters();
        if (amount == 0) revert InvalidParameters();
        if (maxLoanAmounts[token] > 0 && amount > maxLoanAmounts[token]) {
            revert AmountExceedsMaximum();
        }
        if (maxActiveLoans[token] > 0 && totalActiveLoans[token] >= maxActiveLoans[token]) {
            revert MaxLoansExceeded();
        }

        // Check balance
        if (IERC20(token).balanceOf(msg.sender) < amount) revert InsufficientBalance();

        // Transfer tokens to this contract
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        // Generate loan ID
        loanId = keccak256(abi.encodePacked(
            token, 
            amount, 
            msg.sender, 
            borrower, 
            timeout, 
            block.timestamp,
            block.number
        ));

        // Store loan details
        loans[loanId] = Loan({
            token: token,
            amount: amount,
            owner: msg.sender,
            borrower: borrower,
            timeout: block.timestamp + timeout,
            isActive: true,
            createdAt: block.timestamp
        });

        // Update active loans count
        totalActiveLoans[token]++;

        emit LoanCreated(loanId, token, amount, msg.sender, borrower, timeout);
    }

    /// @notice Execute a flash loan with an arbitrary call
    /// @param loanId The ID of the loan to execute
    /// @param target The contract to call with the borrowed funds
    /// @param data The calldata to execute on the target contract
    function executeFlashLoan(
        bytes32 loanId, 
        address target, 
        bytes calldata data
    ) external whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        if (!loan.isActive) revert LoanNotActive();
        if (msg.sender != loan.borrower) revert NotAuthorized();
        if (block.timestamp > loan.timeout) revert TimeoutNotElapsed();
        if (target == address(0)) revert InvalidParameters();

        // Transfer tokens to target
        bool success = IERC20(loan.token).transfer(target, loan.amount);
        if (!success) revert TransferFailed();

        emit LoanClaimed(loanId, loan.borrower);

        // Make the arbitrary call
        (success,) = target.call(data);
        if (!success) revert CallFailed();

        // Check that loan was repaid
        uint256 balance = IERC20(loan.token).balanceOf(address(this));
        if (balance < loan.amount) revert TransferFailed();

        // Transfer tokens back to owner
        success = IERC20(loan.token).transfer(loan.owner, loan.amount);
        if (!success) revert TransferFailed();

        loan.isActive = false;
        totalActiveLoans[loan.token]--;
        emit LoanRepaid(loanId, msg.sender);
    }

    /// @notice Reclaim tokens after timeout has elapsed
    /// @param loanId The ID of the loan to reclaim
    function reclaimExpiredLoan(bytes32 loanId) external whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        if (!loan.isActive) revert LoanNotActive();
        if (block.timestamp <= loan.timeout) revert TimeoutNotElapsed();
        if (msg.sender != loan.owner) revert NotAuthorized();

        // Transfer all tokens back to owner
        uint256 balance = IERC20(loan.token).balanceOf(address(this));
        bool success = IERC20(loan.token).transfer(loan.owner, balance);
        if (!success) revert TransferFailed();

        loan.isActive = false;
        totalActiveLoans[loan.token]--;
        emit LoanReclaimed(loanId, msg.sender);
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

    /// @notice Set maximum active loans for a token
    function setMaxActiveLoans(address token, uint256 max) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidParameters();
        maxActiveLoans[token] = max;
        emit MaxActiveLoansUpdated(token, max);
    }

    /// @notice Set maximum loan amount for a token
    function setMaxLoanAmount(address token, uint256 max) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidParameters();
        maxLoanAmounts[token] = max;
        emit MaxLoanAmountUpdated(token, max);
    }

    /// @notice Emergency withdraw tokens
    function emergencyWithdraw(address token, address to) external onlyRole(EMERGENCY_ROLE) {
        if (token == address(0) || to == address(0)) revert InvalidParameters();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        bool success = IERC20(token).transfer(to, balance);
        if (!success) revert TransferFailed();
        
        emit EmergencyWithdraw(token, to, balance);
    }
}
