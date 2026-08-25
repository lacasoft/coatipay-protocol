# CoatiPay

## White Paper v0.1

**Red abierta de pagos para el mundo hispanohablante**

_Abril 2026_

---

## Resumen Ejecutivo

CoatiPay es una red de enrutamiento de pagos de código abierto. Cualquiera puede operar un nodeit, cualquier comercio puede recibir pagos en USDC con cero comisiones, y los desarrolladores tienen una experiencia similar a Stripe: SDK limpios, webhooks, payment intents.

Lo que ofrecemos:

- **Red comunitaria:** 1.0% por transacción (vs 2.9%+ de Stripe)
- **Soporte x402 nativo:** micropagos gasless para agentes de IA (USDC-native, sin necesidad de ETH); económicamente viables desde ~$0.30/llamada en Base — el sub-centavo requiere netting off-chain (hoja de ruta)
- **SDK en TS, Python, PHP:** la misma DX que ya conoces (JS en npm y Python en PyPI publicados; PHP pendiente en Packagist)

No hay token especulativo. No custodiamos fondos. Los pagos van directo de cliente a comercio.

---

## 1. Por qué existe CoatiPay

### 1.1 Pagos digitales en América Latina hoy

América Latina está en plena digitalización de pagos. México, Colombia, Chile, Argentina y Brasil tienen políticas activas para reducir el uso de efectivo. Esto es una oportunidad enorme para construir infraestructura abierta.

Pero hoy las opciones son limitadas:

| Solución | Problema |
|----------|----------|
| Stripe | 2.9% + $0.30, no llega a todo LATAM |
| Mercado Pago, Clip, Conekta | Comisiones similares, ecosistemas cerrados |
| BTCPay Server | Excelente pero solo BTC, sin red de nodeits, DX más pesada |

No existe una opción que sea todo esto a la vez:

- Código abierto
- Comisiones casi cero
- Fácil de integrar como Stripe
- Con una red comunitaria de nodeits
- Que hable español como ciudadano de primera clase

Esa es la razón de CoatiPay.

### 1.2 Para quién es esto

- **Comercios** que quieren dejar de pagar 3% por cada venta
- **Desarrolladores** que quieren integrar pagos en minutos, no semanas
- **Operadores de nodeit** que quieren ganar USDC enrutando transacciones
- **Proyectos de IA** que necesitan micropagos máquina→máquina
- **Comunidades crypto** que quieren participar en infraestructura real

No necesitas ser experto en blockchain. Si sabes usar Stripe, sabes usar CoatiPay.

---

## 2. Qué hace CoatiPay

> **Sobre la terminología:** El protocolo CoatiPay define una red de **nodos** — servidores que facilitan el enrutamiento de pagos entre cliente y comercio. **`nodeit`** es la implementación de referencia: el daemon open source que estoy desarrollando. Cualquier daemon compatible con el protocolo puede registrarse en el `NodeRegistry`; el mío se llama `nodeit`. En el resto de este documento uso **nodeit** cuando hablo de una instancia concreta del software de referencia, y reservo *nodo* para las especificaciones técnicas del protocolo (ver `PROTOCOL.md`).

### 2.1 Modelo de pagos

CoatiPay es una capa de enrutamiento. No es un banco, no es un gateway fiat, no custodia dinero.

```
Cliente → (paga USDC directo) → Comercio
              ↑
              │
         Nodeit CoatiPay
    (observa, confirma, cobra fee)
```

El nodeit nunca toca los fondos. Solo confirma que la transacción ocurrió y avisa al comercio via webhook.

### 2.2 Cómo se cobra

**Comisión del protocolo: 1.0% (100 bps) sobre cada pago liquidado.**

El comercio recibe el **99%** de forma directa; el 1% restante se reparte
on-chain, en la misma transacción, sin que nadie lo custodie en el camino:

- **0.7%** (70% de la comisión) → el **nodeit** que enrutó el pago
- **0.3%** (30% de la comisión) → el treasury del protocolo

