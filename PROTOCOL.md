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

Si la parte del treasury fuera mayor, los operadores tendrían menos incentivo para correr nodes. Si fuera menor, el proyecto necesitaría rondas de financiamiento externo recurrentes para cubrir bienes públicos básicos. 70/30 es el equilibrio que mantiene viables a ambos lados (ver ADR-002 para el análisis económico completo; ADR-005 sube la comisión total a 150 bps y deja el reparto intacto).

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
Fee total = 15,000 (1.5% = 150 bps)
  └─ Parte del node (70%) = 10,500
  └─ Treasury (30%) = 4,500
El comercio recibe = 985,000
```

Para micropagos (x402, sub-cent): el split aplica igual on-chain. El payer ya es **gasless** vía
ERC-3009 — firma una autorización off-chain y el nodeit submitea la tx y paga el gas (no se
necesita ningún paymaster). Lo que limita el sub-centavo no es el gas del payer sino el piso
económico de cada liquidación on-chain: con gas de Base (~$0.0036 por intent) el break-even
ronda **~$0.30/llamada**. Los micropagos **sub-centavo** ($0.001) solo se vuelven rentables con
**netting off-chain** (acumular muchas llamadas de un mismo payer y liquidar la suma en una sola
tx) — está en la hoja de ruta, no implementado hoy. Ver ADR-002 para el análisis económico y ADR-005 para la revisión de la comisión a 150 bps.

---

## 4. Protocolo On-Chain

Cuatro smart contracts en Base definen las reglas del protocolo: `NodeRegistry`, `StakeManager`, `SettlementHub` y `IntentSignerGate`. Todos son **no actualizables** (sin patrones proxy) — las reglas no se pueden cambiar después del deploy; un cambio se hace con un despliegue nuevo y una migración. El diseño de la versión actual está en [ADR-009](audits/adr/009-una-parte-que-falla-no-detiene-a-las-demas.md): **una parte que falla no detiene a las demás**.

**Sobre pausa y guardian:** los contratos NO tienen admin keys arbitrarias (nadie puede mover fondos ni reescribir estado), pero **sí tienen una pausa de emergencia** vía un `Pausable` base controlado por un guardian. La pausa gatea el *riesgo nuevo*: registrar nodos e intents, y depositar stake. Como cada pago se registra on-chain al liquidarse, pausar el hub detiene también los pagos que el pagador ya firmó y aún no se registraron; los ya registrados se pueden pagar. **La pausa no retiene el dinero de nadie**: con los contratos en pausa se puede retirar stake y cobrar las comisiones acreditadas. El guardian se transfiere en dos pasos (`transferGuardian` + `acceptGuardian` del propuesto): una dirección mal escrita nunca se queda con el cargo. En mainnet el guardian será un **multisig** —previsto de 3-de-5—, nunca una llave única, mantenido por la Fundación (sin migración a gobernanza on-chain comprometida); `Deploy.s.sol` se niega a desplegar en mainnet con un guardian que no lo sea. Hoy, en testnet, es una sola cartera. Esta es una decisión de diseño deliberada: un exploit descubierto post-deploy sin mecanismo de pausa significa pérdida total para los afectados; el compromiso pragmático es pausa-gobernada-por-multisig, no ausencia de pausa. (Ver `audits/adr/` y el whitepaper §3.2 para el razonamiento completo.)

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
// La lista, por páginas: crece con los nodeits.
function activeNodeCount() external view returns (uint256);
function getActiveNodesPage(uint256 offset, uint256 limit) external view returns (address[] memory);
```

**Stake mínimo (`minStake`):** variable de estado en `NodeRegistry`, inicializada en el deploy y nunca cero.
- **Mainnet:** 100 USDC (100,000,000 micro-unidades) — valor anti-Sybil del protocolo
- **Sepolia testnet:** 40 USDC (40,000,000 micro-unidades) — inicial reducido para facilitar onboarding con faucets

