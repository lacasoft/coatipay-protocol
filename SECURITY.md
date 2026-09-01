# Política de seguridad

Este repositorio contiene los contratos que **mueven dinero real**. Si encuentras
una vulnerabilidad, queremos saberlo antes que nadie.

## Cómo reportar

**📧 security@coatipay.com**

Escríbenos en español o inglés, como te resulte natural. Incluye lo que tengas:
qué falla, cómo reproducirlo, y qué impacto le ves. Un reporte parcial es mejor
que ningún reporte.

- Acusamos recibo en **48 horas**.
- **Reconocimiento público** cuando el fix esté desplegado, y sitio en el [hall of
  fame](#hall-of-fame) de este documento.
- **No ofrecemos recompensa económica.** No tenemos programa de bug bounty y no
  lo prometemos para más adelante. Lo decimos por delante para que decidas si te
  compensa mirar, en vez de que lo descubras después de invertir tu tiempo.
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

## Hall of fame

Quienes encontraron un fallo de seguridad y nos lo contaron antes que a nadie,
dándonos la oportunidad de corregirlo antes de que le costara dinero a alguien.

| Fecha | Hallazgo | Severidad | Reporta |
|---|---|---|---|
| 2026-08 | La firma ERC-3009 no estaba atada al intent: el destino del pago lo decidía un campo de calldata que elige el nodeit | Crítica | [ibnu76](https://github.com/ibnu76) |
| 2026-08 | El sistema de disputas no validaba nada y castigaba a las 48 h sin votación | Alta | [ibnu76](https://github.com/ibnu76) |

Ambos corregidos en
[ADR-004](audits/adr/004-auth-binding-y-retirada-de-disputas.md). El primero,
además, nos llevó a un tercer fallo de la misma clase que el reporte no cubría
y que por nuestra cuenta no habríamos buscado.

Ambos hallazgos llegaron con pruebas de concepto que funcionaban, y con la
severidad bien calibrada: F-2 se reportó como denegación de servicio y no como
robo, que es lo que era. Esa honestidad es la razón por la que nos tomamos el
resto en serio y fuimos a buscar más.
