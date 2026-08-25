// Lightning was dropped (out of scope) — settlement is EVM/USDC. Base is live;
// Polygon/Solana are roadmap (Fase 3 multi-chain).
export type Chain = 'base' | 'polygon' | 'solana'
export type Currency = 'usdc' | 'btc'

export type PaymentIntentStatus =
  | 'created'
  | 'settled'
  | 'failed'
  | 'expired'
  | 'cancelled'
  | 'disputed'

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