`minStake` cambia **con aviso**: el guardian lo propone (`proposeMinStake`), y cualquiera lo aplica (`applyMinStake`) pasados `MIN_STAKE_DELAY` = 7 días —el mismo plazo que un retiro de stake—; el guardian puede cancelar la propuesta. Puede subir o bajar: un error se corrige proponiendo el valor anterior, y una llave robada se ve venir una semana antes. El vigía de la plataforma avisa de cualquier propuesta pendiente. La API compara el stake de cada nodeit con el `minStake` vigente al repartir trabajo ([ADR-008](audits/adr/008-stake-minimo-exigido-al-repartir-trabajo.md)).

### 4.2 StakeManager.sol

**Responsabilidad:** Depósitos de stake y retiros con timelock.

El stake es **fianza y barrera anti-Sybil**: acredita a un operador para entrar en el registro y le obliga a comprometer capital. **No se puede confiscar** — el protocolo no tiene castigo económico (ver ADR-004). No existe ninguna llave, ni siquiera la del guardian, capaz de mover el stake de un operador: cada depósito entra desde `msg.sender` y solo puede salir hacia `msg.sender`, también con el contrato en pausa.

```solidity
struct StakeInfo {
    uint256 staked;
    uint256 pendingWithdrawal;
    uint256 unlockAt;
}

uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;

function deposit(uint256 amount) external;           // se frena en pausa
function requestWithdrawal(uint256 amount) external; // funciona en pausa
function executeWithdrawal() external;               // funciona en pausa
function getStakeInfo(address operator) external view returns (StakeInfo memory);

// Lo que llega por error (USDC sin `deposit`, otros tokens) sale hacia la
// tesorería, inmutable. Nunca toca `totalHeld` (lo depositado y lo que sale).
function sweepSurplus() external;
function sweepToken(address token) external;
```

**Timelock de retiro:** 7 días entre `requestWithdrawal()` y `executeWithdrawal()`. Ya no se calibra contra ninguna ventana de adjudicación: no hay nada que adjudicar. Su motivo es **dar tiempo a detectar que un operador se va**. `requestWithdrawal()` descuenta el importe de `staked` en el acto y emite `WithdrawalRequested`, así que la salida es visible on-chain una semana antes de que el USDC se mueva: cualquiera puede leer `getStakeInfo()` y ver que el colateral bajó, y el routing puede dejar de asignarle intents si queda por debajo de `minStake`. Un operador no puede vaciar su stake y desaparecer en el mismo bloque.

### 4.3 SettlementHub.sol

**Responsabilidad:** El contrato que **mueve los fondos**. Jala USDC del payer, paga al comercio en la misma transacción y **acredita** las comisiones del nodeit y de la tesorería, que cada uno cobra después. Introducido en ADR-003 como el corazón del settlement gasless ERC-3009; el reparto *pull* y lo demás de esta versión, en ADR-009.

```solidity
uint16  public constant PROTOCOL_FEE_BPS   = 150;  // 1.5% fee total
uint16  public constant TREASURY_SHARE_BPS = 45;   // 0.45% a la tesorería
uint16  public constant OPERATOR_SHARE_BPS = 105;  // 1.05% al nodeit
uint256 public constant MAX_BATCH_SIZE     = 50;   // cap del batch (x402)

// Única dirección cuya firma autoriza a registrar un intent. Inmutable.
// En producción, un IntentSignerGate (§4.4).
address public immutable intentSigner;

// El id on-chain de un cobro lleva dentro al comercio: el pagador lo firma
// como nonce, así que su firma fija también a quién paga.
function intentIdOf(address merchant, bytes32 ref) public pure returns (bytes32);

// El nodeit registra el intent on-chain (lazy, en el primer claim), pero el
// contenido lo autoriza la plataforma con una firma EIP-712 de `intentSigner`.
struct IntentRegistration {
    bytes32 ref;         // referencia del cobro: keccak256 del id "pi_…"
    address merchant;
    address operator;
    uint256 amount;
    uint64  expiresAt;
    bytes   signature;   // EIP-712 de intentSigner sobre (intentIdOf(merchant, ref), merchant, operator, amount, expiresAt)
}

function registerIntent(IntentRegistration calldata reg) external returns (bytes32 intentId);
function registerIntentBatch(IntentRegistration[] calldata regs) external returns (uint256 registered);

// Tres caminos de pago. El gasless (ERC-3009) es el de Fase 1:
function payIntent(bytes32 intentId) external;                       // approve + pay
function payIntentWithPermit(bytes32, uint256, uint8, bytes32, bytes32) external;  // EIP-2612
function payIntentWithAuthorization(Authorization calldata auth) external;          // ERC-3009 gasless
function payIntentBatchWithAuthorization(Authorization[] calldata auths) external;  // batch x402

// Las comisiones acreditadas, y quién las cobra.
mapping(address => uint256) public accrued;
uint256 public totalAccrued;
function claim() external returns (uint256);                     // lo propio
function claimFor(address account) external returns (uint256);   // cualquiera; el dinero va a `account`

// Lo que llega por error: el USDC sobrante se acredita a la tesorería; otros
// tokens se le envían.
function sweepSurplus() external;
function sweepToken(address token) external;

function getIntent(bytes32 intentId) external view returns (Intent memory);

event IntentRegistered(...);
event IntentRegistrationSkipped(bytes32 indexed intentId, bytes reason);
event IntentSettled(...);   // fuente de verdad off-chain del settlement
event FeesClaimed(address indexed account, uint256 amount);
```

