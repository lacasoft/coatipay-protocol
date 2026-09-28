import { describe, expectTypeOf, it } from 'vitest'
import type { PaymentIntentStatus, WebhookEventType } from '../src'

// Comprobaciones de tipos: las verifica `tsc` (npm run typecheck), no vitest.
describe('public states and events', () => {
  it('there is no failed state', () => {
    expectTypeOf<PaymentIntentStatus>().toEqualTypeOf<
      'created' | 'settled' | 'expired' | 'cancelled'
    >()
  })

  it('one event per state, and no failed event', () => {
    expectTypeOf<WebhookEventType>().toEqualTypeOf<`payment_intent.${PaymentIntentStatus}`>()
  })
})
