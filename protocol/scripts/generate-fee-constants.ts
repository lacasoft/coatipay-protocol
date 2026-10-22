// Single-source-of-truth generator for CoatiPay protocol constants.
//
// Source of truth: packages/contracts/src/SettlementHub.sol
//                  packages/contracts/src/StakeManager.sol (WITHDRAWAL_TIMELOCK)
//                  packages/contracts/src/NodeRegistry.sol (MIN_STAKE_DELAY)
// Output:         packages/protocol/src/fee-constants.generated.ts
//
// Usage:
//   pnpm --filter @lacasoft/coatipay-protocol generate:fee-constants          # writes file
//   pnpm --filter @lacasoft/coatipay-protocol check:fee-constants             # exits 1 on drift
//
// Why this exists: protocol invariants (fee bps, batch size cap) are declared
// in Solidity (on-chain, source of truth) AND used in TS (off-chain
// previews, SDK validation, API zod schemas). If they ever drift, off-chain
// code lies to merchants/payers about what the contract will accept.
// Generating from Solidity guarantees they stay in sync.
//
// Filename note: still called `fee-constants` for backward-compat with the
// CI gate name; the scope is now broader ("protocol constants"). Rename
// would touch CI config + every consumer; deferred until next refactor.
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SOURCE = resolve(__dirname, '../../contracts/src/SettlementHub.sol')
const STAKE_SOURCE = resolve(__dirname, '../../contracts/src/StakeManager.sol')
const REGISTRY_SOURCE = resolve(__dirname, '../../contracts/src/NodeRegistry.sol')
const TARGET = resolve(__dirname, '../src/fee-constants.generated.ts')
// El script de despliegue REPITE los valores a proposito, como comprobacion de
// que el artefacto desplegado es el esperado. Esa repeticion es util, pero se
// queda atras: al pasar de 100 a 150 bps (ADR-005) el `require` viejo habria
// hecho revertir el despliegue, y `forge test` no lo detecta porque no ejecuta
// los scripts. Por eso el gate tambien lo vigila.
const DEPLOY_SCRIPT = resolve(__dirname, '../../contracts/script/Deploy.s.sol')

/// Segundos de cada unidad de tiempo de Solidity.
const UNIDADES: Record<string, number> = {
  seconds: 1,
  minutes: 60,
  hours: 3_600,
  days: 86_400,
  weeks: 604_800,
}

/// Extract any `uintN public constant <NAME> = <expr>;` from the Solidity
/// source. Supports plain integer literals, time-unit literals (`30 days`,
/// in seconds) and simple subtraction expressions of two named constants
/// (covers SettlementHub's current pattern, e.g.
/// `OPERATOR_SHARE_BPS = PROTOCOL_FEE_BPS - TREASURY_SHARE_BPS`).
function extractConstant(sol: string, name: string, ctx: Record<string, number>): number {
  // `uint\d+` covers uint8, uint16, uint64, uint96, uint256, etc.
  const re = new RegExp(`uint\\d+\\s+public\\s+constant\\s+${name}\\s*=\\s*([^;]+);`)
  const m = sol.match(re)
  if (!m) throw new Error(`Constant ${name} not found in ${SOURCE}`)
  const expr = m[1].trim()

  // Plain integer literal (with optional `_` digit separators)
  if (/^[\d_]+$/.test(expr)) return Number(expr.replace(/_/g, ''))

  // Time-unit literal: `30 days` → seconds, as Solidity evaluates it.
  const tiempo = expr.match(/^([\d_]+)\s+(seconds|minutes|hours|days|weeks)$/)
  if (tiempo) return Number(tiempo[1].replace(/_/g, '')) * (UNIDADES[tiempo[2]] as number)

  // Subtraction expression: <NAME_A> - <NAME_B>
  const subMatch = expr.match(/^(\w+)\s*-\s*(\w+)$/)
  if (subMatch) {
    const a = ctx[subMatch[1]] ?? extractConstant(sol, subMatch[1], ctx)
    const b = ctx[subMatch[2]] ?? extractConstant(sol, subMatch[2], ctx)
    return a - b
  }

  throw new Error(`Cannot evaluate expression for ${name}: "${expr}". Update generator.`)
}

