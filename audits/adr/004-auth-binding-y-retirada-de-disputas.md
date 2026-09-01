# ADR-004 — Atadura de la autorización al intent, y retirada del sistema de disputas

> **Status**: 🟢 **Aceptado** (2026-08-29)
> **Date**: 2026-08-29
> **Supersede**: ADR-001 §3.10 (integración con disputas), ADR-002 §2.1 en lo
> relativo al slashing, y el registro permissionless de intents de ADR-001.
> El reparto de comisiones (100 bps, 70/30) sigue vigente sin cambios.

## Contexto

El 2026-08-29 recibimos la divulgación externa de [ibnu76](https://github.com/ibnu76) sobre los
contratos públicos, con pruebas de concepto ejecutables. Reprodujimos ambos hallazgos de
forma independiente antes de tocar código.

### F-1 — La autorización gasless no estaba atada a su intent (crítica)

La firma ERC-3009 que emite el pagador cubre `from`, `to`, `value`,
`validAfter`, `validBefore` y `nonce`. **No cubre el intent.** Y como USDC exige
`msg.sender == to`, el `to` firmado es siempre el hub: la firma nunca puede
nombrar al comercio.

El destino del dinero lo decidía `auth.intentId`, un campo del calldata que
elige quien envía la transacción — el nodeit, que es **la parte no confiable por
diseño**. Un nodeit malicioso registraba un intent propio por el mismo importe y
aplicaba ahí la firma del pagador.

Reproducido: el atacante se lleva **997 de 1000 USDC** (99% del comercio + 0.7%
del operador) y el comercio honesto recibe cero.

Esto anulaba la razón de ser del SettlementHub, que ADR-001 justifica diciendo
que *«con el split atómico el operador ya no puede robar pagos»*.

### F-2 — Cualquiera podía quemar el stake de cualquier nodeit (alta)

`DisputeResolver.openDispute` no validaba nada: ni que quien abre sea el comercio
del pago, ni que el intent exista, ni que el nodeit señalado lo hubiera enrutado.
El contrato no tenía referencia alguna al SettlementHub. Pasadas 48 horas sin
respuesta, `expireDispute` ejecutaba el castigo **sin votación de árbitros**.

Es denegación de servicio, no robo: los fondos van al treasury y el atacante no
gana nada. Pero un solo castigo del 20% deja al nodeit **por debajo del
`minStake`**, y el API rechaza a quien no llega al mínimo. Es decir: saca al
operador de la red.

### F-3 — El nodeit elegía a quién se paga (crítica, hallazgo propio)

Al comprobar si la corrección de F-1 era **íntegra** encontramos una segunda
ruta de la misma clase, que el reporte externo no cubría.

`registerIntent` era permissionless y **el daemon del nodeit es quien lo llama**
on-chain, con datos que le entrega el API. Nada le obligaba a usarlos: bastaba
sustituir la dirección del comercio por la suya al registrar el intent que el
API le había asignado. El nonce seguía coincidiendo con el `intentId`, así que
la atadura de F-1 no lo detectaba.

Reproducido con la corrección de F-1 ya aplicada: el nodeit se lleva los mismos
**997 de 1000 USDC**. Tampoco había red de seguridad off-chain — el vigilante de
eventos registra los importes pero nunca compara la dirección del comercio.

La causa raíz es que **el contrato no tenía ninguna fuente autenticada** para
saber quién es el comercio de un intent: se fiaba de quien llamaba, que es la
parte no confiable.

## Decisión

### 1. `nonce == intentId`, exigido on-chain

`_payAndSettleViaAuth` revierte con `AuthorizationNotBoundToIntent` si el nonce
de la autorización no es el identificador del intent que se paga.

Encierra cada firma en un intent concreto: `registerIntent` rechaza
identificadores repetidos, así que ese intent ya tiene dueño y no se puede
suplantar. El nonce de USDC es un `bytes32` arbitrario que se consume una sola
vez, de modo que reutilizarlo queda bloqueado por partida doble.

**Descartamos la otra mitad del arreglo sugerido** —guardar el pagador esperado
en el intent al registrarlo— porque no es implementable en el flujo actual: el
intent se registra **antes** de que el pagador conecte su cartera, así que su
dirección todavía no se conoce. La atadura del nonce cierra el fallo por sí sola.

Efecto secundario deseable: el mapa de nonces de USDC pasa a garantizar también
una sola liquidación por intent, de forma independiente al estado del intent.

### 2. El registro de intents va firmado (EIP-712)

`registerIntent` exige la firma de `intentSigner` sobre
`(intentId, merchant, operator, amount, expiresAt)`. El nodeit sigue enviando la
transacción y pagando el gas, pero no puede alterar el contenido.

**`intentSigner` es inmutable a propósito.** Si el guardian pudiera rotarlo,
tendría capacidad de atar pagos en vuelo a un comercio de su elección — es
decir, de mover fondos, que es exactamente la potestad que este diseño le niega.

**Y acepta un multisig.** La verificación usa `SignatureChecker`, no
`ECDSA.tryRecover`, así que el firmante puede ser una cartera normal o un
contrato ERC-1271 — el mismo mecanismo que USDC ya emplea aquí para las smart
wallets. **En producción debe ser un multisig**, y el contrato admite ambos solo
por compatibilidad.

Eso resuelve la tensión que dejaba la inmutabilidad. Con una sola clave, el
peor escenario era caro: perderla o que se filtrara obligaba a **redesplegar el
hub entero**, y una sola llave bastaba para autorizar. Con un multisig la
dirección sigue siendo inmutable —el guardian no la toca— pero **los firmantes
se rotan por dentro**, así que el peor escenario pasa a ser *cambiar un firmante
en el Safe*. Y comprometer una llave deja de ser suficiente: hay que alcanzar
el umbral.

La pausa sigue existiendo como palanca de emergencia para el caso en que se
comprometa el umbral entero.

Es una centralización real y hay que declararla: la plataforma pasa a ser
autoritativa sobre el binding intent→comercio. Ya lo era de facto —decide el
alta de comercios y el enrutamiento—, pero ahora queda explícito en el contrato.

De paso, el lote pasa de seis arreglos paralelos a **un arreglo de structs**.
Elimina de raíz la clase de fallo de longitudes descuadradas (y su test, que ya
no puede fallar) y resuelve el agotamiento de pila que provocaba el parámetro
extra.

### 3. Se retiran las disputas y el slashing

Eliminados `DisputeResolver.sol`, `IDisputeResolver.sol`, sus tests e
invariantes, y de `StakeManager`: `slash()`, `initialize()`, el campo
`disputeResolver` y el `treasury` —que solo existía para recibir lo castigado y
quedaba como estado muerto.

No es solo una respuesta a F-2. Al revisarlo encontramos que el sistema de
disputas:

- **Nunca se usó.** Cero eventos emitidos on-chain desde su despliegue.
- **No estaba cableado.** `disputeResolverAddress` se leía en la configuración
  del API y no la consumía nadie; los webhooks `dispute.opened` y
  `dispute.resolved` estaban declarados y nada los emitía; el panel contemplaba
  un estado `disputed` que nada asignaba.
- **Había perdido su motivo.** Nació antes que el SettlementHub, cuando un
  nodeit sí podía quedarse el pago. ADR-001 §3.10 ya reconoció ese cambio y
  reasignó las disputas a «castigar mala conducta de enrutamiento».

Con F-1 corregida, lo peor que puede hacer un nodeit es **negarse a liquidar**, y
eso ya se autocastiga: no cobra su 0.7%. El castigo económico no aporta una
defensa que el diseño no tenga ya.

**El stake se mantiene**, y sigue siendo obligatorio: acredita a un nodeit para
entrar en el registro y es barrera anti-Sybil y compromiso de capital. Lo que
desaparece es la capacidad de confiscarlo.

## Alternativas descartadas

**Arreglar las disputas** enlazando el contrato al SettlementHub y validando
comercio y operador, como sugería el reporte. Cierra F-2 correctamente, pero
mantiene 364 líneas en el alcance de auditoría para una función que nunca se ha
usado ni está cableada.

**Conservar `slash()` restringido al guardian.** Crearía una llave privilegiada
capaz de mover fondos de operadores al treasury, y rompería la afirmación del
documento de alcance de que no existen admin keys que muevan fondos. Empeora la
auditoría en lugar de mejorarla.

## Consecuencias

- **Los contratos hay que redesplegarlos.** Las constantes y la lógica viven en
  bytecode no actualizable.
- **El despliegue es un corte limpio, no una transición gradual.** El registro
  cambia de firma (struct + firma EIP-712), así que el daemon viejo no puede
  hablar con el contrato nuevo ni al revés. La secuencia es: desplegar los
  contratos nuevos, y **después** apuntar API y daemon a las direcciones nuevas
  en la misma ventana. Los intents registrados en el contrato viejo que no se
  hayan liquidado hay que drenarlos antes o darlos por caducados.
  (Una versión anterior de este documento decía que el cambio off-chain podía ir
  primero por ser compatible con ambos contratos: eso valía cuando la corrección
  era solo la atadura del nonce, y dejó de ser cierto al firmar el registro.)
- **El SDK cambia de comportamiento**: el nonce dejaba de ser aleatorio. Exige
  publicar versión nueva de los tres SDK.
- **Despliegue más simple y más seguro**: sin la dependencia circular
  StakeManager↔DisputeResolver desaparece la fase con el deployer como guardian
  temporal. Los cuatro contratos reciben al guardian real en su constructor y el
  deployer no llega a tener autoridad en ningún momento.
- **Menos superficie de auditoría**: −364 líneas de DisputeResolver, más
  `slash()` y el cableado asociado.
- **Hay que preparar el multisig antes de desplegar**: su dirección se pasa al
  constructor y no se puede cambiar después. Decidir umbral y custodia de las
  llaves forma parte del despliegue, no es un ajuste posterior.
- **La invariante de conservación se refuerza**: sin fuga al treasury, todo lo
  depositado o sigue en el contrato o volvió a su dueño. Pasa de desigualdad a
  igualdad exacta.
- **Hay que actualizar la documentación** que vende disputas y *piel en el
  juego*: whitepaper, PROTOCOL, INFRASTRUCTURE y el documento de alcance.

## Verificación

- El exploit de F-1 se reprodujo primero contra el código vigente (997 USDC al
  atacante, 0 al comercio) y **después** se comprobó que revierte.
- **Nueve** tests de regresión en `SettlementHub.authBinding.t.sol`: la
  autorización redirigida, el nonce suelto, el lote con un elemento redirigido,
  el nodeit nombrándose comercio, la alteración del comercio o del importe tras
  firmar, el lote con un elemento manipulado, y los dos caminos legítimos.
- El ataque de F-3 se reprodujo **con la corrección de F-1 ya aplicada** —para
  demostrar que era insuficiente— y después se comprobó que revierte.
- El arnés de pruebas ya no acepta un nonce suelto: se deriva del intent, para
  que ningún test futuro pruebe un camino que no existe.
- Seis tests con un multisig 2-de-3, incluido el que da sentido al cambio: se
  retira una llave comprometida, las sanas siguen autorizando contra el mismo
  hub, la retirada deja de contar y `intentSigner` no cambia en ningún momento.
- Suite completa en verde. El recuento cuadra exactamente con lo eliminado:
  197 − 44 − 6 − 10 − 1 − 1 − 3 − 1 + 9 + 1 + 6 = **147**, y los 147 pasan.
