// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20 as IERC20Any} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";
import {Pausable} from "./Pausable.sol";

/// @title  SettlementHub
/// @notice Trustless on-chain settlement for OpenRelay payments. Receives
///         payer's USDC and, in the same transaction:
///          98.50% → merchant, transferred at once
///           1.05% → operator (the routing node that registered the intent),
///                   credited — claimed later with `claim()`
///           0.45% → treasury, credited — claimed with `claimFor(treasury)`
/// @dev    See ADR-001 + ADR-002 for the full design rationale, and ADR-009
///         for why the fees are credited instead of pushed: if USDC blocks
///         the operator or the treasury, payments keep settling and their
///         fees wait in the hub until they can be claimed. Before, one
///         blocked party made every payment revert.
///         ADR-002 recalibrated the fee from 50 bps (80/20) to 100 bps
///         (70/30) for sustainable operator + treasury economics.
///         ADR-005 later raised the total to 150 bps, keeping the 70/30
///         split untouched.
///
///         Trust model: replaces the prior "operator-side daemon forwards
///         funds" pattern with on-chain enforcement. Operator can no longer
///         steal payments by withholding forwarding — the contract pays the
///         merchant and credits the fees in the payment transaction itself.
///
///         Pause semantics: `pause()` blocks intent registration. The
///         payment functions are not paused, so an intent that is already
///         registered can still be paid. But the nodeit registers each intent
///         right before settling it, so while paused the payments whose
///         intents were not registered yet wait — and expire if the pause
///         outlasts their authorization. Claims and sweeps keep working:
///         the pause never holds anyone's money.
contract SettlementHub is Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20Any;

    // ── Constants ────────────────────────────────────────────

    /// @notice Total protocol fee in basis points (1 bp = 0.01%).
    ///         150 bps = 1.5% of the payment amount.
    /// @dev    ADR-005: raised from 100 bps, riding the redeploy that ADR-004
    ///         already forced. The constant lives in non-upgradeable bytecode,
    ///         so changing it at any other time would cost a redeploy and a
    ///         re-audit of its own.
    uint16 public constant PROTOCOL_FEE_BPS = 150;

    /// @notice Treasury's share of the payment in basis points.
    ///         45 bps = 0.45% of the amount (= 30% of the protocol fee).
    /// @dev    ADR-005: the 70/30 split is unchanged, so the treasury share
    ///         scales with the fee and the relative incentive to run an
    ///         operator node stays the same.
    uint16 public constant TREASURY_SHARE_BPS = 45;

    /// @notice Implicit operator share = PROTOCOL_FEE_BPS - TREASURY_SHARE_BPS.
    ///         105 bps = 1.05% of the amount (= 70% of the protocol fee).
    uint16 public constant OPERATOR_SHARE_BPS = PROTOCOL_FEE_BPS - TREASURY_SHARE_BPS;

    /// @notice Denominator for basis-point math.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum offset (from now) for `expiresAt`. Caps the lifetime
    ///         of any single intent to bound storage permanence — a misuse
    ///         like `expiresAt = type(uint64).max` would otherwise create a
    ///         row that `cancelExpired` can never clean up. 30 days covers
    ///         the realistic e-commerce window; longer-running intents must
    ///         be re-registered.
    uint64 public constant MAX_EXPIRY_OFFSET = 30 days;

    /// @notice Maximum number of authorizations that can be settled in a
    ///         single `payIntentBatchWithAuthorization` call. Bounded by
    ///         Base block gas limit (30M); single auth ~150K gas, so the
    ///         theoretical max is ~200. We pick 50 with 4x safety margin
    ///         (~7.5M gas) to leave room for gas fluctuations and to keep
    ///         per-batch worst-case cost predictable. See ADR-003 §2.2.1.
    uint256 public constant MAX_BATCH_SIZE = 50;

    // ── State ─────────────────────────────────────────────────

    IERC20 public immutable usdc;
    address public immutable treasury;

    /// @notice Única dirección cuya firma autoriza a registrar un intent.
    ///
    ///         INMUTABLE a propósito: el guardian no puede cambiar quién
    ///         autoriza registros.
    ///
    ///         Puede ser una cartera normal o un **contrato ERC-1271**; la
    ///         verificación usa `SignatureChecker`, que acepta ambas. En
    ///         producción es un `IntentSignerGate` (ADR-009 §4): la API firma
    ///         con una clave caliente, y solo un admin frío puede cambiarla,
    ///         sin redesplegar el hub. Y como el `intentId` lleva dentro al
    ///         comercio (`intentIdOf`), ni quien controle este firmante puede
    ///         atar a otro comercio un pago que el pagador ya firmó.
    address public immutable intentSigner;

    /// @notice Comisiones acreditadas y aún no reclamadas, por cuenta: la de
    ///         cada operador y la de la tesorería (ADR-009 §1).
    mapping(address => uint256) public accrued;

    /// @notice Suma de `accrued`. El hub nunca tiene menos USDC que esto; lo
    ///         que tenga por encima llegó por error y sale con `sweepSurplus`.
    uint256 public totalAccrued;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Estructura que firma `intentSigner` para autorizar un registro.
    bytes32 public constant REGISTER_INTENT_TYPEHASH =
        keccak256("RegisterIntent(bytes32 intentId,address merchant,address operator,uint256 amount,uint64 expiresAt)");

    enum IntentStatus {
        Registered, // 0 — intent declared, awaiting payment
        Settled, // 1 — paid: merchant paid, fees credited
        Cancelled // 2 — registered, never paid, expired and pruned
    }

    /// @dev Storage layout packs into 2 slots (vs. 4 with naive ordering):
    ///        slot 0: merchant (20) + amount (12)  — 32 bytes
    ///        slot 1: operator (20) + expiresAt (8) + status (1) — 29 bytes
    ///      `amount` is `uint96` (max ≈ 7.9 × 10²⁸). USDC has 6 decimals
    ///      ⇒ max representable = ~79 sextillion USDC, well beyond any
    ///      realistic supply (~50B circulating). Saves one cold SLOAD/SSTORE
    ///      per intent operation (~10k gas registerIntent, ~5k payIntent).
    struct Intent {
        address merchant;
        uint96 amount;
        address operator;
        uint64 expiresAt;
        IntentStatus status;
    }

    /// @notice intentId → Intent. Keys are `intentIdOf(merchant, ref)`, where
    ///         `ref` identifies the payment off-chain (e.g. keccak256 of the
    ///         API's `pi_xxx` string).
    mapping(bytes32 => Intent) private _intents;

    /// @notice ERC-3009 authorization parameters wrapped as a struct so the
    ///         batch function can take a single calldata array (cleaner SDK
    ///         ergonomics + avoids "stack too deep" with 8 parallel arrays).
    /// @notice Un registro de intent autorizado por `intentSigner`.
    ///         Se agrupa en un struct en vez de arreglos paralelos: elimina la
    ///         clase de fallo de longitudes descuadradas y evita agotar la pila.
    ///
    ///         No lleva el `intentId`: lo calcula el hub con
    ///         `intentIdOf(merchant, ref)` (ADR-009 §3). La firma de
    ///         `intentSigner` cubre ese `intentId` calculado.
    struct IntentRegistration {
        bytes32 ref;
        address merchant;
        address operator;
        uint256 amount;
        uint64 expiresAt;
        bytes signature;
    }

    struct Authorization {
        bytes32 intentId;
        address payer;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        /// EOA ECDSA (65-byte) OR ERC-1271 contract-wallet signature. USDC's
        /// `SignatureChecker` (FiatTokenV2_2) validates both, so EOAs and smart
        /// wallets (e.g. Coinbase Smart Wallet) share this single path.
        bytes signature;
    }

    // ── Events ───────────────────────────────────────────────

    event IntentRegistered(
        bytes32 indexed intentId, address indexed merchant, address indexed operator, uint256 amount, uint64 expiresAt
    );

    event IntentSettled(
        bytes32 indexed intentId,
        address indexed payer,
        uint256 merchantAmount,
        uint256 operatorFee,
        uint256 treasuryFee
    );

    event IntentCancelled(bytes32 indexed intentId);

    /// @notice Un registro de `registerIntentBatch` no pasó y se saltó; el
    ///         resto del lote siguió. `reason` es el error con que revirtió.
    event IntentRegistrationSkipped(bytes32 indexed intentId, bytes reason);

    /// @notice `account` cobró las comisiones que tenía acreditadas.
    event FeesClaimed(address indexed account, uint256 amount);

    /// @notice Lo que sobraba de `token` se acreditó (USDC) o se envió (otro
    ///         token) a la tesorería.
    event SurplusSwept(address indexed token, uint256 amount);

    /// @notice Emitted once at construction. Indexers and auditors use this
    ///         to verify the protocol's economic constants without reading
    ///         the bytecode.
    event ProtocolDeployed(
        address indexed usdc, address indexed treasury, uint16 protocolFeeBps, uint16 treasuryShareBps
    );

    // ── Errors ───────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error AlreadyRegistered();
    /// @notice La autorización ERC-3009 no está atada al intent que se paga.
    error AuthorizationNotBoundToIntent();
    /// @notice El registro del intent no viene firmado por `intentSigner`.
    error InvalidIntentSignature();
    error IntentNotFound();
    error IntentNotPayable();
    error IntentExpired();
    error IntentNotExpired();
    error TransferFailed();
    error InvalidExpiry();
    error BatchTooLarge();
    error Forbidden();
    error NothingToClaim();
    error NothingToSweep();
    /// @notice El USDC se rescata con `sweepSurplus()`, que respeta lo acreditado.
    error UseSweepSurplus();

    // ── Constructor ──────────────────────────────────────────

    constructor(address _usdc, address _treasury, address _guardian, address _intentSigner) Pausable(_guardian) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_intentSigner == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        treasury = _treasury;
        intentSigner = _intentSigner;
        emit ProtocolDeployed(_usdc, _treasury, PROTOCOL_FEE_BPS, TREASURY_SHARE_BPS);
    }

    /// @notice Separador de dominio EIP-712. Se calcula en cada llamada en
    ///         lugar de cachearse: así una bifurcación de la cadena invalida
    ///         automáticamente las firmas de la cadena original.
    // Mayúsculas a propósito: es el nombre que fija EIP-712 y el que usa el
    // propio USDC. Renombrarlo para contentar al linter rompería la convención
    // que cualquier integrador espera encontrar.
    // slither-disable-next-line naming-convention
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH, keccak256("CoatiPay SettlementHub"), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    /// @dev Verifica que `intentSigner` autorizó ESTE registro concreto.
    ///      Sin esto, quien envía la transacción —el nodeit, la parte no
    ///      confiable— elegía la dirección del comercio y podía ponerse a sí
    ///      mismo, quedándose el pago aunque la autorización del pagador
    ///      estuviera correctamente atada a su intent.
    function _requireSignedRegistration(bytes32 intentId, IntentRegistration calldata reg) internal view {
        bytes32 structHash = keccak256(
            abi.encode(REGISTER_INTENT_TYPEHASH, intentId, reg.merchant, reg.operator, reg.amount, reg.expiresAt)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        // SignatureChecker acepta tanto una cartera normal (ECDSA) como un
        // contrato que implemente ERC-1271 — `IntentSignerGate`, en
        // producción. Importa porque `intentSigner` es inmutable: con una sola
        // clave, perderla o que se filtre obliga a redesplegar. Apuntando a un
        // contrato, la dirección sigue siendo inmutable pero **la clave que
        // firma se puede rotar por dentro**. Es el mismo mecanismo que usa
        // USDC para las smart wallets.
        if (!SignatureChecker.isValidSignatureNow(intentSigner, digest, reg.signature)) {
            revert InvalidIntentSignature();
        }
    }

    // ── Intent registration ──────────────────────────────────

    /// @notice El `intentId` de un cobro: el comercio y la referencia del
    ///         cobro fuera de la cadena, juntos (ADR-009 §3).
    ///
    ///         El pagador firma su autorización ERC-3009 con
    ///         `nonce == intentId`, así que su firma fija también el comercio:
    ///         registrar ese mismo `intentId` con otro comercio es imposible,
    ///         porque daría otro `intentId`.
    function intentIdOf(address merchant, bytes32 ref) public pure returns (bytes32) {
        return keccak256(abi.encode(merchant, ref));
    }

    /// @notice Register an intent that a payer can later fulfill. Requires a
    ///         registration signed by `intentSigner`; the `operator` it names
    ///         is the only party that earns the operator fee on settlement.
    /// @dev    Reverts if the intent already exists (a second call cannot
    ///         overwrite).
    /// @dev    Blocked when paused (see the contract-level pause semantics).
    function registerIntent(IntentRegistration calldata reg)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 intentId)
    {
        intentId = intentIdOf(reg.merchant, reg.ref);
        _requireSignedRegistration(intentId, reg);
        _registerIntent(intentId, reg.merchant, reg.operator, reg.amount, reg.expiresAt);
    }

    /// @notice Register multiple intents in one transaction. Designed for
    ///         x402 micropayments where per-intent gas would otherwise
    ///         dominate the operator's 1.05% fee. Returns count of successful
    ///         registrations.
    ///
    ///         Skip-on-failure, like the payment batch (ADR-009 §2):
    ///          - an intent that is already registered is skipped silently —
    ///            it is the normal case of a retried batch;
    ///          - a registration that would revert (bad signature, expiry out
    ///            of range, zero amount…) is skipped with
    ///            `IntentRegistrationSkipped`, and the rest of the batch is
    ///            registered. Before, one invalid registration reverted the
    ///            whole batch and every payment in it.
    /// @dev    Each registration runs in a self-call wrapped in try/catch —
    ///         the same pattern, and the same layered defenses, as
    ///         `payIntentBatchWithAuthorization` (see there).
    function registerIntentBatch(IntentRegistration[] calldata regs)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 registered)
    {
        uint256 len = regs.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i; i < len;) {
            bytes32 intentId = intentIdOf(regs[i].merchant, regs[i].ref);
            if (_intents[intentId].merchant == address(0)) {
                // slither-disable-next-line calls-loop
                try this.registerOneSelfCall(regs[i]) {
                    unchecked {
                        ++registered;
                    }
                } catch (bytes memory reason) {
                    emit IntentRegistrationSkipped(intentId, reason);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Self-call entry point used by `registerIntentBatch` to enable
    ///         per-element try/catch.
    /// @dev    Guarded by `msg.sender == address(this)` — equivalent to
    ///         internal at the access-control level. La firma se exige por
    ///         elemento: el lote no puede ser un atajo para registrar sin
    ///         autorización.
    function registerOneSelfCall(IntentRegistration calldata reg) external {
        if (msg.sender != address(this)) revert Forbidden();
        bytes32 intentId = intentIdOf(reg.merchant, reg.ref);
        _requireSignedRegistration(intentId, reg);
        _registerIntent(intentId, reg.merchant, reg.operator, reg.amount, reg.expiresAt);
    }

    function _registerIntent(bytes32 intentId, address merchant, address operator, uint256 amount, uint64 expiresAt)
        internal
    {
        if (merchant == address(0) || operator == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Cap amount at uint96 max to fit the packed storage layout.
        if (amount > type(uint96).max) revert AmountTooLarge();
        // slither-disable-next-line timestamp
        if (expiresAt <= block.timestamp) revert InvalidExpiry();
        // Bound storage permanence: cap intent lifetime to MAX_EXPIRY_OFFSET.
        // slither-disable-next-line timestamp
        if (expiresAt > block.timestamp + MAX_EXPIRY_OFFSET) revert InvalidExpiry();
        if (_intents[intentId].merchant != address(0)) revert AlreadyRegistered();

        _intents[intentId] = Intent({
            merchant: merchant,
            amount: uint96(amount),
            operator: operator,
            expiresAt: expiresAt,
            status: IntentStatus.Registered
        });

        emit IntentRegistered(intentId, merchant, operator, amount, expiresAt);
    }

    // ── Payment ──────────────────────────────────────────────

    /// @notice Pay a registered intent in 2 transactions: caller must have
    ///         already approved this contract for `intent.amount` USDC.
    ///         Pays the merchant, credits the fees and marks the intent Settled.
    /// @dev    Pause semantics (Q5): NOT blocked when paused. Allows payers
    ///         in flight to complete even if guardian halts new commitments.
    function payIntent(bytes32 intentId) external nonReentrant {
        _payAndSettle(intentId, msg.sender);
    }

    /// @notice Pay a registered intent in 1 transaction using EIP-2612
    ///         permit. USDC v2.2 on Base supports permit; this is the
    ///         preferred UX (no separate approve tx).
    /// @dev    The permit signature authorizes this contract to pull
    ///         `intent.amount` USDC from `msg.sender`.
    /// @dev Slither flags `reentrancy-no-eth` because we make 2 external calls
    ///      (permit + settle) and update state between them. False positive:
    ///      `nonReentrant` makes physical re-entry impossible, and `getIntent`
    ///      (the only reader) is `view` — cannot exploit any intermediate
    ///      state. The CEI-strict ordering inside `_payAndSettle` writes
    ///      status BEFORE its own external transfers, which is the actual
    ///      protection that matters.
    // slither-disable-next-line reentrancy-no-eth
    function payIntentWithPermit(bytes32 intentId, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        // Read only the fields we need for the permit (saves SLOAD vs full
        // struct load to memory).
        address merchant_ = _intents[intentId].merchant;
        if (merchant_ == address(0)) revert IntentNotFound();
        uint256 amount_ = _intents[intentId].amount;

        // Permit front-running protection: a mempool observer could extract
        // (deadline, v, r, s), submit the permit directly to USDC ahead of
        // this tx, consume the nonce, and griefing-revert this call.
        // Standard mitigation (used by 1inch, Yearn, Uniswap helpers): wrap
        // permit in try/catch and proceed regardless. If the front-runner
        // beat us, the allowance is already set and `_payAndSettle` succeeds.
        // If the permit truly was bad, `_payAndSettle` reverts on
        // `transferFrom` with TransferFailed — same outcome as without permit.
        // slither-disable-next-line unused-return
        try IERC20Permit(address(usdc)).permit(msg.sender, address(this), amount_, deadline, v, r, s) {} catch {}

        _payAndSettle(intentId, msg.sender);
    }

    /// @notice Pay a registered intent gaslessly for the payer using ERC-3009.
    ///         The payer signs an EIP-712 `ReceiveWithAuthorization` message
    ///         off-chain (FREE — no gas). Anyone (typically the nodeit operator)
    ///         submits this tx and pays the gas in ETH. USDC pulls `intent.amount`
    ///         from the payer to this contract; the merchant is paid at once and the
    ///         fees are credited.
    /// @dev    Uses `receiveWithAuthorization` (NOT `transferWithAuthorization`)
    ///         because USDC enforces `msg.sender == to` for the receive variant —
    ///         this prevents the on-chain front-running attack where an observer
    ///         could redirect funds or burn the nonce. See ADR-003 §2.1.1.
    /// @dev    The `payer` parameter is informational/wrapping — the actual
    ///         enforcement is in USDC's signature verification: if `payer`
    ///         doesn't match the signer of the authorization, USDC reverts.
    ///         No need for an extra ecrecover here.
    /// @dev    `auth.signature` is a raw `bytes` blob, settled via USDC's
    ///         `SignatureChecker` (FiatTokenV2_2). Works for EOA ECDSA
    ///         signatures AND ERC-1271 smart-contract wallets (Coinbase Smart
    ///         Wallet, Safe, …) with one code path.
    /// @dev    Pause semantics: NOT blocked when paused (consistent with
    ///         `payIntent` / `payIntentWithPermit`).
    function payIntentWithAuthorization(Authorization calldata auth) external nonReentrant {
        _payAndSettleViaAuth(auth);
    }

    /// @notice Batched gasless settlement (ERC-3009). Designed for x402
    ///         micropayments where per-intent gas would otherwise dominate
    ///         the operator's 1.05% fee. Skip-on-failure semantics: any
    ///         single bad authorization is silently skipped; the rest proceed.
    ///         Returns count of successful settlements.
    /// @dev    Implementation uses `try this.payOneAuthorizedSelfCall(...)`
    ///         to wrap each authorization in a self-call so individual
    ///         reverts (bad sig, expired, nonce reused, etc.) don't poison
    ///         the entire batch.
    ///
    ///         Slither flags `calls-in-loop` (informational) on the
    ///         `try this....` line — true positive that we mitigate
    ///         intentionally by design. Three layered defenses:
    ///           1. `MAX_BATCH_SIZE = 50` caps total gas at ~7.5M, well
    ///              within Base's 30M block limit (4x safety margin).
    ///              Cannot OOG.
    ///           2. `try/catch` per element handles per-authorization
    ///              reverts gracefully (the batch design requires this).
    ///           3. Self-call (msg.sender == address(this) guard on
    ///              `payOneAuthorizedSelfCall`) ensures no untrusted
    ///              external code is invoked — the call routes back to
    ///              our own contract.
    ///
    ///         This is the canonical pattern for skip-on-failure batch
    ///         processing in Solidity — used by OpenZeppelin Governor's
    ///         `_castVoteBatch`, Multicall, Compound's batch helpers, etc.
    ///         The disable annotation at the call site exists because the
    ///         pattern cannot be expressed without external self-call,
    ///         not because we're hiding a real risk.
    /// @dev    `nonReentrant` at the batch level blocks nested re-entry;
    ///         the inner `payOneAuthorizedSelfCall` therefore must NOT
    ///         carry its own `nonReentrant` (OZ guard would auto-revert).
    function payIntentBatchWithAuthorization(Authorization[] calldata auths)
        external
        nonReentrant
        returns (uint256 settled)
    {
        uint256 len = auths.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < len;) {
            // slither-disable-next-line calls-loop
            try this.payOneAuthorizedSelfCall(auths[i]) {
                unchecked {
                    ++settled;
                }
            } catch {
                // skip-on-failure (matches registerIntentBatch semantics)
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Self-call entry point used by `payIntentBatchWithAuthorization`
    ///         to enable per-element try/catch (Solidity only allows
    ///         try/catch on external calls).
    /// @dev    Guarded by `msg.sender == address(this)` — equivalent to
    ///         internal at the access-control level. The "SelfCall" suffix
    ///         in the name communicates this intent without the leading
    ///         underscore (which slither flagged as naming-convention
    ///         violation for an external function).
    function payOneAuthorizedSelfCall(Authorization calldata auth) external {
        if (msg.sender != address(this)) revert Forbidden();
        _payAndSettleViaAuth(auth);
    }

    /// @notice Internal settlement logic shared by the approve and permit
    ///         payment paths. CEI ordering: validate (Checks), mark the intent
    ///         settled and credit the fees (Effects), then pull from the payer
    ///         and pay the merchant (Interactions).
    function _payAndSettle(bytes32 intentId, address payer) internal {
        Intent storage intent = _intents[intentId];
        // Cache to memory to avoid 4+ SLOADs in this function body.
        Intent memory snap = intent;
        if (snap.merchant == address(0)) revert IntentNotFound();
        if (snap.status != IntentStatus.Registered) revert IntentNotPayable();
        // slither-disable-next-line timestamp
        if (block.timestamp >= snap.expiresAt) revert IntentExpired();

        // Effects: mark as settled and credit the fees BEFORE any external call.
        intent.status = IntentStatus.Settled;
        uint256 amount = snap.amount;
        (uint256 merchantAmount, uint256 operatorFee, uint256 treasuryFee) = _credit(snap.operator, amount);

        // Interactions: pull from payer, then pay the merchant.
        bool ok = usdc.transferFrom(payer, address(this), amount);
        if (!ok) revert TransferFailed();
        ok = usdc.transfer(snap.merchant, merchantAmount);
        if (!ok) revert TransferFailed();

        // slither-disable-next-line reentrancy-events
        emit IntentSettled(intentId, payer, merchantAmount, operatorFee, treasuryFee);
    }

    /// @dev Acredita las comisiones de un pago y devuelve el reparto. Solo
    ///      escribe en el almacenamiento del hub: ninguna transferencia que
    ///      pueda fallar por culpa del operador o de la tesorería (ADR-009 §1).
    function _credit(address operatorAddr, uint256 amount)
        internal
        returns (uint256 merchantAmount, uint256 operatorFee, uint256 treasuryFee)
    {
        (merchantAmount, operatorFee, treasuryFee) = _split(amount);
        accrued[operatorAddr] += operatorFee;
        accrued[treasury] += treasuryFee;
        totalAccrued += operatorFee + treasuryFee;
    }

    function _split(uint256 amount)
        internal
        pure
        returns (uint256 merchantAmount, uint256 operatorFee, uint256 treasuryFee)
    {
        treasuryFee = (amount * TREASURY_SHARE_BPS) / BPS_DENOMINATOR;
        operatorFee = (amount * OPERATOR_SHARE_BPS) / BPS_DENOMINATOR;
        merchantAmount = amount - treasuryFee - operatorFee;
    }

    /// @notice ERC-3009 settlement variant. Same Effects-Interactions
    ///         ordering as `_payAndSettle`, but pulls USDC via
    ///         `receiveWithAuthorization` instead of `transferFrom`.
    /// @dev    USDC's receiveWithAuthorization enforces `msg.sender == to`
    ///         (= this contract), so on-chain front-running is impossible:
    ///         no other actor can submit the payer's signed authorization
    ///         to redirect funds or burn the nonce. See ADR-003 §2.1.1.
    /// @dev Slither flags `reentrancy-no-eth` because we make 2 external
    ///      calls (receiveWithAuthorization + the merchant transfer) and
    ///      update state between them. False positive: `nonReentrant` at the
    ///      caller blocks physical re-entry, status is set BEFORE the
    ///      external calls (CEI), and `getIntent` (the only reader) is
    ///      `view`. Same justification as `_payAndSettle`.
    // slither-disable-next-line reentrancy-no-eth
    function _payAndSettleViaAuth(Authorization calldata auth) internal {
        // La firma ERC-3009 cubre `from`, `to`, `value`, `validAfter`,
        // `validBefore` y `nonce` — no el intent. Y como USDC exige
        // `msg.sender == to`, el `to` firmado es siempre este contrato y no
        // puede nombrar al comercio. Sin esta atadura, quien envía la
        // transacción —el nodeit, la parte NO confiable— podía aplicar la
        // firma del pagador a un intent propio y quedarse el pago.
        //
        // Exigir `nonce == intentId` encierra cada firma en un intent
        // concreto: `registerIntent` rechaza identificadores repetidos, así
        // que ese intent ya tiene dueño y no se puede suplantar. El nonce de
        // USDC es un bytes32 arbitrario que se consume una sola vez, de modo
        // que reutilizarlo en otro intent es imposible por partida doble.
        if (auth.nonce != auth.intentId) revert AuthorizationNotBoundToIntent();

        address merchantAddr;
        uint256 amount;
        uint256 merchantAmount;
        uint256 operatorFee;
        uint256 treasuryFee;

        // Block scope drops `intent`/`snap` from stack after Effects so the
        // receiveWithAuthorization call below has stack room (Solidity stack
        // limit = 16 slots; without scoping this function blows past).
        {
            Intent storage intent = _intents[auth.intentId];
            Intent memory snap = intent;
            if (snap.merchant == address(0)) revert IntentNotFound();
            if (snap.status != IntentStatus.Registered) revert IntentNotPayable();
            // slither-disable-next-line timestamp
            if (block.timestamp >= snap.expiresAt) revert IntentExpired();

            // Effects: mark as settled and credit the fees BEFORE any
            // external call.
            intent.status = IntentStatus.Settled;

            merchantAddr = snap.merchant;
            amount = snap.amount;
            (merchantAmount, operatorFee, treasuryFee) = _credit(snap.operator, amount);
        }

        // Interactions: (1) pull from payer via ERC-3009, (2) pay the merchant.
        // USDC enforces msg.sender == to, so on-chain front-running is
        // impossible. Reverts on bad sig, expired, before validAfter,
        // nonce already consumed, or payer mismatch.
        IERC3009(address(usdc))
            .receiveWithAuthorization(
                auth.payer, address(this), amount, auth.validAfter, auth.validBefore, auth.nonce, auth.signature
            );

        bool ok = usdc.transfer(merchantAddr, merchantAmount);
        if (!ok) revert TransferFailed();

        // slither-disable-next-line reentrancy-events
        emit IntentSettled(auth.intentId, auth.payer, merchantAmount, operatorFee, treasuryFee);
    }

    // ── Comisiones acreditadas (ADR-009 §1) ──────────────────

    /// @notice Cobra las comisiones acreditadas a quien llama.
    /// @dev    Funciona en pausa: la pausa no retiene el dinero de nadie.
    function claim() external nonReentrant returns (uint256) {
        return _claim(msg.sender);
    }

    /// @notice Cobra las comisiones acreditadas a `account` y se las envía a
    ///         `account`. Cualquiera puede llamarlo: el dinero solo sale hacia
    ///         su dueño. Así una tarea periódica barre lo de la tesorería sin
    ///         tener sus llaves.
    /// @dev    No hay forma de cobrar hacia otra dirección: una cuenta que el
    ///         emisor de USDC tenga bloqueada no puede desviar su saldo, y cobra
    ///         cuando la desbloqueen.
    function claimFor(address account) external nonReentrant returns (uint256) {
        return _claim(account);
    }

    // `amount == 0` es «no hay nada que cobrar»: cualquier saldo mayor se cobra.
    // slither-disable-next-line incorrect-equality
    function _claim(address account) internal returns (uint256 amount) {
        amount = accrued[account];
        if (amount == 0) revert NothingToClaim();
        accrued[account] = 0;
        totalAccrued -= amount;
        bool ok = usdc.transfer(account, amount);
        if (!ok) revert TransferFailed();
        emit FeesClaimed(account, amount);
    }

    // ── Rescate de lo que sobra (ADR-009 §8) ─────────────────

    /// @notice Acredita a la tesorería el USDC del hub que no está acreditado
    ///         a nadie: lo que llegó por una transferencia directa. Sale con
    ///         `claimFor(treasury)`. Cualquiera puede llamarlo: nunca toca lo
    ///         acreditado a otros.
    function sweepSurplus() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        // `<=` y no `==`: si el saldo quedara por debajo de lo acreditado (algo
        // que solo podría hacer el emisor del token), no hay sobrante.
        if (balance <= totalAccrued) revert NothingToSweep();
        uint256 surplus = balance - totalAccrued;
        accrued[treasury] += surplus;
        totalAccrued += surplus;
        emit SurplusSwept(address(usdc), surplus);
    }

    /// @notice Envía a la tesorería todo el saldo de un token que no es USDC.
    ///         `SafeERC20` porque puede ser cualquier token, también uno que no
    ///         devuelve `bool`. El hub no acepta ETH (no tiene `receive`).
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

    // ── Cleanup ──────────────────────────────────────────────

    /// @notice Cancel an expired, never-paid intent. Anyone can call.
    ///         Marks intent as Cancelled (storage stays for audit trail).
    /// @dev    Reverts if intent does not exist, or if it is already
    ///         Settled / Cancelled, or if it has not yet expired.
    function cancelExpired(bytes32 intentId) external nonReentrant {
        Intent storage intent = _intents[intentId];
        if (intent.merchant == address(0)) revert IntentNotFound();
        if (intent.status != IntentStatus.Registered) revert IntentNotPayable();
        // slither-disable-next-line timestamp
        if (block.timestamp < intent.expiresAt) revert IntentNotExpired();

        intent.status = IntentStatus.Cancelled;
        emit IntentCancelled(intentId);
    }

    // ── Views ─────────────────────────────────────────────────

    function getIntent(bytes32 intentId) external view returns (Intent memory) {
        return _intents[intentId];
    }

    /// @notice Convenience view: compute the split that would happen for a
    ///         given amount. Useful for off-chain validation before
    ///         submitting a tx.
    function previewSplit(uint256 amount)
        external
        pure
        returns (uint256 merchantAmount, uint256 operatorFee, uint256 treasuryFee)
    {
        return _split(amount);
    }
}
