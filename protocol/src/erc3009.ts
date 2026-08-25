// SPDX-License-Identifier: Apache-2.0
//
// ERC-3009 `ReceiveWithAuthorization` EIP-712 constants for USDC on Base.
//
// Single source of truth shared by the SDK (which signs the authorization)
// and the API (which recovers + verifies the signer). Each package used to
// keep its own copy, and both hardcoded the EIP-712 domain `name` as
// 'USD Coin' — correct for Base mainnet USDC but WRONG for Base Sepolia USDC,
// whose name() reports 'USDC'. Because signer and verifier shared the same
// wrong value they agreed with each other but not with the real token, so
// authorizations passed API validation and then reverted on-chain with
// 'FiatTokenV2: invalid signature'. Centralizing here prevents the drift.

export type SupportedChain = 'base' | 'base-sepolia'

/// Canonical USDC contract addresses.
/// Source: https://developers.circle.com/stablecoins/docs/usdc-on-base
export const USDC_ADDRESSES = {
  base: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  'base-sepolia': '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
} as const satisfies Record<SupportedChain, `0x${string}`>

export const CHAIN_IDS = {
  base: 8453,
  'base-sepolia': 84532,
} as const satisfies Record<SupportedChain, number>

/// USDC's EIP-712 domain `name` — per-chain. Verified on-chain via name():
/// Base mainnet USDC reports 'USD Coin'; Base Sepolia USDC reports 'USDC'.
export const USDC_DOMAIN_NAMES = {
  base: 'USD Coin',
  'base-sepolia': 'USDC',
} as const satisfies Record<SupportedChain, string>

/// USDC FiatToken EIP-712 domain `version` — '2' on both Base chains.
export const USDC_DOMAIN_VERSION = '2'

export interface Eip712Field {
  name: string
  type: string
}

/// EIP-712 type tuple for the ERC-3009 `ReceiveWithAuthorization` struct.
/// Frozen by the ERC-3009 spec — does not vary per chain. Consumed by the SDK
/// (builds the typed data to sign) and the API (recovers the signer).
export const RECEIVE_WITH_AUTHORIZATION_TYPES: { ReceiveWithAuthorization: Eip712Field[] } = {
  ReceiveWithAuthorization: [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ],
}

export interface UsdcEip712Domain {
  name: string
  version: string
  chainId: number
  verifyingContract: `0x${string}`
}

/// Builds the full USDC EIP-712 domain for the given chain.
export function usdcDomain(chain: SupportedChain): UsdcEip712Domain {
  return {
    name: USDC_DOMAIN_NAMES[chain],
    version: USDC_DOMAIN_VERSION,
    chainId: CHAIN_IDS[chain],
    verifyingContract: USDC_ADDRESSES[chain],
  }
}
