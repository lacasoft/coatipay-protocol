# ADR-005 — Comisión del protocolo del 1.0% al 1.5%

> **Status**: 🟢 **Aceptado** (2026-08-31)
> **Date**: 2026-08-31
> **Supersede**: ADR-002 §2.1 en los valores de la comisión. El reparto 70/30
> entre nodeit y treasury, y el razonamiento que lo sostiene, siguen vigentes.

## Contexto

La comisión del protocolo es una constante del bytecode y los contratos **no
son actualizables por diseño**. Cambiarla en cualquier momento cuesta un
redespliegue completo y una re-auditoría.

[ADR-004](004-auth-binding-y-retirada-de-disputas.md) ya obliga a redesplegar
por seguridad, y la auditoría externa **todavía no ha empezado**. Es decir: la
ventana en la que este cambio es prácticamente gratuito está abierta ahora y no
va a repetirse.

## Decisión

| Constante | Antes | Ahora |
|---|---|---|
| `PROTOCOL_FEE_BPS` | 100 (1.0%) | **150 (1.5%)** |
| `TREASURY_SHARE_BPS` | 30 (0.3%) | **45 (0.45%)** |
| `OPERATOR_SHARE_BPS` *(derivada)* | 70 (0.7%) | **105 (1.05%)** |
| Recibe el comercio | 99% | **98.5%** |

**El reparto 70/30 se mantiene.** Subir la comisión sin tocar el reparto hace
que la parte del nodeit suba en proporción —de 0.7% a 1.05%— y no cambia el
incentivo relativo de operar un nodo justo cuando queremos que la red crezca.
Mover el reparto a la vez que el precio habría exigido justificar dos cosas en
lugar de una.

## La promesa del 1% a los primeros adoptantes se retira

Se había considerado respetar el 1% a quienes entraran primero. **No es
expresable en este contrato**: `PROTOCOL_FEE_BPS` es una constante única y
global, no hay tarifa por comercio. Desplegar a 1.5% significa que **todos**
pagan 1.5%.

Las alternativas se descartaron:

- **Devolver la diferencia fuera del contrato** exigiría un flujo manual y
  custodial — exactamente lo que este diseño evita.
- **Un segundo hub al 1%** para los comercios antiguos duplicaría la superficie
  de auditoría y el trabajo de operación, para honrar una promesa que todavía no
  ha vinculado a nadie.

Estamos en testnet y no hay comercios reales pagando comisiones, así que la
promesa no ha creado ninguna expectativa que romper. Pero **hay que retirarla
de la comunicación pública antes de que alguien se acoja a ella**: landing,
READMEs de los SDK y whitepaper.

## Consecuencias

- El redespliegue de ADR-004 lleva también este cambio. No hay redespliegue
  adicional.
- **`fee-constants.generated.ts` se regenera desde el contrato** con el
  generador SSOT; no se edita a mano. El gate de deriva en CI lo comprueba.
- Los tres SDK publican versión nueva de todos modos por ADR-004; la comisión
  viaja en esa misma publicación.
- La **calculadora de la landing** es lo más frágil: sus cifras están escritas a
  mano y dejan de cuadrar. Ver [[project_mapa_comision_1pct]] en las notas del
  proyecto para el inventario de dónde vive el 1%.
- El redondeo del split sigue siendo **a la baja y a favor del comercio**: sobre
  1000 unidades base, 986 / 10 / 4, sin polvo perdido.
- Frente a un procesador tradicional (2.9% + $0.30) el ahorro sigue siendo
  amplio en pagos típicos de LATAM, aunque menor que antes. Los documentos que
  citaban un porcentaje concreto de ahorro hay que recalcularlos o dejar de
  fijar la cifra.

## Verificación

- 147 tests en verde con las constantes nuevas.
- Comprobado que el generador SSOT lee el contrato y propaga: 150 / 45 / 105.
- `previewSplit(1000)` → 986 / 10 / 4, y la invariante de conservación sigue
  cerrando sin polvo.
