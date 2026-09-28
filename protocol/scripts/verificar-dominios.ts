// Contrasta los separadores de dominio EIP-712 de los vectores con el del USDC
// desplegado en cada red (`DOMAIN_SEPARATOR()`). Así el ancla de la firma no es
// solo viem: es el propio contrato que la va a comprobar.
//
// Uso: npm run check:dominios
//   Sale con 1 si alguno no coincide. Si la red no responde tras varios
//   intentos, avisa y sale con 0: un RPC público caído no es un fallo nuestro.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { createPublicClient, http, parseAbi } from 'viem'
import { base, baseSepolia } from 'viem/chains'
import { DIRECTORIO } from './generar-vectores'

const REDES = { base, 'base-sepolia': baseSepolia } as const
const ABI = parseAbi(['function DOMAIN_SEPARATOR() view returns (bytes32)'])

async function main() {
  const casos = JSON.parse(readFileSync(resolve(DIRECTORIO, 'autorizacion.json'), 'utf8')).casos as {
    entrada: { chain: keyof typeof REDES }
    esperado: { domain: { verifyingContract: `0x${string}` }; domain_separator: string }
  }[]
  const porRed = new Map(casos.map((c) => [c.entrada.chain, c.esperado]))
  let distintos = 0
  for (const [red, e] of porRed) {
    const cliente = createPublicClient({ chain: REDES[red], transport: http(undefined, { retryCount: 3 }) })
    let enCadena: string
    try {
      enCadena = await cliente.readContract({
        address: e.domain.verifyingContract,
        abi: ABI,
        functionName: 'DOMAIN_SEPARATOR',
      })
    } catch (err) {
      console.log(`::warning::${red}: la red no respondió (${(err as Error).message.split('\n')[0]}); no se pudo contrastar`)
      continue
    }
    if (enCadena.toLowerCase() === e.domain_separator.toLowerCase()) {
      console.log(`OK — ${red}: el separador de dominio es el del USDC desplegado`)
    } else {
      distintos++
      console.error(`::error::${red}: vectores ${e.domain_separator}, USDC en cadena ${enCadena}`)
    }
  }
  if (distintos) process.exit(1)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