interface ExtractedConstants {
  PROTOCOL_FEE_BPS: number
  TREASURY_SHARE_BPS: number
  OPERATOR_SHARE_BPS: number
  MAX_BATCH_SIZE: number
  MAX_EXPIRY_OFFSET: number
  WITHDRAWAL_TIMELOCK: number
  MIN_STAKE_DELAY: number
}

/// Lo que firma `intentSigner` para autorizar un registro: el tipo EIP-712 y
/// el dominio del hub. Salen del contrato como texto, igual que las cifras:
/// una firma con otro tipo u otro dominio la rechaza el hub.
interface ExtractedRegistration {
  REGISTER_INTENT_TYPE: string
  SETTLEMENT_HUB_DOMAIN_NAME: string
  SETTLEMENT_HUB_DOMAIN_VERSION: string
}

function extractRegistration(sol: string): ExtractedRegistration {
  const tipo = sol.match(/REGISTER_INTENT_TYPEHASH\s*=\s*keccak256\("([^"]+)"\)/)
  if (!tipo) throw new Error(`REGISTER_INTENT_TYPEHASH not found in ${SOURCE}`)
  const dominio = sol.match(/_DOMAIN_TYPEHASH,\s*keccak256\("([^"]+)"\),\s*keccak256\("([^"]+)"\)/)
  if (!dominio) throw new Error(`EIP-712 domain name/version not found in DOMAIN_SEPARATOR() of ${SOURCE}`)
  if (!/^RegisterIntent\((\w+ \w+)(,\w+ \w+)*\)$/.test(tipo[1] as string)) {
    throw new Error(`Unexpected REGISTER_INTENT_TYPEHASH type string: "${tipo[1]}". Update generator.`)
  }
  return {
    REGISTER_INTENT_TYPE: tipo[1] as string,
    SETTLEMENT_HUB_DOMAIN_NAME: dominio[1] as string,
    SETTLEMENT_HUB_DOMAIN_VERSION: dominio[2] as string,
  }
}

