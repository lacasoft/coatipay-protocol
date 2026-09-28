import type { PaymentIntent } from './payment-intent'

/**
 * One event per status change of a payment intent. Delivery is at least once
 * and not ordered: deduplicate by `id`, and trust `data.status` and `created`
 * over the order of arrival. A `payment_intent.settled` can follow an
 * `expired` or `cancelled` one (see `PaymentIntentStatus`).
 */
export type WebhookEventType =
  | 'payment_intent.created'
  | 'payment_intent.settled'
  | 'payment_intent.expired'
  | 'payment_intent.cancelled'

export interface WebhookEvent {
  id: string
  type: WebhookEventType
  created: number
  data: PaymentIntent
}

