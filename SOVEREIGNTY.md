# Por qué construimos CoatiPay

*Este documento no es técnico. Es la razón de fondo por la que vale la pena construir infraestructura de pagos de propiedad comunitaria para el mundo hispanohablante, y por qué ahora es el momento.*

---

## La motivación

América Latina y España están digitalizando sus pagos a una velocidad enorme. México avanza hacia pagos digitales obligatorios en gasolineras y casetas. Colombia, Chile, Argentina y Brasil tienen políticas activas para reducir el uso de efectivo. España ya tiene una base sólida de pagos electrónicos y busca integrar cripto al día a día comercial.

La pregunta no es si va a haber pagos digitales en la región. Ya los hay, y cada vez son más. La pregunta es **sobre qué infraestructura van a correr**.

Hoy las opciones son pocas, caras y cerradas. CoatiPay existe para ofrecer una opción más: abierta, barata y comunitaria.

---

## El problema práctico

Si eres dueño de un comercio pequeño o mediano en LATAM, tienes básicamente estas alternativas:

- **Stripe:** funciona bien, pero cobra ~2.9% + $0.30 por transacción. Para un comercio que mueve $50,000/mes, eso son ~$1,480 mensuales en comisiones. No llega a todos los países de la región con la misma calidad.
- **Mercado Pago, Clip, Conekta, OpenPay:** mejor cobertura local, pero comisiones similares y ecosistemas cerrados. Cambiar de proveedor implica rehacer integración.
- **BTCPay Server u otras soluciones cripto auto-alojadas:** excelentes para BTC, pero sin red de nodeits, sin SDKs modernos y con una experiencia de desarrollo más pesada.

No existe una opción que combine todo esto a la vez:

- Código abierto
- Comisiones muy por debajo de un procesador tradicional
- Tan fácil de integrar como Stripe
- Con una red comunitaria de nodeits
- Que trate al español como ciudadano de primera clase
- Con soporte nativo para pagos máquina→máquina (x402) para agentes de IA

Esa es la opción que queremos construir.

---

## ¿Por qué el mundo hispanohablante?

Porque es nuestra región, porque hablamos el idioma, y porque hay demanda real.

LATAM y España suman más de 600 millones de hispanohablantes. La gran mayoría de la documentación técnica de cripto, SDKs, tutoriales y soporte está en inglés. Los desarrolladores aprenden inglés por necesidad, pero eso introduce una fricción que los mercados anglosajones no tienen.

CoatiPay está pensado para que un desarrollador en Guadalajara, Medellín, Buenos Aires, Madrid o Santiago pueda integrar pagos sin tener que adaptarse a un ecosistema que nunca fue diseñado pensando en él. Documentación en español. SDKs probados con comercios locales. Comunidad que discute en español.

No es nacionalismo — es reconocer que las herramientas son mejores cuando se construyen cerca de los usuarios que las van a usar.

---

## Qué es CoatiPay, en concreto

CoatiPay es una capa de enrutamiento de pagos en USDC sobre Base L2. No custodiamos fondos. No somos un banco. No somos un gateway de fiat.

Tiene tres piezas:

1. **Contratos on-chain** que llevan el registro de nodeits, stake y disputas.
2. **Nodeits comunitarios** que cualquiera puede correr en un VPS de ~$20/mes y ganan USDC por enrutar pagos.
3. **SDKs y API** que dan a los desarrolladores una experiencia tipo Stripe: payment intents, webhooks, retries, idempotencia.

Es análogo a lo que pasó con Linux frente al software propietario, o con WordPress frente a las plataformas cerradas de blogging: una base abierta sobre la que cualquiera puede construir, sin pedirle permiso a nadie.

---

## ¿Por qué un nodeit comunitario?

Porque la red es más robusta, más barata y más confiable cuando la operan muchas manos.

Un desarrollador en Monterrey corriendo un nodeit en un VPS de $20/mes está contribuyendo a una red que ninguna entidad sola controla. Gana USDC como compensación por trabajo real: mantener la infraestructura arriba, confirmar transacciones, responder rápido. Su stake es piel en el juego. Su reputación se calcula públicamente on-chain.

Esto tiene consecuencias prácticas:

- Un operador de nodeit no puede ser presionado por una entidad externa para bloquear a un comercio sin que el resto de la red lo note.
- El algoritmo de routing no se puede modificar para favorecer a ciertos comercios sin un RFC público y consenso comunitario.
- Los contratos core no son upgradeables por una sola persona u organización.

No es ideología — es diseño de infraestructura.

---

## El caso x402: pagos para agentes de IA

