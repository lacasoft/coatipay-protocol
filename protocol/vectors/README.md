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
| `errores.json` | Cada código del catálogo con su estado HTTP, su categoría y la clase de error que lanza el SDK. |

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
