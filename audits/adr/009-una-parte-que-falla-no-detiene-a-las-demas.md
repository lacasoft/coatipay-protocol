# ADR-009 — Una parte que falla no detiene a las demás

> **Status**: 🟡 **Propuesto** (2026-10-22)
> **Date**: 2026-10-22
> **Supersede**: ADR-001 en el reparto en el momento a operador y tesorería
> (§ split atómico); ADR-004 en la recomendación de que `intentSigner` sea un
> multisig (pasa a ser un contrato propio, §4); el `setMinStake` de
> `NodeRegistry` que solo sube, tal como lo describe ADR-008 (§5).
> **Exige**: un despliegue nuevo de los tres contratos y de uno más
> (`IntentSignerGate`). Las comisiones no cambian.

## Contexto

La revisión de seguridad de octubre de 2026 partió de un reporte externo: si
Circle pone en la lista negra de USDC a la tesorería, el hub deja de liquidar
**todos** los pagos, porque reparte en el momento y revierte entero si una de las
tres transferencias falla. A partir de ahí se buscó en todo el sistema la misma
familia de fallos: una parte que falla y detiene a las demás, una pieza crítica
sin plan B, una palanca de una sola llave que no se puede deshacer.

Lo que se pudo arreglar fuera de los contratos ya está desplegado (el plazo
máximo de un cobro, la cola que no reparte lo que no se puede registrar, el
nodeit que aparta lo que falla, la vigilancia de la lista negra). Lo que queda
vive en el bytecode, y los contratos no son actualizables:

| Hallazgo | Qué pasa hoy |
|---|---|
| Tesorería en la lista negra | Ningún pago se liquida; solo se arregla redesplegando |
| Operador en la lista negra | Sus intents no se pueden cobrar, y la firma del pagador queda inservible |
| `registerIntentBatch` | Un registro inválido hace revertir el lote entero |
| `intentSigner` | En la práctica depende de una sola clave: perderla obliga a redesplegar el hub, y es la que decide el comercio de un pago aún no registrado |
| `setMinStake` | Solo sube y no tiene tope: un error o una llave robada deja fuera a todos los nodeits para siempre |
| `transferGuardian` | En un paso: una dirección mal escrita pierde el guardian para siempre |
| Pausa de StakeManager | Congela también los retiros: el guardian puede atrapar el stake de todos |
| Fondos sin salida | USDC enviado al hub por error no sale nunca (hay 20 USDC en el de Sepolia) |
| Despliegue | Nada impide desplegar mainnet con roles críticos en carteras sueltas |

## Principios

El diseño responde a cinco criterios, en este orden cuando chocan:

1. **No mover dinero ajeno.** Ninguna llave —ni el guardian, ni la API, ni un
   nodeit— puede llevarse fondos de nadie. Es la definición del proyecto.
2. **Una parte que falla no detiene a las demás.** Un comercio, un operador o la
   tesorería con problemas afectan a lo suyo, no a los pagos de los demás.
3. **Nada se detiene solo.** Lo que no se pueda arreglar en el acto queda
   retenido y recuperable, no bloqueando.
4. **Ninguna palanca de una sola llave es irreversible.** Lo que una llave pueda
   romper, se tiene que poder ver venir y deshacer.
5. **Evolucionar redesplegando.** Los contratos siguen sin ser actualizables; lo
   que cambie se cambia con un despliegue nuevo y una migración (§10).

## Decisión

### 1. El hub acredita las comisiones; cada uno reclama la suya

El reparto pasa a ser *pull* para operador y tesorería:

- En cada pago, el hub recibe el importe, **transfiere al comercio su parte en el
  acto** y **acredita** a nombre del operador y de la tesorería su comisión
  (`accrued[cuenta]`, y la suma en `totalAccrued`).
- `claim()` envía al que llama lo que tiene acreditado. `claimFor(cuenta)` hace lo
  mismo para otra cuenta, y lo puede llamar cualquiera: **el dinero solo sale
  hacia su dueño**, así que no hace falta permiso. Sirve para que una tarea
  periódica barra lo de la tesorería sin tener sus llaves.
- El comercio sigue cobrando en el momento. Si su cartera está en la lista negra,
  su pago revierte, que es lo correcto: no se debe aceptar un pago para quien no
  puede recibirlo, y acreditarlo dejaría el dinero del pagador retenido.
- La tesorería sigue siendo **inmutable** y siempre del proyecto: un 0.45% de
  cada pago, lo liquide el nodeit que lo liquide. Si la bloquean, los pagos siguen
  y su comisión queda acreditada; **no se puede redirigir** (principio 1), y se
  cobra cuando la desbloqueen.