Son $10 por cada $1,000 movidos, frente a ~$29 de una pasarela de tarjeta: un
65% menos. No hay cuota mensual, ni alta, ni mínimos.

El reparto está fijado en `SettlementHub.sol` y es verificable on-chain. La
parte del nodeit es lo que hace que operar uno tenga sentido económico, y la
del protocolo es lo que sostiene el desarrollo de la red.

### 2.3 Incentivos para operadores de nodeit

Cualquiera puede operar un nodeit. Solo necesitas:

1. Depositar el `minStake` on-chain (**100 USDC en mainnet · 40 USDC en Sepolia testnet**). El stake es recuperable vía `StakeManager.withdraw()` con timelock de 7 días. El guardian puede aumentar `minStake` conforme la red madura — nunca reducirlo — sin afectar a operadores ya registrados.
2. Correr el software en un VPS (~$20/mes)
3. Mantener buen uptime y velocidad

**Ganas:** 70% del fee de cada transacción que enrutas (el 0.7% del monto).
Con $1.5M de volumen mensual → ~$10,500/mes en USDC.
Con $10k/día (500 pagos a $20 promedio) → ~$2,100/mes vs ~$130/mes de costos fijos = **break-even cómodo**.

No hay token. No hay mining. Solo trabajo real por pago real.

---

## 3. Arquitectura técnica

### 3.1 Capas

```
┌─────────────────────────────────────────┐
│  SDK (TypeScript, Python, PHP)          │
├─────────────────────────────────────────┤
│  REST API (Fastify + Postgres + Redis)  │
├─────────────────────────────────────────┤
│  Motor de routing y reputación          │
├─────────────────────────────────────────┤
│  Contratos on-chain (Base)              │
│  - NodeRegistry                         │
│  - StakeManager                         │
│  - DisputeResolver                      │
│  - SettlementHub                        │
├─────────────────────────────────────────┤
│  Settlement (USDC en Base)              │
└─────────────────────────────────────────┘
```

### 3.2 Contratos inteligentes

Cuatro contratos en Base:

- **NodeRegistry:** registro público de nodeits, cualquiera se registra con stake ≥ `minStake` (100 USDC mainnet · 40 USDC testnet; ajustable por guardian, solo incrementos)
- **StakeManager:** depósitos, retiros con timelock 7 días, slashing por disputas
- **DisputeResolver:** si un nodeit no responde en 48 horas, pierde stake automático. Árbitros gestionados por multisig 3-de-5
- **SettlementHub:** el contrato que mueve los fondos — jala el USDC del payer y lo splittea atómicamente on-chain (99% comercio / 0.7% nodeit / 0.3% treasury) en una sola transacción; corazón del settlement gasless ERC-3009

Los cuatro contratos incluyen:
- Guardian con capacidad de pausa de emergencia (ver sección 5.2)
- Eventos para indexación off-chain
- Custom errors para optimización de gas

**Sobre el guardian:** diseños anteriores del protocolo planteaban contratos "sin llaves de admin, sin pausa". En la práctica, un exploit descubierto post-deploy sin mecanismo de pausa significa pérdida total de fondos para los afectados. Elegimos el compromiso pragmático: hay pausa de emergencia, pero está gobernada por un multisig 3-de-5 — nunca por una llave única — mantenido por la Fundación/equipo core (en producción recomendamos un multisig de hardware wallets). No hay una migración a gobernanza on-chain comprometida: lo que descentralizamos es la **operación** de la red (cualquiera corre un nodeit), no el control de los contratos.

### 3.3 Flujo de una transacción

CoatiPay liquida pagos con **ERC-3009 gasless**: el cliente firma una autorización, no envía una transferencia.

