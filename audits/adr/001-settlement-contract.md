# ADR-001 — Settlement Contract for trustless on-chain payment splitting

> **Status**: 🟢 **Accepted** (2026-05-14)
> **Date**: 2026-05-14
> **Author**: Luis Campos (LACA-SOFT)
> **Supersedes**: —
> **Revised by**: ADR-002 (2026-05-14) — fee constants recalibrated from
> 50 bps (80/20) to 100 bps (70/30). The architecture in this ADR is
> unchanged; only the values of `PROTOCOL_FEE_BPS`, `OPERATOR_SHARE_BPS`,
> and `TREASURY_SHARE_BPS` are different from what §3.7 originally documents.
> See `audits/adr/002-fee-structure-and-gas-abstraction.md` for the
> economic analysis behind the change.

---

## Resumen ejecutivo (Español)

**Problema**: hoy el daemon del operator detecta pagos USDC pero no los reenvía al merchant ni divide la fee — esa lógica vive off-chain como "trust the operator". Esto es un gap para mainnet.

**Decisión**: implementar `SettlementHub.sol`, un contrato on-chain que recibe los pagos directamente y los divide automáticamente: 99.5% al merchant, 0.4% al operator, 0.1% al treasury. El operator pierde la capacidad de robar/olvidar forwarding — el contrato lo enforce trustlessly.

**Implicaciones**:
- 1 nuevo contrato (~250 LoC Solidity) entra al scope del audit
- Cambio UX para el payer: en vez de transfer simple a una EOA, llama a una función del contrato (con `permit` de USDC se mantiene en 1 tx)
- Cambio en Deploy.s.sol: 4 contratos en lugar de 3
- Cambio en API/daemon: `derivePaymentAddress` → `registerIntent` on-chain
- Timeline: ~5-6 semanas de trabajo total
- Costo audit: +20-40% sobre el quote actual (un contrato extra y migración)

**Por qué pre-mainnet, no Phase 2**:
- Pre-clientes, pre-audit, pre-fundraise = ventana óptima para refactor mayor
- "Sistema completo" pesa mucho más que "MVP con gap conocido" en pitch deck
- Re-engagement audit cuesta +30-50% que initial scope con Settlement Contract incluido

---

## 1. Context

### 1.1 The problem

OpenRelay's current Phase 1 architecture has a **critical implementation gap**: the routing daemon (`packages/node/src/services/watcher.ts`) detects on-chain USDC payments to per-intent payment addresses, but **does not** forward those funds to the merchant. The forwarding (and the documented 80/20 fee split between operator and treasury) is supposed to happen "operator-side" — but no code implements it.

In practice this means:
- The merchant gets a webhook saying "your payment arrived" but the funds are still sitting in an EOA that the **operator controls** (derived from `keccak256(operator_private_key + intent_index)`).
- A malicious operator could refuse to forward, keep the entire payment, and the only mitigation is the dispute system + 20% stake slash (slash goes to treasury, not back to merchant).
- The fee split (0.4% to operator, 0.1% to treasury) is a documented intention but not on-chain enforced.

### 1.2 Why this matters for Phase 1 closing

The original Phase 1 plan was: audit contracts → mainnet deploy → Phase 2 opens with first merchant. But the contracts we'd be auditing **don't include the settlement step**. A merchant onboarding to the audited mainnet contracts would face:

- **Manual operator dependency**: every payment requires the operator (LACA-SOFT in Phase 1) to manually forward. Doesn't scale beyond demo.
- **Unscoped trust assumption**: auditor can sign off on the contracts but cannot vouch for off-chain fund movement, leaving a critical attack surface uncovered.
- **Fundraise narrative weakness**: pitching "audited contracts + MVP off-chain settlement" is materially weaker than "audited contracts including settlement contract".

### 1.3 Why now (Option A vs B vs C from prior discussion)

| Option | Description | When considered | Why rejected for now |
|---|---|---|---|
| **A** | Settlement Contract on-chain, included in Phase 1 audit scope | This ADR | ✅ chosen |
| **B** | Operator-side daemon auto-forwarding (no new contract) | Considered | Trust model unchanged; Phase 2 audit needed anyway; bad fundraise narrative |
| **C** | Hybrid: Option B for Phase 1, Option A in Phase 2 | Considered | Same as B: ships incomplete |

**Decision driver**: the user is pre-clients, pre-audit, pre-money. Time/runway can absorb 5-6 additional weeks. Strategic completeness > shipping speed.