- `IntentSettled` no cambia: el reconciliador de la API sigue leyendo lo mismo.
  Se añade `FeesClaimed(cuenta, importe)`.
- Las comisiones no cambian: 150 bps, 105 al operador y 45 a la tesorería.

De paso, el pago cuesta menos gas: dos escrituras en el almacenamiento del hub en
vez de dos transferencias de USDC, y en un lote el saldo de un mismo operador se
acumula.

### 2. Un registro inválido no hunde el lote

`registerIntentBatch` salta lo que no pasa, como ya hace el lote de pagos: cada
registro se intenta por separado (llamada a sí mismo con `try/catch`), lo que
falla se salta con un evento `IntentRegistrationSkipped(intentId)` y el resto se
registra. `registerIntent`, de uno en uno, sigue revirtiendo. El nodeit conserva
su aislamiento como segunda línea.

### 3. El `intentId` lleva dentro al comercio

El hub exige `intentId == keccak256(abi.encode(merchant, ref))`, donde `ref` es
el identificador del cobro fuera de la cadena (hoy `keccak256("pi_…")`). El
registro firmado incluye `ref`.

Como el pagador firma `nonce == intentId`, **su firma fija el comercio**: ni
quien controle `intentSigner` puede registrar ese `intentId` con otro comercio
para quedarse un pago ya firmado. El operador no entra en el `intentId`: se
decide cuando un nodeit toma el trabajo, después de que el pagador firme, y lo
fija el registro firmado. Lo que podría desviar quien controle `intentSigner` es
esa comisión del 1.05%, nunca el pago del comercio. Cambia cómo se calcula el
`intentId` en la API, el nodeit, el checkout y los SDK (ver «Consumidores que
cambian»).

### 4. `intentSigner` es un contrato propio, con la clave caliente rotable

Un contrato nuevo, `IntentSignerGate`, es el `intentSigner` del hub:

- Implementa ERC-1271: una firma vale si la recupera la **clave caliente** de la
  API (`signer`). La API sigue firmando cada registro sola, sin coordinar a nadie.
- Solo `admin` —un multisig frío, en mainnet— puede cambiar `signer`, al
  instante. Una clave robada se retira sin redesplegar el hub, y la clave caliente
  **no puede** rotarse a sí misma ni cambiar el admin: quien la robe no puede
  quedarse con el contrato. `signer = 0` es el freno de emergencia: ningún
  registro nuevo pasa hasta nombrar otro.
- El admin se transfiere en dos pasos (§6).
- Sigue siendo inmutable en el hub: el guardian no puede cambiar quién autoriza
  registros.

Se descartó un Safe 2-de-N con un co-firmante (otro servicio en el camino de
cada pago) y seguir con el Safe 1-de-1 (cualquier dueño puede echar a los demás).

### 5. `minStake` con plazo, al alza y a la baja

`setMinStake` se sustituye por:

- `proposeMinStake(nuevo)` (guardian): anuncia el cambio, con evento.
- `applyMinStake()` (cualquiera): lo aplica pasado `MIN_STAKE_DELAY` (7 días, el
  mismo plazo que un retiro de stake: un nodeit tiene tiempo de reponer o de
  irse).
- `cancelMinStakeProposal()` (guardian).

Puede bajar: un error se corrige proponiendo el valor anterior. Una llave robada
se ve venir una semana antes y se cancela rotando el guardian. El vigía de la API
avisa de cualquier propuesta pendiente.

### 6. El guardian se transfiere en dos pasos

`transferGuardian(nuevo)` lo deja pendiente y `acceptGuardian()`, llamado por el
nuevo, lo hace efectivo. Una dirección mal escrita nunca acepta, y el guardian
sigue siendo el anterior. Lo mismo para el `admin` de `IntentSignerGate`.

### 7. La pausa no atrapa fondos, y se documenta lo que hace

- En StakeManager, `requestWithdrawal` y `executeWithdrawal` funcionan con el
  contrato en pausa; `deposit` no. La pausa frena el riesgo nuevo, no retiene el
  stake de nadie.
- En el hub, `claim` y `claimFor` funcionan en pausa.
- El NatSpec del hub dice lo que hace la pausa: bloquea registros, y como cada
  pago se registra al liquidarse, detiene también los pagos aún no registrados.

### 8. Lo que llega por error tiene salida

- Hub: `sweepSurplus()` envía a la tesorería el USDC que no esté acreditado a
  nadie (`balanceOf(hub) − totalAccrued`). `sweepToken(token)` hace lo mismo con
  cualquier otro token. Los dos los puede llamar cualquiera: el destino es fijo.
