# ADR-006 — Verificar todas las firmas del pagador, y ejecutar solo el despliegue que la política permite

> **Status**: 🟢 **Aceptado** (2026-09-26)
> **Date**: 2026-09-26
> **Supersede**: — No cambia ningún contrato. Corrige la implementación
> off-chain del camino de monederos contrafactuales (ERC-6492) que añadió la
> fase 2 de ADR-003.

## Contexto

En el camino gasless, el pagador firma una autorización `ReceiveWithAuthorization`
y el nodeit la envía a la cadena pagando el gas (ADR-003). La firma puede venir
de tres tipos de cartera:

- **Cartera normal (EOA):** una firma ECDSA de 65 bytes.
- **Monedero inteligente ya desplegado (ERC-1271):** el contrato del monedero
  decide si la firma vale; USDC se lo pregunta al liquidar.
- **Monedero inteligente sin desplegar (ERC-6492):** la firma lleva envueltos
  `(fábrica, datosDeLaFábrica, firmaInterna)`. Como USDC no entiende ese
  envoltorio, **el nodeit despliega primero el monedero** —llamando a la fábrica
  con esos datos, desde su cuenta— y liquida después con la firma interna.

### Qué fallaba (F-4, hallazgo propio)

Lo encontramos el 2026-09-26 revisando una propuesta de arquitectura para el
nodo.

1. **La API solo verificaba las firmas de 65 bytes.** El resto las dejaba «para
   la liquidación», con el argumento de que USDC las comprueba en cadena.
2. **El nodeit ejecutaba la fábrica que venía en la firma sin comprobarla**:
   enviaba `(fábrica, datos)` tal cual, desde su propia cuenta.
3. **Al desempaquetar Multicall3** —el envoltorio que usa `keys.coinbase.com`—
   enviaba cada llamada interna directamente, lo que convertía al nodeit en
   `msg.sender` de cada una.
4. La comprobación de que el monedero quedó desplegado existía, pero corría
   **después** de minar la transacción: llegaba tarde.

El argumento del punto 1 era falso para este caso: el despliegue ocurre
**antes** de que USDC llegue a comprobar nada.

Así que cualquiera con un enlace de pago —el `client_secret` viaja en la URL—
podía fabricar una «firma» con fábrica = USDC y datos =
`transfer(atacante, saldo)`, y el nodeit la ejecutaba. Reproducido en un fork de
Base Sepolia con el estado real:

| | Antes | Después |
|---|---|---|
| USDC del operador | 40.610085 | 0 |
| USDC del atacante | 0 | 40.610085 |
| Nodos activos | `[0xf73e…]` | `[]` |

El `deactivate()` saca al único nodeit de la red: **con un solo nodo, ningún
pago se liquida**. Fondos de comercios y pagadores, nunca en riesgo: no pasan
por la cuenta del nodeit. El stake tampoco: su retiro vuelve al propio nodo, con
timelock. En las transacciones del operador en cadena no hay ninguna a una
fábrica, así que no hubo explotación.

**Es la misma familia que F-1 y F-3 (ADR-004):** la parte de confianza
ejecutaba lo que le entregaba la parte no confiable.

## Decisión

Dos capas, y hacen falta las dos.

### 1. La API verifica todas las firmas contra la cadena

Antes de encolar una autorización, la API comprueba su firma para **cualquier**
tipo de cartera, sobre el mensaje que reconstruye ella misma a partir del intent
(`to = hub`, `value = importe del intent`, `nonce = intentId`), nunca a partir
de lo que manda la petición:

- **Primero, ECDSA en local.** Si la firma recupera al pagador, está verificada
  sin consultar la cadena: una cartera normal no gasta RPC.
- **Si no, un `eth_call` al validador universal de ERC-6492**, sin desplegarlo.
  Simula el despliegue del monedero, sin gas ni cambio de estado, y llama a
  `isValidSignature`. Una firma fabricada no pasa.
- **Un revert es un «no»** (`invalid_signer`, 400). **Cualquier otro fallo de esa
  llamada no es un veredicto** (`signature_unverifiable`, 503, reintentable), y
  nunca se acepta.
- **Las firmas ERC-8010 se rechazan de entrada** (`unsupported_signature`): viem
  sabe verificarlas simulando una delegación EIP-7702, pero ni el hub ni USDC
  pueden liquidarlas.

No se usa `verifyTypedData` de viem: en la versión 2.56 convierte **cualquier**
fallo del `eth_call`, también un RPC caído, en `false`. El pagador recibiría
«firma no válida» por una caída del nodo RPC.

### 2. El nodeit solo ejecuta `createAccount` en fábricas permitidas

Toda llamada de despliegue —**después** de desempaquetar Multicall3— debe ir a
una fábrica permitida **y** empezar por el selector de
`createAccount(bytes[],uint256)`. Si alguna no cumple, no se envía nada.

| Fábrica | Dirección |
|---|---|
| `CoinbaseSmartWalletFactory` v1 | `0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a` |
| `CoinbaseSmartWalletFactory` v1.1 | `0xba5ed110efdba3d005bfc882d75358acbbb85842` |

Las dos verificadas en cadena: mismo bytecode en Base y en Base Sepolia, y
`createAccount(owners, nonce)` devuelve la misma dirección que
`getAddress(owners, nonce)`. La v1.1 es la que usa viem por defecto para
monederos nuevos; sin ella se rechazarían pagos legítimos.

La comprobación se hace **sobre la firma, sin tocar la cadena, antes de
cualquier acción**:

- Una autorización rechazada no cuesta gas, ni siquiera el registro del intent.
- El rechazo es **permanente**: la misma firma volvería a rechazarse.
- **En un lote, la rechazada sale sola.** Antes, cualquier fallo dejaba todas las
  filas para reintentar, y la mala tumbaba cada lote al que volvía, hasta que
  caducaban las legítimas que iban con ella.

### Por qué no basta con una sola capa

**Solo la verificación de la API no basta.** Un Multicall3 puede juntar un
`createAccount` **legítimo** con un `transfer`, con `allowFailure` en el
segundo. El `createAccount` crea un monedero real que sí valida la firma, así que
la verificación **la acepta, y con razón**: la firma es auténtica. Lo único que
lo frena es la política del nodeit. Comprobado en el fork.

**Solo la política del nodeit tampoco.** Sin la verificación de la API, una
firma inventada con una fábrica permitida llegaría al nodeit, que registraría el
intent y desplegaría un monedero cualquiera antes de que la liquidación fallara:
gas del operador quemado a voluntad de un tercero.

## Alternativas descartadas

- **Contener primero, rechazando todas las firmas ERC-6492 en el nodeit, y
  arreglar después.** Es un parche temporal y deja fuera justo lo que ERC-6492
  existe para soportar: los pagos con un Coinbase Smart Wallet recién creado.
  Sin clientes reales todavía, no había nada que proteger con prisa a cambio de
  un arreglo a medias.
- **Que el nodeit verifique también la firma antes de desplegar.** No detiene el
  caso del Multicall3 mixto, y con la política aplicada la única llamada que el
  nodeit puede llegar a ejecutar es inofensiva: crear el monedero del pagador en
  una fábrica conocida. Duplicaría consultas a la cadena sin cerrar nada.
- **No desempaquetar Multicall3 y enviarlo entero.** Los reverts internos con
  `allowFailure` quedarían ocultos —un despliegue «correcto» sin monedero—, y no
  resuelve el caso directo: con fábrica = USDC sin Multicall3, el nodeit es
  `msg.sender` igualmente. La política sobre las llamadas desempaquetadas cubre
  los dos casos.
- **Una lista de contratos permitidos** (hub, registro, `StakeManager`), como
  planteaba la propuesta de arquitectura. Rompe los pagos contrafactuales —hace
  falta llamar a la fábrica— y **no impide lo dañino**: `deactivate()` vive en un
  contrato permitido. La lista tiene que ser por selector y ligada a la
  operación.

**Queda como trabajo aparte, no como alternativa:** separar la clave de
identidad del nodeit de la de gas. Si la cuenta que envía transacciones solo
tuviera ETH, un fallo de esta familia no podría llevarse comisiones ni
desactivar el nodo. No sustituye a esta decisión; reduce el alcance de la
siguiente.

## Consecuencias

- **Solo Coinbase Smart Wallet puede pagar sin estar desplegado.** Un monedero
  de otra fábrica (Safe, Kernel…) paga en cuanto está desplegado, por ERC-1271,
  pero no antes. Añadir una fábrica es añadir código al que llamará la cuenta del
  nodeit: se verifica en cadena como estas dos antes de entrar en la lista.
- Una cartera normal no consulta la cadena al verificarse. Un monedero
  inteligente cuesta un `eth_call` por autorización, y si el RPC no responde el
  pagador recibe un 503 que le pide reintentar, no un «firma no válida».
- **Los pagos con Safe y firma de 65 bytes ya no se rechazan.** Antes se
  comparaba la firma con el propietario, no con el Safe; ahora se aplica la
  misma regla que USDC en cadena.
- **Ningún contrato cambia**: no hay redespliegue y el alcance de contratos de la
  auditoría es el mismo. El alcance off-chain sí crece (un archivo nuevo y dos
  modificados); el documento de alcance lo recoge como F-4.
- **El repositorio público `coatipay-node` queda pendiente de sincronizar.**
  Sigue con el ABI anterior a ADR-004 y el settler anterior a este arreglo.
  Contra el hub actual no puede liquidar nada —su `registerIntent` sin firma
  revierte antes de llegar al despliegue—, pero quien lo actualice sin este
  arreglo reabre F-4.
- **Sin aviso público.** Fue un hallazgo interno, sin explotación y sin reporte
  externo.

## Verificación

- **Tests:** API 219 y nodeit 55 en verde tras el arreglo. Tres tests existentes
  usaban fábricas inventadas —una sin código en ninguna red— y daban por bueno el
  comportamiento vulnerable; ahora usan la real. Los tests nuevos cubren:
  - Los ataques: directo, Multicall3 mixto, `deactivate()` y un lote con un
    elemento malo y otro bueno.
  - El verificador: una EOA no consulta el RPC, y un revert se distingue de una
    caída de red.
  - El rechazo de ERC-8010.
- **Pruebas en negativo:** los tests fallan contra el código anterior y contra el
  verificador de viem.
- **Fork de Base Sepolia, con el validador real de la API y el settler real:**
  - Coinbase v1.1 (envoltorio directo), Coinbase v1 (vía Multicall3) y Safe 1.4.1
    liquidan con el reparto exacto. El validador anterior rechazaba el Safe.
  - Los dos ataques no envían **ninguna** transacción.
  - El settler anterior, en el mismo fork, reproduce el robo.
- **RPC público real de Base Sepolia:** una firma inválida da un veredicto, no un
  error de red.
- **Producción, 2026-09-26:** desplegados el nodeit y la API. Un pago real de 5
  USDC liquidó 4.925 / 0.0525 / 0.0225 (98.5% / 1.05% / 0.45%), tx
  `0xe4594815c792bbabf04bccf5ea420f115e39803f7047e0dba6aae2dd9f5f4f2b`.