```javascript
// 1. El comercio crea un PaymentIntent
const intent = await coatipay.paymentIntents.create({
  amount: 5000,  // 50.00 USDC
  currency: 'USDC',
  webhookUrl: 'https://micomercio.com/webhook'
})

// 2. El cliente firma off-chain una autorización ERC-3009
//    (ReceiveWithAuthorization, EIP-712) con su propia wallet.
//    El SDK la envía a la API, que la encola.

// 3. El daemon del nodeit reclama la autorización de la cola
//    y submitea payIntentWithAuthorization a SettlementHub.sol
//    (el nodeit paga el gas — el pago es gasless para el cliente)

// 4. SettlementHub.sol jala el USDC del cliente y lo splittea
//    atómicamente on-chain: 99% al comercio, 0.7% al nodeit,
//    0.3% al treasury. Emite el evento IntentSettled.

// 5. Un event watcher confirma el evento IntentSettled on-chain
//    y la API marca el intent como settled.

// 6. Webhook al comercio: status = 'settled'
```

El nodeit nunca intercepta los fondos: el USDC se mueve del cliente al comercio dentro de una sola transacción atómica del contrato.

### 3.4 Sistema de scoring — Fase 2 (planificado)

Con un solo bootstrap nodeit, hoy no hay selección entre candidatos: cada intent va a la cola de la API y lo liquida ese nodeit. Cuando la red abra a registro permissionless en Fase 2, cada nodeit tendrá un score público y la API repartirá el tráfico según ese score:

```
Score = (uptime_30d × 0.30)
      + (velocidad_settlement × 0.30)
      + (stake × 0.20)
      + (ratio_disputes_ganados × 0.20)
```

Un nodeit con mal comportamiento perderá tráfico orgánicamente — sin que nadie lo expulse. Un nodeit con excelente historial ganará más tráfico y más fees. El motor de routing multi-node (descubrimiento de nodeits desde `NodeRegistry.sol`, scoring por reputación, racing paralelo) es una feature de Fase 2.

### 3.5 x402 — Pagos para agentes de IA

HTTP 402 es un estándar para pagos máquina→máquina: un agente IA paga por una llamada y recibe datos. El monto debe cubrir el gas de liquidación (piso ~$0.30/llamada en Base; ver §nota de economía abajo).

**Primera petición sin pago:**

```http
GET /api/datos HTTP/1.1
Host: api.ejemplo.com
```

```http
HTTP/1.1 402 Payment Required
Content-Type: application/json

{
  "amount": 1000,
  "asset": "USDC",
  "payTo": "0x742d35Cc...",
  "chain": "base"
}
```

**Segunda petición con prueba de pago:**

```http
GET /api/datos HTTP/1.1
Host: api.ejemplo.com
X-PAYMENT: eyJ0eF9oYXNoIjoiMHgxMjM0Li4uIiwiY2hhaW4iOiJiYXNlIn0=
```

```http
HTTP/1.1 200 OK
Content-Type: application/json

{ "data": "..." }
```

Stripe no puede hacer pagos pequeños (su fee mínimo de ~$0.30 + porcentaje los hace inviables). Nosotros liquidamos pagos pequeños gasless on-chain a partir de ~$0.30/llamada.

> **Nota de economía (honesta).** El node paga el gas (ETH) y se queda el 0.7% del fee (USDC), así que cada liquidación tiene un piso: con gas de Base (~$0.002–0.005) el break-even ronda **~$0.30/llamada**. El node nunca liquida por debajo de ese piso (lo escala con el gas en vivo). Los micropagos **sub-centavo** ($0.001) solo se vuelven rentables con **netting** (acumular muchas llamadas de un pagador y liquidar la suma en una sola tx) — está en la hoja de ruta.

---

## 4. Economía

### 4.1 Comisiones

| Concepto | Fee | Quién paga |
|----------|-----|------------|
| Comisión del protocolo | 1.0% (100 bps) | Comercio |
| Alta, cuota mensual o mínimos | — | No aplica |

Distribución del 1.0%:

- **70%** → nodeit (USDC) — 0.7% del monto
- **30%** → treasury del protocolo — 0.3% del monto