- StakeManager: lleva la cuenta de lo depositado y lo que está saliendo
  (`totalHeld`) y `sweepSurplus()` envía el resto a la tesorería, que pasa a ser
  un parámetro inmutable también aquí, solo para esto.

Ninguno puede tocar lo acreditado ni el stake de nadie: solo lo que sobra.

### 9. Guardas de despliegue para mainnet

`Deploy.s.sol`, en la red principal de Base (`chainid` 8453), exige que la
tesorería, el guardian y el `admin` de `IntentSignerGate` sean contratos (un
multisig), y despliega el propio `IntentSignerGate`. En testnet admite carteras
sueltas, como hoy.

### 10. Cómo se evoluciona

Los contratos siguen sin ser actualizables. Un cambio futuro se hace como este:
despliegue nuevo, la API pasa a registrar en el hub nuevo y el viejo se queda
para lo que tenga pendiente. Con el reparto *pull*, lo acreditado en un hub viejo
se puede reclamar siempre: un hub retirado no retiene dinero de nadie.

## Lo que no cambia

- Las comisiones (ADR-005), el tope de lote (50) y el plazo máximo de un intent
  (30 días).
- La atadura de la firma del pagador a su intent (`nonce == intentId`, ADR-004).
- Que el comercio cobre en la misma transacción del pago.
- Que nadie pueda mover fondos de nadie.

## Alternativas descartadas

- **Pagar en el momento y acreditar solo si falla.** El caso normal no cambia,
  pero son dos caminos que probar y auditar, y el gas no baja.
- **Tesorería redirigible por el guardian.** Recupera la comisión de una
  tesorería bloqueada a cambio de darle al guardian poder sobre ese dinero, contra
  el principio 1.
- **Acreditar también al comercio.** Un comercio bloqueado dejaría el dinero del
  pagador retenido en el hub; mejor que su pago no pase.
- **`intentSigner` como Safe 2-de-N con co-firmante**, o **1-de-1** como hoy:
  ver §4.
- **`minStake` con tope fijo o en dos pasos**: el tope hay que elegirlo hoy para
  siempre, y los dos pasos no protegen de una llave robada.

## Consumidores que cambian

| Dónde | Qué |
|---|---|
| `coatipay-protocol/contracts` | Los cuatro contratos, `Deploy.s.sol`, pruebas, invariantes y las pruebas de concepto de la revisión como regresión |
| `coatipay-protocol/protocol` | Constantes generadas (`MIN_STAKE_DELAY`), el cálculo del `intentId`, el registro con `ref`, vectores para los SDK; versión 0.2.0 |
| API | El cálculo y guardado del `on_chain_id`, la firma del registro (directa, sin el envoltorio de Safe), el preflight (`signer` del gate = clave de la API), el vigía (propuestas de `minStake`, saldo acreditado de la tesorería), una tarea que barre lo de la tesorería |
| Nodeit | El `intentId` que da la API en vez de calcularlo, el ABI nuevo, `claim()` periódico de su comisión |
| Checkout | El `nonce` que firma el pagador |
| SDK (JS, Python, PHP) | El cálculo del `intentId` y la autorización ERC-3009; versiones nuevas |
| Docs | PROTOCOL, INFRASTRUCTURE, SECURITY, el README del protocolo y de `coatipay-node`, la landing, y SCOPE |

## Migración en Base Sepolia

- Se despliegan los contratos nuevos y `IntentSignerGate`; las direcciones van a
  `contracts/deployments/sepolia.json`.
- El nodeit bootstrap se registra en el `NodeRegistry` nuevo con stake nuevo: el
  del StakeManager viejo tarda 7 días en salir.
- La API pasa al hub nuevo cuando no queden autorizaciones pendientes del viejo;
  ningún intent del viejo dura más de 30 días.
- Los 20 USDC del hub viejo no tienen salida (es el problema de §8); se pierden.

## Verificación

El cambio se da por bueno cuando hay pruebas de que:

- con la tesorería o un operador en la lista negra, los pagos se liquidan (las
  pruebas de concepto de la revisión, ahora como regresión, contra el USDC real
  en una bifurcación de Base Sepolia);
- `balanceOf(hub) ≥ totalAccrued` siempre (invariante);
- un registro inválido en un lote no impide los demás;
- un `intentId` que no corresponde al comercio no se registra, aunque lo firme
  `intentSigner`;
- solo `admin` cambia el `signer`, y la clave caliente no puede;
- `minStake` no cambia antes del plazo, y se puede cancelar;
- un guardian mal escrito no se queda con nada;
- con StakeManager en pausa se puede retirar;
- el rescate solo mueve lo que sobra.
