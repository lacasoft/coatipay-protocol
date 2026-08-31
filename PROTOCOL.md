# Especificación del Protocolo CoatiPay

**Versión:** 0.1 (Borrador)
**Estado:** Trabajo en progreso
**Autores:** Contribuidores de CoatiPay

---

## Resumen

Este documento define el Protocolo CoatiPay — las reglas, estructuras de datos, formatos de mensajes y máquinas de estado que rigen cómo se crean, enrutan, liquidan y confirman los payment intents a través de la red CoatiPay.

Cualquier implementación que se ajuste a esta especificación es un node CoatiPay válido. Cualquier SDK que se ajuste a esta especificación puede enrutar a través de cualquier node compatible. La compatibilidad se define por este documento, no por ninguna implementación de referencia.

---

## Justificación del Diseño

Antes de la especificación técnica, esta sección documenta por qué el protocolo está diseñado como está. Cada decisión tiene una razón. Entender las razones ayuda a los contribuidores a realizar mejores cambios.

### Por qué los fondos nunca pasan por los nodes

La invariante de protocolo más importante. Los nodes son observadores y confirmadores — detectan transferencias on-chain y las confirman a la capa de API. Nunca retienen ni intermedian fondos.

Este diseño fue elegido porque elimina toda una clase de ataques: un node malicioso no puede robar fondos en tránsito, porque los fondos nunca están en tránsito a través del node. La superficie de ataque se limita a: (a) un node mintiendo sobre una liquidación que no ocurrió — lo desmiente el evento on-chain `IntentSettled`, que es la única fuente de verdad del settlement, o (b) un node quedándose offline tras la asignación — el intent caduca en `expires_at` y nadie cobra fee, porque el fee del nodeit solo existe dentro de la transacción que liquida.

Cualquier cambio de protocolo que haga pasar fondos a través de los nodes debe tratarse como una regresión crítica, no como una feature.

### Por qué contratos no actualizables

Los contratos actualizables (patrones proxy) le dan a alguien — inevitablemente al deployer o a un multisig — el poder de cambiar las reglas después del hecho. Ese poder es incompatible con el modelo de confianza de un protocolo comunitario.

Si un bug requiere corrección, la respuesta correcta es: (1) divulgarlo, (2) pausar la funcionalidad afectada mediante una decisión comunitaria, (3) desplegar nuevos contratos, (4) migrar con consentimiento comunitario. Esto es más lento que una actualización. También es confiable de una manera que las actualizaciones no lo son.

### Por qué nodes sin permisos (no una whitelist)

Un comité de whitelist es un vector de centralización. Quien controle la whitelist controla la red. En el contexto de la infraestructura de pagos de LATAM, una whitelist controlada por el equipo fundador podría ser presionada por reguladores, adquirida por una institución, o simplemente convertirse en un cuello de botella a medida que cambian las prioridades del equipo.

El registro sin permisos con incentivos económicos (stake, reputación, fees) logra el mismo filtrado de calidad sin centralización. Un node con mal comportamiento pierde el routing orgánicamente — sin necesidad de comité.

### Por qué USDC, no un token de protocolo

Un token de protocolo crea una capa de especulación sobre la capa de pagos. Cada decisión económica queda enredada con la dinámica del precio del token. Los contribuidores son incentivados a promover el token en lugar de construir el producto. Los usuarios se confunden sobre si están usando un sistema de pagos o un instrumento financiero.

USDC es aburrido. Es 1:1 con USD, redimible por Circle, y aceptado en todas partes. Los operadores de nodes ganan USDC aburrido. El treasury acumula USDC aburrido. Este es el tipo correcto de aburrimiento para la infraestructura de pagos.

### Por qué el fee split es 70/30 (node/treasury)

Los operadores de nodes hacen el trabajo — corren la infraestructura, mantienen el uptime, apuestan capital. Reciben la mayoría de los fees. La asignación del 30% al treasury es lo mínimo necesario para que el treasury sea **auto-sostenible** a volúmenes alcanzables (~$10M/mes vs ~$30M/mes con el split 80/20 anterior) — los nodes se benefician colectivamente del trabajo continuo que el treasury financia: auditorías, desarrollo de SDK, documentación, crecimiento comunitario.

