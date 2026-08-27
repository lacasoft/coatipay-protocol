# Guía de Infraestructura de CoatiPay

*Todo lo que necesitas para convertirte en un experto técnico en CoatiPay. Este documento cubre arquitectura, componentes internos, ciclo de vida de transacciones, modelo económico, seguridad, despliegue e integración en profundidad total.*

---

## Tabla de Contenidos

1. [Visión General del Sistema](#1-visión-general-del-sistema)
2. [Mapa de Componentes](#2-mapa-de-componentes)
3. [Settlement Layer](#3-settlement-layer)
4. [Capa de Smart Contracts](#4-capa-de-smart-contracts)
5. [Routing Engine](#5-routing-engine)
6. [Capa de API](#6-capa-de-api)
7. [Node Daemon](#7-node-daemon)
8. [Capa de SDK](#8-capa-de-sdk)
9. [Protocolo x402](#9-protocolo-x402)
10. [Ciclo de Vida de la Transacción](#10-ciclo-de-vida-de-la-transacción)
11. [Modelo Económico](#11-modelo-económico)
12. [Modelo de Seguridad](#12-modelo-de-seguridad)
13. [Guía de Operación de Node](#13-guía-de-operación-de-node)
14. [Guía de Integración para Comercios](#14-guía-de-integración-para-comercios)
15. [Guía de Despliegue](#15-guía-de-despliegue)
16. [Análisis Comparativo](#16-análisis-comparativo)
17. [Invariantes y Garantías](#17-invariantes-y-garantías)

---

## 1. Visión General del Sistema

CoatiPay es un sistema de routing de pagos de cinco capas. Cada capa tiene una única responsabilidad bien definida y se comunica con las capas adyacentes a través de interfaces documentadas.

```
┌──────────────────────────────────────────────────────────┐
│  SDK Layer                                               │
│  @lacasoft/coatipay-sdk (TS) · coatipay-sdk (Py) · coatipay-sdk (PHP)  │
│  x402 middleware for Fastify · Next.js · Express         │
├──────────────────────────────────────────────────────────┤
│  API Layer                                               │
│  Fastify REST API · PostgreSQL · Redis                   │
│  Routing Engine · Webhook Delivery · Auth                │
├──────────────────────────────────────────────────────────┤
│  Routing Layer                                           │
│  Node discovery · Score computation · Intent assignment  │
├──────────────────────────────────────────────────────────┤
│  Protocol Layer (on-chain)                               │
│  NodeRegistry · StakeManager · DisputeResolver · SettlementHub │
├──────────────────────────────────────────────────────────┤
│  Settlement Layer                                        │
│  Base (USDC) — live · Polygon / Solana — roadmap        │
└──────────────────────────────────────────────────────────┘
```

**La invariante no negociable a través de todas las capas:**
Los fondos fluyen directamente del payer al comercio. Ninguna capa, componente o node retiene fondos en ningún momento. Los nodes observan, confirman y ganan fees del monto liquidado — nunca están en la ruta de los fondos.

---

## 2. Mapa de Componentes

### Grafo de dependencias de paquetes

```
@lacasoft/coatipay-protocol          (público — tipos, constantes, errores)
    ├── @lacasoft/coatipay-sdk       (público — SDK de JS/TS)
    └── la plataforma                (privada — API, dashboard, nodeit)

coatipay-sdk (PyPI)      ─┐
lacasoft/coatipay-sdk    ─┴─ independientes: reimplementan el protocolo
  (Packagist, PHP)            en su lenguaje, sin depender del paquete TS

contracts/  (Solidity)   ── independiente de los paquetes TS
```

### Cómo está repartido el código

El protocolo y los SDKs son **públicos**; la implementación que opera CoatiPay
es **privada**. Un integrador nunca necesita clonar nada: instala un SDK.

```
lacasoft/coatipay-protocol        🌐 público   ← estás aquí
├── contracts/                       Solidity + Foundry
│   ├── src/
│   │   ├── SettlementHub.sol        liquida y reparte
│   │   ├── NodeRegistry.sol         registro de nodeits
│   │   ├── StakeManager.sol         custodia del stake
│   │   ├── DisputeResolver.sol      arbitraje 3-de-5
│   │   └── Pausable.sol
│   ├── test/                        197 tests (unitarios, fuzz e invariantes)
│   └── deployments/sepolia.json     direcciones canónicas
└── protocol/                        @lacasoft/coatipay-protocol
    └── src/
        ├── types/                   PaymentIntent, NodeInfo, WebhookEvent, x402
        ├── constants.ts             generado desde SettlementHub.sol
        └── errors.ts                CoatiPaySDKError, códigos de error

lacasoft/coatipay-js-sdk          🌐 público   @lacasoft/coatipay-sdk
lacasoft/coatipay-python-sdk      🌐 público   coatipay-sdk (PyPI)
lacasoft/coatipay-php-sdk         🌐 público   lacasoft/coatipay-sdk (Packagist)

lacasoft/openrelay-platform       🔒 privado
├── packages/api/                    API del comercio (Fastify)
├── packages/dashboard/              panel y checkout (Next.js)
└── packages/node/                   daemon del nodeit
```

> **Por qué la plataforma es privada.** El dashboard y el checkout son
> superficie de phishing: una copia fiel del panel de cobro es una herramienta
> de fraude lista para usar. El protocolo —lo que hay que poder auditar y
> verificar— es justo lo que sí está abierto.


---

## 3. Settlement Layer

### 3.1 Por qué Base + USDC

Base es un L2 sobre Ethereum respaldado por Coinbase. Fue seleccionado como la settlement layer primaria por tres razones:

**Fees.** Las transacciones en Base cuestan entre $0.001 y $0.005, haciendo los micropagos económicamente viables. En Ethereum mainnet, un pago de $0.001 costaría entre $2–5 en gas. En Base, el costo de gas es menor que el pago.

**Ecosistema x402.** El protocolo x402 (HTTP 402 Payment Required para pagos máquina-a-máquina) fue diseñado con Base como el chain primario. La implementación de referencia de x402.org apunta a Base Sepolia para pruebas.

**Liquidez de USDC.** El USDC de Circle en Base tiene liquidez profunda, es redimible 1:1 por USD, y es la unidad de cuenta estándar para transacciones cripto business-to-business.

### 3.2 Dirección del contrato USDC

```
Base mainnet:  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
Base Sepolia:  0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

### 3.3 Representación de montos

Todos los montos de USDC en CoatiPay usan micro-unidades de 6 decimales:

```
1 USDC         = 1,000,000 micro-units
$10.00 USDC    = 10,000,000
$0.001 USDC    = 1,000
$100.00 USDC   = 100,000,000
```

**Nunca confundir unidades.** Cada endpoint de API, método del SDK y función de smart contract usa micro-unidades. El único lugar donde aparecen montos legibles por humanos es en la capa de visualización del dashboard del comercio.

### 3.4 Lightning — fuera de alcance

Lightning fue **considerado y descartado** (fuera de alcance): no se va a implementar y el enum de chains ya no lo incluye. CoatiPay liquida exclusivamente en EVM/USDC — Base hoy, con Polygon y Solana en la hoja de ruta (ver §3.1).

### 3.5 Confirmaciones requeridas por chain

| Chain | Confirmaciones | Tiempo típico |
|---|---|---|
| Base | 1 | ~2 segundos |
| Ethereum mainnet (futuro) | 12 | ~2.5 minutos |

---

## 4. Capa de Smart Contracts

Cuatro contratos no actualizables en Base definen todas las reglas del protocolo on-chain: `NodeRegistry`, `StakeManager`, `DisputeResolver` y `SettlementHub` (todos extienden una base `Pausable` compartida).

### Estado del deploy

El primer deploy de Fase B5 en testnet se completó en **Base Sepolia (chainId 84532)**. Los cuatro contratos están live y con código fuente verificado en Basescan. La fuente canónica de verdad para las direcciones desplegadas, el bloque, el hash del commit y los parámetros del constructor es `contracts/deployments/sepolia.json` — ese JSON es lo que leen la API, el node daemon y cualquier integrador. Mainnet permanece bloqueado por la auditoría externa pendiente.

### Principios de diseño

- **No actualizables:** Sin patrones proxy y sin admin keys que muevan fondos — nadie puede mover fondos ni reescribir estado. **Sí** existe una pausa de emergencia (la base `Pausable` compartida) controlada por un guardian (un multisig 3-de-5, no una sola key), que bloquea el registro y las operaciones de nueva escritura pero no detiene settlements en vuelo; el guardian lo mantiene la Fundación (sin migración a gobernanza on-chain comprometida). Lo que se audita es lo que corre. Si un bug requiere una corrección, la respuesta correcta es un nuevo despliegue con una ruta de migración aprobada por RFC.
- **Superficie mínima:** Cada contrato hace exactamente una cosa. Sin preocupaciones cruzadas.
- **Denominado en USDC:** Todo el stake, fees y slashing son en USDC. Sin token de protocolo.
- **Orientado a eventos:** Todos los cambios de estado emiten eventos. El routing engine off-chain y el node daemon dependen de los event logs, no de polling.

---

### 4.1 NodeRegistry.sol

**Responsabilidad:** Registro y descubrimiento de nodes sin permisos.

**Estado:**
```solidity
mapping(address => Node) private _nodes;
address[] private _activeOperators;
```

**Funciones clave:**

`register(string endpoint)`
- Invocable por cualquiera que **ya tenga stake depositado**. Flujo de 3 tx: `usdc.approve(stakeManager, amount)` → `stakeManager.deposit(amount)` → `register(endpoint)`
- Requiere `staked >= minStake` (100 USDC en mainnet · 40 USDC en Sepolia testnet — ajustable por guardian vía `setMinStake`, solo incrementos). **NO transfiere USDC**: solo verifica el stake on-chain vía `StakeManager.getStakeInfo()` (least-privilege — el registry no mueve fondos)
- Hace push del operator a `_activeOperators`
- Emite `NodeRegistered`

`deactivate()`
- Remueve al operator de `_activeOperators`
- NO libera el stake — debe pasar por StakeManager
- Emite `NodeDeactivated`

`getActiveNodes() → address[]`
- Devuelve todas las direcciones de operators activos
- Usado por el routing engine para descubrir candidatos

**Eventos a los que el routing engine escucha:**
```
NodeRegistered(address indexed operator, string endpoint, uint256 stake)
NodeUpdated(address indexed operator, string endpoint)
NodeDeactivated(address indexed operator)
```

**Invariantes de seguridad:**
- Una dirección no puede registrarse dos veces (verificado vía `registeredAt != 0`)
- El stake lo retiene StakeManager, no NodeRegistry — el registry no tiene balance de tokens
- `getActiveNodes()` es O(n) — aceptable para la Fase 1, necesita paginación en la Fase 3

---

### 4.2 StakeManager.sol

**Responsabilidad:** Custodia de stake en USDC, timelock de retiro y slashing.

**Estado:**
```solidity
mapping(address => StakeInfo) private _stakes;

struct StakeInfo {
    uint256 staked;
    uint256 pendingWithdrawal;
    uint256 unlockAt;
}
```

**El timelock de retiro:**

El timelock de 7 días entre `requestWithdrawal()` y `executeWithdrawal()` es la protección principal contra exit scams de nodes. Sin él, un node malicioso podría:
1. Aceptar un payment intent grande
2. Fallar en enrutarlo apropiadamente
3. Retirar inmediatamente todo el stake antes de que el comercio abra una dispute

Con el timelock, el comercio tiene 7 días para abrir una dispute después del settlement. La ventana de dispute y el timelock de retiro son intencionalmente iguales — crean un sistema cerrado donde un node no puede retirar antes de que una dispute pueda resolverse.

**Mecánica de slashing:**

Cuando `DisputeResolver` llama a `slash(operator, amount, disputeId)`:
1. La función verifica `staked + pendingWithdrawal` como el monto total susceptible de slash
2. Reduce `staked` primero, luego `pendingWithdrawal` si staked es insuficiente
3. El monto del slash está limitado al total disponible — el slashing nunca puede crear balances negativos
4. Los fondos slasheados permanecen en el contrato y son rastreados para retiro al treasury (feature de Fase 2)

**Control de acceso:**
- `depositFor()` — solo invocable por la dirección `nodeRegistry` (configurada en el deploy, inmutable)
- `slash()` — solo invocable por la dirección `disputeResolver` (configurada en el deploy, inmutable)
- `deposit()`, `requestWithdrawal()`, `executeWithdrawal()` — invocables por cualquier operator registrado

---

### 4.3 DisputeResolver.sol

**Responsabilidad:** Adjudicación de disputes y decisiones de slashing de stake.

**Ciclo de vida:**

```
Open → NodeResponded → Resolved (MerchantWins or NodeWins)
Open → (48h passes without response) → Expired → Slashed
```

**Mecánica de votación (Fase 1):**

Las disputes se resuelven por un multisig 3-de-5. Cada arbiter llama a `vote(disputeId, outcome)`. Cuando se acumulan 3 votos por el mismo outcome, `_resolve()` se dispara automáticamente. Esto evita requerir un paso de ejecución separado.

Decisiones clave de diseño:
- **Votación concurrente:** Los 5 arbiters pueden votar en cualquier orden. El umbral dispara la resolución automáticamente.
- **Sin cambios de voto:** Una vez que un arbiter vota, su voto es inmutable (verificado vía `arbiterVotes[disputeId][msg.sender] != None`).
- **Expirada = MerchantWins:** Si un node falla en responder dentro de 48 horas, `expireDispute()` puede ser llamada por cualquiera. Una dispute expirada dispara slashing sin votos de arbiters. Esto previene que los nodes ignoren disputes para evitar el slashing.

**Almacenamiento de evidencia:**

La evidencia se almacena como IPFS CIDs (hashes direccionados por contenido), no como datos on-chain. Esto mantiene los costos de almacenamiento del contrato bajos mientras hace la evidencia públicamente auditable — cualquiera puede recuperar el contenido de IPFS para cualquier dispute.

**Sobre el conjunto de árbitros:**

Los árbitros del multisig los gestiona la Fundación; no hay un reemplazo por gobernanza on-chain comprometido. Si fuera necesario cambiar la lógica de `vote()`, sería vía un nuevo despliegue con una migración aprobada por RFC.

---

### 4.4 SettlementHub.sol

**Responsabilidad:** Settlement trustless on-chain y split atómico de fees. Es el contrato que **mueve los fondos** — jala el USDC del payer y lo splittea on-chain (comercio + node operator + treasury) en una sola transacción, reemplazando el modelo de confianza previo de "el daemon del operador reenvía los fondos".

**Split de fees (atómico, on-chain):** para cualquier `amount`, el contrato envía 99% al comercio, 0.7% al node operator y 0.3% al treasury, en la misma transacción. Las constantes de fee son `public constant` — no configurables, sin forma de cambiar el fee post-deploy:

```solidity
uint16  public constant PROTOCOL_FEE_BPS   = 100;  // 1.0% fee total
uint16  public constant OPERATOR_SHARE_BPS = 70;   // 0.7% al node operator
uint16  public constant TREASURY_SHARE_BPS = 30;   // 0.3% al treasury
uint256 public constant MAX_BATCH_SIZE     = 50;   // tope de batch (x402)
```

**Tres pay paths** — el path gasless ERC-3009 es el de la Fase 1:
- `payIntent` — approve + pay
- `payIntentWithPermit` — EIP-2612
- `payIntentWithAuthorization` — **ERC-3009 gasless** (el payer firma off-chain una autorización `ReceiveWithAuthorization`; el nodeit la submitea y paga el gas) + `payIntentBatchWithAuthorization` para batch x402 (hasta `MAX_BATCH_SIZE = 50`)

`IntentSettled` es la **fuente de verdad** del settlement — el event watcher off-chain lo observa y marca el intent como `settled`. `SettlementHub` usa `nonReentrant` en cada pay path y sigue Checks-Effects-Interactions.

### 4.5 Orden de despliegue de contratos

Debido a dependencias circulares (Registry necesita StakeManager, StakeManager necesita la dirección de Registry), los contratos se despliegan en este orden:

```
1. Deploy StakeManager (with deployer address as placeholder for both registry and resolver)
2. Deploy DisputeResolver (with real StakeManager address)
3. Deploy NodeRegistry (with real StakeManager address)
4. Deploy SettlementHub (with usdc, treasury, and the real guardian in its constructor)
```

Las direcciones placeholder en StakeManager nunca son invocadas maliciosamente — el wallet del deployer no tiene permisos especiales en la lógica del contrato. Esta es una limitación conocida de la Fase 1 con una ruta de migración documentada a un patrón factory en la Fase 2.

---

## 5. Routing Engine — Fase 2 (planificado, no implementado)

> **Estado:** El motor de routing multi-node descrito en esta sección **no está implementado.** Hoy la red opera con un solo bootstrap nodeit: cada intent va a una cola de la API y es liquidado por ese nodeit vía ERC-3009 (ver §7 y §10), sin descubrimiento de nodeits, sin scoring y sin racing. El descubrimiento de candidatos desde `NodeRegistry.sol`, el scoring por reputación y el racing paralelo son una feature de **Fase 2**. La especificación se conserva aquí como referencia de diseño para esa fase.

Cuando haya múltiples nodeits registrados on-chain, la capa de API seleccionará un nodeit por intent con el algoritmo siguiente.

### 5.1 Fórmula del score del node

```
Score = (uptime_weight   × 0.30)
      + (speed_weight    × 0.30)
      + (stake_weight    × 0.20)
      + (disputes_weight × 0.20)

Where:
  uptime_weight   = node.uptime_30d  (0.0–1.0, from /info endpoint)

  speed_weight    = 1 - (node.avg_settlement_ms / MAX_SETTLEMENT_MS)
                   MAX_SETTLEMENT_MS = 30,000ms
                   Capped at 0.0 (never negative)

  stake_weight    = min(node.stake / TARGET_STAKE, 1.0)
                   TARGET_STAKE = 10,000 USDC = 10,000,000,000 micro-units
                   A node with 100 USDC (minimum) has stake_weight = 0.01
                   A node with 10,000+ USDC has stake_weight = 1.0

  disputes_weight = disputes_won / max(disputes_total, 1)
                   New nodes with 0 disputes get disputes_weight = 1.0
                   (benefit of the doubt, corrected by uptime and stake)
```

**Interpretación:** El score pondera el uptime y la velocidad igualmente al 30% cada uno porque la confiabilidad y el rendimiento son las preocupaciones primarias del comercio. El stake (20%) refleja skin in the game — un node dispuesto a hacer stake de más está económicamente alineado con el buen comportamiento. El historial de disputes (20%) es una señal de confianza que crece con el tiempo.

### 5.2 Filtros duros (aplicados antes del scoring)

Los nodes que fallan cualquier filtro duro son excluidos del routing sin importar el score:

| Filtro | Condición |
|---|---|
| Registro on-chain | No está en NodeRegistry |
| Flag activo | `active = false` en el registry |
| Soporte de chain | No lista el chain solicitado en `/health` |
| Capacidad | `/health` devuelve `capacity < 0.1` |
| Latencia | Round-trip a `/health` > 5 segundos |
| Bloqueo por dispute | Tiene dispute abierta en estado `Open` |
| Whitelist del comercio | No está en la `node_whitelist` del comercio (si está configurada) |
| Blacklist del comercio | Está en la `node_blacklist` del comercio (si está configurada) |
| Stake mínimo | Por debajo de la preferencia `min_stake` del comercio |
| Score mínimo | Por debajo de la preferencia `min_score` del comercio |

### 5.3 Algoritmo de racing paralelo

```typescript
async function routeIntent(intent, candidates): Promise<RouteResult | null> {
  // 1. Apply hard filters
  const eligible = candidates
    .filter(c => passesHardFilters(c, intent, merchantPrefs))
    .sort((a, b) => b.score - a.score)
    .slice(0, ROUTING_CANDIDATES)  // top 5

  if (eligible.length === 0) return null

  // 2. Race concurrent assignment requests
  const results = await Promise.allSettled(
    eligible.map(c => assignToNode(c.node.endpoint, intent))
  )

  // 3. Return first accepted response
  for (const result of results) {
    if (result.status === 'fulfilled') return result.value
  }

  return null  // all candidates rejected
}
```

**Por qué paralelo, no secuencial:** Si el nodeit con mayor score está temporalmente al máximo de capacidad, el routing secuencial esperaría por un timeout antes de intentar el siguiente candidato. El racing paralelo distribuye la autorización ERC-3009 a varios candidatos a la vez, y el primer nodeit en concretar el settlement on-chain gana el fee.

**Manejo de rechazos:** Si un nodeit candidato no reclama ni liquida la autorización, lo hace el siguiente candidato. Si ningún candidato liquida, el intent permanece en `created` hasta `expires_at`.

### 5.4 Cacheado de scores

Los scores se cachean en Redis con un TTL de 60 segundos. Esto significa:
- Los scores de los nodes se refrescan como máximo una vez por minuto
- Los scores obsoletos persisten hasta por 60 segundos después de que un node cambia de estado
- El routing engine NO re-obtiene los scores para cada intent — usa el valor cacheado

El TTL de 60 segundos es un balance deliberado entre la frescura y el rendimiento. A escala, re-computar scores para cada intent desde los datos en vivo de `/info` del node sería prohibitivamente costoso.

---

## 6. Capa de API

### 6.1 Stack tecnológico

| Preocupación | Elección | Razón |
|---|---|---|
| Framework | Fastify 4 | 3× más rápido que Express. Validación nativa de JSON schema. Mejor sistema de plugins. |
| Base de datos | PostgreSQL 16 | JSONB para metadata. TIMESTAMPTZ nativo. Garantías ACID. |
| Cache | Redis 7 | Cacheado de scores. Rate limiting. Protección contra replay de x402. |
| Validación | Zod | Seguridad de tipos en runtime en todos los bordes de la API. |
| Auth | API key (Bearer) | Auth más simple viable para tooling de desarrolladores. |

### 6.2 Autenticación

Cada request de API (excepto health check) requiere un header `Authorization: Bearer <key>`.

Formatos de key:
```
pk_live_xxx   Public key — read-only (GET endpoints)
sk_live_xxx   Secret key — full access (POST, DELETE)
pk_test_xxx   Public key — testnet
sk_test_xxx   Secret key — testnet
```

Las keys se almacenan en `api_keys.key_hash` como **HMAC-SHA256 con un pepper del servidor** (ver `lib/auth-hash.ts`). La key en texto plano se devuelve una sola vez al momento de la creación y nunca se almacena. Si se pierde, la key debe ser regenerada.

> **Revocación manual (procedimiento actual).** Todavía no existe un endpoint
> de revocación; revocar una key hoy es una operación de dos pasos:
>
> ```sql
> UPDATE api_keys SET revoked_at = now() WHERE id = 'key_xxx';
> ```
> ```bash
> redis-cli DEL "cache:auth:<key_hash>"
> ```
>
> El segundo paso es obligatorio: el lookup de auth está cacheado
> (`AUTH_CACHE_TTL_SECONDS`, default 60s) y sin el `DEL` la key revocada
> sigue siendo aceptada hasta que el TTL expire. Cuando exista el endpoint
> de revocación, hará ambos pasos atómicamente.

### 6.3 Resumen del schema de la base de datos

```sql
merchants           -- merchant accounts, wallet addresses, routing prefs
api_keys            -- hashed API keys with prefix metadata
payment_intents     -- full intent lifecycle with status machine
webhook_endpoints   -- registered webhook URLs with event subscriptions
webhook_deliveries  -- delivery attempts, retry state, response codes
disputes            -- dispute lifecycle with IPFS evidence CIDs
x402_payments_used  -- tx_hash uniqueness table for replay protection
```

El schema completo (baseline) está en `packages/api/src/lib/schema.sql`,
con `IF NOT EXISTS` en todo para que sea re-aplicable. Para cambios
incrementales sobre una DB existente, hay un sistema de migraciones
versionadas en `packages/api/migrations/` que se aplica con
`pnpm migrate` (en la plataforma). El runner traquea cada versión
en la tabla `schema_migrations` y aplica cada archivo en su propia
transacción. Ver `packages/api/migrations/README.md`.

### 6.4 Rate limiting

El rate limiting se aplica globalmente por API key vía Redis:
- 100 requests por minuto para keys estándar
- Headers de límite devueltos en cada respuesta (`X-RateLimit-Remaining`, etc.)
- Las respuestas 429 incluyen el header `Retry-After`

### 6.5 Entrega de webhooks

Los webhooks se entregan con reintento de backoff exponencial:

```
Attempt 1:   immediate
Attempt 2:   30 seconds
Attempt 3:   5 minutes
Attempt 4:   30 minutes
Attempt 5:   2 hours
Attempt 6:   12 hours
After 6 failures: marked as failed, no more retries
```

Los payloads de webhook se firman con HMAC-SHA256:
```
Header: X-Signature: t=<timestamp>,v1=<hmac_hex>
HMAC input: <timestamp>.<payload_json>
```

Los comercios verifican las firmas usando `relay.webhooks.verify(payload, signature, secret)`.

---

## 7. Node Daemon

### 7.1 Qué hace un node

El daemon del nodeit es un servidor HTTP que:
1. Se registra on-chain en `NodeRegistry.sol` al iniciarse
2. Expone dos rutas públicas: `/health` e `/info`
3. Poletea la cola de autorizaciones ERC-3009 de la API y reclama las pendientes
4. Submitea `payIntentWithAuthorization` a `SettlementHub.sol` (pagando el gas) por cada autorización reclamada
5. Confirma el settlement vía el evento on-chain `IntentSettled` y notifica a la API
6. Mantiene su propio store local de intents liquidados para auditoría

### 7.2 Rutas del node en detalle

**`GET /health`** — liveness pública
```json
{
  "status": "ok",
  "version": "0.1.0",
  "operator": "0x...",
  "chains": ["base"],
  "capacity": 0.87
}
```
`capacity` es un float de 0–1 que representa el margen disponible del nodeit. Lo consume el motor de routing multi-node de Fase 2 (ver §5).

**`GET /info`** — métricas públicas de reputación
```json
{
  "operator": "0x...",
  "version": "0.1.0",
  "uptime_30d": 0.997,
  "avg_settlement_ms": 4200,
  "total_settled": 8432,
  "stake": "5000000000"
}
```
`stake` se devuelve como string para evitar problemas de precisión con BigInt de JavaScript.

`/health` e `/info` son los únicos endpoints HTTP que el daemon expone. El settlement no se hace por una ruta HTTP del nodeit (ver §7.3).

### 7.3 Settlement ERC-3009 (interno)

El settlement no se dispara por un endpoint HTTP expuesto del nodeit, sino por un loop interno del daemon:

1. El payer firma off-chain una autorización EIP-712 `ReceiveWithAuthorization` con su propia wallet. El SDK la envía a la API, que la encola.
2. El daemon del nodeit poletea esa cola, reclama una autorización pendiente y submitea `payIntentWithAuthorization` a `SettlementHub.sol`. **El nodeit paga el gas de esta transacción.**
3. `SettlementHub.sol` jala el USDC del payer y lo splittea atómicamente on-chain (99% comercio, 0.7% nodeit, 0.3% treasury) y emite `IntentSettled`.
4. Un event watcher confirma el settlement leyendo el evento `IntentSettled` y la API marca el intent como `settled`.

No hay autenticación HMAC entre la API y el nodeit: el nodeit consume la cola de la API y el settlement se valida on-chain, no por una firma de request. El comercio nunca define una dirección de pago — el USDC va del payer al comercio dentro de la transacción atómica del contrato.

### 7.4 Modelo de pago ERC-3009

CoatiPay liquida pagos con el estándar **ERC-3009 (`ReceiveWithAuthorization`)**, no con direcciones de pago derivadas por intent.

El payer firma off-chain una autorización EIP-712 — una estructura que incluye `from`, `to`, `value`, `validAfter`, `validBefore` y un `nonce` único — usando su propia wallet. Esa firma autoriza a `SettlementHub.sol` a jalar exactamente ese monto de USDC del payer cuando el contrato la presente on-chain.

Esto elimina por completo la necesidad de una dirección de pago única por intent y de derivación de HD wallet:

- No hay dirección derivada por intent — el payer paga desde su propia wallet.
- El `value` de la autorización fija el monto exacto; el contrato rechaza cualquier discrepancia. No es posible que un payer pague el monto equivocado y reclame otro intent.
- El `nonce` se consume on-chain en el primer uso, lo que previene replay de la autorización.
- El pago es **gasless para el payer**: el nodeit submitea la transacción y paga el gas.

---

## 8. Capa de SDK

### 8.1 Filosofía de diseño

El SDK está diseñado para sentirse idéntico al SDK de Stripe para los desarrolladores que han usado Stripe. Los mismos patrones: clases de recurso, async/await, verificación de webhooks, manejo de errores. El objetivo es cero fricción para la migración.

### 8.2 Flujo de request

```typescript
const relay = new CoatiPay({ apiKey: 'sk_live_xxx' })

// Creates a PaymentIntents resource instance
// All resource instances share the same HTTP client and config

await relay.paymentIntents.create(params)
// → POST https://api.coatipay.com/v1/payment_intents
// → Authorization: Bearer sk_live_xxx
// → Content-Type: application/json
// → CoatiPay-Version: 0.1
```

### 8.3 Manejo de errores

```typescript
try {
  const intent = await relay.paymentIntents.create({ ... })
} catch (e) {
  if (e instanceof CoatiPaySDKError) {
    console.log(e.code)    // 'invalid_api_key'
    console.log(e.message) // 'Missing or malformed Authorization header.'
    console.log(e.doc_url) // 'https://docs.coatipay.com/errors/invalid_api_key'
  }
}
```

Todos los errores de API son instancias de `CoatiPaySDKError`. Los errores de red (timeout, fallo de DNS) se re-lanzan como instancias estándar de `Error` — el SDK no se traga los fallos de red.

### 8.4 Configuración del host

El SDK apunta a la API de CoatiPay por defecto; `baseUrl` solo se usa para
entornos de prueba o instancias internas.

```typescript
const relay = new CoatiPay({ apiKey: 'sk_live_xxx' })
// baseUrl por defecto: 'https://api.coatipay.com'
```

---

## 9. Protocolo x402

### 9.1 Qué es x402

x402 es una implementación de HTTP 402 Payment Required para pagos máquina-a-máquina. Permite que cualquier servidor HTTP requiera un micropago antes de servir una respuesta, y que cualquier cliente HTTP (incluyendo agentes de IA) haga ese pago autónomamente.

Este es el primitivo de pago que hace posibles las economías de agentes de IA. Un agente que necesita datos de una API premium puede pagar por ellos sin intervención humana, tarjetas de crédito ni suscripciones.

### 9.2 El flujo HTTP de x402

```
Step 1 — Agent requests resource:
  GET /api/premium-data HTTP/1.1
  Host: merchant.example.com

Step 2 — Server responds with 402:
  HTTP/1.1 402 Payment Required
  Content-Type: application/json

  {
    "x402Version": 1,
    "accepts": [{
      "scheme": "exact",
      "network": "base",
      "maxAmountRequired": "1000",
      "resource": "https://merchant.example.com/api/premium-data",
      "description": "Premium data access",
      "mimeType": "application/json",
      "payTo": "0x...",              // merchant wallet on Base
      "maxTimeoutSeconds": 300,
      "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",  // USDC
      "extra": { "name": "USDC", "version": "2" }
    }]
  }

Step 3 — Agent constructs and signs a USDC transfer on Base

Step 4 — Agent retries with payment proof:
  GET /api/premium-data HTTP/1.1
  Host: merchant.example.com
  X-PAYMENT: <base64_encoded_payment_payload>

Step 5 — Server verifies payment on-chain via CoatiPay API:
  POST /v1/x402/verify
  { "payment": "<X-PAYMENT value>", "amount": 1000, "chain": "base" }

Step 6 — Server serves the resource:
  HTTP/1.1 200 OK
  X-PAYMENT-RESPONSE: <verification_result>
  Content-Type: application/json

  { "data": "premium content" }
```

### 9.3 Protección contra replay

El endpoint de verificación de x402 almacena cada `tx_hash` verificado en la tabla de PostgreSQL `x402_payments_used`. Las requests subsecuentes con el mismo `tx_hash` se rechazan con `402 Payment Required` — el agente debe hacer un nuevo pago on-chain.

Esto también se cachea en Redis para rendimiento: la primera verificación escribe tanto en PostgreSQL como en Redis. Las verificaciones subsecuentes pegan a Redis primero. El TTL de Redis es de 24 horas (más largo que la ventana de finalidad de Base).

### 9.4 Umbrales de micropagos

> **Diseño de Fase 2 (no implementado).** El routing por monto depende del motor de routing multi-nodo (roadmap) — hoy todo pago se liquida directo. Además, ojo con el piso económico (~$0.30/llamada): el ejemplo `price: 1000` ($0.001) está por debajo y sería rechazado.

Diseño previsto: los pagos chicos usan verificación directa on-chain (el overhead de asignación/routing/confirmación no se justifica); los pagos grandes se enrutan por la red de nodes.
```typescript
// (diseño Fase 2) amount < 10,000 → directo ; amount >= 10,000 → enrutado
relay.x402.middleware({ price: 1000 })  // $0.001 → directo (bajo el piso — ilustrativo)
relay.x402.middleware({ price: 50000 }) // $0.05  → enrutado
```

---

## 10. Ciclo de Vida de la Transacción

### 10.1 Flujo completo desde la llamada del SDK hasta el webhook

```
[Merchant code]
  relay.paymentIntents.create({ amount: 10_000_000, ... })
        │
        ▼
[POST /v1/payment_intents]   status: created
  API validates request
  Generates ID: pi_xxx
  Stores in PostgreSQL
        │
        ▼
[Payer firma la autorización ERC-3009]
  El payer firma off-chain una autorización EIP-712
  ReceiveWithAuthorization con su propia wallet
  (from, to, value, validAfter, validBefore, nonce)
  El SDK envía la firma a la API
        │
        ▼
[API encola la autorización]
  La autorización ERC-3009 entra en la cola de settlement
        │
        ▼
[Daemon del nodeit poletea la cola]
  Reclama la autorización pendiente
  Submitea payIntentWithAuthorization a SettlementHub.sol
  (el nodeit paga el gas)
        │
        ▼
[SettlementHub.sol — transacción atómica on-chain]
  Jala el USDC del payer vía ERC-3009
  Splittea el monto on-chain:
    99.0% → wallet del comercio
     0.7% → nodeit (OPERATOR_SHARE_BPS = 70)
     0.3% → treasury (TREASURY_SHARE_BPS = 30)
  Emite el evento IntentSettled
        │
        ▼
[Event watcher confirma]      status: settled
  Lee el evento IntentSettled on-chain
  La API marca el intent como settled en PostgreSQL
  Encola la entrega del webhook
        │
        ▼
[Webhook delivered to merchant]
  POST merchant's registered webhook URL
  Body: { id: 'evt_xxx', type: 'payment_intent.settled', data: { intent } }
  Signed with HMAC-SHA256
  Merchant fulfills order on verification
```

> **Nota — routing:** El flujo de arriba describe el modelo actual: un solo bootstrap nodeit poletea la cola. La selección de un nodeit entre varios candidatos según score es el motor de routing multi-node de Fase 2 (ver §5).

### 10.2 Transiciones de la máquina de estados (canónicas)

```
created → settled
  Triggered: el evento on-chain IntentSettled se confirma
  Condition: SettlementHub.sol liquidó el intent atómicamente

created → expired
  Triggered: se alcanza el timestamp expires_at
  Condition: el intent no llegó a settled

created → cancelled
  Triggered: el comercio cancela el intent
  Condition: el intent aún no está settled

created → failed
  Triggered: el settlement on-chain no se completó
  Condition: la autorización ERC-3009 fue rechazada por el contrato

settled → disputed
  Triggered: merchant calls dispute endpoint
  Condition: within 7 days of settled_at
```

**Estas transiciones son exhaustivas y exclusivas.** No existe transición fuera de esta tabla. Cualquier código que intente una transición no listada debe ser tratado como un bug.

---

## 11. Modelo Económico

### 11.1 Flujo de fees por transacción

Para un pago de $100.00 USDC:

```
Payer authorizes:  $100.000000 USDC vía firma ERC-3009 ReceiveWithAuthorization

On-chain:          SettlementHub.sol jala el USDC del payer y lo splittea
                   atómicamente en una sola transacción (sin payment_address
                   intermedia — el USDC va directo del payer al comercio)

Merchant receives: $99.000000 USDC
Node receives:     $00.700000 USDC (70% of 1.0% fee)
Treasury receives: $00.300000 USDC (30% of 1.0% fee)
```

Para un micropago x402 de $0.001 USDC (ilustrativo — está POR DEBAJO del piso económico:
la participación de $0.0000070 del node no cubre ~$0.003 de gas, así que el node no
liquidaría esto individualmente; sub-cent necesita netting):
```
Total fee:     $0.0000100 (1.0% of $0.001)
Node receives: $0.0000070
Treasury:      $0.0000030
```

El fee del protocolo es puramente proporcional (1.0%, sin componente fijo), pero cada settlement on-chain le cuesta al nodeit gas que paga de su 0.7%, así que un settlement on-chain **individual** solo alcanza el punto de equilibrio alrededor de **~$0.30/llamada** — y la API impone un piso `MIN_PAYMENT_AMOUNT` (default $0.30), rechazando intents por debajo. Los micropagos sub-cent reales solo son viables con **netting** off-chain (acumular muchas llamadas y liquidar la suma una vez), que está en el roadmap. Aun así, el modelo proporcional de CoatiPay le gana a los procesadores tradicionales cuyo fee fijo (~$0.30 *por* transacción) hace antieconómico cualquier pago pequeño a cualquier volumen.

### 11.2 Modelo de rentabilidad del node

Un node operator puede estimar las ganancias esperadas:

```
monthly_volume    = transactions_per_day × avg_amount × 30
monthly_gross_fee = monthly_volume × 0.01
node_earnings     = monthly_gross_fee × 0.70

Example: 1,000 tx/day, avg $50
  monthly_volume    = $1,500,000
  monthly_gross_fee = $15,000
  node_earnings     = $10,500/month in USDC
```

Costos para un node básico:
```
VPS (2 vCPU, 2GB RAM):  ~$20/month
Minimum stake (100 USDC mainnet · 40 USDC testnet): one-time, recoverable
Base gas for registration: ~$0.005
```

El umbral de rentabilidad ronda los $3,000 de volumen mensual (≈300 transacciones a $10, o 60 a $50) — el punto donde las ganancias del node cubren el costo del VPS. Muy por debajo de lo que cualquier comercio activo generaría.

### 11.3 Modelo del treasury

El treasury acumula el 30% de todos los protocol fees de la red hospedada. Uso en Fase 1:
- Auditorías de seguridad (requeridas antes de mainnet)
- Bounties para contribuidores
- Costos de desarrollo core

La asignación del treasury la decide la Fundación; el balance es públicamente visible on-chain (y vía un dashboard público planificado).

---

## 12. Modelo de Seguridad

### 12.1 Modelo de amenazas por actor

**Node operator malicioso**

*Amenaza:* Liquidar un intent y desviar los fondos a una dirección distinta de la del comercio.
*Mitigación:* El split lo ejecuta `SettlementHub.sol` en una transacción atómica on-chain — el nodeit no controla el destino de los fondos. La dirección del comercio está fijada en el intent (proviene de la capa de API) y el contrato envía el 99% a esa wallet. El nodeit solo submitea la transacción y paga el gas; no puede tocar ni redirigir el USDC.

*Amenaza:* Aceptar trabajo y luego irse offline sin liquidar el intent.
*Mitigación:* Timelock de retiro de stake de 7 días. El comercio puede abrir una dispute dentro de los 7 días. Las disputes sin respuesta disparan slashing automático vía `expireDispute()`.

**Ataque Sybil (muchos nodes falsos)**

*Amenaza:* Crear cientos de nodes de baja calidad para capturar volumen de routing.
*Mitigación:* El stake mínimo de 100 USDC por node hace los ataques Sybil costosos ($100 por node). Un node con stake mínimo tiene `stake_weight = 0.01` — necesitaría uptime y velocidad muy altos para competir con nodes bien stakeados. En 100 nodes falsos, el ataque cuesta $10,000 en USDC bloqueado.

**Compromiso de la key del comercio**

*Amenaza:* El atacante roba la secret API key del comercio y crea payment intents apuntando a su wallet.
*Mitigación:* La dirección del wallet del comercio se configura a nivel de cuenta, no por intent. Una API key comprometida no puede cambiar la wallet de destino — solo puede crear intents, ver historial y registrar webhooks. Los cambios de wallet requieren re-autenticación.

**Ataque de replay de x402**

*Amenaza:* Reutilizar un payment proof para múltiples llamadas a la API.
*Mitigación:* Cada `tx_hash` se almacena en `x402_payments_used` en el primer uso. Los intentos subsecuentes con el mismo `tx_hash` se rechazan. Redis cachea hashes recientes para rendimiento. PostgreSQL es el store durable.

**Replay de una autorización ERC-3009**

*Amenaza:* Reutilizar una autorización `ReceiveWithAuthorization` firmada para jalar fondos del payer más de una vez.
*Mitigación:* Cada autorización lleva un `nonce` único que `SettlementHub.sol` consume on-chain en el primer uso. Cualquier intento de presentar la misma autorización de nuevo es rechazado por el contrato. La autorización también acota la ventana de validez vía `validAfter`/`validBefore`.

**Double-spend**

*Amenaza:* El payer firma una autorización y luego intenta una reorganización de chain para revertir el settlement.
*Mitigación:* El settlement es una transacción atómica de `SettlementHub.sol`; el intent solo pasa a `settled` cuando el evento `IntentSettled` se confirma on-chain. La arquitectura L2 de Base hace que las reorganizaciones más allá de 1 bloque sean extremadamente improbables. Para transacciones de alto valor, los comercios pueden esperar confirmaciones adicionales antes de despachar.

### 12.2 Qué está explícitamente fuera de alcance

- **Gestión de keys del comercio** — responsabilidad del comercio
- **Seguridad del wallet del payer** — responsabilidad del payer
- **Cumplimiento KYC/AML** — responsabilidad del comercio bajo su jurisdicción
- **PCI DSS** — no aplica; no se procesan datos de tarjeta

### 12.3 Invariantes de smart contracts

Estas invariantes deben preservarse a través de todas las actualizaciones de contratos (despliegues) y pueden ser usadas por auditores para verificar la corrección:

1. `StakeManager.totalStaked() >= sum of all slashable amounts` — el contrato nunca crea balances negativos
2. `NodeRegistry.getActiveNodes()` nunca contiene una dirección con `active = false`
3. `DisputeResolver`: una dispute solo puede ser resuelta una vez (verificado vía `status != Resolved && status != Expired`)
4. `StakeManager`: un retiro no puede ser ejecutado antes de `unlockAt` (el timelock se aplica estrictamente)
5. `DisputeResolver`: un arbiter no puede votar dos veces en la misma dispute

### 12.4 Requisitos de auditoría

Los cuatro contratos (`NodeRegistry`, `StakeManager`, `DisputeResolver`, `SettlementHub`, más la base `Pausable` compartida) requieren auditorías de seguridad completas antes del despliegue en Base mainnet:
- Análisis estático (Slither, Mythril)
- Revisión manual por al menos dos investigadores de seguridad independientes
- Fuzzing con forge test --fuzz-runs 10000
- Simulación de ataques económicos

Los reportes de auditoría serán publicados en `/audits` en el repositorio. La comunidad debe tratar cualquier despliegue en mainnet sin una auditoría publicada como no confiable.

---

## 13. Guía de Operación de Node

### 13.1 Requisitos mínimos

| Recurso | Mínimo | Recomendado para producción |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 2 GB |
| Almacenamiento | 10 GB SSD | 50 GB SSD |
| Red | 100 Mbps | 1 Gbps |
| SLA de Uptime | 99% | 99.9% |
| Stake de USDC | 100 USDC (mainnet) · 40 USDC (testnet) | 1,000+ USDC |
| RPC de Base | Público (rate limited) | Dedicado (Alchemy, QuickNode) + backups vía `BASE_RPC_FALLBACK_URLS` |

### 13.2 Correr un nodeit

**La red es permissionless, y el daemon es público:**
[`coatipay-node`](https://github.com/lacasoft/coatipay-node).

No hay whitelist, ni alta que aprobar, ni secreto que pedirnos:

- El **registro on-chain** (`NodeRegistry.register`) acepta a cualquier dirección
  con stake suficiente.
- El **stake** y las reglas de slashing viven en contratos públicos y auditables,
  en este repositorio.
- La **reputación** se computa a partir de datos on-chain.
- La **autenticación** contra el API es por **firma del operador**: el daemon
  firma cada llamada con la llave con la que se registró, y el API recupera esa
  dirección y la comprueba contra `NodeRegistry`. Un operador solo puede actuar
  como sí mismo, porque no puede firmar con la llave de otro.

Para recibir trabajo hay que estar **registrado y activo** **y** mantener el
**stake bonded por encima del mínimo**. Las dos condiciones importan:
`NodeRegistry` solo comprueba el stake **al registrarse**, así que un nodo puede
seguir `active` después de retirarlo — y sin stake no hay garantía económica que
perder si se comporta mal.

```bash
# 1. Depositar el stake — register() NO transfiere USDC por ti
#    USDC.approve(StakeManager, 40_000_000)
#    StakeManager.deposit(40_000_000)

# 2. Registrar el endpoint — verifica que ya tengas >= minStake depositado
#    NodeRegistry.register("https://tu-nodo.example.com")

# 3. Levantar el daemon (ver el README de coatipay-node)
#    docker run -d --env-file .env ghcr.io/lacasoft/node:latest
```

### 13.3 Rotar la identidad del operador

No hay secreto compartido que rotar. El daemon firma con
`NODE_OPERATOR_PRIVATE_KEY`, que **es** su identidad on-chain.

Cambiarla no es rotar una credencial: es cambiar de nodo. El camino pasa por el
registro —dar de alta la dirección nueva con su propio stake, dejar que empiece
a tomar trabajo, y retirar la anterior— y hasta que la nueva esté registrada y
con stake, el API no le dará liquidaciones.

Protege esa llave como protegerías la wallet que respalda tu stake, porque es
exactamente eso.

### 13.4 Recomendaciones de monitoreo

Métricas a rastrear:
- `uptime_pct` — porcentaje de uptime rolling de 30 días
- `avg_settlement_ms` — tiempo promedio rolling de settlement
- `intents_claimed` — autorizaciones ERC-3009 reclamadas de la cola de la API
- `intents_settled` — intents confirmados exitosamente
- `intents_failed` — intents que no pudieron ser liquidados
- `disputes_open` — disputes abiertas actuales (debería ser 0)
- `stake_balance` — stake actual de USDC (alertar si se acerca al mínimo)

Alertas recomendadas:
- `uptime_pct < 0.99` — investigar inmediatamente (impacto en score)
- `disputes_open > 0` — responder dentro de 48 horas o perder la dispute
- `stake_balance < 200_000_000` (200 USDC) — recargar stake

### 13.5 Preparación de evidencia para disputes

Si un comercio abre una dispute contra tu node, tienes 48 horas para responder con contra-evidencia. Mantén logs de:
- Todas las asignaciones de intents (intent_id, amount, merchant_address, assigned_at)
- Todas las transacciones on-chain (tx_hash, block_number, settled_at, amount)
- Logs de uptime del node
- Cualquier log de error alrededor de la ventana de tiempo disputada

Empaqueta esto como un archivo JSON y súbelo a IPFS. El CID de IPFS es tu contra-evidencia.

---

## 14. Guía de Integración para Comercios

### 14.1 Preferencias de routing

```typescript
// Merchants can configure routing via API key settings
{
  routing: {
    mode: 'auto',           // 'auto' | 'whitelist' | 'blacklist'
    node_whitelist: [],     // only use these node operators
    node_blacklist: [],     // never use these node operators
    min_stake: 500_000_000, // minimum 500 USDC stake
    min_score: 0.8,         // minimum node score
  }
}
```

### 14.3 Mejores prácticas de webhooks

```typescript
// Always verify webhook signatures
app.post('/webhooks/coatipay', express.raw({ type: 'application/json' }), (req, res) => {
  let event
  try {
    event = relay.webhooks.verify(
      req.body.toString(),
      req.headers['x-signature'],
      process.env.WEBHOOK_SECRET
    )
  } catch (e) {
    // Invalid signature — reject immediately
    return res.status(400).send('Invalid signature')
  }

  // Idempotency: use event.id to deduplicate
  if (await db.eventProcessed(event.id)) {
    return res.status(200).send('Already processed')
  }

  // Process the event
  switch (event.type) {
    case 'payment_intent.settled':
      await fulfillOrder(event.data.metadata.orderId)
      break
    case 'payment_intent.failed':
      await notifyCustomer(event.data.metadata.orderId, 'payment_failed')
      break
    case 'dispute.opened':
      await alertMerchantTeam(event.data)
      break
  }

  // Respond quickly — process async if needed
  res.status(200).send('OK')
})
```

**Crítico:** CoatiPay reintenta los webhooks hasta 6 veces. Sin verificaciones de idempotencia, procesarás los eventos múltiples veces.

---

## 15. Guía de Despliegue

### 15.1 Desarrollo local

Este repositorio contiene el **protocolo y los contratos**. Lo que puedes correr
en local desde aquí:

```bash
# Contratos — tests, fuzz e invariantes
cd contracts
forge test -vvv

# Desplegar tu propia instancia de los contratos
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast

# Paquete de tipos y constantes
cd protocol
npm install && npm run build
npm run check:fee-constants   # verifica que no haya drift con SettlementHub.sol
```

El **API, el dashboard y el daemon del nodeit** no viven en este repositorio
(ver §2). Si solo quieres cobrar, no necesitas nada de esto: instala un SDK y
apunta a la API hospedada.

### 15.2 Despliegue en testnet (Base Sepolia)

El deploy de referencia en Base Sepolia ya está live (2026-04-18) — las direcciones canónicas están en `contracts/deployments/sepolia.json`. Los pasos a continuación son para operadores que quieren su propio deploy independiente en Sepolia; para solo conectar un node/API al deploy existente, lee ese JSON directamente.

```bash
# 1. Get testnet USDC
# Bridge from Ethereum Sepolia or use a faucet

# 2. Configure deployment .env
DEPLOYER_PRIVATE_KEY=0x...
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e  # Base Sepolia USDC
TREASURY_ADDRESS=0x...
ARBITER_1=0x...
ARBITER_2=0x...
ARBITER_3=0x...
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# 3. Deploy contracts
cd packages/contracts
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 4. Copy output contract addresses to root .env
NODE_REGISTRY_ADDRESS=0x...
STAKE_MANAGER_ADDRESS=0x...
DISPUTE_RESOLVER_ADDRESS=0x...

# 5. Start API and Node with testnet config
```

### 15.3 Despliegue en producción

Para despliegue en producción, consideraciones adicionales:

**Node daemon:**
- Correr detrás de nginx con TLS (Let's Encrypt)
- Usar un RPC dedicado de Base (Alchemy o QuickNode) y configurar **RPCs de respaldo** con `BASE_RPC_FALLBACK_URLS` (failover automático; el RPC público de Base ya se añade como último recurso)
- Configurar alertas para downtime y eventos de dispute
- Almacenar el secret HMAC en un secrets manager (no en archivo .env)

**Capa de API:**
- PostgreSQL con backups automatizados (diario mínimo)
- Redis con persistencia habilitada (AOF)
- Rate limiting ajustado al tráfico esperado
- API keys almacenadas como HMAC-SHA256 con pepper (nunca almacenar texto plano)

**Monitoreo:**
- Endpoint de health check monitoreado externamente (p. ej., UptimeRobot)
- Alertas en fallos de settlement y eventos de dispute
- Log de queries lentas de PostgreSQL habilitado

---

## 16. Análisis Comparativo

### 16.1 CoatiPay vs. Stripe

| | CoatiPay | Stripe |
|---|---|---|
| Fee por transacción | 1.0% | 2.9% + $0.30 |
| Transacción mínima | ~$0.30 (piso económico; sub-cent necesita netting — roadmap) | ~$0.50 (los fees hacen antieconómicas las menores) |
| Soporte de fiat | No | Sí (Visa, MC, ACH) |
| Soporte de cripto | USDC, BTC | Limitado |
| x402 (agentes de IA) | Nativo | No |
| Código abierto | Sí | No |
| Cobertura en México | Completa | Limitada (algunos productos) |
| Tiempo de setup | 1–2 horas | 30 minutos |
| Cumplimiento (KYC/AML) | Responsabilidad del comercio | Stripe lo maneja |

**Cuándo usar Stripe:** Cuando necesitas fiat (tarjetas de crédito, transferencias bancarias) o necesitas que alguien más maneje el cumplimiento. Stripe y CoatiPay son complementarios — muchos comercios deberían usar ambos.

**Cuándo usar CoatiPay:** Cuando aceptas cripto, necesitas cero fees, necesitas micropagos, estás construyendo infraestructura de agentes de IA, o estás en un mercado donde Stripe no llega.

### 16.2 CoatiPay vs. BTCPay Server

| | CoatiPay | BTCPay Server |
|---|---|---|
| Activo primario | USDC (stablecoin) | BTC |
| Soporte de x402 | Nativo | No |
| Red comunitaria | Sí (los nodeits ganan fees) | No |
| DX del SDK | Tipo Stripe | Más complejo |
| Enfoque en LATAM | Explícito | General |
| Lightning | No (fuera de alcance) | Sí (maduro) |
| Soporte de stablecoin | Foco principal | Secundario |

BTCPay Server es el precedente más cercano a CoatiPay. CoatiPay es esencialmente "BTCPay Server para USDC y la era de los agentes de IA."

### 16.3 CoatiPay vs. Alternativas institucionales (productos de BlackRock, CoinShares)

| | CoatiPay | Institucional |
|---|---|---|
| Propiedad | Comunidad / nadie | Accionistas |
| Fees | 0–1.0% | Por determinar (típicamente 0.5–2%) |
| Censurable | No (nodes sin permisos) | Sí (cumplimiento regulatorio) |
| Auditable | Totalmente (código abierto) | Parcialmente |
| Nativo para agentes de IA | Sí | No |
| Claridad regulatoria | Menor (problema del comercio) | Mayor (la institución maneja) |
| Modelo de confianza | Impuesto por el protocolo | Impuesto por la institución |

**El caso de coexistencia:** CoatiPay está posicionado para ser la capa de routing debajo de los productos institucionales, no para competir por clientes institucionales. Un banco desplegando un producto cripto de BlackRock necesita routing de pagos — CoatiPay puede proporcionar ese routing sin que la institución necesite controlar los rieles.

---

## 17. Invariantes y Garantías

Estas son las propiedades que CoatiPay garantiza a todos los participantes. Deben preservarse a través de todas las versiones, implementaciones y despliegues del protocolo.

### Para comercios

1. Los fondos recibidos en el wallet del comercio son tuyos — ninguna parte puede recuperarlos o congelarlos después del settlement
2. La ventana de dispute es siempre exactamente 7 días después del settlement — esto no puede ser acortado por ningún node o arbiter
3. Tu API key nunca se transmite en logs o mensajes de error — solo el prefijo de la key se almacena para identificación
4. Las firmas de webhook se computan sobre el payload exacto — cualquier modificación invalida la firma

### Para node operators

1. El stake solo puede ser slasheado por `DisputeResolver` — ningún otro contrato o dirección puede reducir tu stake
2. El timelock de retiro es exactamente 7 días — esto no puede ser extendido o acortado por ninguna parte
3. Una dispute que no es respondida en 48 horas resulta en slashing automático — no puedes evitarlo yéndote offline
4. Tu capacidad de routing se respeta — si devuelves `capacity < 0.1`, el routing engine no te asignará nuevos intents

### Para payers

1. Los pagos van al wallet del comercio — no a una cuenta custodia que podría ser congelada
2. Los pagos de x402 se verifican on-chain — un servidor no puede reclamar que el pago fue inválido para una transferencia on-chain confirmada

### Para el protocolo

1. No existe admin key que pueda mover fondos, actualizar o reescribir el estado de los contratos desplegados. La única acción privilegiada es una **pausa de emergencia** (la base `Pausable`) en manos de un guardian multisig 3-de-5 — bloquea el registro y las nuevas escrituras pero no puede mover fondos, detener settlements en vuelo, ni cambiar las reglas
2. El fee split (70/30 nodeit/treasury, 100 bps total — ver ADR-002) está codificado en el protocolo (`SettlementHub.sol` constants) y no puede cambiarse sin un nuevo despliegue
3. El stake mínimo (`minStake`) es una variable de estado ajustable por el guardian vía `NodeRegistry.updateMinStake()`, pero el contrato **rechaza reducciones** — solo incrementos. Esto permite que la red aumente la barrera anti-Sybil conforme madura (valor inicial: 100 USDC en mainnet, 40 USDC en Sepolia testnet) sin invalidar a operadores ya registrados.
4. Todos los registros de nodes son sin permisos — ningún comité de whitelist puede bloquear a un node de unirse

---

*Este documento refleja el estado de CoatiPay en v0.1. Se actualiza con cada decisión arquitectónica significativa.*

*Para preguntas, abre una discusión en GitHub. Para problemas de seguridad, envía un email a security@coatipay.com.*
