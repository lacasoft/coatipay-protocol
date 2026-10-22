import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  concat,
  encodeAbiParameters,
  getAddress,
  hashTypedData,
  type Hex,
  keccak256,
  recoverTypedDataAddress,
  toHex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { describe, expect, it } from 'vitest'
import {
  intentIdOf,
  intentRef,
  REGISTER_INTENT_TYPE,
  REGISTER_INTENT_TYPES,
  type RegisterIntentMessage,
  settlementHubDomain,
} from '../src'

const vectores = JSON.parse(readFileSync(resolve(__dirname, '../vectors/nonce.json'), 'utf8'))
const COMERCIO = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'

describe('intentIdOf (ADR-009 §3)', () => {
  it('reproduces every shared vector', () => {
    for (const c of vectores.casos) {
      expect(intentRef(c.intent_id), c.intent_id).toBe(c.ref)
      expect(intentIdOf(c.merchant, c.intent_id), c.intent_id).toBe(c.nonce)
    }
  })

  it('rejects every rejected vector, without hashing it', () => {
    for (const c of vectores.rechazados) {
      expect(() => intentIdOf(c.merchant, c.intent_id), c.motivo).toThrow()
    }
  })

  it('is abi.encode(merchant, ref), as SettlementHub.intentIdOf', () => {
    const ref = keccak256(toHex('pi_x'))
    expect(intentIdOf(COMERCIO, 'pi_x')).toBe(
      keccak256(concat([`0x${'00'.repeat(12)}${COMERCIO.slice(2).toLowerCase()}`, ref])),
    )
  })

  it('the same payment with another merchant is another intent', () => {
    expect(intentIdOf(COMERCIO, 'pi_x')).not.toBe(intentIdOf('0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', 'pi_x'))
  })

  it('does not depend on the case of the merchant address', () => {
    expect(intentIdOf(COMERCIO.toLowerCase(), 'pi_x')).toBe(intentIdOf(COMERCIO, 'pi_x'))
  })
})

describe('the registration signed by intentSigner', () => {
  const hub = '0x00000000000000000000000000000000000c0a71'
  const mensaje: RegisterIntentMessage = {
    intentId: intentIdOf(COMERCIO, 'pi_x'),
    merchant: getAddress(COMERCIO),
    operator: '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
    amount: 1_500_000n,
    expiresAt: 1_790_000_000n,
  }

  it('the fields are the ones of the type string generated from SettlementHub.sol', () => {
    const texto = `RegisterIntent(${REGISTER_INTENT_TYPES.RegisterIntent.map((f) => `${f.type} ${f.name}`).join(',')})`
    expect(texto).toBe(REGISTER_INTENT_TYPE)
  })

  it('viem hashes it exactly as the hub does by hand', () => {
    const dominio = settlementHubDomain(84532, hub)
    const separador = keccak256(
      encodeAbiParameters(
        [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
        [
          keccak256(toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
          keccak256(toHex('CoatiPay SettlementHub')),
          keccak256(toHex('1')),
          84532n,
          hub,
        ],
      ),
    )
    const struct = keccak256(
      encodeAbiParameters(
        [
          { type: 'bytes32' },
          { type: 'bytes32' },
          { type: 'address' },
          { type: 'address' },
          { type: 'uint256' },
          { type: 'uint64' },
        ],
        [
          keccak256(toHex(REGISTER_INTENT_TYPE)),
          mensaje.intentId,
          mensaje.merchant,
          mensaje.operator,
          mensaje.amount,
          mensaje.expiresAt,
        ],
      ),
    )
    const aMano = keccak256(concat(['0x1901', separador, struct]))
    expect(
      hashTypedData({ domain: dominio, types: REGISTER_INTENT_TYPES, primaryType: 'RegisterIntent', message: mensaje }),
    ).toBe(aMano)
  })

  it('a raw ECDSA signature over that digest recovers the hot key (what IntentSignerGate checks)', async () => {
    const clave = privateKeyToAccount('0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d')
    const tipado = {
      domain: settlementHubDomain(84532, hub),
      types: REGISTER_INTENT_TYPES,
      primaryType: 'RegisterIntent' as const,
      message: mensaje,
    }
    const firma = await clave.signTypedData(tipado)
    expect(await recoverTypedDataAddress({ ...tipado, signature: firma as Hex })).toBe(clave.address)
  })
})