> **Nota — micropagos x402**: el split aplica igual on-chain. El payer ya es **gasless** vía
> ERC-3009 — firma una autorización off-chain y el nodeit submitea la tx y paga el gas (ETH),
> así que el payer nunca necesita ETH. Lo que limita los micropagos no es el gas del payer
> sino el piso económico: con gas de Base (~$0.0036 por intent) cada liquidación on-chain tiene
> un break-even de **~$0.30/llamada**. El **sub-centavo** ($0.001) solo se vuelve rentable con
> **netting off-chain** (acumular muchas llamadas de un mismo payer y liquidar la suma en una
> sola tx) — está en la hoja de ruta, no implementado hoy. Ver ADR-002
> (`audits/adr/002-fee-structure-and-gas-abstraction.md`) para análisis económico completo.

### 4.2 Economía del nodeit

Los ingresos del nodeit escalan con el volumen de la red. Dos escenarios:

**Escenario realista — Fase 1 (red nueva)**

```
Volumen mensual  = 1 comercio mediano × $50,000
Fee total        = $50,000 × 0.010 = $500
Ingreso del nodeit = $500 × 0.70 = $350/mes en USDC

Resultado: cubre VPS + costos fijos cómodamente desde el primer comercio.
```

**Escenario maduro — Fase 2+ (red con tracción)**

```
Volumen mensual  = 1,000 tx/día × $50 promedio × 30 días = $1,500,000
Fee total        = $1,500,000 × 0.010 = $15,000
Ingreso del nodeit = $15,000 × 0.70 = $10,500/mes en USDC

Resultado: salario competitivo para infraestructura ~$130/mes.
```

**Costos fijos para cualquier nodeit:**

```
VPS (2 vCPU, 2GB RAM):    ~$20/mes
Stake (100 USDC mainnet): único, recuperable con timelock 7 días
                          (Sepolia testnet: 40 USDC)
Gas de registro en Base:  ~$0.005 (una sola vez)
Gas operacional por intent: ~$0.0036 (registerIntent en Base mainnet)
                           — lo paga el nodeit (el payer es gasless vía ERC-3009);
                             para el caso x402 sub-centavo ver ADR-002 sobre netting.
Total fijo aprox:         ~$110-130/mes
```

Break-even al 0.7%: ~124 pagos/día con avg $5 (vs ~217/día al 0.4% del split anterior). Operadores chicos quedan dentro.

### 4.3 Comparación real

Comercio que procesa $50,000/mes:

| Plataforma | Comisión mensual | Ahorro anual vs Stripe |
|-----------|-----------------|----------------------|
| Stripe | ~$1,480 | — |
| CoatiPay (red) | $500 | $11,760 |
| CoatiPay (auto) | $0 + $30 VPS | $17,400 |

> Nota: aunque el fee subió de 50 a 100 bps (ADR-002), CoatiPay sigue ahorrándole al comercio
> ~65-90% vs Stripe en pagos típicos LATAM, mientras que el split 70/30 hace viable la economía
> del nodeit y acelera 3× el path al treasury auto-financiable.

### 4.4 Treasury

El 30% del fee se acumula en el treasury y financia:

- Auditorías de seguridad
- Desarrollo core y bounties
- Costos operativos iniciales

El treasury lo gestiona la Fundación; su balance es públicamente visible on-chain y los reportes financieros son públicos.

---

## 5. Seguridad

### 5.1 Modelo de amenazas

| Amenaza | Mitigación |
|---------|------------|
| Nodeit roba fondos | Imposible — los fondos nunca pasan por nodeits |
| Nodeit cobra sin liquidar | Disputa + slashing del stake |
| Ataque Sybil | Stake mínimo 100 USDC |
| Exit scam | Timelock 7 días para retirar stake |
| Replay de pagos x402 | Redis `SET NX` + hash de tx en DB |
| Double-spend | Confirmación on-chain requerida |
| Llave HMAC comprometida | Por-nodeit, rotable sin downtime |

### 5.2 Mecanismos de protección

- **Pausa de emergencia:** Guardian puede pausar contratos si se detecta un exploit
- **Multisig para gobernanza:** Agregar árbitros requiere 3-de-5 aprobaciones
- **HMAC-SHA256:** Comunicación API↔Nodeit firmada con ventana de 60 segundos
- **Replay atómico:** Redis `SET NX` previene doble uso de transacciones x402
- **Rate limiting:** 100 req/min por API key con Redis
- **SSRF protection:** URLs de webhooks validadas contra rangos IP privados
- **Non-custodial:** El protocolo nunca tiene acceso a fondos de merchants o clientes