**Registro firmado (EIP-712):** el nodeit sigue enviando la transacción de registro y pagando su gas, pero **no puede alterar lo que registra**. El registro lleva `ref`, no el `intentId`: el hub lo calcula con `intentIdOf(merchant, ref)`, y la firma de `intentSigner` tiene que cubrir exactamente `(intentId, merchant, operator, amount, expiresAt)`; si no, revierte con `InvalidIntentSignature`. El lote la exige **por elemento**: no es un atajo para registrar sin autorización. La verificación usa `SignatureChecker`, así que la firma puede venir de una cartera normal (ECDSA) o de un **contrato ERC-1271**. Es una centralización explícita: la plataforma es autoritativa sobre el binding intent→comercio (ver ADR-004).

**El `intentId` lleva dentro al comercio.** Es `keccak256(abi.encode(merchant, ref))`, y el pagador lo firma como nonce de su autorización ERC-3009 (`nonce == intentId`, abajo). Así, **ni quien controle `intentSigner` puede atar a otro comercio un pago que el pagador ya firmó**: con otro comercio, el id sería otro y la firma no valdría. El operador no entra en el id —se decide cuando un nodeit toma el trabajo, después de que el pagador firme—: lo fija el registro firmado. Los SDK y el checkout calculan el nonce con la cartera del comercio (`merchant_wallet` del cobro); los vectores compartidos lo fijan, y las pruebas de los contratos los leen y exigen que el hub dé cada uno.

**Un registro que no pasa no hunde el lote.** `registerIntentBatch` registra cada elemento por separado: el que revertiría (plazo fuera de rango, importe cero, firma que no vale…) se salta con `IntentRegistrationSkipped(intentId, motivo)` y los demás se registran. Lo ya registrado se salta en silencio (un lote reintentado), y lo que afecta a todos —la pausa— sigue revirtiendo el lote entero. `registerIntent`, de uno en uno, revierte.

**`intentSigner` es inmutable.** La dirección no se puede cambiar, y eso no se negocia: el guardian no puede cambiar quién autoriza registros. Lo que hace soportable esa inmutabilidad es desplegarlo como un `IntentSignerGate` (§4.4): la clave que firma cada registro se rota sin tocar el hub.

**Reparto *pull*:** sobre un monto `amount`, el contrato transfiere el `98.5%` al comercio en la misma transacción del pago, y **acredita** el `1.05%` al nodeit y el `0.45%` a la tesorería (`accrued`, con la suma en `totalAccrued`). Cada uno cobra lo suyo con `claim()`; `claimFor(cuenta)` lo puede llamar cualquiera, porque el dinero solo sale hacia su dueño. Las dos funcionan en pausa. Por qué así: si el emisor de USDC pone en su lista negra a la tesorería o a un nodeit, una transferencia a esa dirección revierte; con el reparto en el momento, revertía el pago entero —con la tesorería bloqueada, **todos** los pagos—. Con el reparto *pull*, los pagos siguen y la comisión de quien está bloqueado espera en el hub hasta que lo desbloqueen. No hay forma de cobrar hacia otra dirección: una cuenta bloqueada no puede desviar su saldo, y la tesorería es inmutable, siempre la del proyecto. Un comercio bloqueado, en cambio, no cobra: su pago revierte, y es lo correcto, porque acreditarle el pago dejaría retenido el dinero del pagador. El comercio absorbe cualquier residuo de redondeo (nunca pierde fondos por debajo del split). Las constantes son `public constant` — no configurables, no hay forma de cambiar el fee post-deploy. Un pago cuesta menos gas que con el reparto en el momento (53.9k frente a 84.1k con USDC real, cuando el nodeit ya tiene saldo acreditado), y cada `claim` unos 60k.

