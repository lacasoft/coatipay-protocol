export interface X402PaymentRequired {
  x402Version: 1
  accepts: X402PaymentOption[]
}

export interface X402PaymentOption {
  scheme: 'exact'
  network: string
  maxAmountRequired: string
  resource: string
  description: string
  mimeType: string
  payTo: string
  maxTimeoutSeconds: number
  asset: string
  extra?: { name: string; version: string }
}

export interface X402MiddlewareOptions {
  price: number
  currency: 'usdc'
  chain: 'base'
  description?: string
}