### 5.3 Auditorías requeridas

Antes de mainnet:

1. Cuatro contratos inteligentes (NodeRegistry, StakeManager, DisputeResolver, SettlementHub) + base `Pausable` — firma independiente
2. Daemon del nodeit — revisión HMAC e implementación de llaves
3. API — penetration test de autenticación y webhooks

Los reportes se publicarán en el repositorio público.

---

## 6. Gobernanza

### 6.1 Por fases

| Fase | Quién gobierna |
|------|---------------|
| 1 | Fundación + multisig del equipo core |
| 2 | Red permissionless + disputas automáticas (la **operación** se descentraliza) |
| 3 | Fundación + multisig del equipo core (el control de los contratos sigue en la Fundación) |

> CoatiPay descentraliza la **operación** de la red (cualquiera corre un nodeit, las disputas son por multisig de árbitros), no el **control de los contratos**: el guardian y el conjunto de árbitros los mantiene la Fundación. No hay gobernanza on-chain comprometida.

### 6.2 Lo que no haremos

- **No habrá token RELAY.** No ICO, no IDO, no "community sale". Los operadores ganan USDC, no tokens especulativos.
- **No habrá fees ocultos.** El 1.0% es público, auditado, on-chain.
- **No venderemos datos.** CoatiPay no monetiza datos de transacciones.

---

## 7. Estado actual y limitaciones

### 7.1 Qué funciona hoy (v0.1)

- Los cuatro contratos inteligentes desplegados (NodeRegistry, StakeManager, DisputeResolver, SettlementHub) + la base `Pausable` heredada, con ~172 tests (unit + fuzz) en Foundry pasando
- **Deploy en Base Sepolia live** con contratos verificados en Basescan (ver `packages/contracts/deployments/sepolia.json`)
- SDK JS/Python/PHP publicables, con tests
- REST API completa (payment intents, webhooks, x402) con ~184 tests
- Daemon del nodeit con verificación on-chain real via viem
- Settlement gasless ERC-3009: el cliente firma una autorización `ReceiveWithAuthorization` y `SettlementHub.sol` jala el USDC y lo splittea atómicamente on-chain
- Webhook queue persistente en Redis (tolerante a crashes)
- CI/CD con typecheck, tests, security audit, coverage

### 7.2 Qué no funciona todavía

Seamos honestos:

- **Deploy en Base Sepolia completo (testnet)** — addresses en `packages/contracts/deployments/sepolia.json`. Mainnet aún no: está bloqueado por auditoría externa pendiente.
- **No hay auditoría externa.** Es requisito obligatorio antes de mainnet. Presupuestado contra el treasury de Fase 2.
- **Solo USDC en Base.** Hoy el único chain de settlement es Base; Polygon y Solana son hoja de ruta (Fase 3). BTC/Lightning quedó fuera de alcance (considerado y descartado).
- **Sin on-ramps fiat — hoy el cliente debe ya tener USDC.**
- **Dashboard de merchant es placeholder.** En Fase 1 se opera via SDK y CLI. UI web viene en Fase 2.
- **Red comunitaria no existe aún.** En Fase 1 corres tu propio nodeit. La red permissionless abre en Fase 2.
- **Routing multi-node es Fase 2.** Hoy hay un solo bootstrap nodeit: cada intent va a una cola y ese nodeit lo liquida, sin pre-ruteo. El motor de routing multi-node (descubrimiento de nodeits desde `NodeRegistry.sol`, scoring por reputación, racing paralelo) está especificado pero no implementado — llega en Fase 2.

**Si estás evaluando CoatiPay para producción hoy: todavía no lo está.** Phase 1 es para developers que quieren entender, romper y mejorar el protocolo en testnet. Las transacciones de Sepolia son juguetes — cero valor económico real. Integrar comercios reales requiere mainnet, y mainnet requiere la auditoría externa que sigue pendiente. Si eres dev/auditor: bienvenido. Si eres comercio: estamos en cola para ti, abrimos en Phase 2.

