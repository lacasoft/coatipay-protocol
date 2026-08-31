# Política de seguridad

Este repositorio contiene los contratos que **mueven dinero real**. Si encuentras
una vulnerabilidad, queremos saberlo antes que nadie.

## Cómo reportar

**📧 security@coatipay.com**

Escríbenos en español o inglés, como te resulte natural. Incluye lo que tengas:
qué falla, cómo reproducirlo, y qué impacto le ves. Un reporte parcial es mejor
que ningún reporte.

- Acusamos recibo en **48 horas**.
- **Reconocimiento público** cuando el fix esté desplegado, y sitio en el hall
  of fame de este documento.
- **Recompensa en USDC** por hallazgos críticos, discrecional y acordada caso
  por caso, **cuando el treasury tenga flujo sostenido**. Somos early-stage y
  hoy no lo tiene: preferimos decírtelo antes de que inviertas tu tiempo, no
  después. Un programa formal con tabla de pagos llegará junto con la auditoría
  externa.
- Si prefieres permanecer anónimo, lo respetamos.

## Si el exploit está activo ahora mismo

Además de escribirnos, pon **`GUARDIAN-PAUSE`** en el asunto. Los contratos son
pausables y escalamos de inmediato al operador del guardian para detener el daño
mientras coordinamos la corrección.

## Divulgación responsable

Por favor **no publiques la vulnerabilidad** en Twitter/X, Discord, Telegram ni
foros hasta que esté corregida y desplegada. No es por ocultarla: mientras el
fallo siga vivo, publicarlo pone en riesgo fondos de terceros.

## Alcance

**Dentro:** los contratos de `contracts/src/` — `SettlementHub`, `NodeRegistry`,
`StakeManager` — y los tipos y constantes de `protocol/`.

**Fuera:** la infraestructura que opera CoatiPay (API, dashboard, nodos) no vive
en este repositorio. Si el fallo está ahí, escríbenos igual a la misma dirección.

## Desplegado hoy

Base Sepolia (testnet). Las direcciones y sus enlaces de verificación están en
[`contracts/deployments/sepolia.json`](contracts/deployments/sepolia.json), con
el código fuente verificado en Basescan.

> El código de los contratos **no se modifica por motivos de marca**. Cualquier
> cambio en la fuente —incluido un comentario— altera el hash de metadata y la
> fuente dejaría de reproducir el bytecode desplegado. La verificación
> reproducible vale más que la consistencia cosmética.
