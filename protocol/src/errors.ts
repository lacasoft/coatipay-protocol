export type CoatiPayErrorCode =
  // Auth
  | 'invalid_api_key'
  | 'insufficient_permissions'
  | 'forbidden' // internal endpoints (HMAC/shared-secret auth failures)
  // Resource lifecycle
  | 'intent_not_found'
  | 'intent_expired'
  | 'intent_already_settled'
  | 'node_not_registered'
  // Validation
  | 'chain_not_supported'
  | 'amount_too_small'
  | 'amount_too_large'
  | 'invalid_webhook_url'
  | 'invalid_payment_payload' // x402 X-PAYMENT header malformed/undecodable
  // Routing & nodeit availability
  | 'no_nodes_available'
  | 'node_unavailable' // bootstrap reachable check failed in /v1/nodes
  // x402 payment
  | 'chain_verification_failed' // on-chain verification could not confirm transfer
  | 'insufficient_payment' // tx confirmed but amount below required
  | 'x402_replay' // tx_hash already used for a previous x402 settlement
  // Disputes
  | 'dispute_window_closed'

export interface CoatiPayError {
  code: CoatiPayErrorCode
  message: string
  param: string | null
  doc_url: string
}

export class CoatiPaySDKError extends Error {
  code: CoatiPayErrorCode
  param: string | null
  doc_url: string
  constructor(error: CoatiPayError) {
    super(error.message)
    this.name = 'CoatiPaySDKError'
    this.code = error.code
    this.param = error.param
    this.doc_url = error.doc_url
  }
}

const AUTH_CODES = new Set<CoatiPayErrorCode>([
  'invalid_api_key',
  'insufficient_permissions',
  'forbidden',
])
const VALIDATION_CODES = new Set<CoatiPayErrorCode>([
  'amount_too_small',
  'amount_too_large',
  'chain_not_supported',
  'invalid_webhook_url',
  'invalid_payment_payload',
])
const ROUTING_CODES = new Set<CoatiPayErrorCode>(['no_nodes_available', 'node_unavailable'])
const PAYMENT_CODES = new Set<CoatiPayErrorCode>([
  'chain_verification_failed',
  'insufficient_payment',
  'x402_replay',
])

/** API key missing, revoked, or lacking permissions. */
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

/** Transport-level failure: network unreachable, timeout, DNS error. */
export class NetworkError extends Error {
  cause: unknown
  constructor(message: string, cause: unknown) {
    super(message)
    this.name = 'NetworkError'
    this.cause = cause
  }
}

/** Build the narrowest typed error from a raw API error object. */
export function classifyError(error: CoatiPayError): CoatiPaySDKError {
  if (AUTH_CODES.has(error.code)) return new AuthError(error)
  if (VALIDATION_CODES.has(error.code)) return new ValidationError(error)
  if (ROUTING_CODES.has(error.code)) return new RoutingError(error)
  if (PAYMENT_CODES.has(error.code)) return new PaymentError(error)
  return new CoatiPaySDKError(error)
}
