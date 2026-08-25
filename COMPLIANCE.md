# CoatiPay — Compliance & Regulatory Positioning

*Este documento explica la posición de CoatiPay bajo los marcos regulatorios emergentes para pagos cripto, incluyendo el GENIUS Act de EE.UU. y regulaciones equivalentes en LATAM y Europa. Está dirigido a merchants, operadores de nodos, y equipos legales que evalúan la integración.*

---

## Lo que es CoatiPay bajo la ley

CoatiPay es un **protocolo de enrutamiento de pagos**. No es:

- Un emisor de stablecoins
- Un custodio de activos digitales
- Un exchange o broker
- Un proveedor de servicios de pago con licencia bancaria
- Una wallet o servicio de custodia

Esta distinción es fundamental para entender qué regulaciones aplican y a quién.

---

## GENIUS Act (EE.UU.) — Vigencia: Enero 2027

### Qué regula

El GENIUS Act (Guiding and Establishing National Innovation for U.S. Stablecoins Act) regula a los **emisores de stablecoins de pago**. Define como emisor a cualquier entidad que emita o redima stablecoins directamente al público.

Los requerimientos principales son:
- Reservas 1:1 en activos líquidos
- Programas de antilavado de dinero (AML)
- Reporte de transacciones sospechosas (SAR)
- Supervisión federal o estatal según el tamaño del emisor

### Cómo afecta a CoatiPay

**CoatiPay no es un emisor de stablecoins.** No emite, no redime, no custodia USDC en ningún momento del proceso de pago. Los fondos fluyen directamente del pagador al wallet del merchant — CoatiPay facilita el descubrimiento y la confirmación de esa transferencia, pero nunca los toca.

**Impacto directo del GENIUS Act sobre CoatiPay: ninguno.**

**Impacto indirecto:** El GENIUS Act aplica a Circle (emisor de USDC). Si Circle implementa nuevos controles de compliance en sus contratos de USDC en Base como resultado del GENIUS Act, esos controles afectarán todas las transacciones USDC — incluyendo las que pasan por CoatiPay. CoatiPay no puede controlar eso y no pretende hacerlo.

### Quién tiene responsabilidades de compliance

| Actor | Responsabilidad |
|---|---|
| **Circle (emisor de USDC)** | Cumplimiento del GENIUS Act como emisor |
| **Merchant** | KYC/AML de sus clientes según la ley de su jurisdicción |
| **Node operator** | Ninguna obligación directa bajo el GENIUS Act |
| **CoatiPay Protocol** | Ninguna — no es emisor ni custodio |

---

## Regulación en México

### Marco actual

La Ley para Regular las Instituciones de Tecnología Financiera (Ley Fintech, 2018) regula a las Instituciones de Tecnología Financiera (ITF) — plataformas de financiamiento colectivo y instituciones de fondos de pago electrónico.

CoatiPay no opera como ITF. No recibe fondos del público, no ofrece rendimientos, no gestiona wallets de usuarios. Es un protocolo técnico de enrutamiento.

### Digitalización obligatoria 2026

El mandato de pagos digitales para gasolineras y casetas (2026) no especifica qué tecnología deben usar los merchants. Crea la demanda — no regula al proveedor de la infraestructura técnica.

### Recomendación para merchants en México

Un merchant mexicano que integra CoatiPay para recibir USDC debe consultar si su actividad requiere registro como ITF. En la mayoría de los casos comerciales (recibir pagos por bienes y servicios), no aplica la regulación de ITF. Un abogado local debe confirmar esto según el giro y volumen específico.

---

## Regulación en la Unión Europea (MiCA)

### Qué es MiCA

El Reglamento sobre Mercados de Criptoactivos (MiCA) aplica en toda la Unión Europea desde junio 2024. Regula emisores de tokens de dinero electrónico (como USDC), proveedores de servicios de criptoactivos (CASPs), y plataformas de trading.

### Cómo afecta a CoatiPay

CoatiPay no es un CASP bajo la definición de MiCA. No ofrece custodia, no opera un exchange, no presta servicios de asesoría en criptoactivos, no gestiona órdenes.

Un operador de nodo en España o Alemania que enruta transacciones y gana fees en USDC podría ser analizado como proveedor de servicios de transferencia — este análisis depende del volumen, la jurisdicción específica, y la estructura del operador. Se recomienda consultoría legal local para operadores de nodo en la UE con volumen significativo.

---

## x402 y pagos entre agentes de IA

### El contexto regulatorio

