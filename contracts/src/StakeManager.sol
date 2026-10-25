// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20 as IERC20Any} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
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
///
///         Pausa (ADR-009 §7): frena los depósitos —el riesgo nuevo— pero no
///         los retiros. El guardian no puede retener el stake de nadie.
contract StakeManager is Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20Any;

    // ── Constants ────────────────────────────────────────────

    uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;

    // ── State ─────────────────────────────────────────────────

    IERC20 public immutable usdc;

    /// @notice Único destino de lo que llega al contrato por error (ADR-009 §8).
    ///         Inmutable: nadie puede redirigirlo, y nunca recibe stake de
    ///         nadie, solo lo que sobra.
    address public immutable treasury;

    /// @notice USDC que pertenece a los nodeits: lo depositado más lo que está
    ///         saliendo. Lo que el contrato tenga por encima es lo que sobra.
    uint256 public totalHeld;

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
    /// @notice Lo que sobraba de `token` salió hacia la tesorería.
    event SurplusSwept(address indexed token, uint256 amount);

    // ── Errors ───────────────────────────────────────────────

    error InsufficientStake(uint256 available, uint256 requested);
    error TimelockNotExpired(uint256 unlockAt);
    error NoPendingWithdrawal();
    error TransferFailed();
    error ZeroAddress();
    error NothingToSweep();
    /// @notice El USDC se rescata con `sweepSurplus()`, que respeta el stake.
    error UseSweepSurplus();

    // ── Constructor ──────────────────────────────────────────

    constructor(address _usdc, address _guardian, address _treasury) Pausable(_guardian) {
        // El error ZeroAddress estaba declarado y no se usaba: la guarda
        // faltaba. Un `usdc` a cero dejaría el contrato inservible y sin
        // forma de arreglarlo, porque es inmutable.
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        treasury = _treasury;
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
        totalHeld += amount;
        bool ok = usdc.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        emit StakeDeposited(msg.sender, amount);
    }

    /// @notice Request a stake withdrawal. Initiates the 7-day timelock.
    /// @dev    Funciona en pausa (ADR-009 §7).
    function requestWithdrawal(uint256 amount) external {
        StakeInfo storage info = _stakes[msg.sender];
        if (info.staked < amount) revert InsufficientStake(info.staked, amount);
        info.staked -= amount;
        info.pendingWithdrawal += amount;
        info.unlockAt = block.timestamp + WITHDRAWAL_TIMELOCK;
        emit WithdrawalRequested(msg.sender, amount, info.unlockAt);
    }

    /// @notice Execute a withdrawal after the timelock has expired.
    /// @dev Uses block.timestamp to enforce the 7-day timelock. Miner skew
    ///      of ±15s is irrelevant against this window. Funciona en pausa
    ///      (ADR-009 §7).
    // slither-disable-next-line timestamp
    function executeWithdrawal() external nonReentrant {
        StakeInfo storage info = _stakes[msg.sender];
        if (info.pendingWithdrawal == 0) revert NoPendingWithdrawal();
        if (block.timestamp < info.unlockAt) revert TimelockNotExpired(info.unlockAt);
        uint256 amount = info.pendingWithdrawal;
        info.pendingWithdrawal = 0;
        info.unlockAt = 0;
        totalHeld -= amount;
        bool ok = usdc.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
        emit WithdrawalExecuted(msg.sender, amount);
    }

    // ── Rescate de lo que sobra (ADR-009 §8) ─────────────────

    /// @notice Envía a la tesorería el USDC que no es stake de nadie: lo que
    ///         llegó por una transferencia directa en vez de por `deposit`.
    ///         Cualquiera puede llamarlo: el destino es fijo y nunca toca
    ///         `totalHeld`.
    function sweepSurplus() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        // `<=` y no `==`: si el saldo quedara por debajo de lo debido (algo
        // que solo podría hacer el emisor del token), no hay sobrante.
        if (balance <= totalHeld) revert NothingToSweep();
        uint256 surplus = balance - totalHeld;
        bool ok = usdc.transfer(treasury, surplus);
        if (!ok) revert TransferFailed();
        emit SurplusSwept(address(usdc), surplus);
    }

    /// @notice Envía a la tesorería todo el saldo de un token que no es el
    ///         USDC del stake. `SafeERC20` porque puede ser cualquier token,
    ///         también uno que no devuelve `bool`.
    // `balance == 0` es «no hay nada que rescatar»; quien envíe más solo
    // consigue que salga hacia la tesorería.
    // slither-disable-next-line incorrect-equality
    function sweepToken(address token) external nonReentrant {
        if (token == address(usdc)) revert UseSweepSurplus();
        uint256 balance = IERC20Any(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        IERC20Any(token).safeTransfer(treasury, balance);
        emit SurplusSwept(token, balance);
    }

    // ── Views ─────────────────────────────────────────────────

    function getStakeInfo(address operator) external view returns (StakeInfo memory) {
        return _stakes[operator];
    }
}