**Lo que llega por error tiene salida.** El USDC del hub por encima de `totalAccrued` llegó sin un pago; `sweepSurplus()` lo acredita a la tesorería, y `sweepToken(token)` le envía cualquier otro token. Los puede llamar cualquiera: el destino es fijo y nunca tocan lo acreditado a otros. El hub no acepta ETH.

**Camino gasless (ERC-3009):** el payer firma off-chain una autorización `ReceiveWithAuthorization` (EIP-712); el node operator la submitea vía `payIntentWithAuthorization` y paga el gas. USDC fuerza `msg.sender == to`, lo que elimina el front-running on-chain de la autorización. **La autorización va atada a su intent:** el contrato exige `nonce == intentId` y revierte con `AuthorizationNotBoundToIntent` en caso contrario, así que una firma solo sirve para el intent cuyo identificador lleva como nonce —y, como el id lleva dentro al comercio, solo para ese comercio— y quien envía la transacción no puede redirigir el dinero. El nonce se quema en el primer uso (replay protection nativa de USDC). La autorización viaja como una firma `bytes` cruda y se liquida con el overload `receiveWithAuthorization(…, bytes)` de USDC (`SignatureChecker`), así que **funciona tanto para wallets EOA (firma ECDSA) como para smart wallets ERC-1271** (p. ej. Coinbase Smart Wallet). Las cuentas **contrafactuales** (smart wallet sin desplegar → firma ERC-6492) también pagan, hoy solo con **Coinbase Smart Wallet**: el nodeit despliega el monedero antes de liquidar, y solo ejecuta `createAccount` en las dos fábricas de Coinbase (v1 y v1.1); cualquier otra llamada se rechaza antes de enviar nada. Antes de encolar una autorización, la API verifica su firma contra la cadena para los tres tipos de cartera ([ADR-006](audits/adr/006-firmas-del-pagador-y-despliegue-erc6492.md)).

**Eventos:** `IntentSettled` es la **fuente de verdad** del settlement. La API lo lee **ella misma** de la cadena —un reconciliador con cursor persistente, margen de confirmaciones y detección de reorganizaciones—, marca el payment intent como `settled` y dispara el webhook. Ningún nodeit informa de qué se pagó: la API no aceptaría su palabra ([ADR-007](audits/adr/007-liquidaciones-leidas-de-la-cadena.md)). El protocolo nunca considera un pago liquidado hasta que este evento on-chain se confirma.

`SettlementHub` usa `nonReentrant` en todos los caminos de pago y sigue el patrón Checks-Effects-Interactions (el estado del intent y las comisiones acreditadas se escriben antes de las transferencias externas).

### 4.4 IntentSignerGate.sol

**Responsabilidad:** ser el `intentSigner` del hub, separando dos cosas que con una cartera normal iban juntas:

- **`signer`**, la clave caliente con la que la plataforma firma cada registro, sola y sin coordinar a nadie;
- **`admin`**, que es lo único que puede cambiar esa clave. En mainnet, un multisig frío (`Deploy.s.sol` lo exige).

```solidity
address public admin;
address public signer;

function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4); // ERC-1271
function setSigner(address newSigner) external;     // solo admin; al instante
function transferAdmin(address newAdmin) external;  // solo admin
function acceptAdmin() external;                    // el propuesto
```

