// SPDX-License-Identifier: Apache-2.0
//
// Shared chain helpers for verifying USDC transfers on Base.
// Used by both the API (x402 payment verification) and the nodeit daemon
// (settlement confirmation). Previously duplicated in both packages, which
// caused a real bug: the node copy multiplied amount by 1e6 a second time,
// making the threshold 1,000,000× too high. Centralizing here prevents
// future divergence.
//
// Callers must pass amounts in USDC base units (6 decimals).

import { createPublicClient, fallback, http, type PublicClient, type Transport } from 'viem'
import { base, baseSepolia } from 'viem/chains'

/**
 * Public (free, rate-limited) Base RPC endpoints. Appended as a last-resort
 * fallback so a paid-provider outage or quota exhaustion degrades the rail to
 * "slow but working" instead of "down".
 */
export const PUBLIC_RPC_URLS = {
  base: 'https://mainnet.base.org',
  baseSepolia: 'https://sepolia.base.org',
} as const

/** Parse a comma-separated list of RPC URLs (e.g. BASE_RPC_FALLBACK_URLS). */
export function parseRpcUrlList(raw: string | undefined): string[] {
  if (!raw) return []
  return raw
    .split(',')
    .map((u) => u.trim())
    .filter(Boolean)
}

/**
 * Assemble the ordered RPC endpoint list for a chain client:
 *   [primary, ...explicit fallbacks, public default]
 * Deduped, order-preserving. The chain's public RPC is always appended as a
 * last-resort backup (unless already present), so there is failover even when
 * no explicit fallback is configured.
 */
export function resolveRpcUrls(
  primary: string,
  fallbackUrls: string[] = [],
  isTestnet = true,
): string[] {
  const publicDefault = isTestnet ? PUBLIC_RPC_URLS.baseSepolia : PUBLIC_RPC_URLS.base
  return [...new Set([primary, ...fallbackUrls, publicDefault])]
}

/**
 * Build a viem transport from an ordered URL list. One URL → a plain HTTP
 * transport; multiple → a `fallback` transport that tries them in order and
 * moves to the next on error (HTTP 429 / 5xx / timeout) — this is what makes a
 * provider quota/outage non-fatal.
 */
export function buildRpcTransport(urls: string[]): Transport {
  if (urls.length <= 1) return http(urls[0])
  return fallback(urls.map((u) => http(u)))
}

/** Transfer(address,address,uint256) topic0 */
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'

/**
 * Build a viem PublicClient for Base mainnet or Base Sepolia.
 * `isTestnet` defaults to true because the daemon ships pointed at testnet
 * in Phase 1; flip to false only after mainnet deploy.
 */
// Explicit return type: viem's inferred PublicClient type is large enough that
// emitting it into the .d.ts trips tsc's TS7056 serialization limit. The chain
// union must be carried (Base is an OP-stack chain whose receipts include
// `deposit` txs, so the default PublicClient is too narrow). Annotating keeps
// the declaration stable (and speeds up the build).
//
// `rpcUrl` accepts a single URL (legacy) or an ordered list; a list builds a
// failover (`fallback`) transport. Use `resolveRpcUrls()` to assemble the list.
export function createChainClient(
  rpcUrl: string | string[],
  isTestnet = true,
): PublicClient<Transport, typeof base | typeof baseSepolia> {
  const urls = Array.isArray(rpcUrl) ? rpcUrl : [rpcUrl]
  return createPublicClient({
    chain: isTestnet ? baseSepolia : base,
    transport: buildRpcTransport(urls),
  })
}

export type ChainClient = ReturnType<typeof createChainClient>

export interface VerifyTransferResult {
  valid: boolean
  reason?: string
  /** Original error from viem/RPC, if any — for distinguishing transient
   *  failures from permanent ones at the call site. */
  error?: unknown
}

/**
 * Verifies that a transaction hash corresponds to a real USDC transfer
 * with the expected recipient and minimum amount.
 *
 * @param expectedAmountBaseUnits Amount in USDC base units (6 decimals).
 *   E.g. 50_000 = 0.05 USDC. Callers store assignments in base units, so
 *   pass them directly; do NOT convert here.
 */
export async function verifyUsdcTransfer(
  client: ChainClient,
  txHash: `0x${string}`,
  expectedTo: string,
  expectedAmountBaseUnits: number,
  usdcAddress: string,
): Promise<VerifyTransferResult> {
  try {
    const receipt = await client.getTransactionReceipt({ hash: txHash })

    if (receipt.status !== 'success') {
      return { valid: false, reason: 'transaction_failed' }
    }

    // Find USDC Transfer event in logs
    const transferLog = receipt.logs.find(
      (log) =>
        log.address.toLowerCase() === usdcAddress.toLowerCase() && log.topics[0] === TRANSFER_TOPIC,
    )

    if (!transferLog) {
      return { valid: false, reason: 'no_usdc_transfer_found' }
    }

    // Decode the Transfer event — topics[2] is the `to` address (zero-padded to 32 bytes)
    const to = `0x${transferLog.topics[2]?.slice(26)}`.toLowerCase()
    const value = BigInt(transferLog.data)

    const expectedAmount = BigInt(expectedAmountBaseUnits)

    if (to !== expectedTo.toLowerCase()) {
      return { valid: false, reason: 'wrong_recipient' }
    }

    if (value < expectedAmount) {
      return { valid: false, reason: 'insufficient_amount' }
    }

    return { valid: true }
  } catch (err) {
    // Distinguish RPC/transient failures from "tx not found / invalid" —
    // callers should log so operators can tell why settlement keeps failing.
    return { valid: false, reason: 'verification_failed', error: err }
  }
}
