import type { PaymentIntent } from './payment-intent'

export type WebhookEventType =
  | 'payment_intent.created'
  | 'payment_intent.settled'
  | 'payment_intent.failed'
  | 'payment_intent.expired'
  | 'payment_intent.cancelled'

export interface WebhookEvent {
  id: string
  type: WebhookEventType
  created: number
  data: PaymentIntent
}

