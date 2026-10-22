import { describe, expect, it } from 'vitest'
import {
  DEFAULT_INTENT_TTL_SECONDS,
  MAX_EXPIRY_OFFSET,
  STAKE_WITHDRAWAL_TIMELOCK_DAYS,
  WITHDRAWAL_TIMELOCK,
} from '../src'

// Los valores salen del contrato (generate-fee-constants.ts, vigilado por
// check:fee-constants en CI). Aquí se prueba lo que el generador no comprueba:
// que lo que se deriva de ellos y lo que se usa con ellos encaja.
describe('constants taken from the contracts', () => {
  it('the default lifetime of a payment fits what the contract accepts to register', () => {
    // Si no cupiera, cada cobro creado con el plazo por defecto revertiría al
    // registrarse.
    expect(DEFAULT_INTENT_TTL_SECONDS).toBeLessThanOrEqual(MAX_EXPIRY_OFFSET)
  })

  it('the expiry limit is in seconds: 30 days', () => {
    expect(MAX_EXPIRY_OFFSET).toBe(30 * 24 * 60 * 60)
  })

  it('the withdrawal timelock in days is derived from the contract, in whole days', () => {
    expect(STAKE_WITHDRAWAL_TIMELOCK_DAYS).toBe(WITHDRAWAL_TIMELOCK / 86_400)
    expect(Number.isInteger(STAKE_WITHDRAWAL_TIMELOCK_DAYS)).toBe(true)
  })
})
