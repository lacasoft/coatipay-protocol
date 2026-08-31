# Hoja de Ruta de CoatiPay

*De testnet a red comunitaria con tracción real. Construido por la comunidad, al ritmo de la comunidad.*

> **Actualización (2026-04-18):** Phase 1 hito completado — deploy en Base Sepolia live con contratos verificados. Ver `packages/contracts/deployments/sepolia.json`.

---

## Por qué existe esta hoja de ruta

América Latina está viviendo una transición acelerada hacia los pagos digitales. México, Colombia, Chile, Argentina y Brasil tienen políticas activas para reducir el uso de efectivo. Esto abre una ventana única para construir infraestructura abierta antes de que los estándares se consoliden alrededor de opciones cerradas.

Las plataformas existentes —Stripe, Mercado Pago, Clip, Conekta— funcionan, pero cobran comisiones que hacen inviable a los comercios de margen pequeño y dejan fuera a quienes no tienen acceso bancario. No existe una opción que sea código abierto, con comisiones casi cero, fácil de integrar y con una red comunitaria de nodeits que hable español como ciudadano de primera clase.

Esa es la oportunidad que persigue CoatiPay. La ventana para construir infraestructura de propiedad comunitaria antes de que los estándares de mercado se vuelvan el default no se mide en años, se mide en meses.

---

## Principios rectores

**LATAM primero.** México es el mercado de lanzamiento. España es el segundo mercado. El resto de LATAM sigue. El problema se siente con más fuerza donde Stripe cobra más caro, llega peor, y donde la transición de efectivo a digital ocurre con más velocidad.

**Complementarios, no sustitutos.** Cuando un banco mexicano quiera ofrecer pagos en USDC a sus clientes, va a necesitar una capa de enrutamiento. CoatiPay puede ser esa capa. No estamos compitiendo contra la adopción institucional de cripto —queremos que se integre sobre infraestructura abierta, no sobre infraestructura cerrada.

**Velocidad sobre perfección.** El mercado se está definiendo ahora. Un v1 funcionando en manos de comercios reales en Ciudad de México vale más que un v2 perfecto en un repositorio de GitHub.

**La comunidad es el diferenciador.** La única ventaja competitiva durable frente a alternativas cerradas es una comunidad de operadores de nodeit, contribuidores y comercios que ninguna entidad controla. Cada decisión en esta hoja de ruta debe priorizar el crecimiento de esa comunidad.

---

## Fase 1 — Fundación

**Objetivo:** Tener el protocolo deployado, funcional, auditado externamente y desplegado en mainnet. Phase 1 cierra cuando CoatiPay puede recibir comercios reales — no antes.

> **Actualización estratégica (2026-05-09) — Luis Campos (LACA-SOFT):**
>
> El plan original de Phase 1 incluía "Primer comercio en producción" como hito de cierre. Fue mi error de framing. **Ningún comercio real va a integrar un sistema de pagos sobre testnet** — las transacciones de Sepolia son juguetes para developers, no flujo de caja para una tienda. Asumí que la tracción comercial podía suceder pre-mainnet y eso no es realista.
>
> La secuencia correcta es:
>
> ```
> Capital → Auditoría externa → Mainnet deploy → Primer comercio
> ```
>
> Mainnet sin auditoría es irresponsable. Comercios sin mainnet es ficción. Por eso "primer comercio" se mueve a Phase 2 — entra en el momento en que mainnet está deployable y los fondos del comercio están en juego de verdad. Phase 1 ahora cierra con la auditoría externa contratada/completada y el deploy a Base mainnet ejecutado.

### Hitos Técnicos

- [x] Contratos inteligentes: `NodeRegistry.sol`, `StakeManager.sol`, `SettlementHub.sol` (desplegado)
- [x] Suite de tests Foundry: 147 tests (131 unitarios + 16 de invariantes/fuzz), todos en verde, en los contratos desplegados
- [x] Script de deploy: `Deploy.s.sol` listo para Base Sepolia
- [x] Daemon del nodeit: API HTTP con Fastify, rutas estructuradas
- [x] API REST: payment intents, webhooks, rutas x402 estructuradas
- [x] SDK JS: `@lacasoft/coatipay-sdk` con payment intents, webhooks, middleware x402
- [x] CI con GitHub Actions: typecheck + test + build + Foundry
- [x] **Deploy de contratos a Base Sepolia** — completado 2026-04-18 (ver `packages/contracts/deployments/sepolia.json`)
- [x] Persistencia en PostgreSQL en la API (`packages/api/src/lib/db.ts` + `repository.ts`)
- [x] Firma HMAC en el daemon del nodeit (`packages/node/src/lib/hmac.ts`, ventana 60s)
- [x] Settlement gasless ERC-3009: el payer firma una autorización `ReceiveWithAuthorization` y `SettlementHub.sol` jala el USDC y lo splittea atómicamente on-chain (99% comercio / 0.7% nodeit / 0.3% treasury)
- [x] Verificación on-chain de pagos x402 + protección contra replay (atomic `SET NX` en Redis + tx_hash en DB)
- [x] Entrega de webhooks con cola de reintentos en Redis
- _Nota:_ "Motor de routing leyendo nodeits desde `NodeRegistry.sol` via viem" se movió a Fase 2 — con un solo nodeit registrado el descubrimiento on-chain da el mismo resultado que el fallback de `BOOTSTRAP_NODE_ENDPOINT`. Ver Fase 2 > Hitos Técnicos.

