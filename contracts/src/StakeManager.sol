// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Pausable} from "./Pausable.sol";

/// @title StakeManager
/// @notice Manages USDC stake deposits, withdrawals (with timelock), and slashing.
/// @dev    Functions that touch USDC transfers are guarded by `nonReentrant`.
///         Standard Centre USDC has no token-callback (transfer hooks), so the
///         practical reentrancy surface is small, but the guard is required
///         defense-in-depth for the cases where (a) the treasury becomes a
///         contract that does callbacks on receipt, or (b) a future migration
///         points `usdc` at a token implementation with hooks.
///
///         StakeManager intentionally does NOT have a `depositFor(operator,...)`
///         function — every stake deposit comes from `msg.sender` (no
///         arbitrary-from parameter). NodeRegistry registers operators by
///         verifying their already-deposited stake via `getStakeInfo()`,
///         not by proxying USDC transfers.
contract StakeManager is Pausable, ReentrancyGuard {
    // ── Constants ────────────────────────────────────────────

    uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;

    // ── State ─────────────────────────────────────────────────

    IERC20 public immutable usdc;
    /// @notice Recipient of slashed stake. Immutable — set at construction.
    address public immutable treasury;
    address public disputeResolver;
    bool private _initialized;

    struct StakeInfo {
        uint256 staked;
        uint256 pendingWithdrawal;
        uint256 unlockAt;
    }

    mapping(address => StakeInfo) private _stakes;

    // ── Events ───────────────────────────────────────────────

    event StakeDeposited(address indexed operator, uint256 amount);
    event WithdrawalRequested(address indexed operator, uint256 amount, uint256 unlockAt);
    event WithdrawalExecuted(address indexed operator, uint256 amount);
    event Slashed(address indexed operator, uint256 amount, bytes32 disputeId);
    event Initialized(address indexed disputeResolver);

    // ── Errors ───────────────────────────────────────────────

    error OnlyDisputeResolver();
    error InsufficientStake(uint256 available, uint256 requested);
    error TimelockNotExpired(uint256 unlockAt);
    error NoPendingWithdrawal();
    error TransferFailed();
    error AlreadyInitialized();
    error ZeroTreasury();
    error ZeroAddress();

    // ── Constructor ──────────────────────────────────────────

    constructor(address _usdc, address _guardian, address _treasury) Pausable(_guardian) {
        if (_treasury == address(0)) revert ZeroTreasury();
        usdc = IERC20(_usdc);
        treasury = _treasury;
    }

    /// @notice Wire up the DisputeResolver address after deployment.
    ///         Resolves the circular dependency: StakeManager.slash() must
    ///         only be callable by DisputeResolver, but DisputeResolver also
    ///         needs StakeManager's address. Can only be called once by the
    ///         guardian.
    function initialize(address resolver) external onlyGuardian {
        if (_initialized) revert AlreadyInitialized();
        if (resolver == address(0)) revert ZeroAddress();
        _initialized = true;
        disputeResolver = resolver;
        emit Initialized(resolver);
    }

    // ── External ─────────────────────────────────────────────

    /// @notice Operator deposits USDC into stake. Caller must have approved
    ///         `amount` of USDC to this contract before calling.
    /// @dev    Effects-before-interactions: bookkeeping is updated BEFORE the
    ///         transferFrom. If transfer fails, the whole tx reverts and the
    ///         bookkeeping is rolled back. Robust against any future
    ///         hook-enabled token. `msg.sender` is the staker — there is no
    ///         arbitrary-from parameter, so this fn cannot be used to drain
    ///         someone else's USDC allowance.
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        _stakes[msg.sender].staked += amount;
        bool ok = usdc.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        emit StakeDeposited(msg.sender, amount);
    }

    /// @notice Request a stake withdrawal. Initiates the 7-day timelock.
    function requestWithdrawal(uint256 amount) external whenNotPaused {
        StakeInfo storage info = _stakes[msg.sender];
        if (info.staked < amount) revert InsufficientStake(info.staked, amount);
        info.staked -= amount;
        info.pendingWithdrawal += amount;
        info.unlockAt = block.timestamp + WITHDRAWAL_TIMELOCK;
        emit WithdrawalRequested(msg.sender, amount, info.unlockAt);
    }

    /// @notice Execute a withdrawal after the timelock has expired.
    /// @dev Uses block.timestamp to enforce the 7-day timelock. Miner skew
    ///      of ±15s is irrelevant against this window.
    // slither-disable-next-line timestamp
    function executeWithdrawal() external whenNotPaused nonReentrant {
        StakeInfo storage info = _stakes[msg.sender];
        if (info.pendingWithdrawal == 0) revert NoPendingWithdrawal();
        if (block.timestamp < info.unlockAt) revert TimelockNotExpired(info.unlockAt);
        uint256 amount = info.pendingWithdrawal;
        info.pendingWithdrawal = 0;
        info.unlockAt = 0;
        bool ok = usdc.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
        emit WithdrawalExecuted(msg.sender, amount);
    }

    /// @notice Slash a node's stake. Only callable by DisputeResolver.
    ///         Reduces the operator's accounting (staked + pendingWithdrawal)
    ///         and transfers the slashed USDC to the treasury — previously
    ///         only the accounting was reduced and the funds were stuck in
    ///         this contract with no recovery path.
    function slash(address operator, uint256 amount, bytes32 disputeId) external nonReentrant {
        if (msg.sender != disputeResolver) revert OnlyDisputeResolver();
        StakeInfo storage info = _stakes[operator];
        uint256 slashable = info.staked + info.pendingWithdrawal;
        uint256 slashAmount = amount > slashable ? slashable : amount;
        if (slashAmount == 0) {
            // Nothing to slash — emit for observability and exit cleanly.
            emit Slashed(operator, 0, disputeId);
            return;
        }
        if (slashAmount <= info.staked) {
            info.staked -= slashAmount;
        } else {
            uint256 remainder = slashAmount - info.staked;
            info.staked = 0;
            info.pendingWithdrawal -= remainder;
        }
        // Move slashed funds out of this contract into the treasury.
        bool ok = usdc.transfer(treasury, slashAmount);
        if (!ok) revert TransferFailed();
        emit Slashed(operator, slashAmount, disputeId);
    }

    // ── Views ─────────────────────────────────────────────────

    function getStakeInfo(address operator) external view returns (StakeInfo memory) {
        return _stakes[operator];
    }
}