El hub guarda la dirección del gate, que no cambia; una clave caliente robada o perdida se retira con `setSigner` sin redesplegar el hub. Quien robe la clave caliente no puede rotarla ni tocar el admin: no puede quedarse con el contrato. `setSigner(address(0))` es el **freno de emergencia**: ningún registro nuevo pasa hasta nombrar otra clave. La firma se valida sobre el digest EIP-712 del hub tal cual (que ya lo ata a ese hub y esa red), y `signer` puede ser a su vez un contrato ERC-1271. Lo que una clave caliente robada puede hacer mientras siga vigente está acotado por el hub: como el `intentId` lleva dentro al comercio, no puede atar a otro comercio un pago que el pagador ya firmó.

---

## 5. Ciclo de Vida del Payment Intent

### 5.1 Estados

El modelo de pago de CoatiPay es **ERC-3009 gasless** (ver §3.3). El payer firma off-chain una autorización EIP-712 `ReceiveWithAuthorization`; el daemon del nodeit la reclama de una cola y submitea `payIntentWithAuthorization` al contrato `SettlementHub.sol`, que jala el USDC, paga al comercio y acredita las comisiones en la misma transacción. No hay paso de routing ni de "pago pendiente" en el ciclo de vida — el intent va de `created` a `settled` cuando el evento on-chain `IntentSettled` se confirma.

```
created ──► settled

created ──► cancelled
created ──► expired

(excepcional) cancelled | expired ──► settled
```

`settled` es el único estado terminal de éxito y es definitivo: una vez emitido `IntentSettled` no hay ninguna transición posterior, porque el protocolo no tiene reversos ni adjudicación (ver ADR-004). Estados terminales adicionales: `cancelled` (cancelado por el comercio) y `expired` (pasó `expires_at`), los dos solo sin un pago en camino.

**No hay estado `failed`.** Un pago que no pasa (firma inválida, saldo insuficiente, autorización caducada) deja el intent en `created`, y se puede seguir pagando hasta que vence. Si la autorización se rechazó al liquidarla o caducó, el mismo pagador puede volver a firmar: la API admite una sola autorización **viva** (en cola, reclamada o liquidada) por pagador y cobro, sin distinguir mayúsculas en la dirección ni en el nonce, y responde 409 `nonce_already_used` a una segunda. Reintentar es seguro: el USDC no deja usar dos veces un nonce.

**La cadena manda.** Si un pago ya iba camino de la cadena cuando el intent venció o se canceló, el reconciliador aplica el `IntentSettled` y el intent pasa a `settled`. La API lo evita en lo posible —no cancela ni vence un intent con una autorización que un nodeit ya reclamó—, pero no puede impedirlo del todo: un reclamo liberado por atascado conserva firmas válidas y puede liquidarse tarde.

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

**created → settled** — el evento on-chain `IntentSettled` emitido por `SettlementHub.sol` se confirma. El payer firmó una autorización ERC-3009, el daemon del nodeit la submiteó al contrato, y el contrato jaló el USDC del payer, pagó el 98.5% al comercio y acreditó el 1.05% al nodeit y el 0.45% a la tesorería. Se dispara el webhook `payment_intent.settled`.

**created → expired** — se alcanza el timestamp `expires_at` sin que el intent llegue a `settled` y sin ninguna autorización reclamada por un nodeit. Las autorizaciones que seguían en cola se descartan: el hub rechaza liquidar a partir de `expiresAt` (`IntentExpired`). Se dispara `payment_intent.expired`.

**created → cancelled** — el comercio cancela el intent antes del settlement. Las autorizaciones en cola se descartan; si un nodeit ya reclamó una, no se cancela (409 `payment_in_progress`): ese pago puede liquidarse igual. Se dispara `payment_intent.cancelled`.

**cancelled | expired → settled** (excepcional) — el `IntentSettled` de un pago que ya iba camino de la cadena. Se dispara `payment_intent.settled`.

**No hay transiciones desde `settled`.** El settlement es definitivo: el contrato paga al comercio y acredita las comisiones en la misma transacción en la que recibe los fondos, y no existe camino on-chain ni de API para revertirlo.

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
4. `SettlementHub.sol` jala el USDC del payer, paga el 98.5% al comercio, acredita el 1.05% al nodeit y el 0.45% a la tesorería (cada uno lo cobra después con `claim`), y emite el evento `IntentSettled`.
5. La API lee el evento `IntentSettled` de la cadena —con margen de confirmaciones—, marca el intent como `settled` y dispara el webhook. El nodeit no informa de nada.

