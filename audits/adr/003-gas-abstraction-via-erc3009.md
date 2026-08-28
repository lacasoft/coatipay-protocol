# ADR-003 — Gas abstraction via ERC-3009 (supersedes ADR-002 §2.2)

> **Status**: 🟢 **Accepted** (2026-05-14)
> **Date**: 2026-05-14
> **Author**: Luis Campos (LACA-SOFT)
> **Supersedes**: ADR-002 §2.2 (Circle Paymaster decision). ADR-002 §2.1 fee
> structure (100 bps total, 70/30 split) remains in force, unchanged.
> **Revisions**:
> - 2026-05-14 (v1.0): aceptado, mergeado en PR #72.
> - 2026-05-14 (v1.1): refinamientos post-review externo — added §1.4 (phase
>   disambiguation), §2.1.1 (transferWithAuth vs receiveWithAuth), §2.2.1
>   (batch constraints explícitas), §2.2.2 (gas estimates table), §2.4
>   (USDC native vs bridged), §5.4 (operator failure handling), gas spike
>   + failed-tx footnotes en §2.3.

---

## Resumen ejecutivo (Español)

ADR-002 §2.2 eligió **Circle Paymaster** (ERC-4337 + EIP-7702) como capa de gas abstraction. Durante la planificación de Phase B salió a la luz una alternativa más simple, nativa, y mejor alineada con la tesis non-custodial: **ERC-3009** (`receiveWithAuthorization` / `transferWithAuthorization`) — funcionalidad ya implementada en USDC v2.x desde 2022, sin dependencias externas, sin surcharge, compatible con cualquier wallet que firme EIP-712.

**Decisión**: pivotar a ERC-3009. Agregar `payIntentWithAuthorization` a `SettlementHub.sol`. El nodeit que ya recibe el intent submite la transacción + paga el gas en ETH; recupera el costo del 0.7% que cobra. El payer solo firma un mensaje EIP-712 off-chain — gratis, sin gas, sin smart-account, sin EIP-7702.

**Por qué este pivot vale la pena**:
- Cero dependencias externas (Circle, Pimlico bundler, EIP-7702 wallet support)
- Funciona con **cualquier wallet** que firme EIP-712 — incluido Ledger/Trezor/Metamask viejo
- Sin surcharge del ~21% (10% Circle + 10% Pimlico) — el dinero queda en el ecosistema OpenRelay
- Es el **patrón nativo de x402** (cuyo "facilitator" = nuestro nodeit), por lo que alinea ambos sistemas
- Audit más simple: 1 función nueva en el contrato existente vs auditar UserOp validation client-side + chain of trust con bundler

---

## 1. Context

### 1.1 Cómo llegamos aquí

ADR-002 §2.2 eligió Circle Paymaster basándose en research que enfatizaba ERC-4337 + EIP-7702. En la planificación de Phase B (research-only spike), se confirmó que Circle Paymaster es real, GA en Base, soporta EOAs vía EIP-7702 — pero también surgió que:

- USDC v2.x en Base **ya tiene** `transferWithAuthorization` y `receiveWithAuthorization` (ERC-3009) implementados nativamente desde 2022
- x402 (que pretendemos soportar como first-class) **usa exactamente este mecanismo** — el "facilitator" del flow x402 es el actor que recibe la firma del payer y submitea on-chain
- El rol de "facilitator" en x402 es funcionalmente idéntico al rol del **nodeit** en OpenRelay
- Nuestro contrato actual `SettlementHub.sol` y patrón operacional (operator paga `registerIntent` gas) son consistentes con un patrón "operator-paid settlement"

### 1.2 Lo que NO cambia de ADR-002

ADR-002 §2.1 (fee structure: 100 bps total, 70/30 split nodeit/treasury) **se mantiene íntegro**. Esa decisión está basada en análisis económico (operator break-even, treasury sustainability, Stripe comparativa) y es independiente del mecanismo de gas abstraction.