### Hitos de Mercado

- [x] Primer bootstrap nodeit registrado on-chain y operativo en producción — operator [`0xf73e...5da4`](https://sepolia.basescan.org/address/0xf73e2E5a4493d8a4C28e6f88c14a396C82395da4) separado del deployer, 40 USDC stakeados sirviendo tráfico real — re-registro 2026-05-09 tras redeploy de tanda C, tx [`0x6ffe...5ef6`](https://sepolia.basescan.org/tx/0x6ffe0c08deb2649813cf46b63bf5089b2d486061eb7de87ea0a9b78372635ef6).
- [ ] Anuncio público de testnet en comunidades de desarrolladores hispanohablantes (objetivo: atraer auditores y devs, NO comercios — ver nota estratégica arriba)
- [x] Repositorio público en GitHub bajo `lacasoft` ([github.com/lacasoft/coatipay-protocol](https://github.com/lacasoft/coatipay-protocol))

### Hitos de Mainnet (cierre de Fase 1)

- [ ] Capital recaudado para auditoría externa de smart contracts
  - Estimado de costo: $20-50k USD (firmas como Spearbit/Cantina/OpenZeppelin) o $5-15k (auditor independiente)
  - Vías a explorar: grants del ecosistema Base, RetroPGF de Optimism, ronda angel pequeña, autofunding
- [ ] Auditoría externa contratada — `NodeRegistry.sol`, `StakeManager.sol`, `SettlementHub.sol`, `Pausable.sol` (~990 LOC Solidity, 147 tests Foundry)
- [ ] Findings de la auditoría corregidos y verificados con re-audit
- [ ] Deploy a **Base mainnet** con `minStake = 100 USDC` (piso anti-Sybil documentado en el whitepaper)
- [ ] Bootstrap nodeit operativo en mainnet (mismo daemon, contratos mainnet)
- [ ] `packages/contracts/deployments/mainnet.json` publicado con direcciones canónicas + reporte de auditoría enlazado

### Hitos de Comunidad

- [ ] Primer PR externo mergeado
- [ ] Documentación para operadores de nodeit completa en español e inglés

---

## Fase 2 — Tracción real en mainnet

**Objetivo:** Primer comercio real procesando pagos USDC en mainnet. Registro de nodeits permissionless abierto a cualquiera. Primeros nodeits comunitarios en México y España.

> **Cambio (2026-05-09):** "Primer comercio piloto" se movió a esta fase desde Fase 1. Razón: pre-mainnet (Phase 1) no tiene valor económico real para un comercio — testnet USDC es de juguete. Solo cuando mainnet está vivo y auditado tiene sentido onboardear al primer merchant de producción. Esta fase abre cuando Phase 1 cierra (mainnet deployado).

### Hitos Técnicos

- [ ] Registro permissionless de nodeits via `NodeRegistry.sol` en Base mainnet
- [ ] Motor de routing completo: descubrimiento de nodeits on-chain, cache de score, racing paralelo
- [ ] Sistema de reputación de nodeits: score on-chain visible via `/v1/nodes`
- [x] SDK Python: `coatipay-sdk` publicado en PyPI
- [ ] SDK PHP: `lacasoft/coatipay-sdk` en Packagist
- [ ] Dashboard de comercio: Next.js + shadcn/ui
- [ ] Plugin de WooCommerce (crítico para la adopción de comercios mexicanos)

### Hitos de Mercado

- [ ] **Primer comercio piloto en mainnet** (México) — primera vez que CoatiPay procesa USDC real para una venta real. Ítem que originalmente estaba en Fase 1 antes del reframe del 2026-05-09.
- [ ] Primer nodeit comunitario en México (operador ajeno al equipo)
- [ ] Primer nodeit comunitario en España
- [ ] Primera tienda WooCommerce usando CoatiPay en producción

### Hitos de Comunidad

- [ ] Primer bounty de contribuidor pagado desde el treasury
- [ ] 10+ contribuidores externos
- [ ] Cadencia de llamadas comunitarias establecida (mensuales, en español)
- [ ] Guía para operadores de nodeit traducida: español, inglés, portugués

---

## Fase 3 — Ecosistema

**Objetivo:** Multi-chain. SDK Go para agentes de IA. Capa de compatibilidad para integradores grandes. Treasury autosustentable.

### Hitos Técnicos

- [ ] Soporte para USDC en Polygon
- [ ] Soporte para USDC en Solana
- [ ] SDK Go: `github.com/lacasoft/coatipay-go-sdk`
  - Crítico para infraestructura de agentes de IA (MCP, agentes autónomos)
  - Este es el consumidor principal de x402 en 2026+
- [ ] **Capa de compatibilidad para integradores grandes**
  - CoatiPay como capa de enrutamiento para productos institucionales
  - API documentada para que bancos y gestores de activos integren
  - CoatiPay no hace custodia ni KYC — la institución integradora se encarga de eso
- [ ] Dashboard público del treasury
  - Acumulación de fees visible en tiempo real para cualquiera
  - Asignación de bounties transparente y on-chain
- [ ] La red deja de depender de los bootstrap nodeits del equipo core
  - Los nodeits comunitarios pueden manejar todo el routing por sí solos
  - El equipo core sigue operando nodeits y participando en el protocolo; sus bootstrap nodeits dejan de ser un punto único de fallo

### Hitos de Mercado

- [ ] 10+ nodeits comunitarios activos en Base mainnet
- [ ] 3+ países de LATAM con comercios en producción
- [ ] Primer socio integrador grande usando CoatiPay como capa de enrutamiento
- [ ] v1.0 declarado (ver criterios abajo)

### Hitos de Comunidad

- [ ] Primera votación de gobernanza sobre cambio al protocolo
- [ ] 50+ contribuidores en todos los paquetes
- [ ] Nodeits comunitarios dedicados en MX, ES, AR, CO
- [ ] Primera charla sobre CoatiPay en una conferencia de desarrolladores en español

---

## Criterios para declarar v1.0

La versión 1.0 se declarará cuando las tres condiciones se cumplan simultáneamente:

1. Contratos inteligentes auditados por una firma independiente y desplegados en Base mainnet
2. Al menos 10 nodeits comunitarios independientes activos en la red
3. SDK usado en al menos un deployment de comercio en producción

Estos criterios son públicos, verificables y no negociables. No hay inflación de versiones.

---

## Lo que no está en esta hoja de ruta

**Gateway de fiat.** Stripe procesa Visa y Mastercard porque tiene licencias bancarias en 50 países. CoatiPay nunca va a tener eso — y no lo necesita. Los comercios que necesiten fiat deberían usar Stripe para fiat y CoatiPay para cripto. Son complementarios, no competidores.

**Un token del protocolo.** Nunca va a existir un token RELAY. Los operadores de nodeit ganan USDC. Los contribuidores ganan reputación y voz. Introducir un token especulativo corrompería la estructura de incentivos y atraería a la comunidad equivocada.

**Upgradeabilidad en los contratos core.** Los contratos core son no-upgradeable por diseño. Cualquier cambio al protocolo que requiera modificar contratos pasa por un ciclo completo de auditoría y un deploy nuevo — no por un upgrade. Esto es una característica, no una limitación.

**Capa de cumplimiento KYC/AML.** CoatiPay no procesa identidad. Esa es responsabilidad del comercio según la jurisdicción donde opere. CoatiPay provee el enrutamiento de pagos; el cumplimiento regulatorio queda aguas arriba.

---

## El sentido de urgencia

La ventana para construir alternativas comunitarias es real y finita. Cada mes que CoatiPay no tenga una red de nodeits funcionando y al menos un comercio en producción es un mes en el que las opciones cerradas consolidan su ventaja.

La comunidad tiene la ventaja técnica: código abierto, comisiones casi cero, sin gatekeepers. La única manera de convertir esa ventaja técnica en ventaja de adopción es moviéndonos rápido.

---

*Esta hoja de ruta es un documento vivo. Los cambios se proponen via issues de GitHub etiquetados como `roadmap`. Los cambios aprobados se mergean con un bump de versión y una entrada fechada en el changelog.*

*Última actualización: Abril 2026*
