// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Pausable} from "./Pausable.sol";

/// @title StakeManager
/// @notice Gestiona depósitos de stake en USDC y retiros con timelock.
///         El stake es fianza y barrera anti-Sybil: acredita a un nodeit para
///         entrar en el registro. No hay castigo económico — ver ADR-004.
/// @dev    Functions that touch USDC transfers are guarded by `nonReentrant`.
///         Standard Centre USDC has no token-callback (transfer hooks), so the
///         practical reentrancy surface is small, but the guard is required
///         defense-in-depth por si una migración futura apuntara `usdc` a
///         una implementación con hooks de transferencia.
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

    // ── Errors ───────────────────────────────────────────────

    error InsufficientStake(uint256 available, uint256 requested);
    error TimelockNotExpired(uint256 unlockAt);
    error NoPendingWithdrawal();
    error TransferFailed();
    error ZeroAddress();

    // ── Constructor ──────────────────────────────────────────

    constructor(address _usdc, address _guardian) Pausable(_guardian) {
        // El error ZeroAddress estaba declarado y no se usaba: la guarda
        // faltaba. Un `usdc` a cero dejaría el contrato inservible y sin
        // forma de arreglarlo, porque es inmutable.
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
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


    // ── Views ─────────────────────────────────────────────────

    function getStakeInfo(address operator) external view returns (StakeInfo memory) {
        return _stakes[operator];
    }
}
