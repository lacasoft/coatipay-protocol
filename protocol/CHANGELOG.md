# Changelog

## 0.2.0 — sin publicar

For the contracts of ADR-009 («Una parte que falla no detiene a las demás»).
**Breaking**: the on-chain id of a payment, and so the nonce the payer signs,
now depends on the merchant's wallet. Use it with the new deployment only.

### Changed

- **The on-chain id of a payment carries the merchant.** It was
  `keccak256(utf8(pi_…))`; it is now
  `keccak256(abi.encode(merchantWallet, keccak256(utf8(pi_…))))`, the same as
  `SettlementHub.intentIdOf`. The payer's ERC-3009 nonce is that id, so the
  payer's signature now fixes the merchant too. Computing it needs the
  merchant's wallet.
- Shared vectors move to **format 2**: `nonce.json` cases carry `merchant` and
  `ref`, and its rejected cases add a zero and a malformed wallet;
  `autorizacion.json` inputs carry `merchant`.
- `PROTOCOL_VERSION` is `'0.2'`.
- **`PaymentIntent.merchant_wallet`** (required, nullable): the wallet the
  payment goes to, fixed at creation; what `intentIdOf` needs.

### Added

- **`intentRef(id)`** and **`intentIdOf(merchant, id)`**: the payment's
  reference and its on-chain id. Both throw on an empty id, a blank id or an id
  that is already a bytes32; `intentIdOf` also on a zero or malformed wallet.
- **`REGISTER_INTENT_TYPES`**, **`settlementHubDomain(chainId, hub)`** and
  **`RegisterIntentMessage`**: what `intentSigner` signs to authorize a
  registration. The type string (`REGISTER_INTENT_TYPE`) and the domain name and
  version are generated from `SettlementHub.sol`, like the fees.
- **`MIN_STAKE_DELAY`** (seconds, `604800` = 7 days), from `NodeRegistry`: the
  notice between proposing a new `minStake` and applying it.

The contracts' tests read `vectors/nonce.json` and require `intentIdOf` on
chain to give every nonce in it.

## 0.1.7 — 2026-10-22

### Added

- **`MAX_EXPIRY_OFFSET`** (seconds, `2592000` = 30 days): `SettlementHub` refuses
  to register an intent that expires further than this from the moment it is
  registered (`InvalidExpiry`). Off-chain code can now check an intent's
  lifetime against what the contract accepts, from the same source.
- **`WITHDRAWAL_TIMELOCK`** (seconds, `604800` = 7 days), from `StakeManager`.

Both are generated from the contracts, like the fee constants, and the CI gate
(`check:fee-constants`) now fails if either drifts. The generator understands
Solidity time units (`30 days`).

### Changed

- `STAKE_WITHDRAWAL_TIMELOCK_DAYS` is now derived from `WITHDRAWAL_TIMELOCK`
  instead of written by hand. Same value: 7.
- `MIN_STAKE_USDC` and `TARGET_STAKE_USDC` are documented as reference values,
  not on-chain invariants: the minimum in force is `NodeRegistry.minStake()`.
- `CreatePaymentIntentParams.expires_in` documents its limit: below
  `MAX_EXPIRY_OFFSET`.

## 0.1.6 — 2026-09-28

### Changed

- **`NetworkError` is now a `CoatiPaySDKError`** (code `network_error`), so one
  `catch` covers everything an API call throws, as in the Python and PHP SDKs.
  It gains `status`: the HTTP status of a response that is not a CoatiPay
  error, or `null` when there was no response. Code that checked
  `instanceof CoatiPaySDKError` before `instanceof NetworkError` now takes the
  first branch for network failures: check `NetworkError` first.
- `CoatiPaySDKError.code` is `CoatiPayErrorCode | SdkErrorCode`: the SDK sets
  `network_error` itself; the API never sends it.

### Added

- **`vectors/errores.json` → `respuestas`**: how an SDK reads the HTTP
  response of a call, or its absence (15 cases). A CoatiPay error is a JSON
  object whose `error` is an object with a non-empty `code`; anything else
  that is not a success — no response, a body that is not JSON (a proxy's HTML
  502, even a 2xx), a JSON error that is not CoatiPay's (Fastify's default) —
  is a `NetworkError` with its `status`. The three SDKs disagreed here: a
  `SyntaxError` in JS, a `JSONDecodeError` or a raw `httpx` exception in
  Python, an empty result for a 2xx that is not JSON in PHP.
- `docUrl(code)`: the reference page of an error code.

## 0.1.5 — 2026-09-28

### Changed