Si la parte del treasury fuera mayor, los operadores tendrían menos incentivo para correr nodes. Si fuera menor, el proyecto necesitaría rondas de financiamiento externo recurrentes para cubrir bienes públicos básicos. 70/30 es el equilibrio que mantiene viables a ambos lados (ver ADR-002 para el análisis económico completo).

### Por qué x402 es de primera clase, no un plugin

La economía de agentes de IA necesitará infraestructura de pagos. Esa infraestructura necesita funcionar a escala de micropagos ($0.001 por llamada a API — el sub-centavo solo es viable vía **netting off-chain**, en la hoja de ruta; el piso de liquidación on-chain por llamada individual es ~$0.30), a velocidad de máquina (sin flujo de aprobación humana), y entre agentes autónomos. HTTP 402 es el protocolo natural para esto — es parte del estándar HTTP, disponible en cualquier lenguaje, y no requiere un nuevo protocolo de autenticación.

Hacer de x402 un plugin crearía un protocolo de dos niveles: pagos "reales" y "pagos de IA". No hay razón técnica ni económica para esta distinción. Ambos usan USDC en Base. Ambos usan la misma settlement layer. Construir x402 desde el inicio asegura que las integraciones de comercios sean compatibles con x402 por defecto.

---

## Tabla de Contenidos