function generate(): { values: ExtractedConstants; registration: ExtractedRegistration; content: string } {
  const sol = readFileSync(SOURCE, 'utf-8')
  const ctx: Record<string, number> = {}
  ctx.PROTOCOL_FEE_BPS = extractConstant(sol, 'PROTOCOL_FEE_BPS', ctx)
  ctx.TREASURY_SHARE_BPS = extractConstant(sol, 'TREASURY_SHARE_BPS', ctx)
  ctx.OPERATOR_SHARE_BPS = extractConstant(sol, 'OPERATOR_SHARE_BPS', ctx)
  ctx.MAX_BATCH_SIZE = extractConstant(sol, 'MAX_BATCH_SIZE', ctx)
  ctx.MAX_EXPIRY_OFFSET = extractConstant(sol, 'MAX_EXPIRY_OFFSET', ctx)
  ctx.WITHDRAWAL_TIMELOCK = extractConstant(readFileSync(STAKE_SOURCE, 'utf-8'), 'WITHDRAWAL_TIMELOCK', {})
  ctx.MIN_STAKE_DELAY = extractConstant(readFileSync(REGISTRY_SOURCE, 'utf-8'), 'MIN_STAKE_DELAY', {})
  const reg = extractRegistration(sol)

  if (ctx.OPERATOR_SHARE_BPS + ctx.TREASURY_SHARE_BPS !== ctx.PROTOCOL_FEE_BPS) {
    throw new Error(
      `Sanity check failed in SettlementHub.sol: OPERATOR_SHARE_BPS (${ctx.OPERATOR_SHARE_BPS}) + TREASURY_SHARE_BPS (${ctx.TREASURY_SHARE_BPS}) !== PROTOCOL_FEE_BPS (${ctx.PROTOCOL_FEE_BPS})`,
    )
  }
  if (ctx.MAX_BATCH_SIZE < 1 || ctx.MAX_BATCH_SIZE > 200) {
    throw new Error(
      `Sanity check failed: MAX_BATCH_SIZE = ${ctx.MAX_BATCH_SIZE} is outside the expected range [1, 200]`,
    )
  }
  if (ctx.MAX_EXPIRY_OFFSET < 3_600 || ctx.MAX_EXPIRY_OFFSET > 365 * 86_400) {
    throw new Error(
      `Sanity check failed: MAX_EXPIRY_OFFSET = ${ctx.MAX_EXPIRY_OFFSET} s is outside the expected range [1 hour, 365 days]`,
    )
  }
  if (ctx.WITHDRAWAL_TIMELOCK < 86_400 || ctx.WITHDRAWAL_TIMELOCK > 90 * 86_400) {
    throw new Error(
      `Sanity check failed: WITHDRAWAL_TIMELOCK = ${ctx.WITHDRAWAL_TIMELOCK} s is outside the expected range [1 day, 90 days]`,
    )
  }
  if (ctx.MIN_STAKE_DELAY < 86_400 || ctx.MIN_STAKE_DELAY > 90 * 86_400) {
    throw new Error(
      `Sanity check failed: MIN_STAKE_DELAY = ${ctx.MIN_STAKE_DELAY} s is outside the expected range [1 day, 90 days]`,
    )
  }

  const content = `// AUTO-GENERATED — DO NOT EDIT.
//
// Generated by packages/protocol/scripts/generate-fee-constants.ts from
// the Solidity source of truth: packages/contracts/src/SettlementHub.sol
// (StakeManager.sol for WITHDRAWAL_TIMELOCK, NodeRegistry.sol for
// MIN_STAKE_DELAY).
//
// To regenerate: pnpm --filter @lacasoft/coatipay-protocol generate:fee-constants
// To verify (CI):  pnpm --filter @lacasoft/coatipay-protocol check:fee-constants
//
// Why: protocol invariants are enforced on-chain by SettlementHub.sol.
// Off-chain code (API fee_amount + zod validation, SDK helpers, dashboard)
// must show exactly what the contract will accept. This file mirrors the
// Solidity \`constant\` values so they cannot drift.

export const PROTOCOL_FEE_BPS = ${ctx.PROTOCOL_FEE_BPS}
export const TREASURY_SHARE_BPS = ${ctx.TREASURY_SHARE_BPS}
export const OPERATOR_SHARE_BPS = ${ctx.OPERATOR_SHARE_BPS}
export const MAX_BATCH_SIZE = ${ctx.MAX_BATCH_SIZE}

/// Segundos. Un intent no se puede registrar si caduca más allá de esto desde
/// el momento del registro (\`InvalidExpiry\`).
export const MAX_EXPIRY_OFFSET = ${ctx.MAX_EXPIRY_OFFSET}

/// Segundos que un retiro de stake espera en StakeManager.
export const WITHDRAWAL_TIMELOCK = ${ctx.WITHDRAWAL_TIMELOCK}

/// Segundos entre proponer un \`minStake\` nuevo en NodeRegistry y poder
/// aplicarlo (ADR-009 §5).
export const MIN_STAKE_DELAY = ${ctx.MIN_STAKE_DELAY}

/// Lo que firma \`intentSigner\` para autorizar un registro: el tipo EIP-712
/// (\`REGISTER_INTENT_TYPEHASH\`) y el dominio de \`DOMAIN_SEPARATOR()\`.
export const REGISTER_INTENT_TYPE = '${reg.REGISTER_INTENT_TYPE}'
export const SETTLEMENT_HUB_DOMAIN_NAME = '${reg.SETTLEMENT_HUB_DOMAIN_NAME}'
export const SETTLEMENT_HUB_DOMAIN_VERSION = '${reg.SETTLEMENT_HUB_DOMAIN_VERSION}'
`

  return {
    values: ctx as ExtractedConstants,
    registration: reg,
    content,
  }
}

