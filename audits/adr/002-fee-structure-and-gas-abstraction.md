# ADR-002 — Fee structure recalibration + gas abstraction strategy

> **Status**: 🟢 **Accepted** (2026-05-14)
> **Date**: 2026-05-14
> **Author**: Luis Campos (LACA-SOFT)
> **Supersedes**: — (refines ADR-001 §3.7 fee constants and §5 consequences)
> **Implementation**: Phase A (fee recalibration + SSOT) is in PR `feat/fee-recalibration-100bps`.
> Phase C (mainnet redeploy) is tracked as follow-up work; not a blocker for this ADR's acceptance.
>
> ⚠️ **§2.2 / Phase B (Circle Paymaster) is SUPERSEDED by [ADR-003](003-gas-abstraction-via-erc3009.md).**
> Gas abstraction ships via **ERC-3009 gasless settlement** (payer signs an authorization off-chain,
> the nodeit submits the tx and pays the gas) — **Circle Paymaster was never implemented** and is NOT
> the live plan. The historical analysis below (§2.2, §5) is kept for the record; read it as
> "options evaluated", not "what we built".

---

## Resumen ejecutivo (Español)

**Problema**: la estructura de fee actual (50 bps total, 80/20 split) está implementada en el SettlementHub (PR #69), **pero la math no cierra para sustentabilidad real**. Análisis demuestra:

- Operator a 0.4%: break-even solo con vol > 200 pagos/día Y avg ≥ $5. Excluye operators chicos.
- Treasury a 0.1%: auto-financiable solo desde $50M+/mes volumen. Requiere subsidio externo durante años.
- Use case x402 micropagos ($0.001-0.10): **completamente roto sin gas abstraction**. Operator pierde $0.0036 por intent.

**Decisión**:
1. **Subir fee total a 100 bps** (1.0%): 70 bps al operator, 30 bps al treasury
2. **Implementar gas abstraction** (Circle Paymaster integration) antes de mainnet — sin esto x402 es vapor

**Por qué no es "tarde para cambiar"**: los fees son constantes en SettlementHub.sol (PR #69, no mergeado todavía). Cambio = 3 constantes + actualizar tests + docs. Implementación: ~1 día. Gas abstraction: ~3-4 semanas + audit cost incremental.

---

## 1. Context

### 1.1 Why we're revisiting fees

ADR-001 §3.7 hardcoded `PROTOCOL_FEE_BPS = 50` and split 80/20 (40 bps operator, 10 bps treasury). Those numbers came from the existing `packages/protocol/src/constants.ts` (PROTOCOL_FEE_BPS = 50) without formal economic analysis.

After implementing SettlementHub (PR #69), conversation surfaced that the math doesn't close for sustainable economics. The user's priorities (verbatim, 2026-05-14):

> "que el sistema funcione correctamente, que genere valor, que no invente cosas que no puede hacer, que incluya todos los costos reales, que si el 50 puntos base no alcanza lo diga y que busquemos mejorar eso para que esto sea un negocio real no un fake o un mvp o un poc"

This ADR captures the formal economic analysis and the recalibration.

### 1.2 Why gas abstraction is in scope here

Fee structure and gas abstraction are tightly coupled:

- Without gas abstraction: payer needs ETH on Base → friction for non-crypto-native users → blocks LATAM mass adoption
- Without gas abstraction: x402 use case ($0.001-0.10 payments) is economically broken — gas dominates payment value
- With higher fees: more headroom to absorb paymaster costs
- With paymaster: more justification for higher fees (gives users a tangible benefit)

Treating them as one decision avoids re-opening the topic later.

---

## 2. Decision

### 2.1 Fee structure: 50 bps → 100 bps total

| Concept | Current (ADR-001) | Proposed | Δ |
|---|---|---|---|
| `PROTOCOL_FEE_BPS` | 50 (0.5%) | **100 (1.0%)** | +50 bps |
| `OPERATOR_SHARE_BPS` | 40 (0.4%) | **70 (0.7%)** | +30 bps |
| `TREASURY_SHARE_BPS` | 10 (0.1%) | **30 (0.3%)** | +20 bps |
| `NODE_FEE_SHARE` (legacy, off-chain) | 0.8 | **0.7** | -0.1 |
| `TREASURY_FEE_SHARE` (legacy, off-chain) | 0.2 | **0.3** | +0.1 |

**Rationale**: see §3 (Operator Economics Analysis) and §4 (Treasury Sustainability).

### 2.2 Gas abstraction: Circle Paymaster integration

We integrate **Circle Paymaster** (released 2025) as the default gas abstraction layer:

- Payer pays gas in USDC (no ETH needed)
- Circle takes a fee (~3-5% of gas cost, paid in USDC)
- Compatible with ERC-4337 account abstraction infrastructure
- USDC ↔ paymaster interface is standard (no protocol-specific contract changes)

**Rationale**: see §5 (Gas Abstraction Options).

### 2.3 Both changes ship together pre-mainnet

The fee changes and Circle Paymaster integration are implemented in coordinated PRs:

- PR-A: protocol constants + SettlementHub constants + tests + docs
- PR-B: Circle Paymaster integration in API/daemon/SDK
- PR-C: redeploy Sepolia with new fees + Circle Paymaster setup

PR-A is independent (~1 day work). PR-B requires Circle SDK integration (~3-4 weeks). They can ship in sequence or parallel.

---

## 3. Operator economics analysis

### 3.1 Operator monthly fixed costs

| Item | Cost / month |
|---|---|
| Hosting (daemon 24/7, Fly.io equivalent) | ~$10 |
| Monitoring (Grafana/Datadog free tier OK) | ~$0-20 |
| Stake locked (opportunity cost: $100 at 5% APY) | ~$0.42 |
| Gas operacional per intent (~$0.0036 each — Base mainnet at 0.01 gwei) | varies w/ volume |
| Dev/devops time (estimated 2h/mes at $50/h) | ~$100 |
| **Fixed total** | **~$110-130/mes** |

### 3.2 Break-even volume at different fees

Operator needs $130/mes net to cover fixed costs:

| Avg payment | Volume needed (0.4% fee = current) | Volume needed (0.7% fee = proposed) |
|---|---|---|
| $1 | 32,500 pagos (1,083/día) | **18,571 pagos (619/día)** |
| $5 | 6,500 pagos (217/día) | **3,714 pagos (124/día)** |
| $10 | 3,250 pagos (108/día) | **1,857 pagos (62/día)** |
| $50 | 650 pagos (22/día) | **372 pagos (12/día)** |
| $100 | 325 pagos (11/día) | **186 pagos (6/día)** |

**Reading**: at 0.7% operator fee, break-even volume drops ~43% across all payment sizes. A small operator processing 50 LATAM remittance payments/day (avg $50) clears $130/mes vs being marginal at 0.4%.

### 3.3 Profit at scale

For an operator processing 500 payments/day at $20 avg ($10k volume):

| Fee | Monthly revenue | Net (after $130 fixed costs) |
|---|---|---|
| 0.4% (current) | $1,200 | $1,070 |
| 0.7% (proposed) | $2,100 | $1,970 |

Almost **2x take-home pay** for the same operational effort. Material for attracting independent operators (Phase 3 multi-operator marketplace).

### 3.4 Comparison to alternatives

What operators could earn doing something else with $100 in capital:

| Activity | Yearly return on $100 |
|---|---|
| T-bills (5% APY) | $5 |
| ETH staking (~3.5% APY) | $3.50 |
| OpenRelay operator at 0.4% (500 pay/day, $20 avg) | ~$12,840 |
| OpenRelay operator at 0.7% (same) | ~$23,640 |

The return on operator effort dwarfs return on capital. What matters is **whether the effort is worth it relative to other dev contracting**. At 0.7%, yes. At 0.4%, marginally.

---

## 4. Treasury sustainability analysis

### 4.1 Costs treasury must fund (Phase 1-3)

| Item | Annual cost estimate |
|---|---|
| Annual audit (recurring as code changes) | $30k-100k |
| Bug bounty program (Immunefi pool) | $10k-50k |
| Dev team (2 FTE at average rate) | $200k-300k |
| Marketing / community / docs | $50k-100k |
| Legal / compliance review | $20k-50k |
| **Total annual** | **~$310k-600k** |

### 4.2 Treasury self-financing threshold

Revenue at different fees and volumes:

| Monthly volume | Treasury at 0.1% | Treasury at 0.3% |
|---|---|---|
| $100k | $100/mes = $1.2k/año | $300/mes = $3.6k/año |
| $1M | $1k/mes = $12k/año | $3k/mes = $36k/año |
| $10M | $10k/mes = $120k/año | $30k/mes = $360k/año |
| $50M | $50k/mes = $600k/año | $150k/mes = $1.8M/año |
| $100M | $100k/mes = $1.2M/año | $300k/mes = $3.6M/año |

**Reading**: at 0.1%, treasury hits the ~$310k threshold at **$30M+/mes volume**. At 0.3%, the threshold drops to **~$10M/mes** — 3x faster path to self-funding.

For Phase 1-2 (expected < $1M/mes), treasury auto-funding is impossible at either fee. External funding (equity, grants) covers the gap. **But the recovery curve from external funding to self-funding is 3x faster at 0.3% — that's the difference between needing 3 funding rounds vs 1.**

### 4.3 Comparison to alternatives (merchant side)

What does the merchant gain vs Stripe / banks at the new fee?

| Provider | Fee | Settlement time | LATAM access |
|---|---|---|---|
| **OpenRelay (proposed 1.0%)** | 1.0% | ~2s (Base block time) | Universal (any USDC wallet) |
| Stripe | 2.9% + $0.30 | 2-7 days | Limited LATAM |
| Coinbase Commerce | 1.0% | minutes | Universal but centralized |
| BitPay | 1.0% + $0.25 | minutes | Universal but centralized |
| Bank wire (LATAM) | 5-8% + FX | 1-5 days | Universal but expensive |

**Reading**: 1.0% is still **undercutting Stripe by 65-90%** for typical payment sizes. Competitive with Coinbase Commerce / BitPay but decentralized + faster settlement.

For a $50 payment:
- Stripe: $1.75
- OpenRelay (new): $0.50
- Savings vs Stripe: $1.25 per payment (71% reduction)

Merchant value proposition is intact.

---

## 5. Gas abstraction analysis

### 5.1 Why this matters

Without gas abstraction, every payer needs ETH on Base. This is:

- **Friction for onboarding**: customer has USDC (from Bitso, Circle, etc.) but no ETH → must bridge ETH first → poor UX
- **Catastrophic for x402**: $0.001 payment requires $0.0036 gas (3.6× the payment!) → use case completely unviable
- **LATAM-specific blocker**: most users only hold USDC (from remittance flows), not ETH

### 5.2 Options evaluated

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A. Circle Paymaster** | Payer pays gas in USDC via Circle's CCTP+paymaster service | Zero protocol code changes; Circle handles complexity; battle-tested; widely supported wallets | Dependency on Circle; ~3-5% paymaster fee on top of gas cost; not fully decentralized |
| **B. Self-built ERC-4337 Paymaster** | Build our own paymaster contract that accepts USDC and pays ETH | Full control; can subsidize gas for marketing campaigns; decentralized; potential revenue stream | Implementation cost; additional audit; protocol-specific liquidity (need USDC + ETH float); operational complexity |
| **C. Operator-sponsored gas** | Operator pays payer's gas; deducts equivalent USDC from merchant amount | No new contract code (just daemon logic); leverages existing operator economics | Reduces merchant's effective payment; complex gas estimation on/off chain; doesn't help operator's own registerIntent gas |
| **D. Biconomy / Pimlico** | Third-party paymaster-as-a-service | Battle-tested; no contract code | Higher fee (~5-10%); third-party dependency; not Circle-aligned (USDC native makes Circle more natural) |
| **E. Hybrid (A + C)** | Circle Paymaster as default; operator-sponsored as fallback for x402 batches | Best of both worlds | Two integration paths; documentation complexity |

### 5.3 Recommended: Option A (Circle Paymaster)

**Decision: Option A — Circle Paymaster integration**.

Rationale:
- Aligned with USDC ecosystem (Centre is Circle subsidiary; native integration)
- Zero protocol contract changes (we don't need to build/audit a paymaster ourselves)
- ~3-5% paymaster fee is acceptable: payer pays $0.0036 base gas + ~$0.0002 paymaster fee = ~$0.004 total. Still ~0.08% of a $5 payment.
- Mainstream wallet support: Coinbase Wallet, MetaMask Snaps, Rabby, etc.
- Removes the "you need ETH" friction entirely from the merchant pitch

When NOT Circle Paymaster: if x402 micropayments need to batch payments cheaper than Circle's overhead, we can add Option C (operator-sponsored batched gas) as a Phase 3 enhancement. Not blocker for mainnet.

### 5.4 Where Circle Paymaster integration touches our code

| Component | Change |
|---|---|
| `SettlementHub.sol` | **NO changes** — paymaster is transport-layer, contract API unchanged |
| `packages/sdk-js` | Add Circle Paymaster client + helper to wrap `payIntent` calls |
| `packages/api/src/routes/payment-intents.ts` | Optionally expose paymaster sponsorship in the intent creation response |
| Dashboard | Add UI hint: "no ETH needed — pay gas in USDC" |
| Docs | Document the payer flow with Circle Paymaster |

Estimated work: **3-4 weeks** including testing on Sepolia. Audit cost incremental: **$5-10k** (paymaster integration review, smaller than auditing a new contract since no new contract is added).

---

## 6. Implementation plan

### Phase A: Fee adjustment (1 day work)

| Task | File |
|---|---|
| 1. Update `SettlementHub.sol` constants | `packages/contracts/src/SettlementHub.sol`: `PROTOCOL_FEE_BPS = 100`, `TREASURY_SHARE_BPS = 30` |
| 2. Update unit tests with new expected splits | `packages/contracts/test/SettlementHub.t.sol`: fee math assertions |
| 3. Update invariants with new ratios | `packages/contracts/test/invariants/SettlementHub.invariants.t.sol`: `invariant_feeSplitRatio` |
| 4. Update protocol constants | `packages/protocol/src/constants.ts`: `PROTOCOL_FEE_BPS`, `NODE_FEE_SHARE`, `TREASURY_FEE_SHARE` |
| 5. Update API tests that hardcode 50 bps | Search + update |
| 6. Update docs | `README.md`, `docs/en/README.md`, `WHITEPAPER.md`, `ROADMAP.md`, `audits/SCOPE.md`, `audits/adr/001-settlement-contract.md` (note fee revision) |
| 7. Re-run all tests, slither, coverage | full validation |
| 8. Refresh `.gas-snapshot` | baselines change |

PR after `PR #69` merges, before mainnet redeploy.

### Phase B: Circle Paymaster integration (3-4 weeks)

| Week | Tasks |
|---|---|
| Week B1 | Research Circle Paymaster API + Base mainnet/Sepolia support. Design SDK integration. Set up Circle developer account + sponsorship policies. |
| Week B2 | Implement SDK helper. Update `payIntent` flow to optionally use Circle. Document UX in dashboard + SDK examples. |
| Week B3 | E2E testing on Sepolia with Circle's testnet paymaster. Gas cost measurement and reporting. |
| Week B4 | Audit prep: write Circle integration ADR (this becomes ADR-003 if needed). Add to SCOPE.md as in-scope helper. |

### Phase C: Mainnet readiness (1 week)

| Task | Notes |
|---|---|
| Redeploy on Sepolia with new fees | Standard `forge script` flow |
| Update `sepolia.json` with new contract addresses | History keeps prior orphans documented |
| E2E test with Circle Paymaster on Sepolia | Real flow: payer with no ETH pays a real intent |
| Send updated SCOPE.md to audit firms | Includes new fee constants + paymaster integration |

---

## 7. Consequences

### 7.1 Positive

- **Operator economics viable**: 0.7% per pago × realistic LATAM volumes → break-even at 124 payments/día (avg $5) instead of 217. 43% lower bar to operator profitability.
- **Treasury self-financing 3x faster**: $10M/mes threshold instead of $30M/mes. Reduces external funding dependency.
- **x402 use case unlocked**: Circle Paymaster makes $0.001-0.10 micropayments economically viable for payers.
- **LATAM mass adoption enabled**: payers no longer need ETH — pay gas in USDC.
- **Honest economics**: documented analysis backs up the pitch deck claims about sustainable margins.
- **Audit narrative stronger**: "we audited the fee math AND the gas strategy" >> "we audited the contracts but the gas situation is unclear".

### 7.2 Negative

- **Higher merchant fee** (1.0% vs 0.5%). Still competitive (65-90% cheaper than Stripe) but communicate clearly.
- **Circle Paymaster dependency**: ~3-5% paymaster fee on gas + dependency on Circle's service availability + slight loss of "fully decentralized" narrative (mitigation: Option B self-built paymaster as Phase 3 roadmap item).
- **Audit cost increase**: integration adds ~$5-10k to audit. Acceptable given the strategic value.
- **Phase A timing**: need to redo gas snapshots + invariant test values + docs.

### 7.3 Neutral

- **No new contracts**: SettlementHub stays the same. Just constant values change.
- **No breaking change to ADR-001 architecture**: §3 design holds; §3.7 constants are recalibrated.

---

## 8. Resolved decisions (formerly "open questions")

The four open questions raised at proposal time are resolved (2026-05-14, by author):

### Q1: Fee target — RESOLVED → 100 bps total (70 op / 30 treasury)

Confirmed (option (a) of the original options). Rationale per §3 (operator economics) and §4 (treasury sustainability): 100 bps is the lowest fee at which the operator break-even reaches realistic LATAM volumes (~124 pagos/día at $5 avg) AND the treasury self-financing threshold drops to ~$10M/mes, while staying 65-90% cheaper than Stripe.

### Q2: Gas abstraction approach — RESOLVED → Circle Paymaster

Confirmed (option (a)). Native USDC alignment, zero protocol contract changes, mainstream wallet support. Self-built ERC-4337 paymaster remains a Phase 3 roadmap option if we want to recover the Circle fee margin or reduce dependency.

### Q3: Sequencing vs PR #69 — RESOLVED (moot)

PR #69 (SettlementHub) was already merged into `master` before this ADR's implementation began. The fee recalibration is therefore landing as a follow-up PR (`feat/fee-recalibration-100bps`) instead of an amendment. Acceptable trade-off: 1 commit in `master` history briefly carried the prior 50 bps constants, but the fee values were never deployed to mainnet under those constants — Sepolia will be redeployed with the corrected values as part of Phase C of this ADR.

### Q4: Fee revision policy — RESOLVED → Keep as `constant` (immutable in bytecode)

Confirmed (option (a)). Adjustability is a footgun (guardian compromise = fee increase attack). Phase 3 governance can introduce upgradable fees via a proper proxy migration if/when needed. Strong commitment to merchants: "the fee on day 1 = the fee on day 1000, unless we redeploy and you opt-in."

### Q5 (added during implementation): Single-source-of-truth for fee constants

Raised by author after seeing fees declared in two places (`SettlementHub.sol` AND `packages/protocol/src/constants.ts`). Risk: if they ever drift, the off-chain layer (API `fee_amount`, dashboard preview, SDK) lies to merchants about what they will be charged on-chain.

**Resolved → option (1)**: generator script reads the Solidity contract and writes `packages/protocol/src/fee-constants.generated.ts`. The hand-written `constants.ts` re-exports from it and derives `NODE_FEE_SHARE` / `TREASURY_FEE_SHARE` from the canonical bps values. CI gate (`pnpm --filter @lacasoft/openrelay-protocol check:fee-constants`) fails the build on drift. Implemented in the same PR as the fee recalibration.

---

## 9. References

- ADR-001: Settlement Contract design (`audits/adr/001-settlement-contract.md`)
- Circle Paymaster docs: <https://developers.circle.com/stablecoin/docs/paymaster> (verify current URL)
- Comparable fee structures in DeFi: Cowswap (~0.1% protocol), 1inch (~0.5% protocol), Uniswap V4 (variable per pool)
- Stripe fee reference: <https://stripe.com/pricing> (2.9% + $0.30 standard)
- User reframe on time-bias: `study/01-big-picture.md §1.4` (when written) + memory `feedback_no_time_bias.md`

---

## 10. Sign-off

- [x] Author (LACA-SOFT) — fee structure + gas abstraction strategy accepted (2026-05-14)
- [ ] Auditor pre-engagement review (when audit firm engaged)

Status: 🟢 **Accepted**. Implementation tracking:

- **Phase A (fee recalibration + SSOT)**: PR `feat/fee-recalibration-100bps` — applies the 100 bps split, adds the SSOT generator + CI drift check, updates all docs/tests.
- **Phase B (Circle Paymaster integration)**: pending — not a blocker for ADR acceptance, but required before mainnet for x402 viability.
- **Phase C (mainnet redeploy)**: pending — Sepolia first with the new fees + Circle Paymaster, then mainnet after audit sign-off.
