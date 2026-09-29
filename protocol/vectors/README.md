# Vectores compartidos entre los SDK

Casos de entrada y salida esperada que **los tres SDK de CoatiPay** (JS, Python, PHP)
reproducen en sus tests. Donde cada SDK implementa lo mismo por su cuenta —la firma
EIP-712 se hashea a mano en Python y en PHP; la verificación de webhooks la escribió
cada uno—, una divergencia deja de ser una sorpresa en producción: es un test rojo.

| Fichero | Qué fija |
|---|---|
| `nonce.json` | El nonce de la autorización ERC-3009: `keccak256` de los bytes UTF-8 del id del cobro. Nunca del id leído como hexadecimal (ver `0xdeadbeef`). Y los ids que hay que **rechazar** con un error (vacío, solo espacios, un bytes32 ya derivado): su hash daría un nonce que parece válido y no es el de ningún cobro. |
| `autorizacion.json` | Por red: el dominio EIP-712 del USDC, su separador, el mensaje `ReceiveWithAuthorization`, el digest, la firma con una clave de prueba pública y el cuerpo de `POST /v1/payment_intents/:id/authorize`. |
| `webhooks.json` | La verificación de la cabecera `X-Signature`: 21 casos con su resultado (válida, o el motivo). |
| `errores.json` | Cada código del catálogo con su estado HTTP, su categoría y la clase de error que lanza el SDK. Y en `respuestas`, cómo se interpreta la respuesta HTTP de una llamada, o su ausencia: 15 casos. |

## De dónde salen

No se escriben a mano. `scripts/generar-vectores.ts` los calcula con viem (firma) y
`node:crypto` (HMAC), y ahí vive también la **verificación de webhooks de referencia**:

- Partes separadas por comas (se ignoran los espacios alrededor), cada una `clave=valor`.
  Una parte sin `=`, o sin clave, es cabecera mal formada.
- Un solo `t`, solo dígitos. Al menos un `v1`. Otras claves se ignoran.
- `|ahora − t| ≤ tolerancia`: 300 s por defecto, límite incluido.
- HMAC-SHA256 del secreto sobre `<t>.<cuerpo>`, en hex minúsculas: vale si coincide con
  **cualquier** `v1`, para poder rotar el secreto sin cortar la entrega.
- Orden: formato, tolerancia, firma. Motivos: `malformed_header`,
  `timestamp_out_of_tolerance`, `no_matching_signature`.

Y la **interpretación de la respuesta** de la API (`respuestas` en `errores.json`):

- Un error de CoatiPay es un objeto JSON cuyo `error` es un objeto con `code` de texto no
  vacío. Lanza la clase de su categoría (la base, `CoatiPaySDKError`, si el SDK no conoce el
  código), con `param` null si no viene y, sin `doc_url`, la página del código.
- Todo lo demás es `NetworkError` (code `network_error`, hereda de `CoatiPaySDKError`): sin
  respuesta (red, DNS, timeout; `status` null), un cuerpo que no es JSON aunque sea un 2xx (el
  502 en HTML de un proxy), o un JSON de error que no es de CoatiPay (el `error` de texto que
  pone Fastify por defecto). `status` es el HTTP de esa respuesta.
- Un 2xx con JSON es éxito.

Así, un solo `catch` de `CoatiPaySDKError` cubre cualquier llamada, en los tres SDK.

La clave privada de `autorizacion.json` es la cuenta 0 de Anvil/Hardhat: pública, sin
fondos en las redes de CoatiPay. La firma es determinista (RFC 6979), con `s` bajo y
`v` 27/28 —el USDC rechaza el resto—.

## Cómo se comprueban

- `npm run check:vectores` — los ficheros son los que genera el script.
- `npm test` — cada firma recupera al pagador, con `s` bajo; el digest es el de viem;
  los errores cubren el catálogo entero.
- `npm run check:dominios` — el separador de dominio de cada red es el que devuelve el
  USDC desplegado (`DOMAIN_SEPARATOR()`): el ancla es el propio contrato.

## Cómo los usa un SDK

Se publican dentro del paquete npm (`@lacasoft/coatipay-protocol/vectors/`). Cada SDK
guarda una copia en sus tests y su CI comprueba que es la de la última versión publicada
(`npm pack @lacasoft/coatipay-protocol@latest`). Para la hora de los webhooks, el SDK
tiene que aceptar una hora inyectada: la de `webhooks.json` (`ahora`).

Las **direcciones** se comparan sin distinguir mayúsculas. El checksum EIP-55 es
presentación: la firma es sobre los 20 bytes, así que un SDK que da `from`/`to` o el
`payer` del cuerpo en minúsculas (Python) cumple igual que uno que los da con checksum (JS).
