# ADR-007 — La API lee de la cadena qué se pagó; el nodeit no informa de nada

> **Status**: 🟢 **Aceptado** (2026-09-27)
> **Date**: 2026-09-27
> **Supersede**: — No cambia ningún contrato. Sustituye el camino off-chain por
> el que un pago pasaba a «liquidado»: el watcher de eventos de cada nodeit, que
> informaba a la API (fase B4 de ADR-003).

## Contexto

Hasta ahora, un pago pasaba a `settled` así: el nodeit que lo había enviado
vigilaba los eventos `IntentSettled` del hub y se lo contaba a la API
(`/v1/internal/settlements/by-on-chain-id`). Antes, al registrar el intent en
la cadena, le había contado también su identificador on-chain
(`/v1/internal/intents/:id/registered`).

### Qué fallaba (F-5, hallazgo propio)

Lo encontramos el 2026-09-27 al abordar la reconciliación de pagos, uno de los
puntos del informe de preparación para el piloto. La API **aplicaba lo que el
nodeit decía, sin comprobarlo**, y cualquiera puede ser nodeit: registrarse es
abierto con 40 USDC de stake, que además no se pueden confiscar (ADR-004).

| Ruta | Qué podía hacer un nodeit malicioso |
|---|---|
| `/settlements/by-on-chain-id` | Marcar como **pagado** un cobro que nadie pagó. El comercio recibía el webhook `payment_intent.settled` y entregaría sin cobrar |
| `/intents/:id/registered` | Asignar a un cobro B el identificador de otro cobro A (se quedaba el primero que escribiera). **El pago de A se registraba entonces como pago de B**, de otro comercio, y A no se registraba nunca |
| `/authorizations/:id/rejected` | Rechazar autorizaciones que había reclamado otro nodeit |

Reproducido antes del arreglo, el cambiazo contra un Postgres real. No se
explotó ni se podía: el único nodeit activo en la cadena es el nuestro, y la
API exige estar activo. Con el primer nodeit de terceros habría sido
explotable. Al desplegar el arreglo, la migración no encontró ningún
identificador que no correspondiera a su cobro.

**Es la misma familia que F-1, F-3 (ADR-004) y F-4 (ADR-006):** la parte de
confianza actuaba sobre lo que le entregaba la no confiable.

### El fallo de fiabilidad que lo destapó

El watcher del nodeit era el **único** camino a `settled`, y podía perder
pagos para siempre:

- **Su cursor vivía en memoria.** Tras un reinicio solo releía unos minutos de
  bloques: un nodeit caído más tiempo dejaba pagos movidos en la cadena y
  nunca registrados.
- **Un 404 descartaba el evento.** Si el aviso de registro no había llegado, la
  API respondía 404 «para que el watcher reintente» y el watcher lo descartaba.
  Cada parte asumía que la otra reintentaba; ninguna lo hacía. El código y el
  documento de alcance de la auditoría decían que se reintentaba.

## Decisión

**La API lee la cadena ella misma, y ningún nodeit le informa de nada sobre
ella.**

### 1. Un reconciliador en la API, única vía a «liquidado»

Lee los eventos `IntentSettled` del hub y aplica cada uno al cobro que le
corresponde, con los datos del propio evento:

- **Cursor en Postgres.** Sobrevive a reinicios y no depende de ningún nodo.
  Avanza solo después de aplicar un tramo entero, así que un fallo a mitad se
  repite, no se salta.
- **Margen de confirmaciones.** Solo se aplica lo que está unos bloques por
  debajo de la cabeza.
- **Tramos que se adaptan.** Si el proveedor RPC rechaza el tramo por grande
  (el público de Base admite 1,000 bloques; otros, 10), lo reduce solo.
- **Reorganizaciones.** Guarda el hash del último bloque leído. Si deja de ser
  canónico, retrocede, comprueba cada pago del tramo por su recibo, corrige los
  que se re-minaron en otro bloque y marca los que desaparecieron. **No los
  deshace en silencio:** el comercio ya recibió el webhook, así que se deja
  constancia y se registra como error para revisarlo con él.
- **Identidad de cada pago:** bloque, hash, posición del evento y la hora del
  bloque, no la de quien lo procesa.
- **La cadena manda:** un cobro `expired` o `cancelled` que se pagó queda
  registrado como pagado.
