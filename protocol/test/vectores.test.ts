import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { type Hex, hashTypedData, recoverTypedDataAddress } from 'viem'
import { describe, expect, it } from 'vitest'
import { ERROR_CATALOG, RECEIVE_WITH_AUTHORIZATION_TYPES } from '../src'
import { DIRECTORIO, generarVectores } from '../scripts/generar-vectores'

/// El orden de la curva secp256k1: una firma con s > n/2 la rechaza el USDC.
const MITAD_DE_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n

const leer = (nombre: string) => JSON.parse(readFileSync(resolve(DIRECTORIO, nombre), 'utf8'))

describe('vectores compartidos entre SDK', () => {
  it('los ficheros publicados son los que genera el script', async () => {
    const generados = await generarVectores()
    for (const [nombre, contenido] of Object.entries(generados)) {
      expect(readFileSync(resolve(DIRECTORIO, nombre), 'utf8'), `${nombre}: npm run generate:vectores`).toBe(contenido)
    }
  })

  it('cada firma de autorización es del pagador, con s bajo y v 27/28', async () => {
    for (const c of leer('autorizacion.json').casos) {
      const e = c.esperado
      const tipado = {
        domain: e.domain,
        types: RECEIVE_WITH_AUTHORIZATION_TYPES,
        primaryType: 'ReceiveWithAuthorization' as const,
        message: {
          ...e.message,
          value: BigInt(e.message.value),
          validAfter: BigInt(e.message.validAfter),
          validBefore: BigInt(e.message.validBefore),
        },
      }
      expect(hashTypedData(tipado)).toBe(e.digest)
      const firmante = await recoverTypedDataAddress({ ...tipado, signature: e.signature as Hex })
      expect(firmante).toBe(e.api_body.payer)
      const s = BigInt(`0x${(e.signature as string).slice(66, 130)}`)
      expect(s <= MITAD_DE_N, 's bajo').toBe(true)
      expect(['1b', '1c']).toContain((e.signature as string).slice(-2))
    }
  })

  it('el nonce de cada autorización es el de su cobro', () => {
    const nonces = Object.fromEntries(
      leer('nonce.json').casos.map((c: { intent_id: string; nonce: string }) => [c.intent_id, c.nonce]),
    )
    for (const c of leer('autorizacion.json').casos) {
      expect(c.esperado.message.nonce).toBe(nonces[c.entrada.intent_id])
    }
  })

  it('los errores cubren el catálogo entero', () => {
    expect(Object.keys(leer('errores.json').codigos).sort()).toEqual(Object.keys(ERROR_CATALOG).sort())
  })
})
