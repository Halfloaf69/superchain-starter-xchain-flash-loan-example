# Contracts

Smart contracts demonstrating cross-chain messaging on the Superchain using [interoperability](https://specs.optimism.io/interop/overview.html). The contracts have been enhanced with production-ready security features and risk management controls.

## Contracts

### [CrosschainFlashLoanBridge.sol](./src/CrosschainFlashLoanBridge.sol)

The main contract that coordinates cross-chain flash loan operations.

#### Key Features
- Cross-chain token bridging
- Rate limiting between loans
- Circuit breaker for emergency situations
- Fee management
- Role-based access control

#### Security Features
- Reentrancy protection
- Emergency pause functionality
- Input validation
- Rate limiting
- Circuit breaker

#### Admin Functions
```solidity
function pause() external onlyRole(ADMIN_ROLE)
function unpause() external onlyRole(ADMIN_ROLE)
function setCircuitBreaker(bool _active) external onlyRole(EMERGENCY_ROLE)
function setMaxLoanAmount(uint256 _amount) external onlyRole(ADMIN_ROLE)
function setMinTimeBetweenLoans(uint256 _time) external onlyRole(ADMIN_ROLE)
function withdrawFees() external onlyRole(ADMIN_ROLE)
```

### [FlashLoanVault.sol](./src/FlashLoanVault.sol)

Manages flash loans on each chain with enhanced security features.

#### Key Features
- Flash loan creation and execution
- Loan timeout management
- Token-specific limits
- Emergency withdrawal
- Comprehensive event logging

#### Security Features
- Reentrancy protection
- Emergency pause functionality
- Role-based access control
- Input validation
- Maximum loan limits

#### Admin Functions
```solidity
function pause() external onlyRole(ADMIN_ROLE)
function unpause() external onlyRole(ADMIN_ROLE)
function setMaxActiveLoans(address token, uint256 max) external onlyRole(ADMIN_ROLE)
function setMaxLoanAmount(address token, uint256 max) external onlyRole(ADMIN_ROLE)
function emergencyWithdraw(address token, address to) external onlyRole(EMERGENCY_ROLE)
```

### [CrosschainFlashLoanToken.sol](./src/CrosschainFlashLoanToken.sol)

The ERC20 token used for flash loans with cross-chain support.

#### Key Features
- Cross-chain compatibility
- Standard ERC20 functionality
- Integration with SuperchainTokenBridge

### [TargetContract.sol](./src/TargetContract.sol)

Example contract demonstrating how to use flash-loaned tokens.

## Security Implementation Details

### Access Control
The contracts implement a three-tier role system:
- `ADMIN_ROLE`: Full administrative access
- `OPERATOR_ROLE`: Operational access
- `EMERGENCY_ROLE`: Emergency controls

### Rate Limiting
```solidity
mapping(address => uint256) public lastLoanTime;
uint256 public minTimeBetweenLoans;

// Rate limit check
if (block.timestamp < lastLoanTime[msg.sender] + minTimeBetweenLoans) {
    revert RateLimitExceeded();
}
```

### Circuit Breaker
```solidity
bool public circuitBreaker;

// Circuit breaker check
if (circuitBreaker) revert CircuitBreakerActive();
```

### Maximum Limits
```solidity
mapping(address => uint256) public maxLoanAmounts;
mapping(address => uint256) public maxActiveLoans;
mapping(address => uint256) public totalActiveLoans;
```

## Events and Monitoring

### CrosschainFlashLoanBridge Events
```solidity
event CrosschainFlashLoanInitiated(uint256 indexed destinationChain, address indexed borrower, uint256 amount, uint256 fee);
event CrosschainFlashLoanCompleted(uint256 indexed sourceChain, address indexed borrower, uint256 amount);
event CircuitBreakerSet(bool active);
event MaxLoanAmountUpdated(uint256 newAmount);
event MinTimeBetweenLoansUpdated(uint256 newTime);
```

- Counter that can only be incremented through cross-chain messages
- Uses `L2ToL2CrossDomainMessenger` for message verification
- Tracks last incrementer's chain ID and address
- Events emitted for all increments with source chain details

### [CrossChainCounterIncrementer.sol](./src/CrossChainCounterIncrementer.sol)
- Sends cross-chain increment messages to `CrossChainCounter` instances
- Uses `L2ToL2CrossDomainMessenger` for message passing
### FlashLoanVault Events
```solidity
event LoanCreated(bytes32 indexed loanId, address indexed token, uint256 amount, address owner, address borrower, uint256 timeout);
event LoanRepaid(bytes32 indexed loanId, address indexed repayer);
event LoanClaimed(bytes32 indexed loanId, address indexed borrower);
event LoanReclaimed(bytes32 indexed loanId, address indexed reclaimer);
event MaxActiveLoansUpdated(address indexed token, uint256 newMax);
event MaxLoanAmountUpdated(address indexed token, uint256 newMax);
event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
### Custom Errors
```solidity
error InsufficientFee();
error TransferFailed();
error CallFailed();
error CircuitBreakerActive();
error AmountExceedsMaximum();
error RateLimitExceeded();
error InvalidParameters();
error UnauthorizedAccess();
error LoanNotActive();
error NotAuthorized();
error TimeoutNotElapsed();
error InsufficientBalance();
error MaxLoansExceeded();
error TokenNotSupported();
```

## Development

### Dependencies

```bash
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Deploy

Deploy to multiple chains using either:

1. Super CLI (recommended):

```bash
cd ../ && pnpm sup
```

2. Direct Forge script:

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## Architecture

### Cross-Chain Messaging Flow (1)

1. User calls `increment(chainId, counterAddress)` on `CrossChainCounterIncrementer`
2. `CrossChainCounterIncrementer` sends message via `L2ToL2CrossDomainMessenger`
3. Target chain's messenger delivers message to `CrossChainCounter`
4. `CrossChainCounter` verifies messenger and executes increment

### Cross-Chain Messaging Flow (2)

1. User calls `increment(chainId, counterAddress)` on `CrossChainCounterIncrementer` by directly ending a message through `L2ToL2CrossDomainMessenger`
2. Target chain's messenger delivers message to `CrossChainCounter`
3. `CrossChainCounter` verifies messenger and executes increment

## Testing

Tests are in `test/` directory:

- Unit tests for both contracts
- Uses Foundry's cheatcodes for chain simulation
- Integration tests for cross-chain scenarios
- Fuzzing tests for edge cases
- Invariant tests for critical properties

```bash
forge test
```

## Deployment Checklist

Before deploying to production:

1. **Security Verification**
   - Verify all security features are enabled
   - Test reentrancy protection
   - Verify access control setup
   - Test emergency procedures

2. **Parameter Configuration**
   - Set appropriate maximum loan amounts
   - Configure rate limiting parameters
   - Set up token-specific limits
   - Configure circuit breaker

3. **Monitoring Setup**
   - Configure event monitoring
   - Set up alerts for critical events
   - Monitor rate limiting
   - Track loan statistics

4. **Testing**
   - Run all unit tests
   - Execute integration tests
   - Perform fuzzing tests
   - Test emergency procedures

## Dependencies

- OpenZeppelin Contracts
  - ReentrancyGuard
  - Pausable
  - AccessControl
- Optimism Interop Libraries
  - CrossDomainMessageLib
  - ISuperchainTokenBridge
  - IL2ToL2CrossDomainMessenger

## License

MIT
