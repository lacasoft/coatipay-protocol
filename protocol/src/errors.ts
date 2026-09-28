/**
 * Every error code the CoatiPay API can return: the single source of truth.
 *
 * - The API can only answer with a code from this catalog, and with its HTTP
 *   status: the status comes from here, not from each route.
 * - Every code has a public reference page at
 *   `https://coatipay.com/docs/errors/<code>` (the `doc_url` of every error
 *   response). The docs site is checked against this catalog in CI.
 * - The SDKs classify errors by `category`.
 *
 * Adding a code means adding it here, publishing this package, and publishing
 * its reference page — before the API can emit it.
 */

/** What kind of problem the error reports. Drives `classifyError`. */
export type ErrorCategory =
  /** The credentials are missing, invalid, or not enough for the action. */
  | 'auth'
  /** The request is malformed or its values are not acceptable. */
  | 'validation'
  /** The resource does not exist, or does not belong to the caller. */
  | 'not_found'
  /** The request is valid, but conflicts with the current state. */
  | 'conflict'
  /** An x402 payment could not be verified, or was already used. */
  | 'payment'
  /** No routing node is reachable. */
  | 'routing'
  /** Too many requests: wait and retry. */
  | 'rate_limit'
  /** A dependency (the chain) did not answer: retry. */
  | 'unavailable'
  /** Unexpected server error. */
  | 'internal'

export interface ErrorDefinition {
  /** The HTTP status the API returns this code with. Always the same. */
  http: number
  category: ErrorCategory
}

export const ERROR_CATALOG = {
  // ── Authentication ─────────────────────────────────────────────
  invalid_api_key: { http: 401, category: 'auth' },
  insufficient_permissions: { http: 403, category: 'auth' },
  /** Operator authentication failed on the node↔API channel. */
  forbidden: { http: 403, category: 'auth' },
  session_required: { http: 403, category: 'auth' },
  invalid_session: { http: 401, category: 'auth' },
  /** A magic-link or access token that is invalid or expired. */
  invalid_token: { http: 401, category: 'auth' },

  // ── Validation ─────────────────────────────────────────────────
  invalid_request: { http: 400, category: 'validation' },
  /** Below the minimum payable amount: settling it would cost more gas than it earns. */
  amount_below_minimum: { http: 400, category: 'validation' },
  invalid_webhook_url: { http: 400, category: 'validation' },
  /** The x402 `X-PAYMENT` payload is malformed or undecodable. */
  invalid_payment_payload: { http: 400, category: 'validation' },
  authorization_expired: { http: 400, category: 'validation' },
  authorization_not_yet_valid: { http: 400, category: 'validation' },
  /** The authorization's nonce is not the intent's on-chain id (ADR-004). */
  authorization_not_bound_to_intent: { http: 400, category: 'validation' },
  /** The signature is not valid for the claimed payer. */
  invalid_signer: { http: 400, category: 'validation' },
  unsupported_chain: { http: 400, category: 'validation' },
  /** A signature format the chain cannot settle (ERC-8010). */
  unsupported_signature: { http: 400, category: 'validation' },

  // ── Not found ──────────────────────────────────────────────────
  intent_not_found: { http: 404, category: 'not_found' },
  not_found: { http: 404, category: 'not_found' },
  node_not_registered: { http: 404, category: 'not_found' },
  /** Node↔API channel: the authorization is not claimed by the caller. */
  authorization_not_claimed: { http: 404, category: 'not_found' },

  // ── Conflict with the current state ────────────────────────────
  intent_already_settled: { http: 409, category: 'conflict' },
  /**
   * The intent cannot be cancelled now: a payment for it is being settled
   * on-chain. It ends `settled`, or cancellable again if that payment fails.
   */
  payment_in_progress: { http: 409, category: 'conflict' },
  /** Already settled, cancelled or expired. */
  intent_not_payable: { http: 400, category: 'conflict' },
  nonce_already_used: { http: 409, category: 'conflict' },
  /** The same Idempotency-Key was used with different parameters. */
  idempotency_key_reused: { http: 409, category: 'conflict' },
  webhook_endpoint_deleted: { http: 409, category: 'conflict' },
  email_taken: { http: 409, category: 'conflict' },
  already_reviewed: { http: 409, category: 'conflict' },

  // ── x402 payment ───────────────────────────────────────────────
  /** On-chain verification could not confirm the transfer. */
  chain_verification_failed: { http: 402, category: 'payment' },
  /** The transfer was confirmed, but for less than required. */
  insufficient_payment: { http: 402, category: 'payment' },
  /** The transaction was already used for a previous x402 payment. */
  x402_replay: { http: 409, category: 'payment' },

  // ── Availability ───────────────────────────────────────────────
  /** The bootstrap routing node did not answer. */
  node_unavailable: { http: 502, category: 'routing' },
  rate_limited: { http: 429, category: 'rate_limit' },
  /** The chain could not be asked to verify a smart-wallet signature. Retry. */
  signature_unverifiable: { http: 503, category: 'unavailable' },
  internal_error: { http: 500, category: 'internal' },
} as const satisfies Record<string, ErrorDefinition>