- **`vectors/nonce.json`: ids that must be rejected** (`rechazados`): empty,
  whitespace only, and an already-derived bytes32. Their hash is a nonce that
  looks valid and belongs to no intent, so an SDK must throw instead. Found by
  the vectors themselves: the JS and PHP SDKs signed a whitespace-only id,
  Python rejected it. The empty id, which 0.1.4 listed with a nonce, moves here.

## 0.1.4 — 2026-09-28

### Added

- **Shared vectors for the SDKs** (`vectors/`, published in the package): input
  and expected output that the JS, Python and PHP SDKs reproduce in their tests.
  - `nonce.json` — the authorization nonce is `keccak256` of the intent id's
    UTF-8 bytes, never the id read as hex.
  - `autorizacion.json` — per network: the USDC EIP-712 domain and its
    separator, the `ReceiveWithAuthorization` message, the digest, the
    signature with a public test key (low `s`, `v` 27/28) and the API body.
  - `webhooks.json` — 21 cases for the `X-Signature` check, with the reference
    semantics: strict `t`, any matching `v1` (secret rotation), inclusive
    tolerance, and a reason on failure.
  - `errores.json` — every catalog code with its HTTP status, category and SDK
    error class.

  Generated by `scripts/generar-vectores.ts` (viem and `node:crypto`), never by
  hand. CI checks they are up to date, and checks each network's domain
  separator against the USDC deployed there (`DOMAIN_SEPARATOR()`).

## 0.1.3 — 2026-09-28

### Removed

- **The `failed` status and the `payment_intent.failed` event.** Nothing ever
  set an intent to `failed` or sent that event: a payment that does not go
  through leaves the intent `created`, still payable until it expires. Code
  that branches on either no longer type-checks — that branch never ran.

### Added

- **`payment_in_progress` (409, `conflict`)**: the intent cannot be cancelled
  because a payment for it is being settled on-chain. It ends `settled`, or
  cancellable again if that payment fails.
- The lifecycle is documented on `PaymentIntentStatus`, and the delivery
  guarantees on `WebhookEventType`: at least once, not ordered, and a
  `payment_intent.settled` can follow an `expired` or `cancelled` one — the
  chain has the last word.

## 0.1.2 — 2026-09-28

### Changed

- **The error codes are now a catalog, and match what the API returns.**
  `CoatiPayErrorCode` listed five codes the API no longer returns and lacked
  about twenty it does — every signature-validation reason, `invalid_request`,
  `not_found`, `idempotency_key_reused`… — so a TypeScript integration was
  typed against errors it could never see.

  `ERROR_CATALOG` is now the single source of truth: every code the API can
  return, with the HTTP status it always comes with and a category.
  `CoatiPayErrorCode` is derived from it. The API can only answer with a code
  from this catalog, and each code has a reference page at
  `https://coatipay.com/docs/errors/<code>`, checked against the catalog in CI.

  Removed (never returned): `amount_too_small`, `amount_too_large`,
  `chain_not_supported`, `intent_expired`, `no_nodes_available`. Code comparing
  against them no longer type-checks, which is the point: that branch never
  ran.

  New: `rate_limited` (429). The API used to label a rate-limited request
  `invalid_request`.

- **`classifyError` classifies by category.** More codes map to their class:
  `invalid_session` and `invalid_token` → `AuthError`; every validation reason
  and `invalid_request` → `ValidationError`. A new `RateLimitError` for
  `rate_limited`. Every class still extends `CoatiPaySDKError`, and a code this
  version does not know (a newer API) gives a plain `CoatiPaySDKError` instead
  of failing.

### Added

- A test suite (`npm test`), run in CI. The package had none.

## 0.1.1 — 2026-09-25

### Changed

- **Protocol fee constants now reflect ADR-005.** `0.1.0` still shipped the
  pre-ADR-005 values, so anything installing this package read a fee the
  contract no longer charges.

  | | 0.1.0 | 0.1.1 |
  |---|---|---|
  | `PROTOCOL_FEE_BPS` | 100 | **150** |
  | `TREASURY_SHARE_BPS` | 30 | **45** |
  | `OPERATOR_SHARE_BPS` | 70 | **105** |

  The 70/30 split between routing node and treasury is unchanged; the merchant
  now receives **98.5%**.

  These values are generated from `SettlementHub.sol` and guarded by a CI drift
  gate — they are never written by hand. The gap was that the package was not
  republished after the contract changed, not that the values diverged in the
  repository.

  ADR-005:
  https://github.com/lacasoft/coatipay-protocol/blob/master/audits/adr/005-comision-al-1-5-por-ciento.md