- **Idempotente:** varias instancias de la API no se pisan.

### 2. El webhook, al menos una vez

Una bandeja de salida en la propia tabla de cobros: si el pago quedó registrado
pero el aviso no llegó a encolarse (Redis caído, reinicio a mitad), el
reconciliador lo reintenta en la vuelta siguiente.

### 3. El identificador on-chain lo pone la API

Es determinista (`keccak256(id del cobro)`), así que la API lo guarda al crear
el cobro. Nadie tiene que informarle, y nadie puede cambiarlo.

### 4. El canal interno ya no acepta afirmaciones

Al nodeit se le reparte trabajo y se le deja devolver el suyo, nada más:

- Fuera `/settlements/by-on-chain-id` y `/intents/:id/registered`.
- `/rejected` solo lo acepta del nodeit que reclamó esa autorización, y
  mientras siga reclamada.

### 5. Se retira el watcher del nodeit

Deja de hacer falta. Cada nodeit se ahorra unas 43,000 llamadas RPC al día, y
es una pieza menos en la que confiar. El nodeit sigue leyendo la cadena para su
propio trabajo: comprueba si un cobro ya está registrado antes de registrarlo,
también en los lotes.

## Alternativas descartadas

- **Mantener el watcher y verificar en la API cada aviso** leyendo su recibo.
  Cierra el engaño, pero deja la fiabilidad en manos de los nodeits: si ninguno
  vigila, nada se registra. Y cada nodeit seguiría gastando RPC en algo que la
  API tiene que comprobar de todos modos.
- **Persistir el cursor del watcher en disco**, en el volumen del nodeit. Cierra
  la pérdida por reinicio, no la de F-5, y obliga a cada nodeit de la comunidad
  a cuidar un estado que no es suyo.
- **Leer solo hasta el bloque «safe» de Base** en lugar de dejar un margen de
  confirmaciones. Casi elimina las reorganizaciones, pero retrasa el aviso al
  comercio varios minutos. Con margen y detección, el aviso llega en segundos y
  la rara reorganización queda registrada.

## Consecuencias

- **Un pago queda registrado aunque todos los nodeits estén caídos**, en cuanto
  la API lee su bloque.
- **La API necesita saber desde dónde leer:** el bloque en que se desplegó el
  hub (`SETTLEMENT_HUB_DEPLOY_BLOCK`). Sin él, no arranca. El primer arranque se
  pone al día desde ahí; en Base Sepolia, unos 4 minutos.
- **Los pagos de hubs anteriores** no se vuelven a leer: sus eventos están en
  contratos que ya no se consultan.
- **Para un operador de nodeit** desaparecen las variables `EVENT_*` y el campo
  `watcher` de `/health`.
- **Ningún contrato cambia:** no hay redespliegue, y el alcance de contratos de
  la auditoría es el mismo. El alcance off-chain cambia: entra el reconciliador
  y sale el watcher.
- **Sin aviso público.** Fue un hallazgo interno, sin explotación y sin reporte
  externo.

## Verificación

- **Tests:** API 255, 24 de ellos contra un Postgres real que también corre en
  CI, y nodeit 50.
  - Con cada garantía del reconciliador rota a propósito —confirmaciones,
    cursor, reducción de tramo, reorganización, bandeja—, su test falla.
  - Un test despliega sobre una base con el esquema anterior. Falta hacía: el
    primer intento de despliegue abortó porque el esquema base usaba columnas
    que en una base existente solo añade la migración siguiente. Producción no
    cambió.
- **RPC público real de Base Sepolia:** el reconciliador se puso al día desde el
  despliegue del hub (1,138 lecturas en tramos de 1,000) y aplicó un pago real
  con su transacción y su bloque.
- **Fork de Base Sepolia:** un pago nuevo queda registrado con su bloque, y una
  reorganización real que lo elimina queda detectada y marcada.
- **Producción, 2026-09-27:** desplegado. Un pago real de 0.85 USDC liquidó
  0.83725 / 0.008925 / 0.003825, y el reconciliador lo registró 12 segundos
  después de su bloque, con el webhook encolado. El nodeit no informó de nada.
  Tx `0xb26e57b2b2e2b216a2589d4dd1cef5daa1fffa10dacc2fae44a52e74589ca9ac`.
