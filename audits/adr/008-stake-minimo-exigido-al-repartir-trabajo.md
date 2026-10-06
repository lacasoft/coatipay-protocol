# ADR-008 — El stake mínimo se exige al repartir el trabajo, no en el contrato

> **Status**: 🟢 **Aceptado** (2026-10-06)
> **Date**: 2026-10-06
> **Supersede**: — No cambia ningún contrato. Deja decidida, con plazo y con
> pruebas, una comprobación que la API ya hacía sin que estuviera escrita en
> ninguna parte.

## Contexto

`NodeRegistry.register()` exige que el operador tenga depositado al menos
`minStake`, y lo comprueba **una sola vez**. Después hay dos maneras de quedar
por debajo sin que el registro se entere:

- **El nodeit retira.** `StakeManager.requestWithdrawal()` descuenta el stake en
  el acto —pasa a `pendingWithdrawal`, con siete días de espera— y no avisa al
  registro.
- **El guardian sube el mínimo.** `setMinStake()` solo puede subirlo, y puede
  dejarlo por encima de lo que tiene depositado un nodeit ya registrado.

En los dos casos el registro sigue diciendo `active = true` de un nodeit que ya
no cumple el mínimo. La revisión de septiembre de 2026 (hallazgo M-03) pedía
decidir dónde vive la garantía «un nodeit bajo el mínimo no recibe trabajo»:
en el contrato o fuera de él, y dejarlo escrito con pruebas.

### Qué protege el stake

Desde ADR-004 el stake **no se confisca**: ninguna llave puede quitárselo a
nadie. Es la condición para entrar en el registro y una barrera contra crear
nodeits en masa. No es una fianza contra el robo, porque un nodeit no puede
quedarse un pago: el reparto es atómico en el contrato, el comercio lo fija la
firma de `intentSigner`, y la autorización del pagador solo vale para su intent.

Lo peor que puede hacer un nodeit es no liquidar lo que tomó, y eso vuelve a la
cola a los cinco minutos. Así que lo que está en juego con un nodeit sin stake
no son los fondos de nadie: es que siga cobrando su 1.05 % sin tener nada
depositado.

### Por dónde recibe trabajo un nodeit

Por un solo sitio: el canal interno de la API. El nodeit **pide** trabajo
(`claim`, `claim-batch`) y, sobre lo que ya tomó, devuelve (`rejected`) o avisa
(`broadcast`). La API no le asigna cobros de antemano, y la cadena no le da
nada que liquidar por su cuenta: `registerIntent` exige el registro firmado por
`intentSigner` (ADR-004), que la API emite en esa misma respuesta y para el
operador que acaba de autenticarse.

## Decisión

**La garantía vive en la API, no en el contrato.**

### 1. Cada petición comprueba el stake en la cadena

Antes de leer siquiera el cuerpo, las cuatro rutas del canal interno pasan por
la misma comprobación: el operador que firmó la petición tiene que estar
registrado, `active`, y con `staked >= minStake`.

- `staked` es lo depositado (`StakeManager.getStakeInfo`). Lo que está saliendo
  (`pendingWithdrawal`) **no cuenta**, aunque siga en el contrato.
- `minStake` se lee del registro en la misma consulta: si el guardian lo sube,
  vale el nuevo.

Quien no pasa recibe el mismo 403 genérico que cualquier otro rechazo, para que
no se pueda sondear el registro a través de la API. El motivo
(`insufficient_stake`) queda en el log.

### 2. Plazo máximo de revocación: 30 segundos

La lectura de la cadena se guarda `NODES_CACHE_TTL_SECONDS` —30 por defecto—
para no hacer tres lecturas de contrato en cada petición de cada nodeit. Ese es
el plazo: desde que el retiro, o la subida del mínimo, está en la cadena que ve
la API, el nodeit deja de pasar **como mucho 30 segundos después**.

La configuración **no admite más de 60**: con un valor mayor, la API no
arranca. El plazo no se puede alargar sin que alguien lo vea.

Si el caché no está disponible, la cadena se lee en cada petición: más
estricto, no menos.

### 3. Sin lectura, no pasa nadie

Si el registro no se puede leer —el RPC no contesta—, la petición termina en
error y no se reparte nada. Una lectura fallida nunca se toma por buena, y no
se guarda.