/// Comprueba que las aserciones repetidas de Deploy.s.sol siguen coincidiendo
/// con el contrato. Devuelve la lista de divergencias.
function checkDeployScript(ctx: Record<string, number>): string[] {
  let sol: string
  try {
    sol = readFileSync(DEPLOY_SCRIPT, 'utf-8')
  } catch {
    return [`${DEPLOY_SCRIPT} no se pudo leer`]
  }
  const problemas: string[] = []
  const vistos = new Set<string>()
  const re = /settlementHub\.(\w+)\(\)\s*==\s*(\d+)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(sol)) !== null) {
    const [, nombre, valorTexto] = m
    if (!(nombre in ctx)) continue
    vistos.add(nombre)
    const valor = Number(valorTexto)
    if (valor !== ctx[nombre]) {
      problemas.push(`Deploy.s.sol exige ${nombre} == ${valor}, pero el contrato declara ${ctx[nombre]}`)
    }
  }
  for (const nombre of ['PROTOCOL_FEE_BPS', 'TREASURY_SHARE_BPS', 'OPERATOR_SHARE_BPS']) {
    if (!vistos.has(nombre)) {
      problemas.push(`Deploy.s.sol ya no comprueba ${nombre}: la verificacion de despliegue perdio cobertura`)
    }
  }
  return problemas
}

const mode = process.argv.includes('--check') ? 'check' : 'write'

const result = generate()

const derivas = checkDeployScript(result.values as unknown as Record<string, number>)
if (derivas.length > 0) {
  console.error('Deriva en el script de despliegue:')
  for (const d of derivas) console.error(`  - ${d}`)
  console.error('El despliegue revertiria. Actualiza contracts/script/Deploy.s.sol.')
  process.exit(1)
}

if (mode === 'check') {
  let existing: string
  try {
    existing = readFileSync(TARGET, 'utf-8')
  } catch {
    console.error(`Drift detected: ${TARGET} does not exist. Run generate:fee-constants.`)
    process.exit(1)
  }
  if (existing !== result.content) {
    console.error(
      `Drift detected: ${TARGET} is out of sync with ${SOURCE} or ${STAKE_SOURCE}.\nRun \`pnpm --filter @lacasoft/coatipay-protocol generate:fee-constants\` and commit.`,
    )
    process.exit(1)
  }
  console.log(
    `OK — protocol constants in sync (PROTOCOL=${result.values.PROTOCOL_FEE_BPS} TREASURY=${result.values.TREASURY_SHARE_BPS} OPERATOR=${result.values.OPERATOR_SHARE_BPS} MAX_BATCH=${result.values.MAX_BATCH_SIZE} MAX_EXPIRY_OFFSET=${result.values.MAX_EXPIRY_OFFSET} WITHDRAWAL_TIMELOCK=${result.values.WITHDRAWAL_TIMELOCK} MIN_STAKE_DELAY=${result.values.MIN_STAKE_DELAY} REGISTER_INTENT_TYPE="${result.registration.REGISTER_INTENT_TYPE}")`,
  )
} else {
  writeFileSync(TARGET, result.content)
  console.log(`Wrote ${TARGET}`)
  console.log(`  PROTOCOL_FEE_BPS   = ${result.values.PROTOCOL_FEE_BPS}`)
  console.log(`  TREASURY_SHARE_BPS = ${result.values.TREASURY_SHARE_BPS}`)
  console.log(`  OPERATOR_SHARE_BPS = ${result.values.OPERATOR_SHARE_BPS}`)
  console.log(`  MAX_BATCH_SIZE     = ${result.values.MAX_BATCH_SIZE}`)
  console.log(`  MAX_EXPIRY_OFFSET  = ${result.values.MAX_EXPIRY_OFFSET}`)
  console.log(`  WITHDRAWAL_TIMELOCK = ${result.values.WITHDRAWAL_TIMELOCK}`)
  console.log(`  MIN_STAKE_DELAY    = ${result.values.MIN_STAKE_DELAY}`)
  console.log(`  REGISTER_INTENT_TYPE = ${result.registration.REGISTER_INTENT_TYPE}`)
  console.log(
    `  SETTLEMENT_HUB_DOMAIN = ${result.registration.SETTLEMENT_HUB_DOMAIN_NAME} v${result.registration.SETTLEMENT_HUB_DOMAIN_VERSION}`,
  )
}
