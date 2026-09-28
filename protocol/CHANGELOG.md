# Changelog

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