---

## 8. Hoja de ruta

### Fase 1 — Fundación

> **Reframe estratégico (2026-05-09) — Luis Campos (LACA-SOFT):** El plan original incluía "Primer comercio" en esta fase. Eso fue un error de framing — ningún comercio real va a procesar ventas sobre testnet. La secuencia correcta es **capital → auditoría externa → mainnet → primer comercio**. Phase 1 cierra cuando el protocolo está en mainnet con auditoría pasada, no antes. "Primer comercio" se mueve a Phase 2.

- ✅ Contratos + tests en Foundry (cuatro contratos desplegados + base `Pausable`; ~172 tests, fuzz testing)
- ✅ SDK JavaScript, Python, PHP
- ✅ Verificación on-chain de pagos via viem
- ✅ Settlement gasless ERC-3009 vía `SettlementHub.sol` (split atómico on-chain)
- ✅ CI/CD con GitHub Actions
- ✅ Auditoría interna de seguridad (ver [`docs/audits/2026-04-15-internal-snapshot.md`](docs/audits/2026-04-15-internal-snapshot.md))
- ✅ Deploy en Base Sepolia — versión actual 2026-05-09 con fixes de tanda C (slash 20% real, treasury transfer, guards de zero-address). Ver [`packages/contracts/deployments/sepolia.json`](packages/contracts/deployments/sepolia.json).
- ✅ Primer bootstrap nodeit registrado on-chain y operativo en producción
- ✅ Repositorio público en GitHub bajo `lacasoft/coatipay-protocol`
- 🔄 **Capital recaudado para auditoría externa** ($20-50k estimado para firma; $5-15k para auditor independiente)
- 🔄 **Auditoría externa contratada y completada**, findings remediados
- 🔄 **Deploy a Base mainnet** con `minStake = 100 USDC`
- 🔄 **Bootstrap nodeit en mainnet** (mismo daemon, contratos mainnet)

### Fase 2 — Tracción real en mainnet

- 🔄 **Primer comercio piloto en mainnet** (México) — primera venta real procesada por CoatiPay con USDC real
- Registro permissionless de nodeits en Base mainnet
- Motor de routing con reputación on-chain
- Plugin WooCommerce
- Dashboard de comercio (Next.js)
- Primeros nodeits comunitarios (México, España, Argentina)

### Fase 3 — Ecosistema

- Multi-chain (Polygon, Solana)
- SDK Go para agentes IA
- Treasury autosustentable

### Criterios para v1.0

1. Auditoría completa desplegada en Base mainnet
2. ≥10 nodeits comunitarios independientes activos
3. SDK en producción en al menos un comercio real

---

## 9. Cómo participar

### Desarrolladores

```bash
git clone https://github.com/lacasoft/coatipay-protocol
cd coatipay-protocol
docker-compose up
```

### Comercios

```javascript
import { CoatiPay } from '@lacasoft/coatipay-sdk'

const client = new CoatiPay({ apiKey: 'sk_test_...' })
const intent = await client.paymentIntents.create({
  amount: 2500,  // 25.00 USDC
  currency: 'USDC'
})
```

### Operadores de nodeit

```bash
# Registrar nodeit on-chain (stake >= minStake: 100 USDC mainnet · 40 USDC testnet)
# Correr el daemon
npm run node:start
```

### Comunidad

- **GitHub:** issues y PRs
- **Traducciones** de documentación
- **Grupos locales** en LATAM y España

---

## Apéndice A — Stack técnico