/** A code the API can return. Derived from the catalog, so it cannot drift. */
export type CoatiPayErrorCode = keyof typeof ERROR_CATALOG

export interface CoatiPayError {
  code: CoatiPayErrorCode
  message: string
  param: string | null
  doc_url: string
}

/**
 * A code the SDK sets itself. The API never sends it, so it is not in the
 * catalog; it has a reference page all the same.
 */
export type SdkErrorCode = 'network_error'

/**
 * Every error an API call throws: the API's, classified by `classifyError`,
 * and `NetworkError` when there was no CoatiPay answer. One `catch` covers
 * them all, as in every CoatiPay SDK.
 */
export class CoatiPaySDKError extends Error {
  code: CoatiPayErrorCode | SdkErrorCode
  param: string | null
  doc_url: string
  constructor(error: CoatiPayError | (Omit<CoatiPayError, 'code'> & { code: SdkErrorCode })) {
    super(error.message)
    this.name = 'CoatiPaySDKError'
    this.code = error.code
    this.param = error.param
    this.doc_url = error.doc_url
  }
}

/** API key missing, revoked, or lacking permissions; or an invalid session or token. */
export class AuthError extends CoatiPaySDKError {
  constructor(error: CoatiPayError) {
    super(error)
    this.name = 'AuthError'
  }
}

/** Request parameters failed server-side validation. */
export class ValidationError extends CoatiPaySDKError {
  constructor(error: CoatiPayError) {
    super(error)
    this.name = 'ValidationError'
  }
}

/** No nodeit available to route the payment, or bootstrap nodeit unreachable. */
export class RoutingError extends CoatiPaySDKError {
  constructor(error: CoatiPayError) {
    super(error)
    this.name = 'RoutingError'
  }
}

/** x402 payment verification failed: chain mismatch, insufficient amount, or replay. */
export class PaymentError extends CoatiPaySDKError {
  constructor(error: CoatiPayError) {
    super(error)
    this.name = 'PaymentError'
  }
}

/** Too many requests. Wait before retrying (the response carries `Retry-After`). */
export class RateLimitError extends CoatiPaySDKError {
  constructor(error: CoatiPayError) {
    super(error)
    this.name = 'RateLimitError'
  }
}

/**
 * The request got no CoatiPay answer: no response at all (network, DNS,
 * timeout: `status` is `null`), or a response that is not a CoatiPay error
 * (a proxy's HTML 502, a body that is not JSON: `status` is its HTTP status).
 * Whether the request took effect is unknown: before retrying a write, check.
 * Code `network_error`. The rule is shared by every CoatiPay SDK
 * (`vectors/errores.json`, `respuestas`).
 */
export class NetworkError extends CoatiPaySDKError {
  /** The HTTP status of the response, or `null` if there was none. */
  status: number | null
  cause: unknown
  constructor(message: string, cause: unknown, status: number | null = null) {
    super({ code: 'network_error', message, param: null, doc_url: docUrl('network_error') })
    this.name = 'NetworkError'
    this.cause = cause
    this.status = status
  }
}

/** The reference page of an error code. */
export function docUrl(code: string): string {
  return `https://coatipay.com/docs/errors/${code}`
}

/**
 * Build the narrowest typed error from a raw API error object. A code this
 * version of the package does not know (a newer API) becomes a plain
 * `CoatiPaySDKError`, never a crash.
 */
export function classifyError(error: CoatiPayError): CoatiPaySDKError {
  const definicion = (ERROR_CATALOG as Record<string, ErrorDefinition>)[error.code]
  switch (definicion?.category) {
    case 'auth':
      return new AuthError(error)
    case 'validation':
      return new ValidationError(error)
    case 'routing':
      return new RoutingError(error)
    case 'payment':
      return new PaymentError(error)
    case 'rate_limit':
      return new RateLimitError(error)
    default:
      return new CoatiPaySDKError(error)
  }
}