---

## 2. Decision

We will implement **`SettlementHub.sol`**, a single on-chain contract that:

1. Accepts intent registrations from the operator (`registerIntent`).
2. Accepts payments from the payer (`payIntent` or `payIntentWithPermit`).
3. **Atomically** splits the payment on receipt:
   - `merchant` receives **99.5%** of the amount.
   - `operator` receives **0.4%** of the amount.
   - `treasury` receives **0.1%** of the amount.
4. Emits events that the daemon and indexers consume to update off-chain state.

The contract is added to the Phase 1 audit scope. The current `derivePaymentAddress` flow in the daemon is removed.

---

## 3. Detailed design

### 3.1 Contract architecture: single Hub vs per-intent CREATE2

**Decision**: single `SettlementHub` contract.

**Rationale**:
- One deploy, one address to track — simpler operationally.
- Lower per-payment gas: no contract deployment per intent.
- Audit-friendly: 250 LoC in one contract beats N proxies.
- Battle-tested pattern (1inch, Cowswap, Across all use a hub for settlement).

**Rejected**: per-intent `CREATE2` proxies. Maintains current "send to address X" UX but expensive (proxy deploy on every settle), more complex audit, edge cases on undeployed proxies.

### 3.2 Payment flow: 2-tx vs 1-tx with permit

**Decision**: support **both**.

- **2-tx fallback**: `usdc.approve(SettlementHub, amount)` then `SettlementHub.payIntent(intentId)`. Standard ERC20 flow, works with any wallet.
- **1-tx with EIP-2612 permit**: `SettlementHub.payIntentWithPermit(intentId, deadline, v, r, s)`. Centre USDC on Base supports EIP-2612 via FiatTokenV2_2.

**Rationale**:
- Permit is preferred UX (matches current 1-tx feel) but not all wallets support it.
- 2-tx fallback ensures any wallet can pay.
- Both paths share the same internal `_payAndSettle` so audit surface is small.

### 3.3 Settlement trigger: auto vs separate `settle()` call

**Decision**: **auto-settle** on `payIntent` / `payIntentWithPermit`. No separate `settle()` function.

**Rationale**:
- One function call = one outcome. Reduces state transitions to audit.
- Eliminates the "paid but not settled" intermediate state where funds sit in the contract for an unknown duration.
- Lower gas: one contract call vs two.
- Removes the question "who pays gas to call settle?" — the payer pays for the full flow.

**Rejected**: separate `settle()` call. Useful only if payment and settlement need to be timed independently (e.g., multi-party authorization), which is not our use case.

### 3.4 Intent registration: who calls `registerIntent`?

**Decision**: the **operator** calls `registerIntent` on assignment.

**Rationale**:
- Operator already has the intent context after the API assigns it (current behavior).
- Operator pays the gas → cost is built into their 0.4% revenue share.
- Trust model: operator already has signing authority for routing; no new trust required.
- Merchant doesn't need an on-chain hot wallet (zero gas cost for merchants — important for adoption).

**Function signature**:
```solidity
function registerIntent(
    bytes32 intentId,
    address merchant,
    address operator,
    uint256 amount,
    uint64 expiresAt
) external returns (bool);
```

**Authorization**: any address can register (no caller restriction). Why? Because the operator's signature (msg.sender) is recorded as `intent.operator` and only that operator's address gets the fee share when settled. A malicious "registrar" gets nothing for their gas.

**Edge case**: same `intentId` registered twice. Reverts on second call (idempotent).

### 3.5 Batched registration for micropayments (x402)

**Decision**: support a `registerIntentBatch` function for amortized gas on x402 micropayments.

**Rationale**:
- x402 use case: AI agent paying $0.001 per API call.
- Per-intent gas on Base ≈ $0.0005-0.005 (varies). Could exceed payment fee.
- Batching 100 intents in one tx amortizes the gas cost across them.

**Function signature**:
```solidity
function registerIntentBatch(
    bytes32[] calldata intentIds,
    address[] calldata merchants,
    address[] calldata operators,
    uint256[] calldata amounts,
    uint64[] calldata expirations
) external returns (uint256 registered);
```

Skip-on-conflict semantics: if any intent in the batch is already registered, that one is skipped (not the whole batch).

### 3.6 Refund and expiry

**Decision**: explicit expiry + refund mechanism.