| Componente | Tecnología | Razón |
|-----------|-----------|-------|
| Monorepo | Turborepo + pnpm | Estándar actual, cache de CI |
| Lenguaje | TypeScript 5.5 strict | Seguridad de tipos end-to-end |
| API | Fastify 4 | 3× más rápido que Express |
| Base de datos | PostgreSQL 16 | JSONB, ACID, probado en producción |
| Cache | Redis 7 | Rate limiting, replay protection |
| Blockchain | viem 2 | Type-safe, estándar para Base/EVM |
| Contratos | Solidity 0.8.25 + Foundry | Mejor DX de testing |
| Chain | Base (USDC) | Fees sub-centavo, ecosistema x402 |
| Linter | Biome | Linting y formato en una herramienta |
| Validación | Zod | Runtime type safety |
| Tests | Vitest + Foundry | Cobertura TS y Solidity |
| CI/CD | GitHub Actions | PR validation + releases |
| Contenedores | Docker + Compose | Deploy en un comando |

---

## Apéndice B — Constantes del protocolo

```
PROTOCOL_VERSION         = "0.1"
USDC_BASE_ADDRESS        = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
USDC_DECIMALS            = 6
minStake (mainnet)       = 100,000,000   (100 USDC) — initial value at deploy
minStake (Sepolia)       =  40,000,000   ( 40 USDC) — initial value at deploy
                           adjustable by guardian via NodeRegistry.updateMinStake(),
                           increase-only (never reduced).
PROTOCOL_FEE_BPS         = 100           (1.0%)   — generated from SettlementHub.sol
NODE_FEE_SHARE           = 0.70          (70% al nodeit)  — derived from OPERATOR_SHARE_BPS / PROTOCOL_FEE_BPS
TREASURY_FEE_SHARE       = 0.30          (30% al treasury) — derived from TREASURY_SHARE_BPS / PROTOCOL_FEE_BPS
OPERATOR_SHARE_BPS       = 70            (0.7% del monto)
TREASURY_SHARE_BPS       = 30            (0.3% del monto)
DEFAULT_INTENT_TTL       = 1800          (30 minutos)
DISPUTE_WINDOW_DAYS      = 7
STAKE_WITHDRAWAL_DAYS    = 7
ROUTING_CANDIDATES       = 5
BASE_CONFIRMATIONS       = 1
NODE_RESPONSE_WINDOW     = 48 horas
SCORE_CACHE_TTL          = 60 segundos
```

---

## Apéndice C — Glosario

**Payment Intent** — La unidad fundamental de CoatiPay. Representa una intención de pago con un ciclo de vida definido: `created → settled`. Estados terminales adicionales: `cancelled`, `expired`, `failed`; `disputed` para el flujo de disputas.

**Nodo** — Concepto del protocolo: servidor registrado on-chain que facilita el enrutamiento de pagos. Observa transacciones y confirma settlements. Nunca custodia fondos. Ver `PROTOCOL.md` para la especificación técnica.

**Nodeit** — La implementación de referencia de un nodo CoatiPay. El daemon open source distribuido por este proyecto. Cualquier daemon compatible con el protocolo puede actuar como nodo; nuestro daemon se llama `nodeit` (ver `packages/node/` en el repo).

**Stake** — USDC depositado por un operador de nodeit como garantía económica de buen comportamiento.

**Slashing** — Reducción forzada del stake como consecuencia de perder un dispute.

**Score** — Métricas de reputación computadas públicamente (uptime, velocidad, stake, historial).

**x402** — Protocolo HTTP 402 Payment Required para pagos máquina-a-máquina entre agentes de IA.

**Settlement** — Confirmación on-chain de que los fondos llegaron al wallet del merchant.

**Treasury** — Fondo del protocolo (30% de fees) que financia desarrollo y auditorías.

**USDC** — USD Coin, stablecoin 1:1 con USD emitida por Circle. Asset de settlement primario.

---

## Contacto y recursos

| Recurso | Enlace |
|---------|--------|
| Repositorio | github.com/lacasoft/coatipay-protocol |
| Documentación | docs.coatipay.com |
| SDK npm | @lacasoft/coatipay-sdk |
| Protocolo x402 | x402.org |
| Contacto | hola@coatipay.com |
| Seguridad | security@coatipay.com |

---

_Apache License 2.0 — construido por la comunidad, para el mundo hispanohablante y más allá._

_v0.1 — Abril 2026_
