import type { PaymentIntent } from './payment-intent'

export type WebhookEventType =
  | 'payment_intent.created'
  | 'payment_intent.settled'
  | 'payment_intent.failed'
  | 'payment_intent.expired'
  | 'payment_intent.cancelled'
  | 'dispute.opened'
  | 'dispute.resolved'

export interface WebhookEvent {
  id: string
  type: WebhookEventType
  created: number
  data: PaymentIntent | DisputeEvent
}

export interface DisputeEvent {
  dispute_id: string
  payment_intent_id: string
  merchant_id: string
  node_operator: string
  status: 'open' | 'responded' | 'resolved' | 'expired'
  outcome?: 'merchant_wins' | 'node_wins'
}
