// Vectores compartidos entre los SDK de CoatiPay (JS, Python, PHP).
//
// Un mismo juego de casos —entrada y salida esperada— que los tres SDK tienen
// que reproducir. Donde cada SDK implementa lo mismo por su cuenta (la firma
// EIP-712 se hashea a mano en Python y en PHP; la verificación de webhooks la
// escribió cada uno a su manera), una divergencia deja de ser una sorpresa en
// producción: es un test rojo.
//
// Salida: protocol/vectors/*.json, publicados dentro del paquete npm. Cada SDK
// guarda una copia y su CI comprueba que es la publicada.
//
// Uso:
//   npm run generate:vectores     # escribe los ficheros
//   npm run check:vectores        # sale con 1 si difieren de lo que se genera
//
// Las salidas esperadas no se escriben a mano: las calculan viem (firma) y
// node:crypto (HMAC). El separador de dominio de cada red, además, lo contrasta
// con el USDC desplegado `npm run check:dominios`.
import { createHmac } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { domainSeparator, hashTypedData, type Hex, keccak256, toHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { docUrl, ERROR_CATALOG, type ErrorCategory, type ErrorDefinition } from '../src/errors'
import {
  RECEIVE_WITH_AUTHORIZATION_TYPES,
  type SupportedChain,
  usdcDomain,
} from '../src/erc3009'

export const DIRECTORIO = resolve(__dirname, '../vectors')

/// Versión del formato de los vectores. Sube si cambia la forma de un fichero.
const FORMATO = 1

// ── nonce ──────────────────────────────────────────────────────────

/// El nonce de la autorización ES el id on-chain del cobro: keccak256 de los
/// bytes UTF-8 de su id. Nunca del id interpretado como hexadecimal.
export function nonceDe(intentId: string): Hex {
  return keccak256(toHex(intentId))
}

function vectoresNonce() {
  const ids = [
    'pi_V1StGXR8_Z5jdHi6B-myT',
    'pi_a',
    '0xdeadbeef', // parece hexadecimal: se hashea como texto
    'pi_ñandú', // no ASCII: UTF-8
  ]
  return {
    formato: FORMATO,
    descripcion:
      'El nonce de la autorización ERC-3009 es el id on-chain del cobro: keccak256 de los bytes UTF-8 del id. Nunca del id leído como hexadecimal. Los ids de `rechazados` se rechazan con un error, sin hashearlos: su hash daría un nonce que parece válido y no es el de ningún cobro.',
    casos: ids.map((intent_id) => ({ intent_id, nonce: nonceDe(intent_id) })),
    rechazados: [
      { intent_id: '', motivo: 'vacío' },
      { intent_id: '   ', motivo: 'solo espacios' },
      {
        intent_id: `0x${'ab'.repeat(32)}`,
        motivo: 'ya es un id on-chain (bytes32): hashearlo otra vez daría otro nonce',
      },
    ],
  }
}

// ── autorización ERC-3009 ──────────────────────────────────────────

/// Clave de prueba pública (la cuenta 0 de Anvil/Hardhat). Nunca tiene fondos
/// en las redes de CoatiPay: sirve para que la firma sea reproducible.
const CLAVE_DE_PRUEBA = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as const
const HUB_DE_PRUEBA = '0x00000000000000000000000000000000000c0a71' as const

async function vectoresAutorizacion() {
  const pagador = privateKeyToAccount(CLAVE_DE_PRUEBA)
  const casos = []
  for (const [red, intentId, importe] of [
    ['base-sepolia', 'pi_V1StGXR8_Z5jdHi6B-myT', 1_500_000n],
    ['base', 'pi_V1StGXR8_Z5jdHi6B-myT', 1_500_000n],
    ['base-sepolia', 'pi_a', 300_000n],
  ] as const satisfies readonly [SupportedChain, string, bigint][]) {
    const dominio = usdcDomain(red)
    const mensaje = {
      from: pagador.address,
      to: HUB_DE_PRUEBA,
      value: importe,
      validAfter: 0n,
      validBefore: 1_790_000_000n,
      nonce: nonceDe(intentId),
    }
    const tipado = {
      domain: dominio,
      types: RECEIVE_WITH_AUTHORIZATION_TYPES,
      primaryType: 'ReceiveWithAuthorization' as const,
      message: mensaje,
    }
    const firma = await pagador.signTypedData(tipado)
    casos.push({
      entrada: {
        chain: red,
        intent_id: intentId,
        amount: importe.toString(),
        payer_private_key: CLAVE_DE_PRUEBA,
        settlement_hub: HUB_DE_PRUEBA,
        valid_after: '0',
        valid_before: '1790000000',
      },
      esperado: {
        domain: dominio,
        domain_separator: domainSeparator({ domain: dominio }),
        message: {
          from: mensaje.from,
          to: mensaje.to,
          value: mensaje.value.toString(),
          validAfter: '0',
          validBefore: '1790000000',
          nonce: mensaje.nonce,
        },
        digest: hashTypedData(tipado),
        /// 65 bytes: r ‖ s ‖ v, con `s` bajo y `v` 27/28 (el USDC rechaza el resto).
        signature: firma,
        /// El cuerpo de `POST /v1/payment_intents/:id/authorize`.
        api_body: {
          payer: pagador.address,
          valid_after: '0',
          valid_before: '1790000000',
          nonce: mensaje.nonce,
          signature: firma,
        },
      },
    })
  }
  return {
    formato: FORMATO,
    descripcion:
      'Autorizaciones ERC-3009 ReceiveWithAuthorization. Dominio EIP-712: el del USDC de la red (name "USDC" en Base Sepolia y "USD Coin" en Base, version "2"). La clave de prueba es pública (cuenta 0 de Anvil): la firma es determinista (RFC 6979) y con s bajo.',
    casos,
  }
}

// ── webhooks ───────────────────────────────────────────────────────

export type MotivoWebhook = 'malformed_header' | 'timestamp_out_of_tolerance' | 'no_matching_signature'

/// La verificación de referencia. Cabecera `X-Signature: t=<segundos>,v1=<hex>`:
///   1. Partes separadas por comas, sin espacios alrededor. Cada parte es
///      `clave=valor`: una sin `=`, o sin clave, es cabecera mal formada.
///   2. Un solo `t`, solo dígitos. Al menos un `v1`. Otras claves se ignoran.
///   3. |ahora − t| ≤ tolerancia (300 s por defecto), límite incluido.
///   4. HMAC-SHA256 del secreto sobre `<t>.<cuerpo>`, en hex minúsculas:
///      vale si coincide con CUALQUIER `v1` (rotación de secretos).
export function verificarWebhook(
  cuerpo: string,
  cabecera: string,
  secreto: string,
  ahora: number,
  tolerancia = 300,
): { ok: true } | { ok: false; motivo: MotivoWebhook } {
  const ts: string[] = []
  const firmas: string[] = []
  for (const bruta of cabecera.split(',')) {
    const parte = bruta.trim()
    const igual = parte.indexOf('=')
    if (igual <= 0) return { ok: false, motivo: 'malformed_header' }
    const clave = parte.slice(0, igual)
    const valor = parte.slice(igual + 1)
    if (clave === 't') ts.push(valor)
    if (clave === 'v1') firmas.push(valor)
  }
  const t = ts[0]
  if (ts.length !== 1 || t === undefined || !/^\d+$/.test(t) || firmas.length === 0) {
    return { ok: false, motivo: 'malformed_header' }
  }
  if (Math.abs(ahora - Number(t)) > tolerancia) {
    return { ok: false, motivo: 'timestamp_out_of_tolerance' }
  }
  const esperada = createHmac('sha256', secreto).update(`${t}.${cuerpo}`).digest('hex')
  return firmas.includes(esperada) ? { ok: true } : { ok: false, motivo: 'no_matching_signature' }
}

function vectoresWebhooks() {
  const secreto = 'whsec_vector_de_prueba'
  const ahora = 1_790_000_000
  const evento = {
    id: 'evt_0123456789abcdef0123456789abcdef',
    type: 'payment_intent.settled',
    created: ahora - 5,
    data: {
      id: 'pi_V1StGXR8_Z5jdHi6B-myT',
      merchant_id: 'mid_ejemplo',
      amount: 1500000,
      currency: 'usdc',
      chain: 'base',
      status: 'settled',
      node_operator: '0x00000000000000000000000000000000000000aa',
      payer_address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
      tx_hash: `0x${'ab'.repeat(32)}`,
      fee_amount: 22500,
      metadata: { order_id: 'o_1' },
      created_at: ahora - 600,
      expires_at: ahora + 1200,
      settled_at: ahora - 5,
    },
  }
  const cuerpo = JSON.stringify(evento)
  const firma = (t: number | string, s = secreto, c = cuerpo) =>
    createHmac('sha256', s).update(`${t}.${c}`).digest('hex')
  const buena = firma(ahora)
  const mala = firma(ahora, 'whsec_otro')

  const casos: { nombre: string; cabecera: string; cuerpo?: string; ahora?: number; tolerancia?: number }[] = [
    { nombre: 'valida', cabecera: `t=${ahora},v1=${buena}` },
    { nombre: 'en_el_limite_de_la_tolerancia', cabecera: `t=${ahora - 300},v1=${firma(ahora - 300)}` },
    { nombre: 'fuera_de_tolerancia', cabecera: `t=${ahora - 301},v1=${firma(ahora - 301)}` },
    { nombre: 'del_futuro_fuera_de_tolerancia', cabecera: `t=${ahora + 301},v1=${firma(ahora + 301)}` },
    { nombre: 'tolerancia_propia', cabecera: `t=${ahora - 600},v1=${firma(ahora - 600)}`, tolerancia: 900 },
    { nombre: 'cuerpo_alterado', cabecera: `t=${ahora},v1=${buena}`, cuerpo: cuerpo.replace('1500000', '1500001') },
    { nombre: 'otro_secreto', cabecera: `t=${ahora},v1=${mala}` },
    { nombre: 'rotacion_la_buena_segunda', cabecera: `t=${ahora},v1=${mala},v1=${buena}` },
    { nombre: 'rotacion_la_buena_primera', cabecera: `t=${ahora},v1=${buena},v1=${mala}` },
    { nombre: 'claves_desconocidas_se_ignoran', cabecera: `t=${ahora},v0=abc,v1=${buena},v2=def` },
    { nombre: 'espacios_tras_las_comas', cabecera: `t=${ahora}, v1=${buena}` },
    { nombre: 'firma_en_mayusculas', cabecera: `t=${ahora},v1=${buena.toUpperCase()}` },
    { nombre: 'sin_t', cabecera: `v1=${buena}` },
    { nombre: 'sin_v1', cabecera: `t=${ahora}` },
    { nombre: 'parte_sin_igual', cabecera: `t=${ahora},v1` },
    { nombre: 'clave_vacia', cabecera: `t=${ahora},=${buena}` },
    { nombre: 't_con_exponente', cabecera: `t=1e9,v1=${firma('1e9')}` },
    { nombre: 't_decimal', cabecera: `t=${ahora}.5,v1=${firma(`${ahora}.5`)}` },
    { nombre: 't_negativo', cabecera: `t=-${ahora},v1=${firma(`-${ahora}`)}` },
    { nombre: 't_repetido', cabecera: `t=${ahora},t=${ahora},v1=${buena}` },
    { nombre: 'cabecera_vacia', cabecera: '' },
  ]

  return {
    formato: FORMATO,
    descripcion:
      'Verificación de la cabecera X-Signature (t=<segundos>,v1=<hex>): partes separadas por comas (se ignoran los espacios alrededor), cada una clave=valor; un solo t, solo dígitos; al menos un v1; otras claves se ignoran. Vale si |ahora − t| ≤ tolerancia (300 s por defecto, límite incluido) y el HMAC-SHA256 del secreto sobre "<t>.<cuerpo>", en hex minúsculas, coincide con CUALQUIER v1. Orden: formato, tolerancia, firma. Motivos: malformed_header, timestamp_out_of_tolerance, no_matching_signature.',
    secreto,
    ahora,
    tolerancia_por_defecto: 300,
    cuerpo,
    evento,
    casos: casos.map((c) => {
      const r = verificarWebhook(c.cuerpo ?? cuerpo, c.cabecera, secreto, c.ahora ?? ahora, c.tolerancia)
      return {
        nombre: c.nombre,
        cabecera: c.cabecera,
        ...(c.cuerpo !== undefined ? { cuerpo: c.cuerpo } : {}),
        ...(c.tolerancia !== undefined ? { tolerancia: c.tolerancia } : {}),
        esperado: r.ok ? { valida: true } : { valida: false, motivo: r.motivo },
      }
    }),
  }
}

// ── errores ────────────────────────────────────────────────────────

/// La clase de error de cada categoría. Las que no tienen clase propia
/// (not_found, conflict, unavailable, internal) usan la base.
const CLASES: Record<ErrorCategory, string> = {
  auth: 'AuthError',
  validation: 'ValidationError',
  not_found: 'CoatiPaySDKError',
  conflict: 'CoatiPaySDKError',
  payment: 'PaymentError',
  routing: 'RoutingError',
  rate_limit: 'RateLimitError',
  unavailable: 'CoatiPaySDKError',
  internal: 'CoatiPaySDKError',
}

type Respuesta = { status: number; cuerpo: string } | null

type Interpretacion =
  | { ok: true }
  | { ok: false; clase: string; code: string; status: number | null; param: string | null; doc_url: string }

const esObjeto = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/// Cómo interpreta un SDK la respuesta HTTP de la API, o su ausencia
/// (implementación de referencia; de aquí salen los casos esperados):
///   1. Sin respuesta (red, DNS, timeout) → NetworkError, status null.
///   2. Un cuerpo que no es JSON → NetworkError con el status, sea cual sea
///      (un 502 en HTML del proxy, un 200 que no es JSON).
///   3. 2xx con JSON → éxito.
///   4. Un error de CoatiPay es un objeto JSON cuyo `error` es un objeto con
///      `code` de texto no vacío → la clase de su categoría (la base si el SDK
///      no conoce el código); `param` null si no viene; sin `doc_url`, la
///      página del código.
///   5. Cualquier otro JSON de error (sin `error`, o el `error` de texto que
///      pone Fastify por defecto) no es de CoatiPay → NetworkError con el status.
/// NetworkError tiene code `network_error` y hereda de CoatiPaySDKError.
export function interpretarRespuesta(r: Respuesta): Interpretacion {
  const deRed = (status: number | null): Interpretacion => ({
    ok: false,
    clase: 'NetworkError',
    code: 'network_error',
    status,
    param: null,
    doc_url: docUrl('network_error'),
  })
  if (r === null) return deRed(null)
  let cuerpo: unknown
  try {
    cuerpo = JSON.parse(r.cuerpo)
  } catch {
    return deRed(r.status)
  }
  if (r.status >= 200 && r.status < 300) return { ok: true }
  const error = esObjeto(cuerpo) ? cuerpo.error : undefined
  if (!esObjeto(error) || typeof error.code !== 'string' || error.code === '') return deRed(r.status)
  const definicion = (ERROR_CATALOG as Record<string, ErrorDefinition>)[error.code]
  return {
    ok: false,
    clase: definicion ? CLASES[definicion.category] : 'CoatiPaySDKError',
    code: error.code,
    status: r.status,
    param: typeof error.param === 'string' ? error.param : null,
    doc_url: typeof error.doc_url === 'string' ? error.doc_url : docUrl(error.code),
  }
}

function vectoresErrores() {
  const deLaApi = (code: string, extra: Record<string, unknown> = {}) =>
    JSON.stringify({
      error: { code, message: 'Mensaje de la API', param: null, doc_url: docUrl(code), ...extra },
    })

  const casos: { nombre: string; respuesta: Respuesta }[] = [
    { nombre: 'exito', respuesta: { status: 200, cuerpo: '{"id":"pi_1","status":"created"}' } },
    { nombre: 'error_de_la_api', respuesta: { status: 409, cuerpo: deLaApi('payment_in_progress') } },
    { nombre: 'error_de_la_api_con_su_clase', respuesta: { status: 401, cuerpo: deLaApi('invalid_api_key') } },
    {
      nombre: 'error_con_param',
      respuesta: { status: 400, cuerpo: deLaApi('amount_below_minimum', { param: 'amount' }) },
    },
    {
      nombre: 'error_sin_doc_url',
      respuesta: {
        status: 400,
        cuerpo: JSON.stringify({ error: { code: 'invalid_request', message: 'm', param: 'amount' } }),
      },
    },
    { nombre: 'codigo_desconocido', respuesta: { status: 418, cuerpo: deLaApi('codigo_de_una_api_mas_nueva') } },
    { nombre: 'sin_respuesta', respuesta: null },
    { nombre: 'proxy_502_en_html', respuesta: { status: 502, cuerpo: '<html><body>502 Bad Gateway</body></html>' } },
    { nombre: 'proxy_503_vacio', respuesta: { status: 503, cuerpo: '' } },
    {
      nombre: 'error_por_defecto_de_fastify',
      respuesta: {
        status: 500,
        cuerpo: '{"statusCode":500,"error":"Internal Server Error","message":"boom"}',
      },
    },
    { nombre: 'json_sin_error', respuesta: { status: 500, cuerpo: '{"message":"boom"}' } },
    { nombre: 'error_sin_code', respuesta: { status: 400, cuerpo: '{"error":{"message":"m"}}' } },
    { nombre: 'error_con_code_vacio', respuesta: { status: 400, cuerpo: '{"error":{"code":"","message":"m"}}' } },
    { nombre: 'json_que_no_es_objeto', respuesta: { status: 400, cuerpo: '["invalid_request"]' } },
    { nombre: 'exito_que_no_es_json', respuesta: { status: 200, cuerpo: 'OK' } },
  ]

  return {
    formato: FORMATO,
    descripcion:
      'Cada código del catálogo con su estado HTTP, su categoría y la clase de error que lanza el SDK. Todas heredan de CoatiPaySDKError. Un código que el SDK no conoce (una API más nueva) lanza CoatiPaySDKError, nunca un fallo.',
    codigos: Object.fromEntries(
      Object.entries(ERROR_CATALOG).map(([codigo, { http, category }]) => [
        codigo,
        { http, category, clase: CLASES[category] },
      ]),
    ),
    desconocido: { code: 'codigo_que_no_existe', clase: 'CoatiPaySDKError' },
    respuestas: {
      descripcion:
        'Cómo interpreta el SDK la respuesta HTTP de una llamada, o su ausencia. Un error de CoatiPay es un objeto JSON cuyo `error` es un objeto con `code` de texto no vacío: lanza la clase de su categoría, con `param` null si no viene y, sin `doc_url`, la página del código. Sin respuesta (red, DNS, timeout), un cuerpo que no es JSON (aunque sea un 2xx) o un JSON de error que no es de CoatiPay → NetworkError: code network_error, hereda de CoatiPaySDKError, con `status` (el HTTP, o null si no hubo respuesta). Un 2xx con JSON es éxito. `respuesta` null = no hubo respuesta.',
      casos: casos.map((c) => {
        const r = interpretarRespuesta(c.respuesta)
        return {
          nombre: c.nombre,
          respuesta: c.respuesta,
          esperado: r.ok
            ? { ok: true }
            : {
                ok: false,
                clase: r.clase,
                code: r.code,
                ...(r.clase === 'NetworkError' ? { status: r.status } : {}),
                param: r.param,
                doc_url: r.doc_url,
              },
        }
      }),
    },
  }
}

// ── salida ─────────────────────────────────────────────────────────

export async function generarVectores(): Promise<Record<string, string>> {
  const json = (v: unknown) => `${JSON.stringify(v, null, 2)}\n`
  return {
    'nonce.json': json(vectoresNonce()),
    'autorizacion.json': json(await vectoresAutorizacion()),
    'webhooks.json': json(vectoresWebhooks()),
    'errores.json': json(vectoresErrores()),
  }
}

async function main() {
  const ficheros = await generarVectores()
  if (process.argv.includes('--check')) {
    const distintos = Object.entries(ficheros).filter(([nombre, contenido]) => {
      try {
        return readFileSync(resolve(DIRECTORIO, nombre), 'utf8') !== contenido
      } catch {
        return true
      }
    })
    if (distintos.length) {
      console.error(`Vectores desactualizados: ${distintos.map(([n]) => n).join(', ')}`)
      console.error('Regenera con: npm run generate:vectores')
      process.exit(1)
    }
    console.log(`OK — ${Object.keys(ficheros).length} ficheros de vectores al día`)
  } else {
    mkdirSync(DIRECTORIO, { recursive: true })
    for (const [nombre, contenido] of Object.entries(ficheros)) {
      writeFileSync(resolve(DIRECTORIO, nombre), contenido)
    }
    console.log(`Escritos ${Object.keys(ficheros).length} ficheros en ${DIRECTORIO}`)
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err)
    process.exit(1)
  })
}
