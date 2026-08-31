import {
  MAX_BATCH_SIZE,
  OPERATOR_SHARE_BPS,
  PROTOCOL_FEE_BPS,
  TREASURY_SHARE_BPS,
} from './fee-constants.generated'

export const PROTOCOL_VERSION = '0.1'
export const USDC_BASE_ADDRESS = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
export const USDC_DECIMALS = 6
export const MIN_STAKE_USDC = 100_000_000n
export const TARGET_STAKE_USDC = 10_000_000_000n
export const ROUTING_TIMEOUT_MS = 5_000
export const NODE_ASSIGN_TIMEOUT_MS = 3_000
export const ROUTING_CANDIDATES = 5
export const MAX_SETTLEMENT_MS = 30_000
export const SCORE_CACHE_TTL_MS = 60_000
export const DEFAULT_INTENT_TTL_SECONDS = 1800
export const STAKE_WITHDRAWAL_TIMELOCK_DAYS = 7

// Protocol invariants — single source of truth is SettlementHub.sol.
// `fee-constants.generated.ts` is generated from it; never edit by hand.
// Add a new constant here? See feedback_no_constant_duplication memory rule.
export { MAX_BATCH_SIZE, OPERATOR_SHARE_BPS, PROTOCOL_FEE_BPS, TREASURY_SHARE_BPS }

// Legacy ratio names, derived from the canonical bps values so they cannot
// drift from the on-chain split.
export const NODE_FEE_SHARE = OPERATOR_SHARE_BPS / PROTOCOL_FEE_BPS
export const TREASURY_FEE_SHARE = TREASURY_SHARE_BPS / PROTOCOL_FEE_BPS

// Base is the only settlement chain live today. Lightning was dropped (out of
// scope); Polygon/Solana are roadmap (Fase 3), added here when implemented.
export const SUPPORTED_CHAINS = ['base'] as const
export const BASE_CONFIRMATIONS_REQUIRED = 1

// ── Settlement economics — operator-tunable DEFAULTS (not on-chain invariants) ──
// The node pays gas (in ETH) and keeps OPERATOR_SHARE_BPS of the fee (in USDC),
// so tiny payments settle at a LOSS. To never settle below break-even, the node
// enforces a minimum payment value, calibrated in USDC at a reference gas price
// and scaled live by the current gas price:
//   effectiveMin = MIN_PAYMENT_AMOUNT × max(1, gasPriceLive / GAS_PRICE_REF)
// The ETH/USD rate is baked into MIN_PAYMENT_AMOUNT by the operator (a Chainlink
// ETH/USD feed is the future upgrade — see backlog). Both API (reject at create)
// and node (skip/hold at settle) read these via env, defaulting here so the two
// stay in sync.
export const DEFAULT_MIN_PAYMENT_AMOUNT = 300_000 // 0.30 USDC (6 decimals)
export const DEFAULT_GAS_PRICE_REF_GWEI = 0.02 // Base reference gas price (gwei)