### 4. Se avisa

El vigía de la API compara en cada vuelta el stake de cada nodeit activo del
registro con el mínimo. Si alguno está por debajo:

- avisa por correo: «Un nodeit activo tiene el stake bajo el mínimo», con el
  operador, lo que tiene y lo que falta;
- deja de contarlo entre los nodeits sanos. Si era el único, `/ready` responde
  503: los pagos no pueden avanzar.

## Alternativas descartadas

- **Que lo garantice el contrato** (opción A de M-03): un retiro que cruza el
  mínimo desactiva al nodeit. Tiene una ventaja real —quien lea la cadena ve
  siempre la verdad— y tres costes:
  - `StakeManager` tendría que avisar a `NodeRegistry`, cuando hoy es el
    registro el que lee al otro; o `isActive` y `getActiveNodes` tendrían que
    leer el stake de cada nodeit en cada consulta.
  - No cubre la subida de `minStake`, que deja por debajo a nodeits que no han
    hecho nada, salvo recorriendo la lista entera.
  - Es bytecode nuevo: redespliegue —el stake no viaja de un despliegue a otro—
    y más alcance para la auditoría.

  Hoy nadie más que la API reparte trabajo, así que ese coste compraría una
  garantía que ya se tiene.
- **No guardar la lectura** (plazo cero). Tres lecturas de contrato por
  petición, de cada nodeit, cada diez segundos. Frente a un retiro que tarda
  siete días en completarse, bajar de 30 segundos a cero no cambia nada que
  importe.
- **Rechazar a quien tenga un retiro en curso**, aunque conserve el mínimo.
  Retirar lo que sobra es legítimo; lo que cuenta es lo que queda depositado.

## Consecuencias

- **La cadena puede decir `active` de un nodeit que la API ya no acepta.** Quien
  lea `NodeRegistry` por su cuenta tiene que mirar también el stake.
  `GET /v1/nodes` devuelve `stake` y `min_stake` de cada uno.
- **La garantía depende de que la API sea el único repartidor de trabajo.** Si
  algún día hay otro —un enrutado descentralizado, un segundo frontal—, hará
  falta la opción A, y este ADR se revisa.
- **Durante el plazo**, un nodeit que acaba de bajar del mínimo puede tomar
  trabajo y cobrar su comisión por él. No puede hacer nada que no pudiera hacer
  con stake.
- **Lo que ya había tomado se liquida igual**, si lo envía: el contrato no mira
  el stake al liquidar, y la API registra el pago leyéndolo de la cadena
  (ADR-007). Lo que no envíe vuelve a la cola a los cinco minutos.
- **Al reponer el stake vuelve a pasar** en el mismo plazo, sin que nadie
  intervenga.
- **Ningún contrato cambia:** no hay redespliegue, y el alcance de contratos de
  la auditoría es el mismo.

## Verificación

- **El límite, exacto:** con el mínimo justo pasa y con una unidad menos no; con
  cantidades mayores que 2^53 se compara bien; y si el guardian sube el mínimo
  por encima del stake, deja de pasar.
- **El plazo:** un operador que retira después de haber pasado sigue pasando
  dentro de los 30 segundos y deja de pasar al cumplirse. Lo guardado caduca en
  ese tiempo, ni un segundo más. Con 61 segundos o más en la configuración, la
  API no arranca.
- **Todas las rutas:** las del canal interno se leen de como quedan registradas,
  no de una lista escrita a mano, así que una ruta nueva queda cubierta sola. En
  cada una, un operador bajo el mínimo, sin stake, inactivo o sin registrar
  recibe 403 y no se reparte ni se cambia nada. Con el RPC caído, tampoco.
- **El aviso:** un nodeit activo bajo el mínimo produce la alerta y no cuenta
  como sano aunque responda; si era el único, ninguno sano.
- **Cada garantía rota a propósito** hace fallar alguna prueba: no comparar el
  stake, compararlo como número de coma flotante, alargar el caché, quitar el
  tope, tomar por bueno un fallo del RPC, contar lo que está saliendo, dejar
  una ruta sin comprobar.
- **Contra los contratos desplegados en Base Sepolia**, solo lectura: el nodeit
  bootstrap sale activo, con 40 USDC depositados y 40 de mínimo; una dirección
  que nunca se registró, como no registrada.
