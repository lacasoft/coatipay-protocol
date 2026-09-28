import { describe, expect, it } from 'vitest'
import {
  AuthError,
  type CoatiPayError,
  CoatiPaySDKError,
  classifyError,
  ERROR_CATALOG,
  type ErrorCategory,
  NetworkError,
  PaymentError,
  RateLimitError,
  RoutingError,
  ValidationError,
} from '../src/errors'

const error = (code: string): CoatiPayError => ({
  code: code as CoatiPayError['code'],
  message: 'm',
  param: null,
  doc_url: `https://coatipay.com/docs/errors/${code}`,
})

describe('ERROR_CATALOG', () => {
  it('every code has an HTTP error status and a known category', () => {
    const categorias: ErrorCategory[] = [
      'auth',
      'validation',
      'not_found',
      'conflict',
      'payment',
      'routing',
      'rate_limit',
      'unavailable',
      'internal',
    ]
    for (const [codigo, d] of Object.entries(ERROR_CATALOG)) {
      expect(d.http, codigo).toBeGreaterThanOrEqual(400)
      expect(d.http, codigo).toBeLessThan(600)
      expect(categorias, codigo).toContain(d.category)
      expect(codigo, 'snake_case, as it appears in the doc URL').toMatch(/^[a-z0-9]+(_[a-z0-9]+)*$/)
    }
  })

  it('codes the API no longer returns are gone', () => {
    for (const viejo of [
      'amount_too_small',
      'amount_too_large',
      'chain_not_supported',
      'intent_expired',
      'no_nodes_available',
    ]) {
      expect(ERROR_CATALOG).not.toHaveProperty(viejo)
    }
  })

  it('every status is the one the API uses for it', () => {
    // A few pinned on purpose: the public docs had them wrong.
    expect(ERROR_CATALOG.intent_not_found.http).toBe(404)
    expect(ERROR_CATALOG.rate_limited.http).toBe(429)
    expect(ERROR_CATALOG.signature_unverifiable.http).toBe(503)
    expect(ERROR_CATALOG.chain_verification_failed.http).toBe(402)
    expect(ERROR_CATALOG.session_required.http).toBe(403)
    expect(ERROR_CATALOG.payment_in_progress.http).toBe(409)
  })
})

describe('classifyError', () => {
  it.each([
    ['invalid_api_key', AuthError],
    ['invalid_token', AuthError],
    ['invalid_request', ValidationError],
    ['invalid_signer', ValidationError],
    ['amount_below_minimum', ValidationError],
    ['node_unavailable', RoutingError],
    ['x402_replay', PaymentError],
    ['rate_limited', RateLimitError],
  ] as const)('%s → %s', (codigo, clase) => {
    const e = classifyError(error(codigo))
    expect(e).toBeInstanceOf(clase)
    expect(e).toBeInstanceOf(CoatiPaySDKError)
    expect(e.code).toBe(codigo)
  })

  it('categories without their own class give the base error', () => {
    for (const codigo of ['intent_not_found', 'idempotency_key_reused', 'internal_error']) {
      const e = classifyError(error(codigo))
      expect(e.constructor).toBe(CoatiPaySDKError)
    }
  })

  it('a code this version does not know (a newer API) does not crash', () => {
    const e = classifyError(error('some_future_code'))
    expect(e).toBeInstanceOf(CoatiPaySDKError)
    expect(e.code).toBe('some_future_code')
  })
})

describe('NetworkError', () => {
  it('is a CoatiPaySDKError with code network_error, so one catch covers every call', () => {
    const causa = new TypeError('fetch failed')
    const e = new NetworkError('Network error', causa)
    expect(e).toBeInstanceOf(CoatiPaySDKError)
    expect(e).toBeInstanceOf(Error)
    expect(e.name).toBe('NetworkError')
    expect(e.code).toBe('network_error')
    expect(e.param).toBeNull()
    expect(e.doc_url).toBe('https://coatipay.com/docs/errors/network_error')
    expect(e.cause).toBe(causa)
    expect(e.status).toBeNull()
  })

  it('carries the HTTP status of a response that is not a CoatiPay error', () => {
    expect(new NetworkError('Bad gateway', undefined, 502).status).toBe(502)
  })
})