El estándar HTTP 402 (Payment Required) está ganando tracción como la forma natural de que los agentes de IA paguen por APIs, datos y cómputo. Micropagos de $0.001, sin intervención humana, máquina a máquina.

Stripe no puede hacer esto bien: el fee mínimo por transacción hace inviable cobrar un milésimo de dólar. Las plataformas tradicionales tampoco — fueron diseñadas para humanos firmando pagos, no para agentes autónomos.

CoatiPay trata x402 como ciudadano de primera clase en el diseño del protocolo. Un agente de IA puede pagar por acceso a una API sin fricción, y el comercio recibe USDC casi instantáneo. Este es un mercado que va a crecer mucho en los próximos años, y queremos que el mundo hispanohablante tenga la infraestructura lista.

---

## Comparación honesta de costos

Tomemos un comercio que procesa $50,000 al mes en pagos digitales.

Un procesador tradicional como Stripe cobra ~2.9% + $0.30 por transacción: sobre
$50,000 mensuales son ~$1,480 al mes, cerca de $17,760 al año.

La comisión del protocolo es una **constante pública del contrato desplegado**, no
una tarifa que anunciamos y podemos cambiar por debajo de la mesa: está en
[`SettlementHub.sol`](contracts/src/SettlementHub.sol) y cualquiera la verifica
on-chain antes de integrarse. Hoy es una fracción de lo que cobra un procesador
tradicional, y el reparto entre nodeit y treasury también está fijado ahí.

Lo estructural no es la cifra concreta de un mes: es que el capital se queda en la
economía local en lugar de salir como comisión, multiplicado por los miles de
comercios que están migrando a digital.

---

## Lo que no somos

Para ser claros sobre los límites:

- **No somos un reemplazo de Stripe para fiat.** Si necesitas procesar Visa y Mastercard, usa Stripe. CoatiPay es para pagos en cripto.
- **No somos un banco.** No guardamos tu dinero. No hacemos custodia.
- **No tenemos un token especulativo.** Los operadores ganan USDC, no tokens. Nunca va a haber ICO ni airdrop.
- **No procesamos KYC.** Eso es responsabilidad del comercio según la jurisdicción donde opere.

Queremos ser una pieza sólida y aburrida de infraestructura. Como el protocolo SMTP para email, o TCP/IP para internet. Algo que simplemente funciona y sobre lo que otros construyen.

---

## La responsabilidad que asumimos

Construir infraestructura de pagos implica una responsabilidad real. Código con bugs puede perder fondos de comercios. Un contrato con una vulnerabilidad es peor que una alternativa centralizada bien auditada.

Por eso:

- Los contratos core no son upgradeables. Cualquier cambio pasa por auditoría completa y un deploy nuevo.
- Antes de mainnet hacemos auditoría externa independiente. No negociable.
- La documentación de seguridad es pública. Los bounties para reportes de vulnerabilidades los paga el treasury.
- Todo el código es open source bajo Apache 2.0. Si algo falla, cualquiera puede verlo, auditarlo y proponer un fix.

La calidad técnica no es negociable. La velocidad tampoco. Las dos van juntas.

---

## Cómo participas

Si llegaste hasta aquí, probablemente te interesa participar de alguna forma. Hay varias:

- **Como desarrollador:** integra CoatiPay en un comercio real. El feedback de un usuario real vale más que mil issues de GitHub.
- **Como operador de nodeit:** corre un nodeit en un VPS. Ganas USDC y contribuyes a la descentralización de la red.
- **Como contribuidor:** código, documentación, traducciones, ejemplos. Todo suma.
- **Como comunicador:** escribe sobre CoatiPay en tu idioma, en tu comunidad local, en el contexto que conozcas mejor.

La infraestructura que no usa nadie no sirve de nada. La infraestructura que usa la gente adecuada cambia regiones enteras.

---

## La apuesta

La apuesta es que una comunidad de desarrolladores, operadores y comercios en el mundo hispanohablante puede construir, mantener y escalar infraestructura de pagos abierta, competitiva y mejor que las alternativas cerradas.

No es la única alternativa. No es la definitiva. Pero es una opción real, y creemos que vale la pena construirla.

El comercio en Oaxaca, el desarrollador en Bogotá, el operador de nodeit en Madrid — todos pueden ser participantes de una infraestructura que los sirve, en lugar de extraer valor de ellos.

Por eso existe CoatiPay.

---

*CoatiPay es código abierto bajo Apache License 2.0.*
*Contribuye en: github.com/lacasoft/coatipay-protocol*
*Corre un nodeit. Construye la alternativa.*
