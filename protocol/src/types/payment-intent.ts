// Lightning was dropped (out of scope) — settlement is EVM/USDC. Base is live;
// Polygon/Solana are roadmap (Fase 3 multi-chain).
export type Chain = 'base' | 'polygon' | 'solana'
export type Currency = 'usdc' | 'btc'

/**
 * - `created`: waiting for the payment.
 * - `settled`: paid on-chain. Final: nothing comes after it.
 * - `expired`: `expires_at` passed with no payment in flight.
 * - `cancelled`: cancelled by the merchant, with no payment in flight.
 *
 * There is no `failed` state: a payment that does not go through leaves the
 * intent `created`, still payable until it expires.
 *
 * The chain has the last word: in a rare case — a payment already on its way
 * when the intent expired or was cancelled — an `expired` or `cancelled`
 * intent becomes `settled`.
 */
export type PaymentIntentStatus = 'created' | 'settled' | 'expired' | 'cancelled'

export interface PaymentIntent {
  id: string
  merchant_id: string
  amount: number
  currency: Currency
  chain: Chain | 'auto'
  status: PaymentIntentStatus
  node_operator: string | null
  payer_address: string | null
  tx_hash: string | null
  fee_amount: number
  metadata: Record<string, string>
  created_at: number
  expires_at: number
  settled_at: number | null
  /**
   * Per-intent checkout secret (cs_…). Returned to the OWNING merchant only
   * (create/retrieve/list); it gates the public checkout (`/v1/checkout/:id`)
   * so knowing the intent id alone — which can appear in logs/URLs — isn't
   * enough to view or pay it. Absent on intents created before this existed.
   */
  client_secret?: string | null
}

export interface CreatePaymentIntentParams {
  amount: number
  currency: Currency
  chain: Chain | 'auto'
  metadata?: Record<string, string>
  expires_in?: number
  idempotency_key?: string
}
