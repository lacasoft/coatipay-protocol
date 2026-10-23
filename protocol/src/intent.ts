// SPDX-License-Identifier: Apache-2.0
//
// El id on-chain de un cobro, y lo que firma `intentSigner` para registrarlo.
//
// Desde ADR-009 §3 el id on-chain lleva dentro al comercio:
//
//   ref      = keccak256(bytes UTF-8 del id del cobro, "pi_…")
//   intentId = keccak256(abi.encode(cartera del comercio, ref))
//
// Es lo mismo que calcula `SettlementHub.intentIdOf`, y es el `nonce` que firma
// el pagador en su autorización ERC-3009: su firma fija así también el
// comercio. Un SDK que conozca la cartera del comercio puede comprobar a quién
// ata el pagador su firma.
import {
  type Address,
  encodeAbiParameters,
  getAddress,
  type Hex,
  isAddress,
  keccak256,
  toHex,
  zeroAddress,
} from 'viem'
import type { Eip712Field } from './erc3009'
import {
  REGISTER_INTENT_TYPE,
  SETTLEMENT_HUB_DOMAIN_NAME,
  SETTLEMENT_HUB_DOMAIN_VERSION,
} from './fee-constants.generated'

export { REGISTER_INTENT_TYPE, SETTLEMENT_HUB_DOMAIN_NAME, SETTLEMENT_HUB_DOMAIN_VERSION }

const BYTES32 = /^0x[0-9a-fA-F]{64}$/

/// La referencia de un cobro: keccak256 de los bytes UTF-8 de su id. Nunca del
/// id leído como hexadecimal (`'0xdeadbeef'` se hashea como texto).
///
/// Lanza con un id vacío o de solo espacios, y con un id que ya es un bytes32:
/// hashearlo daría una referencia que parece válida y no es la de ningún cobro.
export function intentRef(paymentIntentId: string): Hex {
  if (paymentIntentId.trim() === '') throw new Error('payment intent id is empty')
  if (BYTES32.test(paymentIntentId)) {
    throw new Error('payment intent id is already a bytes32: pass the original id (pi_…)')
  }
  return keccak256(toHex(paymentIntentId))
}

/// El id on-chain del cobro, que es también el `nonce` de la autorización
/// ERC-3009 del pagador. Igual a `SettlementHub.intentIdOf(merchant, ref)`.
///
/// Lanza si `merchant` no es una dirección o es la dirección cero (el hub no
/// registra un comercio cero), y en los casos de `intentRef`.
export function intentIdOf(merchant: string, paymentIntentId: string): Hex {
  if (!isAddress(merchant, { strict: false })) throw new Error(`merchant is not an address: ${merchant}`)
  const comercio = getAddress(merchant)
  if (comercio === zeroAddress) throw new Error('merchant is the zero address')
  return keccak256(
    encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [comercio, intentRef(paymentIntentId)]),
  )
}

// ── El registro firmado por `intentSigner` ─────────────────────────

/// `RegisterIntent(bytes32 intentId,…)` → los campos, en el formato de viem.
function campos(tipo: string): Eip712Field[] {
  const dentro = tipo.slice(tipo.indexOf('(') + 1, -1)
  return dentro.split(',').map((campo) => {
    const [type, name] = campo.split(' ') as [string, string]
    return { name, type }
  })
}

/// El tipo EIP-712 que firma `intentSigner`. Generado de SettlementHub.sol.
export const REGISTER_INTENT_TYPES: { RegisterIntent: Eip712Field[] } = {
  RegisterIntent: campos(REGISTER_INTENT_TYPE),
}

export interface SettlementHubEip712Domain {
  name: string
  version: string
  chainId: number
  verifyingContract: Address
}

/// El dominio EIP-712 de un SettlementHub: ata la firma a ese hub y esa red.
export function settlementHubDomain(chainId: number, settlementHub: string): SettlementHubEip712Domain {
  return {
    name: SETTLEMENT_HUB_DOMAIN_NAME,
    version: SETTLEMENT_HUB_DOMAIN_VERSION,
    chainId,
    verifyingContract: getAddress(settlementHub),
  }
}

/// El mensaje de un registro. `intentId` es el de `intentIdOf`; al hub se le
/// envía `ref` y él lo recalcula. Alias y no `interface`: viem exige que el
/// mensaje admita índice.
export type RegisterIntentMessage = {
  intentId: Hex
  merchant: Address
  operator: Address
  amount: bigint
  expiresAt: bigint
}