El nodeit nunca retiene fondos en ningún momento: el USDC se mueve del payer al comercio dentro de una sola transacción del contrato, y su comisión la guarda el hub hasta que la cobra.

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
| Node cobra fee sin liquidar | No puede: el 1.05% del nodeit se acredita en la **misma transacción** que paga al comercio. Sin liquidación no hay fee que cobrar |
| Una parte bloqueada por el emisor de USDC detiene los pagos | Con el reparto *pull*, la tesorería o un nodeit en la lista negra no detienen nada: su comisión queda acreditada hasta que puedan cobrarla. Solo el hub bloqueado o el token en pausa detienen los pagos, y el vigía lo avisa |
| Alguien con `intentSigner` ata un pago firmado a otro comercio | El `intentId` lleva dentro al comercio y el pagador lo firma como nonce: con otro comercio el id es otro y la firma no vale. La clave que firma se rota sin redesplegar (`IntentSignerGate`) |
| Ataque Sybil | `minStake` de 100 USDC (mainnet) hace que Sybil sea costoso |
| Node exit scam | Timelock de retiro de 7 días: la salida es visible on-chain una semana antes de que el stake se mueva |
| Double-spend | El settlement es una sola transacción de `SettlementHub.sol`; el intent pasa a `settled` solo al confirmarse el evento `IntentSettled` on-chain |
| Replay de x402 | tx_hash almacenado en x402_payments_used después del primer uso |
| Replay de autorización ERC-3009 | El `nonce` de la autorización `ReceiveWithAuthorization` se consume on-chain en el primer uso |

---

## 10. Códigos de Error

### Formato de Error de API

```json
{
  "error": {
    "code": "payment_in_progress",
    "message": "A payment for this intent is being settled on-chain; it cannot be cancelled now.",
    "param": null,
    "doc_url": "https://coatipay.com/docs/errors/payment_in_progress"
  }
}
```

Todo error de la API tiene esta forma. `param` nombra el campo culpable, si lo hay; `doc_url` es la página del código.

### Catálogo

Los códigos viven en un solo sitio: `ERROR_CATALOG` en `protocol/src/errors.ts`, publicado en `@lacasoft/coatipay-protocol`. Cada código sale siempre con el mismo HTTP y tiene una categoría (`auth`, `validation`, `not_found`, `conflict`, `payment`, `routing`, `rate_limit`, `unavailable`, `internal`). La API solo puede responder con un código del catálogo, y el HTTP lo toma de ahí. No se copia en este documento para que no pueda desfasarse.

- **Referencia pública:** `https://coatipay.com/docs/errors/<code>`, una página por código, con su causa y cómo resolverlo. El CI de la web comprueba que cubre el catálogo entero.
- **En los SDK:** cada código lanza la clase de su categoría (`AuthError`, `ValidationError`, `RoutingError`, `PaymentError`, `RateLimitError`; `CoatiPaySDKError`, la base, para las demás y para un código que el SDK no conoce). Sin respuesta de CoatiPay, `NetworkError` (code `network_error`, que pone el SDK, no la API). La regla es la misma en los tres SDK: `protocol/vectors/errores.json`.

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

Un evento por cada cambio de estado del intent (§5). No hay evento de pago fallido: no existe el estado `failed`.

| Evento | Disparado Cuando |
|---|---|
| `payment_intent.created` | El intent es creado por primera vez |
| `payment_intent.settled` | El evento on-chain `IntentSettled` se confirmó |
| `payment_intent.expired` | TTL alcanzado sin ningún pago en camino |
| `payment_intent.cancelled` | Cancelado por el comercio, sin ningún pago en camino |

- **Al menos una vez, sin orden garantizado.** Cada evento sale de una bandeja de salida escrita en la misma transacción que el cambio de estado. Su `id` es estable: deduplica por él, y guíate por `data.status` y por `created` (cuándo ocurrió), no por el orden de llegada.
- `data` es el intent tal como quedó en ese momento.
- Un `payment_intent.settled` puede llegar después de `expired` o `cancelled` (§5.1): el pago llegó al comercio.

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