El protocolo x402 permite que agentes de IA autónomos realicen micropagos directamente entre sí o hacia APIs de merchants. Este es un área regulatoria en evolución — ninguna jurisdicción tiene un marco específico para pagos M2M (machine-to-machine) en stablecoins.

### La posición de CoatiPay

CoatiPay provee la infraestructura técnica de settlement para transacciones x402. No determina si un agente específico puede o no puede realizar pagos — esa responsabilidad recae en el operador del agente y el merchant que decide proteger sus APIs con x402.

Lo que CoatiPay garantiza técnicamente es que los pagos x402 son verificables on-chain, tienen protección replay, y siguen las mismas reglas de routing que cualquier PaymentIntent.

---

## Preguntas frecuentes de equipos legales

**¿CoatiPay necesita una licencia de transferencia de dinero (MTL) en EE.UU.?**

No. CoatiPay no transfiere dinero — enruta información sobre transferencias que ocurren directamente on-chain entre el pagador y el merchant. El análisis es análogo al de un protocolo como Uniswap o un indexer de blockchain, no al de un servicio de transferencia de dinero tradicional. Recomendamos la consulta de un abogado especializado en crypto-fintech para jurisdicciones específicas.

**¿Los operadores de nodo están sujetos a regulación AML?**

Un operador de nodo en CoatiPay observa transacciones on-chain y cobra fees por ese servicio. No custodia fondos de terceros ni opera como intermediario financiero en el sentido tradicional. La clasificación regulatoria varía por jurisdicción — en EE.UU., la guía del FinCEN sobre "mineros" y "validadores" de blockchain es la referencia más cercana disponible actualmente.

**¿Puede el gobierno congelar transacciones que pasan por CoatiPay?**

CoatiPay no tiene la capacidad técnica de congelar ni revertir fondos — los contratos son no actualizables y nadie puede mover el dinero de un pago. Los contratos **sí** incluyen una pausa de emergencia limitada (un `Pausable` controlado por un multisig 3-de-5) que solo puede detener operaciones *nuevas* (registro de nodos, apertura de disputas) ante un exploit activo; no congela pagos en vuelo ni toca fondos de nadie. Lo que sí puede ocurrir es que Circle (emisor de USDC) implemente blacklisting de addresses en el contrato de USDC. Eso es un control del emisor, no del protocolo de routing.

**¿CoatiPay recopila datos personales de pagadores o merchants?**

El protocolo en sí no recopila datos personales. La API puede almacenar metadata de transacciones que el merchant mismo proporciona. El merchant es el responsable del tratamiento de datos personales bajo GDPR, LGPD, o la ley aplicable en su jurisdicción.

---

## Posición ante el GENIUS Act — Declaración formal

CoatiPay Protocol no es un emisor de stablecoins de pago según la definición del GENIUS Act ni de ningún marco regulatorio equivalente conocido a la fecha de este documento. No emite, no redime, no custodia stablecoins en ningún momento del proceso de enrutamiento de pagos.

CoatiPay es software de código abierto que facilita la comunicación entre pagadores, merchants, y operadores de nodos que confirman transacciones en redes blockchain públicas. La responsabilidad del cumplimiento regulatorio pertenece a:

1. Los emisores de stablecoins utilizados (Circle para USDC)
2. Los merchants que integran el SDK para recibir pagos
3. Los operadores de nodo según las leyes de su jurisdicción

Esta declaración no constituye asesoría legal. Consulta a un abogado especializado en regulación de activos digitales para evaluar tu situación específica.

---

## Cambios regulatorios a monitorear

| Evento | Fecha | Impacto potencial en CoatiPay |
|---|---|---|
| GENIUS Act enforcement | Enero 2027 | Indirecto — afecta a Circle como emisor de USDC |
| MiCA — plena aplicación UE | Junio 2024 (vigente) | Monitorear clasificación de operadores de nodo en UE |
| Regulación stablecoins México | Por definir | Bajo — CoatiPay no es emisor |
| Marco AML para DeFi (FATF) | En desarrollo | Monitorear guías sobre "unhosted wallets" |
| Regulación agentes IA + pagos | Sin marco específico | Área a monitorear — x402 es nuevo |

---

*Este documento se actualiza cuando hay cambios regulatorios materiales que afecten el protocolo. Las actualizaciones siguen el proceso RFC estándar del proyecto.*

*Última actualización: Abril 2026*

*Este documento no constituye asesoría legal. CoatiPay Foundation recomienda consultar a abogados especializados en regulación de activos digitales para evaluar situaciones específicas.*