1. [Terminología](#1-terminología)
2. [Participantes de la Red](#2-participantes-de-la-red)
3. [Settlement Layer](#3-settlement-layer)
4. [Protocolo On-Chain](#4-protocolo-on-chain)
5. [Ciclo de Vida del Payment Intent](#5-ciclo-de-vida-del-payment-intent)
6. [Protocolo de Node](#6-protocolo-de-node)
7. [Algoritmo de Routing](#7-algoritmo-de-routing)
8. [Extensión x402](#8-extensión-x402)
9. [Modelo de Seguridad](#9-modelo-de-seguridad)
10. [Códigos de Error](#10-códigos-de-error)
11. [Versionado](#11-versionado)

---

## 1. Terminología

| Término | Definición |
|---|---|
| **Merchant** | Una entidad que integra CoatiPay para recibir pagos |
| **Payer** | La entidad que inicia un pago (humano o agente de IA) |
| **Node** | Un servidor operado por la comunidad que facilita el routing de pagos |
| **Node Operator** | La entidad que corre y apuesta stake en un node |
| **Payment Intent** | Una intención declarada de pagar un monto específico, con un ciclo de vida definido |
| **Settlement** | La transferencia on-chain de fondos del payer al comercio |
| **Routing** | La selección de un node óptimo para facilitar un payment intent |
| **Stake** | USDC depositado por un node operator como colateral |
| **Score** | Una métrica de reputación pública y on-chain para un node |
| **Treasury** | El fondo controlado por el protocolo para desarrollo y bounties |
| **x402** | El protocolo de micropagos basado en HTTP 402 para pagos máquina-a-máquina |

---

## 2. Participantes de la Red

### 2.1 Comercios

Un comercio es cualquier entidad que haya desplegado la API de CoatiPay e integrado el SDK en su producto.

Los comercios tienen:
- Un merchant ID (`mid_xxx`) — globalmente único, asignado al registrarse
- Una o más API keys — `pk_live_xxx` (pública) y `sk_live_xxx` (secreta)
- Una dirección de wallet de destino por cada chain soportado
- Webhook endpoints registrados para la entrega de eventos

Los comercios interactúan con la red exclusivamente a través de la capa de API. No tienen comunicación directa a nivel de protocolo con los nodes.

### 2.2 Payers

Un payer es cualquier entidad que envía fondos para completar un payment intent. Los payers pueden ser:

- **Humano** — interactuando a través de una UI de checkout impulsada por el SDK
- **Agente** — un agente de IA autónomo usando la extensión x402 (ver Sección 8)

Los payers no tienen identidad persistente en el protocolo a menos que sea proporcionada explícitamente por el comercio a través de metadata.

### 2.3 Nodes

Un node es un servidor registrado on-chain que participa en el routing de pagos. Los nodes:

- Se registran vía `NodeRegistry.sol` con un depósito de USDC en stake
- Exponen una API HTTP compatible (ver Sección 6)
- Monitorean eventos de settlement on-chain
- Confirman la finalización del pago de vuelta a la capa de API
- **Nunca retienen ni custodian fondos en ningún momento**

Un node que no está registrado on-chain NO DEBE ser usado por el routing engine.

### 2.4 Bootstrap Nodes

Durante la Fase 1, el core team de CoatiPay opera un conjunto de bootstrap nodes. Estos nodes:

- Sirven como los objetivos iniciales de routing mientras la red crece
- Están registrados on-chain de manera idéntica a cualquier otro node — sin privilegios especiales
- Serán complementados progresivamente por nodes comunitarios a medida que se construya la reputación
- Para la Fase 3 la red ya no depende de ellos — siguen operando como nodes comunes, sin ser un punto único de fallo

Las direcciones de los bootstrap nodes se publican en el repositorio y son verificables on-chain.

---

## 3. Settlement Layer

### 3.1 Chains y Activos Soportados

| Chain | Activo | Chain ID | Estado |
|---|---|---|---|
| Base Sepolia (testnet) | USDC | 84532 | **En vivo** — contratos desplegados y verificados |
| Base mainnet | USDC | 8453 | Bloqueado por auditoría externa |
| Polygon | USDC | 137 | Planeado (Fase 2) |
| Solana | USDC | — | Planeado (Fase 2) |

Base + USDC es la settlement layer principal y la **única implementada** hoy. Todos los protocol fees y stake están denominados en USDC en Base.

> **Nota sobre Lightning/BTC:** Lightning quedó **fuera de alcance** (considerado y descartado); el enum de chains ya **no incluye** `lightning`. El settlement es exclusivamente EVM/USDC: Base hoy, con Polygon y Solana en la hoja de ruta. Una autorización para cualquier chain que no sea Base es rechazada por el validador (`authorization-validator.ts`).

### 3.2 USDC en Base

```
USDC (Base mainnet):  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
USDC (Base Sepolia):  0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

Todos los montos en el protocolo están denominados en micro-unidades de USDC (6 decimales). `1,000,000` = $1.00 USDC.

### 3.3 Flujo de Fondos

**Los fondos fluyen directamente del payer al comercio. Los nodes nunca retienen fondos.**

```
Payer Wallet ──────────────────────────────► Merchant Wallet
                                                    ▲
Node (observa, confirma, gana fee de)     ──────────┘
                                        (fee deducido on-chain de la transferencia)
```

Fee split por transacción:
```
Monto = 1,000,000 (1.00 USDC)
Fee total = 10,000 (1.0% = 100 bps)
  └─ Parte del node (70%) = 7,000
  └─ Treasury (30%) = 3,000
El comercio recibe = 990,000
```

Para micropagos (x402, sub-cent): el split aplica igual on-chain. El payer ya es **gasless** vía
ERC-3009 — firma una autorización off-chain y el nodeit submitea la tx y paga el gas (no se
necesita ningún paymaster). Lo que limita el sub-centavo no es el gas del payer sino el piso
económico de cada liquidación on-chain: con gas de Base (~$0.0036 por intent) el break-even
ronda **~$0.30/llamada**. Los micropagos **sub-centavo** ($0.001) solo se vuelven rentables con
**netting off-chain** (acumular muchas llamadas de un mismo payer y liquidar la suma en una sola
tx) — está en la hoja de ruta, no implementado hoy. Ver ADR-002 para el análisis económico.

---

## 4. Protocolo On-Chain

Tres smart contracts en Base definen las reglas del protocolo: `NodeRegistry`, `StakeManager` y `SettlementHub`. Todos son **no actualizables** (sin patrones proxy) — las reglas no se pueden cambiar después del deploy.

**Sobre pausa y guardian:** los contratos NO tienen admin keys arbitrarias (nadie puede mover fondos ni reescribir estado), pero **sí tienen una pausa de emergencia** vía un `Pausable` base controlado por un guardian. La pausa solo gatea operaciones de *registro* y *escritura nueva* (p. ej. `register`, `registerIntent`) — **no** detiene liquidaciones en vuelo. El guardian es un **multisig 3-de-5**, nunca una llave única, mantenido por la Fundación (sin migración a gobernanza on-chain comprometida). Esta es una decisión de diseño deliberada: un exploit descubierto post-deploy sin mecanismo de pausa significa pérdida total para los afectados; el compromiso pragmático es pausa-gobernada-por-multisig, no ausencia de pausa. (Ver `audits/adr/` y el whitepaper §3.2 para el razonamiento completo.)

### 4.1 NodeRegistry.sol

**Responsabilidad:** Registro y descubrimiento de nodes.

```solidity
struct Node {
    address operator;       // wallet that controls the node
    string  endpoint;       // HTTPS URL of the node API
    uint256 registeredAt;   // block timestamp of registration
    bool    active;         // operator-controlled active flag
}

// El stake se deposita por separado en StakeManager ANTES de registrar;
// register() verifica que el operador ya tenga >= minStake stakeado.
function register(string calldata endpoint) external;
function updateEndpoint(string calldata endpoint) external;
function deactivate() external;
function activate() external;
function getNode(address operator) external view returns (Node memory);
function getActiveNodes() external view returns (address[] memory);
```

**Stake mínimo (`minStake`):** variable de estado en `NodeRegistry`, inicializada en el deploy.
- **Mainnet:** 100 USDC (100,000,000 micro-unidades) — valor anti-Sybil del protocolo
- **Sepolia testnet:** 40 USDC (40,000,000 micro-unidades) — inicial reducido para facilitar onboarding con faucets

El guardian puede aumentar `minStake` vía `NodeRegistry.updateMinStake(uint256)` conforme la red madura. El contrato **rechaza reducciones** — solo incrementos. Esto permite subir la barrera anti-Sybil sin comprometer a operadores ya registrados (su stake existente sigue válido).

### 4.2 StakeManager.sol

**Responsabilidad:** Depósitos de stake y retiros con timelock.

El stake es **fianza y barrera anti-Sybil**: acredita a un operador para entrar en el registro y le obliga a comprometer capital. **No se puede confiscar** — el protocolo no tiene castigo económico (ver ADR-004). No existe ninguna llave, ni siquiera la del guardian, capaz de mover el stake de un operador: cada depósito entra desde `msg.sender` y solo puede salir hacia `msg.sender`.

```solidity
struct StakeInfo {
    uint256 staked;
    uint256 pendingWithdrawal;
    uint256 unlockAt;
}

uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;

function deposit(uint256 amount) external;
function requestWithdrawal(uint256 amount) external;
function executeWithdrawal() external;
function getStakeInfo(address operator) external view returns (StakeInfo memory);
```

**Timelock de retiro:** 7 días entre `requestWithdrawal()` y `executeWithdrawal()`. Ya no se calibra contra ninguna ventana de adjudicación: no hay nada que adjudicar. Su motivo es **dar tiempo a detectar que un operador se va**. `requestWithdrawal()` descuenta el importe de `staked` en el acto y emite `WithdrawalRequested`, así que la salida es visible on-chain una semana antes de que el USDC se mueva: cualquiera puede leer `getStakeInfo()` y ver que el colateral bajó, y el routing puede dejar de asignarle intents si queda por debajo de `minStake`. Un operador no puede vaciar su stake y desaparecer en el mismo bloque.

### 4.3 SettlementHub.sol

**Responsabilidad:** El contrato que **mueve los fondos**. Jala USDC del payer y lo splittea atómicamente on-chain (comercio + node operator + treasury) en una sola transacción. Introducido en ADR-003 como el corazón del settlement gasless ERC-3009.

```solidity
uint16  public constant PROTOCOL_FEE_BPS   = 100;  // 1.0% fee total
uint16  public constant TREASURY_SHARE_BPS = 30;   // 0.3% al treasury
uint16  public constant OPERATOR_SHARE_BPS = 70;   // 0.7% al node operator
uint256 public constant MAX_BATCH_SIZE     = 50;   // cap del batch (x402)

// Única dirección cuya firma autoriza a registrar un intent. Inmutable.
// Cartera normal o contrato ERC-1271 — en producción, un multisig.
address public immutable intentSigner;

// El nodeit registra el intent on-chain (lazy, en el primer claim), pero el
// contenido lo autoriza la plataforma con una firma EIP-712 de `intentSigner`.
struct IntentRegistration {
    bytes32 intentId;
    address merchant;
    address operator;
    uint256 amount;
    uint64  expiresAt;
    bytes   signature;   // EIP-712 de intentSigner sobre los cinco campos anteriores
}

function registerIntent(IntentRegistration calldata reg) external;
function registerIntentBatch(IntentRegistration[] calldata regs) external returns (uint256 registered);

// Tres caminos de pago. El gasless (ERC-3009) es el de Fase 1:
function payIntent(bytes32 intentId) external;                       // approve + pay
function payIntentWithPermit(bytes32, uint256, uint8, bytes32, bytes32) external;  // EIP-2612
function payIntentWithAuthorization(Authorization calldata auth) external;          // ERC-3009 gasless
function payIntentBatchWithAuthorization(Authorization[] calldata auths) external;  // batch x402

function getIntent(bytes32 intentId) external view returns (Intent memory);

event IntentRegistered(...);
event IntentSettled(...);   // fuente de verdad off-chain del settlement
```

**Registro firmado (EIP-712):** el nodeit sigue enviando la transacción de registro y pagando su gas, pero **no puede alterar lo que registra**. `registerIntent` recibe un `IntentRegistration` y revierte con `InvalidIntentSignature` si la firma de `intentSigner` no cubre exactamente `(intentId, merchant, operator, amount, expiresAt)`. El lote la exige **por elemento**: no es un atajo para registrar sin autorización. La verificación usa `SignatureChecker`, así que la firma puede venir de una cartera normal (ECDSA) o de un **contrato ERC-1271** — un multisig. Es una centralización explícita: la plataforma es autoritativa sobre el binding intent→comercio (ver ADR-004).

**`intentSigner` es inmutable, y en producción debe ser un multisig.** La dirección no se puede cambiar, y eso no se negocia: si el guardian pudiera rotarla, tendría capacidad de atar pagos en vuelo a un comercio de su elección, que es justamente la potestad de mover fondos que el diseño le niega. Lo que sí depende de con qué se despliegue es el **coste** de esa inmutabilidad:

- **Con una cartera normal (EOA):** una sola llave basta para autorizar, y perderla o que se filtre obliga a **pausar y redesplegar el hub entero**. El contrato admite esta configuración solo por compatibilidad.
- **Con un multisig (ERC-1271):** la dirección sigue siendo inmutable —el guardian no la toca— pero **los firmantes se rotan por dentro del multisig**, sin tocar el contrato. Y para autorizar hace falta alcanzar el umbral, no una sola llave. El peor escenario pasa de «redesplegar el hub» a «retirar un firmante del Safe».

Por eso la recomendación para producción es desplegar `intentSigner` como multisig. Su dirección se pasa al constructor y no se puede cambiar después, así que decidir umbral y custodia de las llaves forma parte del despliegue, no es un ajuste posterior. La pausa sigue siendo la palanca de emergencia para el caso en que se comprometa el umbral entero. `contracts/test/SettlementHub.multisigSigner.t.sol` cubre esta configuración con un multisig 2-de-3: seis tests, incluido el de retirar una llave comprometida sin redesplegar, y el que comprueba que la ruta de cartera normal sigue funcionando.

**Split de fondos (atómico, on-chain):** sobre un monto `amount`, el contrato transfiere `99%` al comercio, `0.7%` al node operator y `0.3%` al treasury, en la misma transacción. El comercio absorbe cualquier residuo de redondeo (nunca pierde fondos por debajo del split). Las constantes son `public constant` — no configurables, no hay forma de cambiar el fee post-deploy.

**Camino gasless (ERC-3009):** el payer firma off-chain una autorización `ReceiveWithAuthorization` (EIP-712); el node operator la submitea vía `payIntentWithAuthorization` y paga el gas. USDC fuerza `msg.sender == to`, lo que elimina el front-running on-chain de la autorización. **La autorización va atada a su intent:** el contrato exige `nonce == intentId` y revierte con `AuthorizationNotBoundToIntent` en caso contrario, así que una firma solo sirve para el intent cuyo identificador lleva como nonce y quien envía la transacción no puede redirigir el dinero. El nonce se quema en el primer uso (replay protection nativa de USDC). La autorización viaja como una firma `bytes` cruda y se liquida con el overload `receiveWithAuthorization(…, bytes)` de USDC (`SignatureChecker`), así que **funciona tanto para wallets EOA (firma ECDSA) como para smart wallets ERC-1271** (p. ej. Coinbase Smart Wallet). Las cuentas *counterfactual* (smart wallet sin desplegar → firma ERC-6492) son trabajo de una fase posterior.

**Eventos:** `IntentSettled` es la **fuente de verdad** del settlement — el `SettlementEventWatcher` off-chain lo observa y marca el payment intent como `settled` + dispara el webhook. El protocolo nunca considera un pago liquidado hasta que este evento on-chain se confirma.

`SettlementHub` usa `nonReentrant` en todos los caminos de pago y sigue el patrón Checks-Effects-Interactions (estado seteado antes de las transferencias externas).

---

## 5. Ciclo de Vida del Payment Intent

### 5.1 Estados

El modelo de pago de CoatiPay es **ERC-3009 gasless** (ver §3.3). El payer firma off-chain una autorización EIP-712 `ReceiveWithAuthorization`; el daemon del nodeit la reclama de una cola y submitea `payIntentWithAuthorization` al contrato `SettlementHub.sol`, que jala el USDC y lo splittea on-chain de forma atómica. No hay paso de routing ni de "pago pendiente" en el ciclo de vida — el intent va de `created` a `settled` cuando el evento on-chain `IntentSettled` se confirma.

```
created ──► settled

created ──► cancelled
created ──► expired
created ──► failed
```

`settled` es el único estado terminal de éxito y es definitivo: una vez emitido `IntentSettled` no hay ninguna transición posterior, porque el protocolo no tiene reversos ni adjudicación (ver ADR-004). Estados terminales adicionales: `cancelled` (cancelado por el comercio), `expired` (pasó `expires_at`), `failed` (el settlement on-chain no se completó).

### 5.2 Objeto Payment Intent

```typescript
interface PaymentIntent {
  id:              string           // "pi_" + 24 random chars
  merchant_id:     string           // "mid_" + 16 chars
  amount:          number           // in asset micro-units
  currency:        "usdc" | "btc"
  chain:           "base" | "polygon" | "auto"
  status:          PaymentIntentStatus
  node_operator:   string | null    // nodeit que liquidó el intent
  payer_address:   string | null    // wallet del payer (de la autorización ERC-3009)
  tx_hash:         string | null    // on-chain tx hash
  fee_amount:      number           // protocol fee charged
  metadata:        Record<string, string>  // max 20 keys
  created_at:      number           // unix timestamp
  expires_at:      number           // unix timestamp (default: +30 min)
  settled_at:      number | null
}
```

### 5.3 Reglas de Transición

**created → settled** — el evento on-chain `IntentSettled` emitido por `SettlementHub.sol` se confirma. El payer firmó una autorización ERC-3009, el daemon del nodeit la submiteó al contrato, y el contrato jaló el USDC del payer y lo splitteó atómicamente (99% al comercio, 0.7% al nodeit, 0.3% al treasury). Se dispara el webhook `payment_intent.settled`.

**created → expired** — se alcanza el timestamp `expires_at` sin que el intent llegue a `settled`.

**created → cancelled** — el comercio cancela el intent antes del settlement.

**created → failed** — el settlement on-chain no se completó (p. ej., la autorización fue rechazada por el contrato).

**No hay transiciones desde `settled`.** El settlement es atómico y definitivo: el contrato reparte los fondos en la misma transacción en la que los recibe, y no existe camino on-chain ni de API para revertirlo.

---

## 6. Protocolo de Node

El daemon del nodeit expone una API HTTP mínima y pública. Todos los endpoints usan JSON.

### 6.1 Endpoints Requeridos

```
GET  /health   → { status, version, operator, chains, capacity }
GET  /info     → { operator, version, uptime_30d, avg_settlement_ms, total_settled, stake }
```

`/health` y `/info` sirven liveness y métricas públicas de reputación. Son los únicos endpoints HTTP que el daemon expone a la red.

### 6.2 Settlement ERC-3009 (interno)

El settlement no se hace por un endpoint HTTP expuesto del nodeit. El flujo es:

1. El payer firma off-chain una autorización EIP-712 `ReceiveWithAuthorization`.
2. El SDK envía esa autorización a la API, que la encola.
3. El daemon del nodeit poletea la cola de la API, reclama la autorización y submitea `payIntentWithAuthorization` al contrato `SettlementHub.sol`. El nodeit paga el gas de esta transacción.
4. `SettlementHub.sol` jala el USDC del payer y lo splittea atómicamente on-chain (99% comercio, 0.7% nodeit, 0.3% treasury) y emite el evento `IntentSettled`.
5. Un event watcher confirma el settlement leyendo el evento `IntentSettled` on-chain, y la API marca el intent como `settled` y dispara el webhook.

El nodeit nunca retiene fondos en ningún momento: el USDC se mueve del payer al comercio dentro de una sola transacción atómica del contrato.

### 6.3 Requisitos de Comportamiento del Node

Un nodeit conforme DEBE:
- Responder a `/health` dentro de 2 segundos
- Poletear la cola de la API y submitear `payIntentWithAuthorization` con prontitud tras reclamar una autorización
- Pagar el gas de la transacción de settlement
- Mantener logs de todos los intents liquidados por un mínimo de 90 días

Un nodeit conforme NO DEBE:
- Actuar como intermediario reteniendo fondos entre el payer y el comercio
- Modificar los montos o metadata de las transacciones
- Submitear autorizaciones para chains no listados en su respuesta `/health`

---

## 7. Algoritmo de Routing — Fase 2 (planificado, no implementado)

> **Estado:** Esta sección especifica el motor de routing multi-node. **No está implementado.** Hoy la red opera con un solo bootstrap nodeit: cada autorización ERC-3009 entra en la cola de la API y es liquidada por ese nodeit, sin pre-ruteo ni scoring. El descubrimiento de nodeits desde `NodeRegistry.sol`, el scoring por reputación y el racing paralelo son una feature de **Fase 2** — la especificación se conserva aquí como referencia de diseño para esa fase.

Cuando haya múltiples nodeits registrados, la API seleccionará un nodeit por intent según el siguiente algoritmo.

### 7.1 Score del Node

```
Score = (uptime_weight × 0.40) + (speed_weight × 0.40)
      + (stake_weight × 0.20)

uptime_weight = uptime_30d (0.0–1.0)
speed_weight  = 1 - (avg_settlement_ms / 30000), min 0
stake_weight  = min(node_stake / 10_000_000_000, 1.0)
```

**Sobre el reparto de pesos:** el 0.20 que antes pesaba el historial de adjudicaciones se reparte **entre uptime y velocidad** (0.30 → 0.40 cada uno), no sobre el stake. La razón es que ese término puntuaba conducta juzgada, y sin adjudicación no queda ningún registro de conducta que puntuar: lo único observable de un nodeit es lo que hace — estar vivo y liquidar rápido. El stake se queda en **0.20 a propósito**: es una barrera de entrada y un compromiso de capital, no una métrica de desempeño, y subirle el peso equivaldría a dejar que el capital compre routing.

Los scores se cachean en Redis, refrescados cada 60 segundos.

### 7.2 Filtros Duros

Aplicados antes del scoring. Los nodes que fallan cualquier filtro son excluidos sin importar el score:
- No registrado on-chain
- `active = false`
- No soporta el chain solicitado
- `capacity < 0.1`
- Round-trip a `/health` > 5 segundos
- No está en la whitelist del comercio (si está configurada)
- Está en la blacklist del comercio (si está configurada)
- Por debajo del stake/score mínimo del comercio (si está configurado)

### 7.3 Selección

1. Aplicar filtros duros
2. Ordenar los restantes por score (descendente)
3. Tomar los 5 primeros
4. Distribuir la autorización del intent a los candidatos según score
5. El primer nodeit en liquidar el intent gana el fee
6. Descartar a los candidatos restantes

---

## 8. Extensión x402

### 8.1 Flujo

```
Agent: GET /api/resource
Server: 402 Payment Required + { x402Version, accepts: [{ amount, asset, payTo }] }
Agent: constructs + signs on-chain payment
Agent: GET /api/resource + X-PAYMENT: <base64_payload>
Server: verifies on-chain → serves resource + X-PAYMENT-RESPONSE
```

### 8.2 Middleware del SDK

```typescript
// Fastify
app.addHook('preHandler', relay.x402.middleware({
  price: 300_000,     // $0.30 USDC (above the settlement floor; see economics)
  currency: 'usdc',
  chain: 'base',
}))

// Next.js App Router
export const GET = relay.x402.handler({
  price: 300_000,     // 0.30 USDC (above the settlement floor; see economics)
  handler: async (req) => Response.json({ data: 'protected' })
})
```

### 8.3 Umbral de routing

- Pagos < $0.01 USDC (< 10,000 micro-unidades): verificación directa on-chain
- Pagos >= $0.01 USDC: enrutados vía la red de nodes

---

## 9. Modelo de Seguridad

| Amenaza | Mitigación |
|---|---|
| Node roba fondos | Los fondos nunca pasan por los nodes — siempre payer-a-comercio |
| Node enruta a dirección equivocada | La dirección del comercio la fija la capa de API y viaja **firmada** (EIP-712 de `intentSigner`): el nodeit envía el registro pero no puede cambiar su contenido |
| Node cobra fee sin liquidar | No puede: el 0.7% del nodeit sale del **mismo split atómico** que paga al comercio, en la misma transacción. Sin liquidación no hay fee que cobrar |
| Ataque Sybil | `minStake` de 100 USDC (mainnet) hace que Sybil sea costoso |
| Node exit scam | Timelock de retiro de 7 días: la salida es visible on-chain una semana antes de que el stake se mueva |
| Double-spend | El settlement es una transacción atómica de `SettlementHub.sol`; el intent pasa a `settled` solo al confirmarse el evento `IntentSettled` on-chain |
| Replay de x402 | tx_hash almacenado en x402_payments_used después del primer uso |
| Replay de autorización ERC-3009 | El `nonce` de la autorización `ReceiveWithAuthorization` se consume on-chain en el primer uso |

---

## 10. Códigos de Error

### Formato de Error de API

```json
{
  "error": {
    "code": "intent_expired",
    "message": "The payment intent has expired.",
    "param": null,
    "doc_url": "https://docs.coatipay.com/errors/intent_expired"
  }
}
```

### Referencia de Códigos de Error

| Código | HTTP | Descripción |
|---|---|---|
| `invalid_api_key` | 401 | API key malformada o revocada |
| `insufficient_permissions` | 403 | Se requiere secret key |
| `intent_not_found` | 404 | El ID del payment intent no existe |
| `intent_expired` | 410 | El intent ha pasado `expires_at` |
| `intent_already_settled` | 409 | No se puede modificar un intent liquidado |
| `no_nodes_available` | 503 | Ningún node cumple con los criterios de routing — solo aplica al motor de routing multi-node de Fase 2 (ver §7); no se produce en el modelo actual de un solo bootstrap nodeit |
| `chain_not_supported` | 400 | El chain solicitado no está activo |
| `amount_too_small` | 400 | Monto por debajo del mínimo del chain |
| `amount_too_large` | 400 | Monto excede la capacidad del node |
| `invalid_webhook_url` | 400 | URL del webhook no alcanzable |
| `node_not_registered` | 403 | Node no está en el registro on-chain |

---

## 11. Versionado

### Versionado del protocolo

`MAJOR.MINOR` — los cambios breaking aumentan MAJOR, las adiciones retrocompatibles aumentan MINOR.

Versión actual: `0.1`. La serie `0.x` permite cambios breaking con 30 días de aviso.

**Criterios para v1.0:**
1. Contratos auditados y desplegados en Base mainnet
2. Al menos 10 nodes comunitarios independientes activos
3. SDK utilizado en al menos un despliegue de comercio en producción

### Versionado de API

Prefijo de URL: `/v1/`. La nueva versión de API no se introducirá antes de la v1.0 del protocolo.

---

## Apéndice A — Eventos de Webhook

| Evento | Disparado Cuando |
|---|---|
| `payment_intent.created` | El intent es creado por primera vez |
| `payment_intent.settled` | El evento on-chain `IntentSettled` se confirmó |
| `payment_intent.failed` | El settlement on-chain falló |
| `payment_intent.expired` | TTL alcanzado sin pago |
| `payment_intent.cancelled` | Cancelado por el comercio antes del settlement |

---

## Apéndice B — Requisitos Mínimos del Node

| Recurso | Mínimo | Recomendado |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 2 GB |
| Disco | 10 GB SSD | 50 GB SSD |
| Red | 100 Mbps | 1 Gbps |
| SLA de Uptime | 99% | 99.9% |
| Stake USDC | 100 USDC (mainnet) · 40 USDC (testnet) | 1,000+ USDC |

---

*Este documento es una especificación viva. Los cambios se proponen vía GitHub issues con la etiqueta `spec`. Los cambios de protocolo requieren un RFC con un período de discusión mínimo de 7 días.*