Las constantes del contrato (`PROTOCOL_FEE_BPS=100`, `TREASURY_SHARE_BPS=30`, `OPERATOR_SHARE_BPS=70`) y el SSOT generator (PR #71) **no requieren cambios**.

### 1.3 Lo que SÍ cambia

Solo §2.2 de ADR-002 (decisión de gas abstraction). En vez de Circle Paymaster + Pimlico bundler + EIP-7702, usamos ERC-3009 nativo + nueva función en SettlementHub.

### 1.4 Disambiguación de fases

**"Phase B"** en este ADR (y en ADR-002 §6) se refiere a una **sub-fase pre-mainnet** dentro de la "ventana de implementación previa al audit externo" — Phases A/B/C son granularidad interna de engineering.

NO confundir con las **Phase 1 / Phase 2 / Phase 3** del WHITEPAPER (`WHITEPAPER.md`) y ROADMAP (`ROADMAP.md`), que se refieren a etapas de madurez del protocolo:

| Concepto | Significado | Documento |
|---|---|---|
| **Phase A** (ADR-002) | Fee recalibration + SSOT generator | Mergeado (PR #71) |
| **Phase B** (ADR-002/003) | Gas abstraction implementation | En curso (este ADR) |
| **Phase C** (ADR-002) | Mainnet readiness + Sepolia redeploy con cambios | Pendiente |
| **Phase 1** (WHITEPAPER) | Bootstrap network, single nodeit, Sepolia | Live |
| **Phase 2** (WHITEPAPER) | Multi-operator marketplace, mainnet | Post-audit |
| **Phase 3** (WHITEPAPER) | Governance + token-less DAO + cross-chain | Post-traction |

Mainnet launch (ADR-001) requiere completar Phase A + B + C + audit externo.

---

## 2. Decision

### 2.1 Mecanismo: ERC-3009 (`receiveWithAuthorization`)

USDC en Base implementa el estándar ERC-3009. La función relevante es:

```solidity
interface IERC3009 {
    function receiveWithAuthorization(
        address from,        // payer address
        address to,          // must == msg.sender (front-running protection)
        uint256 value,       // amount in USDC base units
        uint256 validAfter,  // unix timestamp; tx reverts if block.timestamp <= validAfter
        uint256 validBefore, // unix timestamp; tx reverts if block.timestamp >= validBefore
        bytes32 nonce,       // unique nonce; consumed atomically (replay protection)
        uint8 v, bytes32 r, bytes32 s  // EIP-712 signature
    ) external;
}
```

Front-running es imposible: `receiveWithAuthorization` requiere `msg.sender == to`. Solo el contrato destinatario (SettlementHub) puede consumir el nonce. Esto es **estrictamente mejor** que `permit` (donde había que envolver en try/catch para evitar el front-run benigno).

> **Actualización (PR #148/#149) — soporte de smart wallets vía ERC-1271.** El overload de 9 args con `(uint8 v, bytes32 r, bytes32 s)` solo valida firmas de **EOA** (vía `ecrecover`). Las smart wallets (Coinbase Smart Wallet, Safe, …) firman con **ERC-1271** y no pueden producir una firma ECDSA de 65 bytes — al pagar con una salía `invalid signature length: 992 bytes`. USDC en Base es **FiatTokenV2_2**, que expone un segundo overload `receiveWithAuthorization(…, bytes signature)` validado por `SignatureChecker`, el cual acepta **EOA (ECDSA) y contratos (ERC-1271)** con un único camino. SettlementHub migró su `Authorization` a `bytes signature` y llama a este overload; EOAs y smart wallets comparten el mismo flujo. El contrato se **redesplegó standalone** (nueva dirección, mismos args de constructor; StakeManager/NodeRegistry/DisputeResolver y el stake del nodeit intactos). Las cuentas **counterfactual** (smart wallet sin desplegar → firma envuelta en **ERC-6492**, ~992 bytes) quedan para una fase posterior: el settler deberá desplegar la cuenta antes de liquidar.

#### 2.1.1 Por qué `receiveWithAuthorization` y NO `transferWithAuthorization`

USDC implementa **ambas** funciones del estándar ERC-3009:

| Función | Quién puede llamar | Uso |
|---|---|---|
| `transferWithAuthorization(from, to, value, ..., v, r, s)` | **Cualquiera** (no enforza msg.sender) | Meta-tx genérica payer→payee |
| `receiveWithAuthorization(from, to, value, ..., v, r, s)` | **Solo `to`** (USDC enforza `msg.sender == to`) | Pull pattern hacia un contrato específico |

Elegimos `receiveWithAuthorization` deliberadamente:

1. **Anti front-running on-chain**: con `transferWithAuthorization`, un atacante que observe la firma en mempool puede llamarla antes que el nodeit y dirigir los USDC a un contrato malicioso o consumir el nonce antes que SettlementHub. `receiveWithAuthorization` lo previene a nivel del contrato USDC — solo SettlementHub puede invocarla apuntando a sí mismo.
2. **Garantía atómica del split**: como SettlementHub es quien hace `receiveWithAuthorization` + `_payAndSettle` en la misma tx, no hay ventana donde los USDC estén en el contrato sin haberse split. Con `transferWithAuthorization` un actor externo podría enviar los USDC al hub sin trigger del split.
3. **Auditoría trivial**: el patrón `receive...` es bien conocido (Compound, Aave, Uniswap lo usan para deposits seguros). Auditor lee, entiende, no preguntas.

Documentado para audit: la elección de `receive` over `transfer` es **un decisión consciente de diseño**, no un descuido. Protocolos similares que usan `transferWithAuthorization` ingenuamente han tenido vulns de front-running (e.g., issues conocidos en early integraciones de relayer-as-a-service).

### 2.2 Nuevas funciones: `payIntentWithAuthorization` + batch

Agregar al `SettlementHub.sol`:

```solidity
function payIntentWithAuthorization(
    bytes32 intentId,
    address payer,
    uint256 validAfter,
    uint256 validBefore,
    bytes32 nonce,
    uint8 v,
    bytes32 r,
    bytes32 s
) external nonReentrant {
    address merchant_ = _intents[intentId].merchant;
    if (merchant_ == address(0)) revert IntentNotFound();
    uint256 amount_ = _intents[intentId].amount;

    // ERC-3009 receiveWithAuthorization pulls USDC from payer to this contract.
    // Front-running impossible: USDC enforces msg.sender == to.
    // Payer mismatch impossible: USDC verifies signature against (from, to, amount, ...) tuple.
    IERC3009(address(usdc)).receiveWithAuthorization(
        payer, address(this), amount_,
        validAfter, validBefore, nonce, v, r, s
    );

    // Same atomic split as payIntent / payIntentWithPermit.
    _payAndSettle(intentId, payer);
}

/// @notice Batched gasless settlement for x402 micropayments. Skip-on-failure
///         semantics: a failing authorization (expired, nonce reused,
///         insufficient balance) is silently skipped; the rest proceed.
///         Returns count of successful settlements.
function payIntentBatchWithAuthorization(
    bytes32[] calldata intentIds,
    address[] calldata payers,
    uint256[] calldata validAfters,
    uint256[] calldata validBefores,
    bytes32[] calldata nonces,
    uint8[] calldata vs,
    bytes32[] calldata rs,
    bytes32[] calldata ss
) external nonReentrant returns (uint256 settled) {
    uint256 len = intentIds.length;
    if (
        payers.length != len || validAfters.length != len || validBefores.length != len ||
        nonces.length != len || vs.length != len || rs.length != len || ss.length != len
    ) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < len; ++i) {
        // Reuse single-intent path for atomicity per element.
        // try/catch wraps so one bad auth doesn't poison the whole batch.
        try this._payOneAuthorized(
            intentIds[i], payers[i],
            validAfters[i], validBefores[i],
            nonces[i], vs[i], rs[i], ss[i]
        ) {
            unchecked { ++settled; }
        } catch {
            // skip-on-failure (matches registerIntentBatch semantics)
        }
    }
}

/// @dev External-only re-entry point used for try/catch inside batch.
///      Not callable externally by mistake — the function checks msg.sender == address(this).
function _payOneAuthorized(
    bytes32 intentId, address payer,
    uint256 validAfter, uint256 validBefore,
    bytes32 nonce, uint8 v, bytes32 r, bytes32 s
) external {
    if (msg.sender != address(this)) revert Forbidden();
    address merchant_ = _intents[intentId].merchant;
    if (merchant_ == address(0)) revert IntentNotFound();
    uint256 amount_ = _intents[intentId].amount;

    IERC3009(address(usdc)).receiveWithAuthorization(
        payer, address(this), amount_,
        validAfter, validBefore, nonce, v, r, s
    );
    _payAndSettle(intentId, payer);
}
```

**Patrón skip-on-failure del batch**: idéntico al `registerIntentBatch` ya existente. Una autorización inválida (firma mal, nonce reusado, expirada, balance insuficiente) no revierte todo el batch — se salta y las demás proceden. Devuelve count de settlements exitosos. Crítico para x402 micropagos donde el operator agrupa N pagos y no quiere que 1 fallo cancele el resto.

**Por qué `_payOneAuthorized` como external + self-call**: necesario para que `try/catch` capture el revert del `receiveWithAuthorization` interno. Solidity solo permite try/catch sobre external calls. La protección `msg.sender == address(this)` evita que cualquiera lo invoque directamente.

Coexiste con `payIntent` y `payIntentWithPermit` — no las reemplaza. Cuatro caminos de pago:
- **`payIntent`**: payer ya hizo `usdc.approve()` y tiene ETH. Caso básico para wallets que ya holdean USDC + ETH.
- **`payIntentWithPermit`**: payer tiene ETH pero quiere ahorrarse el `approve` (1 tx menos).
- **`payIntentWithAuthorization`** (nuevo): payer NO tiene ETH ni hace approve. Solo firma EIP-712 off-chain. El nodeit submite + paga gas.
- **`payIntentBatchWithAuthorization`** (nuevo): N autorizaciones gasless en 1 tx. x402 micropagos. El nodeit amortiza el gas entre N pagos.

#### 2.2.1 Constraints explícitas del batch

| Constraint | Valor | Razón |
|---|---|---|
| **Max autorizaciones por batch** | **50** (enforce con `revert BatchTooLarge` si `len > 50`) | Block gas limit Base = 30M. Single payIntentWithAuthorization estimado ~150K gas → 50 × 150K = 7.5M, con safety margin 4x antes del block limit |
| **Restricciones de merchant/operator** | **Ninguna** — autorizaciones de cualquier combinación de payers/merchants/operators | Maximiza utilidad: el nodeit puede juntar pagos de distintos merchants en 1 batch para amortizar gas |
| **Restricciones de orden interno** | **Ninguna** | Cada nonce es independiente; el orden no afecta validity |
| **Nonces duplicados intencionalmente** | Skip-on-failure los maneja | USDC revierte el segundo (nonce ya consumido); el `try/catch` lo captura; el batch sigue |
| **Atomicidad** | Per-autorización dentro del batch (no global) | Una autorización fallida no rolls-back las settled. `nonReentrant` cubre todo el batch externamente |
| **Returns** | `uint256 settled` = count de settlements exitosos | El SDK / daemon usa este número para reconciliar qué pagos fueron procesados |

#### 2.2.2 Gas estimates (validados empíricamente en Phase B1)

Medidos con `forge snapshot` post-implementación (PR de Phase B1, MockUSDCAuth + 21 unit tests):

| Operación | Gas total (test) | Gas marginal por intent | Cost @ 20 gwei en Base (~$3000/ETH) |
|---|---|---|---|
| `payIntentWithAuthorization` (single) | 204K (incluye setup) | **~150K** | **~$0.009** |
| `payIntentBatchWithAuthorization` (5 items) | 590K total | **~118K** amortizado | $0.071 total → $0.014 por pago |
| `payIntentBatchWithAuthorization` (50 items, max — extrapolado) | ~5.5M | **~110K** amortizado | $0.66 total → $0.013 por pago |

**Comparativa con el path tradicional** (de `.gas-snapshot`):
- `registerIntent` solo: ~73K (~$0.0044)
- `payIntent` con USDC ya approved: ~120K (~$0.0072)
- `payIntentWithPermit`: ~170K (~$0.010)
- `payIntentWithAuthorization`: ~150K (~$0.009) — competitivo con permit

**Nota**: estos costos son lower bound. Bajo congestion temporal de Base (gas spike a 50-100 gwei), el costo single sube a $0.022-$0.045 — sigue dentro del break-even de ~$3.50 para pagos típicos LATAM, pero el operator policy debe ajustarse (§2.3 disclaimer).

### 2.3 Quién paga el gas

El **nodeit** que recibió el intent submite `payIntentWithAuthorization` y paga el gas en ETH. Recupera el costo de su 0.7% de fee.

Análisis económico (Base mainnet, gas baseline ~10-30 gwei → costo ~$0.015-0.025 por tx):

| Pago | Fee nodeit (0.7%) | Gas | Margen neto |
|---|---|---|---|
| $1 | $0.007 | $0.025 | -$0.018 (declinar) |
| $3 | $0.021 | $0.025 | -$0.004 (declinar) |
| $5 | $0.035 | $0.025 | +$0.010 |
| $10 | $0.070 | $0.025 | +$0.045 |
| $50 | $0.350 | $0.025 | +$0.325 |
| $100 | $0.700 | $0.025 | +$0.675 |

**Break-even ≈ $3.50 por pago.** Promedio LATAM remittance ($30-100) está cómodamente arriba. Para sub-$3 payments, el nodeit puede:
- Declinar el intent
- Ofrecer settlement batched (`payIntentBatchWithAuthorization` — implementado en Phase B per Q2)
- Cobrar el gas explícitamente al merchant (out of scope para v1)

**Disclaimer de congestion**: la tabla asume Base baseline (~10-30 gwei). Bajo congestion temporal (NFT mint, market events) el gas puede subir 3-10x. En esos casos, el nodeit aplica policy individual (rechazar single intents bajo break-even dinámico, aumentar threshold del batch, pausar aceptación). Esto es **policy operacional del nodeit, no enforce del protocolo** — el contrato siempre acepta cualquier `payIntentWithAuthorization` válida.

**Footnote sobre tx fallidas**: el break-even de $3.50 asume 100% success rate. Si el nodeit experimenta ~1-2% de tx fallidas (gas spike, revert, RPC issues), el operator pagó gas pero no consumió el nonce (puede re-submit). El break-even efectivo sube ~1-3% → ~$3.55-$3.60. Failure rates >10% serían señal de problema operacional, no de diseño económico.

### 2.4 USDC: solo native Circle USDC en Base

OpenRelay opera **exclusivamente sobre Circle's native USDC en Base mainnet** (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`) y su contraparte Sepolia. Estas variantes implementan ERC-3009 completo (Circle published, audit-trail desde 2022).

**No soportadas explícitamente** (out-of-scope para v1):
- USDbC (USD Base Coin, bridged) — siendo deprecado por Circle, sin soporte ERC-3009 garantizado
- USDC bridged en otras L2/L1 (e.g. Polygon PoS USDC) — implementación non-standard de `transferWithAuthorization` documentada por Circle
- Cualquier wrapped USDC

Si en Phase 3 se considera multi-chain, requiere ADR aparte que evalúe la implementación de ERC-3009 en cada variante.

#### 2.4.1 Dominio EIP-712 de USDC — `name` es per-chain

⚠️ **Crítico para el paso a mainnet.** El `name` del dominio EIP-712 que USDC verifica en `receiveWithAuthorization` **no es el mismo en mainnet y testnet** — verificado on-chain vía `name()`:

| Chain | USDC `name()` |
|---|---|
| Base mainnet (`0x8335…2913`) | `USD Coin` |
| Base Sepolia (`0x036C…CF7e`) | `USDC` |

Firmar con el `name` equivocado produce una firma que el validador off-chain **acepta** (si usa el mismo valor equivocado) pero que USDC **revierte on-chain** con `FiatTokenV2: invalid signature`. Esto pasó en Phase B5: ambos lados hardcodeaban `'USD Coin'`, así que coincidían entre sí pero no con el USDC de Sepolia.

Mitigación: los valores viven en un único origen — `USDC_DOMAIN_NAMES` en `@lacasoft/openrelay-protocol` (`erc3009.ts`) — consumido por el SDK (firma) y la API (verificación). La tabla **ya incluye ambos chains**, así que habilitar `chain: 'base'` no requiere cambiar nada. `eip712.test.ts` afirma cada valor por chain, de modo que CI bloquea cualquier regresión antes de mainnet.

### 2.5 Off-chain changes

| Componente | Cambio |
|---|---|
| `SettlementHub.sol` | + `payIntentWithAuthorization` (~30 LoC). + `payIntentBatchWithAuthorization` + `_payOneAuthorized` (~50 LoC). + `IERC3009` interface (~15 LoC). |
| `packages/sdk-js` | + helper para construir + firmar EIP-712 `ReceiveWithAuthorization` (single + batch). + cliente que envía la firma a la API. |
| `packages/api` | + endpoint `POST /v1/payment_intents/:id/authorize` (single) y `POST /v1/payment_intents/batch/authorize` (batch). |
| `packages/node` | + services que consumen autorizaciones pendientes y submitean `payIntentWithAuthorization` / `payIntentBatchWithAuthorization` al hub. + monitoreo de ETH balance y auto-pause (§5.4). |
| `packages/dashboard` | + indicador "gas-free for payer" en el flujo de checkout. |

---

## 3. Comparación honesta vs Circle Paymaster

| Dimensión | Circle Paymaster (ADR-002) | ERC-3009 (ADR-003) |
|---|---|---|
| Dependencias externas | Circle (paymaster) + Pimlico (bundler) | **Ninguna** — solo el contrato USDC nativo |
| Soporte de wallets | Solo wallets EIP-7702 (Metamask post-Pectra, Coinbase, Trust) | **Cualquier wallet que firme EIP-712** (= todas, incluido Ledger/Trezor) |
| Smart-account requerido | Sí, vía EIP-7702 delegation | **No** |
| Surcharge sobre gas | ~10% Circle + ~10% Pimlico ≈ **21%** | **0%** |
| Quién paga gas | Payer (en USDC, dentro de la tx) | Nodeit (en ETH, recupera del 0.7%) |
| Latencia extra | UserOp via bundler ~1-3s | **Tx directa, sin overhead** |
| Cambios en contrato | Ninguno (usa `payIntentWithPermit`) | + 1 función + 1 interface |
| Cambios en SDK | LARGO (UserOp, EIP-7702 detect, bundler, doble permit) | MEDIO (1 firma EIP-712) |
| Failure mode externo | Circle paymaster sin gas → **todas las tx fallan** | Nodeit sin ETH → **solo sus intents** fallan (failover via routing) |
| Audit scope | SDK valida UserOps + bundler chain | 1 función nueva en mismo contrato (patrón conocido) |
| Consistencia con tesis | Introduce 4337 stack a un sistema EOA-native | **Refuerza** USDC native + non-custodial |
| Alignment con x402 | Indirecto (x402 usa ERC-3009, no Paymaster) | **Directo** — x402 facilitator pattern |

---

## 4. Por qué ERC-3009 es la decisión correcta

1. **Cero vendor lock-in**. Circle Paymaster depende de Circle (que el contrato siga refilled) y Pimlico (que el bundler siga vivo). ERC-3009 depende solo del contrato USDC — el mismo de cuyo valor depende todo OpenRelay. Si USDC cae, OpenRelay cae igual con o sin paymaster.

2. **Mass-market wallets, sin discriminación**. EIP-7702 es de mayo 2025; muchos hardware wallets aún no lo soportan en firmware. ERC-3009 funciona con **cualquier wallet** que firme EIP-712 — un estándar de 2018. Esto es crítico para el target LATAM, donde gran parte del mercado usa wallets básicos o hardware.

3. **Sin surcharge externo**. Circle 10% + Pimlico 10% se acumulan sobre cada tx. En ERC-3009, el "surcharge" implícito = el gas que el nodeit absorbe (~$0.025), pero ya está cubierto por el 0.7% que cobra. El cost para el sistema es el mismo, pero **el dinero queda en el ecosistema OpenRelay** en vez de irse a Circle/Pimlico.

4. **Consistencia operacional**. El nodeit ya paga gas en ETH para `registerIntent`. Sumar `payIntentWithAuthorization` al mismo modelo es una extensión natural — no introduce un patrón nuevo (ERC-4337 UserOps, bundlers, paymasters) que requiera explicar a operadores chicos.

5. **Audit story más limpia**. Un auditor entiende `receiveWithAuthorization` (función estándar de USDC, hace 4 años en producción, miles de millones de USDC procesados) muchísimo mejor que el chain of trust SDK→bundler→EntryPoint→Paymaster→USDC. Menos preguntas, menos findings, menos costo.

6. **Alineación nativa con x402**. x402 facilitator pattern usa ERC-3009. Cuando implementemos x402 gasless real (no la versión post-facto verification actual), reusamos exactamente el mismo `payIntentWithAuthorization`.

---

## 5. Trade-offs honestos

### 5.1 Lo que cuesta más

- **Operator gas absorbe el costo.** Para pagos < $4 USDC en modo single, el nodeit pierde dinero por intent. Mitigación implementada en Phase B (no diferida): `payIntentBatchWithAuthorization` permite amortizar gas entre N pagos. Ejemplo: 100 micropagos de $0.01 en 1 batch tx (~$0.04 gas) → costo $0.0004 por pago = 4% del pago — viable.
- **Operador necesita mayor reserva ETH.** Antes solo `registerIntent` (~$0.005). Ahora también `payIntentWithAuthorization` (~$0.020) o batch (~$0.04 amortizado). Total operacional típico ~$0.025/intent single, $0.0004/intent batch. Reserva recomendada: $20-50 ETH para días de operación, según volumen.
- **Dos funciones más en el contrato = más superficie de audit.** ~30 LoC single + ~50 LoC batch + interface ~15 LoC. Costo audit incremental estimado $5-8k (vs ~$5-10k que ADR-002 estimaba para Circle Paymaster integration). **Comparable a más barato.**

### 5.2 Lo que NO se gana (vs Circle)

- **No subsidia gas para pagos < $4**. Si quisiéramos que cualquier pago micro sea viable para el payer sin que el nodeit pierda, hay que ir a batched settlement (Phase 3) o a x402 batched pattern. Circle Paymaster tampoco resuelve esto bien (el surcharge se aplica per-tx).
- **El payer no paga directamente su propio gas en USDC**. Si por alguna razón un payer **prefiere** pagar su propio gas en USDC (caso edge), Circle Paymaster lo permite y ERC-3009 no. No hemos visto demand para esto en research; el caso normal es "payer no quiere lidiar con gas en absoluto", que ERC-3009 cubre perfectamente.

### 5.3 Riesgos nuevos introducidos

- **Operator wallet ETH balance management**. Si el wallet del nodeit se queda sin ETH, sus intents pendientes fallan en submit. Mitigación: alertas en el daemon cuando ETH cae bajo threshold + UI en dashboard. Worst case: routing system falla over a otro nodeit (Phase 2 multi-operator).
- **Garbage authorizations**. Un payer malicioso podría firmar autorizaciones para intents que sabe que el nodeit no podrá ejecutar (ej. nonce ya usado). Mitigación: API valida que la authorization es bien-formada antes de encolar; daemon valida en simulate antes de submit; gas wasted es del nodeit pero está cubierto por su economic margin > 0.

### 5.4 Operator failure handling (operacional, no protocolo)

Tres comportamientos esperados del nodeit, todos **operacionales** (implementados en `packages/node`, no en `SettlementHub.sol`):

1. **Health monitoring + auto-pause**:
   - El daemon verifica ETH balance en cada submit (cheap RPC call cached ~30s)
   - Si balance < threshold (ej. equivalente a $5 USD en ETH), el daemon **deja de aceptar nuevas asignaciones** vía el endpoint `/v1/internal/intents/assign` (responde `{accepted: false, reason: "operator_low_funds"}`)
   - Las asignaciones existentes en queue siguen procesándose mientras haya gas
   - Un endpoint `/health` ya expuesto por el daemon refleja `status: "paused" | "active"` para que el routing layer lo lea

2. **Routing failover**:
   - El `routing` layer (`packages/api/src/services/routing.ts`) ya tiene el concept de "active operator set" (basado en stake + uptime)
   - Operadores en `paused` quedan excluidos del set elegible para nuevas asignaciones
   - Intents que ya fueron asignados a un operador ahora paused y no settled antes del `validBefore` window expiran naturalmente y el merchant recibe error
   - **No hay re-asignación automática** de un intent ya asignado — el merchant decide si re-crea el intent (`POST /v1/payment_intents` de nuevo)

3. **UX cuando un payer firma pero la authorization expira**:
   - El payer firma con `validBefore = now + 30 minutos` (default razonable)
   - Si el operator no settlea antes de eso, USDC.receiveWithAuthorization revierte con "authorization expired"
   - El SDK detecta la expiración (poll status del intent) y le pide al payer **firmar nuevamente** con un nonce nuevo y `validBefore` fresh
   - **No hay slashing** en v1 por no-settle. Si un nodeit acepta y no settlea sistemáticamente, su score baja → routing lo excluye orgánicamente

**Por qué NO slashing en v1**: agregar "didn't settle within window" como nuevo `DisputeType` requiere modificar `DisputeResolver.sol` + nuevo flow de dispute + audit ampliado. Es un trade-off entre rigor económico y scope. El score-based exclusion del routing layer es suficiente para Phase 1-2 con un único operador bootstrap. Si en Phase 3 con múltiples operadores observamos comportamiento adverso, ADR aparte propone el slashing.

---

## 6. Implementation plan

### Phase B1 — Contract (~2-3 días)

| Tarea | Archivo |
|---|---|
| Agregar `IERC3009` interface | `packages/contracts/src/interfaces/IERC3009.sol` |
| Agregar `payIntentWithAuthorization` a SettlementHub | `packages/contracts/src/SettlementHub.sol` |
| Agregar `payIntentBatchWithAuthorization` + `_payOneAuthorized` (skip-on-failure) | mismo |
| Unit tests single (signature válida, expirada, nonce reused, payer mismatch) | `packages/contracts/test/SettlementHub.t.sol` |
| Unit tests batch (mix ok/fail, all ok, all fail, length mismatch revert) | mismo |
| Invariants update (count settled = sum of successful in batch) | `packages/contracts/test/invariants/SettlementHub.invariants.t.sol` |
| Mock USDC con ERC-3009 implementation | `packages/contracts/test/mocks/MockUSDCAuth.sol` |
| `forge test`, `forge snapshot`, slither | full validation |

### Phase B2 — SDK (~3-5 días)

| Tarea | Archivo |
|---|---|
| EIP-712 domain fetch helper (USDC contract DOMAIN_SEPARATOR) | `packages/sdk-js/src/lib/eip712.ts` |
| `ReceiveWithAuthorization` single message builder + signer | `packages/sdk-js/src/resources/payment-intents.ts` |
| `ReceiveWithAuthorization` batch helper (firma múltiples autorizaciones cliente-side) | mismo |
| Wallet integration (viem `signTypedData`) | mismo |
| Submit signature al endpoint API (single + batch) | mismo |
| Tests de signing + edge cases (signer mismatch, malformed, batch composition) | `packages/sdk-js/src/__tests__/...` |

### Phase B3 — API (~2-3 días)

| Tarea | Archivo |
|---|---|
| Endpoint `POST /v1/payment_intents/:id/authorize` (single) | `packages/api/src/routes/payment-intents.ts` |
| Endpoint `POST /v1/payment_intents/batch/authorize` (batch, accepts array) | mismo |
| Validación off-chain de la authorization (recover signer, verifica intent existe, monto matches) | mismo |
| Persistencia + queue para el daemon (single + batch payload) | `packages/api/src/lib/repository.ts` (+ schema migration) |
| Tests | `packages/api/src/__tests__/routes/payment-intents.test.ts` |

### Phase B4 — Daemon (~3-4 días)

| Tarea | Archivo |
|---|---|
| Service que consume autorizaciones pendientes (single) | `packages/node/src/services/authorization-settler.ts` |
| Service de aggregation que detecta pagos chicos pendientes y los empaqueta en batch (configurable batch_size + batch_window_ms) | `packages/node/src/services/batch-settler.ts` |
| Construir + firmar tx `payIntentWithAuthorization` / `payIntentBatchWithAuthorization` con wallet del nodeit | mismo |
| Submit + monitor + retry con back-off (single + batch) | mismo |
| Alerta si ETH balance < threshold | mismo |
| Tests de integración | `packages/node/src/__tests__/...` |

### Phase B5 — E2E + redeploy Sepolia (~2-3 días)

| Tarea | Notas |
|---|---|
| Deploy nuevo SettlementHub en Sepolia | `forge script script/Deploy.s.sol` |
| Update `sepolia.json` con nueva address | History keeps prior orphans documented |
| E2E real: payer con Metamask sin ETH paga un intent vía firma | Validación visual del flujo |
| Update SCOPE.md con nueva función + interface | Para auditor |

---

## 7. Consequences

### 7.1 Positive

- **Cero dependencias externas**: sin Circle, sin Pimlico, sin EIP-7702 wallet support.
- **Universal wallet support**: cualquier wallet con EIP-712 (= todas las modernas, incluido Ledger/Trezor).
- **Sin surcharge**: los ~$0.005 que se irían a Circle/Pimlico se quedan en el ecosistema OpenRelay.
- **Audit más simple**: 1 función conocida vs UserOp + bundler chain of trust.
- **Failure mode localizado**: si un nodeit falla, falla local, no global (con Circle, si su paymaster cae, todo cae).
- **Alignment x402**: usamos exactamente el mecanismo nativo del estándar x402.
- **Refuerza tesis non-custodial**: USDC nativo, sin layers intermediarios.

### 7.2 Negative

- **Sub-$4 payments el nodeit pierde dinero** sin batched settlement (mitigación: threshold mínimo + Phase 3 batch function).
- **Operador necesita mayor reserva ETH** (~$25-50 ETH para operación día-a-día según volumen).
- **1 función nueva en el contrato** = 1 cosa más para auditar (~$3-5k incremental).
- **Daemon más complejo**: nuevo service de settlement + queue management.

### 7.3 Neutral

- **Fee structure intacto**: 100 bps 70/30 de ADR-002 §2.1 sin cambios.
- **`payIntent` y `payIntentWithPermit` siguen existiendo**: 3 caminos de pago coexisten, payer/SDK eligen el adecuado.
- **No bloquea x402 micropagos**: el patrón batched (Phase 3) está claro, no requiere arquitectura nueva.

---

## 8. Resolved decisions (formerly "open questions")

Las cuatro preguntas iniciales fueron resueltas el 2026-05-14 por el autor:

### Q1: Discovery del `payer` address — RESOLVED → (a) parámetro explícito

El SDK envía `(intentId, payer, validAfter, validBefore, nonce, v, r, s)`. La firma EIP-712 contiene el `from`, así que si el `payer` parameter no matchea, USDC.receiveWithAuthorization revierte automáticamente. La criptografía hace el enforcement gratis, sin gas extra y sin reinventar verificación. Es industry-standard de meta-transactions (EIP-2771 y similares pasan el originator como parámetro y dejan que la firma sea fuente de verdad). El intent permanece limpio: representa "merchant wants USDC", el payer aparece solo cuando alguien decide pagar — esto modela correctamente e-commerce y se alinea con x402.

### Q2: Batch en Phase B vs Phase 3 — RESOLVED → (b) implementar batch ahora

Razones del autor: (1) x402 micropagos son first-class según PROTOCOL.md y WHITEPAPER.md — no se puede sostener "x402 nativo" sin que economía cierre para sub-cent payments; (2) si el batch llega después, los nodeits que adopten gasless settlement van a operar con margen negativo en pagos chicos durante la transición y eso desincentiva adopción; (3) mejor un audit con la función completa que un follow-up audit incremental ($5-8k incremental ahora vs nuevo audit round + redeploy + migration concerns más tarde); (4) la función batch reusa el patrón skip-on-failure de `registerIntentBatch` ya auditado conceptualmente — no introduce un patrón nuevo.

### Q3: Endpoint `/v1/x402/verify` — RESOLVED → (a) coexistir

Mantener el endpoint actual de post-facto verification (sirve para flows donde el merchant integra contra mercados crypto-native ya familiarizados con tx_hash flow) y agregar `/v1/payment_intents/:id/authorize` (single + batch) para el flow gasless. Documentar el flow gasless como recomendado para nuevos integradores.

### Q4: Redeploy SettlementHub Sepolia — RESOLVED → (a) redeploy completo

SettlementHub v1 en Sepolia es testnet, sin valor real custodiado. Update `sepolia.json` con la nueva address. La versión vieja queda documentada como orphan en el JSON (preserva auditabilidad histórica). Phase B5 ejecuta esto al final.

---

## 9. References

- ADR-002: Fee structure recalibration + (now-superseded) Circle Paymaster decision (`audits/adr/002-fee-structure-and-gas-abstraction.md`)
- EIP-3009 spec: <https://eips.ethereum.org/EIPS/eip-3009>
- USDC v2.x source (Centre): <https://github.com/centrehq/centre-tokens/blob/master/contracts/v2/FiatTokenV2.sol>
- x402 protocol overview (Coinbase): <https://www.x402.org/>
- Pectra hardfork & EIP-7702 (Circle): <https://www.circle.com/blog/how-the-pectra-upgrade-is-unlocking-gasless-usdc-transactions-with-eip-7702>

---

## 10. Sign-off

- [x] Author (LACA-SOFT) — pivot from Circle Paymaster to ERC-3009 accepted (2026-05-14)
- [ ] Auditor pre-engagement review (when audit firm engaged)

Status: 🟢 **Accepted**. Implementation tracking:

- **Phase B1 (contract)**: PR pendiente — IERC3009 interface + payIntentWithAuthorization + payIntentBatchWithAuthorization + tests
- **Phase B2 (SDK)**: pendiente
- **Phase B3 (API)**: pendiente
- **Phase B4 (Daemon)**: pendiente
- **Phase B5 (Redeploy Sepolia + E2E)**: pendiente