- Each intent has `expiresAt` (unix timestamp). If `block.timestamp >= expiresAt`, `payIntent` reverts with `IntentExpired`.
- If an intent was paid but not settled (shouldn't happen with auto-settle, but defensive), funds can be refunded by anyone calling `refund(intentId)` — this is a no-op in normal flow.
- If an intent was registered but never paid and now expired, anyone can call `cancel(intentId)` to free the storage. No funds to refund (none were sent).

**Decision NOT made**: partial payments. We require **exact amount** (`msg.value` style — must equal `intent.amount` exactly). Rationale: simpler invariants, cleaner audit, avoids ambiguity around "is 99% enough?". If payer underpays, transaction reverts; payer must retry with correct amount.

**Decision NOT made**: payer-initiated refund before expiry. If a payer pays but then changes their mind — no refund. The settlement is atomic with payment.

### 3.7 Fee enforcement

**Decision**: **hardcoded constants** in the contract:

```solidity
uint16 public constant PROTOCOL_FEE_BPS = 50;       // 0.5% total
uint16 public constant TREASURY_SHARE_BPS = 10;     // 0.1% to treasury (20% of total fee)
// Implicit: operator share = PROTOCOL_FEE_BPS - TREASURY_SHARE_BPS = 40 = 0.4%
```

**Rationale**:
- Hardcoded = strong commitment to merchants. Cannot be raised by guardian or anyone.
- Audit-verifiable: math is in code, no governance complexity.
- Phase 2 fee changes require full redeploy with migration plan (intentional friction).

**Rejected**: configurable fees via guardian with upper bound. Adds attack surface for guardian compromise; merchants can't reason about future fees.

### 3.8 Treasury and operator: addresses at construction or per-intent?

**Decision**: **per-intent** for both.

- `treasury` is set at construction time (immutable in the contract — same wallet across all intents).
- `operator` is per-intent: each intent records which operator is owed the 0.4%. Different operators across different intents in the future (multi-operator routing).
- `merchant` is per-intent: each merchant gets paid to their own address.

**Rationale**:
- Treasury immutable matches the existing pattern (StakeManager + DisputeResolver have immutable treasury).
- Per-intent operator unlocks Phase 2 multi-operator routing without contract changes.
- Per-intent merchant is obvious (merchants vary).

### 3.9 Multi-token support

**Decision**: **USDC only** in this contract. No multi-token in Phase 1.

**Rationale**:
- USDC is immutable in the contract (set at construction).
- Adding USDT/DAI/etc. is a separate contract or a Phase 2 upgrade.
- Keep Phase 1 audit scope tight.

### 3.10 Dispute integration

**Decision**: Settlement Contract is **independent** of DisputeResolver in v1.

**Rationale**:
- With Settlement Contract, funds reach merchant atomically — operator can no longer "steal" by withholding.
- Disputes now serve a different purpose: punishing operator misbehavior in routing (wrong service, downtime, etc.) — not fund recovery.
- Slashed funds continue to go to treasury (current behavior). Phase 2 RFC could explore "dispute compensation" where slashes go to disputed merchants.

### 3.11 Events

```solidity
event IntentRegistered(
    bytes32 indexed intentId,
    address indexed merchant,
    address indexed operator,
    uint256 amount,
    uint64 expiresAt
);

event IntentSettled(
    bytes32 indexed intentId,
    address indexed payer,
    uint256 merchantAmount,    // 99.5%
    uint256 operatorFee,       // 0.4%
    uint256 treasuryFee        // 0.1%
);

event IntentCancelled(bytes32 indexed intentId);  // expired without payment
```

The daemon's chain watcher subscribes to `IntentSettled` events to mark intents as paid in SQLite and trigger merchant webhooks.

### 3.12 State storage

```solidity
struct Intent {
    address merchant;       // 20 bytes
    address operator;       // 20 bytes
    uint256 amount;         // 32 bytes
    uint64 expiresAt;       // 8 bytes
    uint8 status;           // 1 byte (0=registered, 1=settled, 2=cancelled)
}
mapping(bytes32 => Intent) public intents;
```

**Decision**: keep `Intent` records forever (no pruning). Storage on Base is cheap (~$0.001 per intent).

### 3.13 Reentrancy and CEI

- All state-changing functions use OpenZeppelin's `ReentrancyGuard.nonReentrant`.
- Internal flow follows checks-effects-interactions:
  - Check: validate intent exists, not yet settled, not expired
  - Effects: update `intent.status = settled`
  - Interactions: 3 USDC transfers (merchant, operator, treasury)

This matches the patterns established in StakeManager (PR #51).

### 3.14 Construction parameters

```solidity
constructor(
    address _usdc,        // immutable USDC reference (Centre USDC on Base)
    address _treasury,    // immutable treasury (same as StakeManager.treasury for consistency)
    address _guardian     // for emergency pause (inherits from Pausable)
);
```

Same role separation as the other 3 contracts: deployer pays gas, treasury immutable, guardian rotatable.

---

## 4. Implementation plan

### Week 1 — Design + spec (this ADR + review)

- [x] Write this ADR
- [ ] User review + feedback iteration
- [ ] Final ADR accepted (status → 🟢 Accepted)
- [ ] Detailed contract spec (function signatures, events, errors, gas estimates)
- [ ] Test plan: unit + invariants + E2E (with mocked USDC supporting permit)

### Week 2 — Contract implementation

- [ ] `packages/contracts/src/SettlementHub.sol`
- [ ] Inherit `Pausable` (existing) + `ReentrancyGuard` (OpenZeppelin)
- [ ] Unit tests in `packages/contracts/test/SettlementHub.t.sol`
- [ ] Invariant tests in `packages/contracts/test/invariants/SettlementHub.invariants.t.sol`
- [ ] Slither pass — must reach 0 findings before moving on
- [ ] `forge fmt` + `forge test` + `forge coverage` baseline

### Week 3 — Integration

- [ ] Update `Deploy.s.sol` to deploy 4 contracts (was 3)
- [ ] Update `IStakeManager` / `IDisputeResolver` if needed (probably not — Settlement Contract is independent)
- [ ] Modify API (`packages/api/src/routes/payment-intents.ts`): replace `derivePaymentAddress` flow with `registerIntent` call from operator
- [ ] Modify daemon (`packages/node/src/services/watcher.ts`): subscribe to `IntentSettled` events instead of `Transfer` events
- [ ] Add new tests for the integration paths
- [ ] Update SDK (`packages/sdk-js`) to expose the new payer flow (`payIntent` and `payIntentWithPermit` helpers)

### Week 4 — Testnet validation

- [ ] Redeploy all 4 contracts to Base Sepolia
- [ ] Update `sepolia.json` with new SettlementHub address
- [ ] Update `fly.toml` with new contract addresses + `fly deploy` daemon
- [ ] E2E test on testnet: real merchant integrates SDK → real payer pays → verify funds split correctly
- [ ] Document observed gas costs per flow (registerIntent + payIntent + permit variant)

### Week 5 — Audit prep finalization

- [ ] Update `audits/SCOPE.md` with new contract in scope
- [ ] Update LoC count (~250 added, total ~1,280 in scope)
- [ ] Re-run Slither + invariants — must be clean
- [ ] Update `audits/SCOPE.md §5` with new SettlementHub invariants
- [ ] Refresh `.gas-snapshot` baseline
- [ ] Re-engage audit firms with updated scope (re-quote if needed)

### Week 6 — Buffer / polish

- [ ] Documentation: update README + ROADMAP
- [ ] Phase 2 reframe in ROADMAP.md (no longer "build settlement", now "multi-operator marketplace + governance")
- [ ] Wrap-up

---

## 5. Consequences

### 5.1 Positive

- **Trustless settlement**: operator can no longer steal payments. Merchants are protected by code, not by reputation/dispute.
- **Honest fee enforcement**: 0.5% / 0.4% / 0.1% split is on-chain, immutable, audit-verifiable.
- **Decentralization-ready**: per-intent operator field unlocks multi-operator routing in Phase 2 with no contract changes.
- **Stronger fundraise narrative**: "audited contracts including settlement" >> "audited contracts + manual settlement".
- **Auditor billable hours used efficiently**: critical path code is reviewed.

### 5.2 Negative

- **Timeline impact**: +5-6 weeks pre-mainnet.
- **Audit cost**: +20-40% over current quote (extra contract + integration).
- **UX shift for payer**: from `usdc.transfer(addr, amt)` to `SettlementHub.payIntent(id)`. Mitigated by EIP-2612 permit (1 tx) but wallets must support it.
- **Operator gas cost**: registerIntent adds ~50k gas per intent (~$0.0005 on Base). Operator's 0.4% revenue must cover this.
- **Storage growth**: every intent stored on-chain forever. Negligible at 100/day, considerable at 100k/day. Phase 2 may need pruning or off-chain indexing.

### 5.3 Neutral

- **Contract count**: 3 → 4 in deployment.
- **Deploy script complexity**: +1 deploy step, +1 verification step.
- **`derivePaymentAddress` removed**: cleaner code, less crypto magic.

---

## 6. Alternatives considered

### 6.1 Operator-side daemon auto-forwarding (Option B)

**Description**: modify the daemon to automatically sign 3 transferFrom transactions after detecting payment.

**Rejected because**:
- Trust model unchanged (operator daemon is still the trust anchor).
- Audit scope unchanged technically, but auditor flags "missing on-chain enforcement" anyway.
- Phase 2 needs Settlement Contract anyway → wasted work in Phase 1.
- Bad fundraise positioning.

### 6.2 Per-intent CREATE2 proxy contracts

**Description**: each intent deploys a deterministic proxy at a unique address; payer sends to that address; proxy forwards to hub on `sweep`.

**Rejected because**:
- Per-intent contract deploys are expensive on settle.
- Audit complexity: each proxy is a contract that needs review (or proven equivalent).
- UX advantage (simple `transfer` to address) is undone by EIP-2612 permit on the hub.

### 6.3 Off-chain signed orders (à la Cowswap/0x)

**Description**: operator signs an EIP-712 typed data order off-chain; payer brings the signed order + payment to the hub.

**Rejected because**:
- Adds signature verification complexity (1-2 weeks of design alone).
- Doesn't solve the "operator could refuse to forward" problem (no order = no settlement).
- Useful pattern for atomic swaps, overkill for single-direction payments.

### 6.4 USDC's own escrow features

**Description**: leverage USDC's `transferAndCall` or similar.

**Rejected because**:
- USDC doesn't have these features (it's plain ERC20 v2.2 with permit).
- Tying to a token-specific extension hurts portability if we ever support other tokens.

---

## 7. Decisions made (resolved 2026-05-14 by Luis Campos)

### Q1: Permit support — required or optional?

**✅ Decision: (b) — support both `payIntent` (2-tx) and `payIntentWithPermit` (1-tx).**

Rationale: maximum wallet compatibility; permit is preferred UX but the 2-tx fallback is small overhead and ensures any wallet works.

### Q2: registerIntent authorization

**✅ Decision: (a) — anyone can call `registerIntent`.**

Rationale: the economic incentive (gas paid with no fee return for unauthorized registrars) is sufficient deterrent. Operator address is recorded in the intent; only that operator receives fees on settle.

### Q3: Intent expiry default

**✅ Decision: (a) — 30 minutes default.**

Rationale: matches existing `DEFAULT_INTENT_TTL_SECONDS = 1800`. Merchants can override per intent. Short enough to keep storage growth manageable, long enough for human payers to complete.

### Q4: Dispute integration timing

**✅ Decision: (a) — Settlement Contract independent of DisputeResolver in v1.**

Rationale: with Settlement Contract enforcing splits atomically, operator can no longer steal funds. Disputes shift purpose to punishing operator misbehavior (slash → treasury). Escrow-with-clawback is a Phase 2 RFC; adds significant complexity (escrow accounting, dispute → contract callback) that would delay mainnet.

### Q5: Pause semantics

**✅ Decision: (b) — pause only blocks new `registerIntent`; existing intents can still be paid.**

Rationale: a pause shouldn't strand payers who are mid-flight. Existing intents remain valid until expiry; new intents are blocked. Soft stop for ongoing payments, hard stop for new commitments.

### Q6: Treasury for the SettlementHub

**✅ Decision: (a) — same address as `StakeManager.treasury`.**

Rationale: single source of protocol revenue (slash + fees) simplifies accounting and the eventual transition to on-chain (DAO) governance in Phase 3. Constructor of `SettlementHub` MUST take the same `treasury` address as `StakeManager.treasury` — Deploy script enforces this.

---

## 8. References

- USDC EIP-2612 implementation on Base: <https://etherscan.io/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913#code>
- OpenZeppelin ReentrancyGuard: `lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol`
- Audit SCOPE.md (this contract will be added): `audits/SCOPE.md`
- Phase 1 strategic reframe (audit before merchant): PR #47, `ROADMAP.md`
- Existing settlement gap discussion: study notes `study/01-big-picture.md §1.3`

---

## 9. Sign-off

- [x] Author (LACA-SOFT) — design accepted (2026-05-14)
- [ ] Auditor pre-engagement review (when audit firm is engaged)

Status: 🟢 **Accepted**. Implementation work begins (Week 2 of the plan in §4).
