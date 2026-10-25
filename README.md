# CoatiPay — protocolo y contratos

Pagos en USDC **sin custodia** y **sin gas para quien paga**, liquidados on-chain
en Base. Este repositorio contiene la parte abierta y verificable del sistema:
los contratos que mueven el dinero y los tipos que describen el protocolo.

**Apache-2.0** · sin token · sin preventa.

---

## 🚀 Estado actual

Desplegado en **Base Sepolia** (testnet), con código fuente **verificado en
Basescan**, guardas de dirección cero y los roles repartidos en wallets
separadas.

| Contrato | Dirección |
|---|---|
| `SettlementHub` | `PENDIENTE_HUB` |
| `NodeRegistry` | `PENDIENTE_REGISTRY` |
| `StakeManager` | `PENDIENTE_STAKE` |
| `IntentSignerGate` | `PENDIENTE_GATE` |

Es el diseño de [ADR-009](audits/adr/009-una-parte-que-falla-no-detiene-a-las-demas.md):
**una parte que falla no detiene a las demás**.

**Roles, en wallets separadas** — ninguna acumula poder sobre las demás:

| Rol | Wallet | Responsabilidad |
|---|---|---|
| Treasury | `0x05CD…8261` | Cobra el 30% de la comisión (**inmutable**) |
| Guardian | `0xbB51…7Ddf` | Pausa de emergencia y `minStake` con 7 días de aviso (rotable en dos pasos) |
| Admin del gate | `0xbB51…7Ddf` | El único que cambia o retira la clave que firma los registros |
| Clave del gate | `0xc6Ff…8cdB` | La API firma con ella cada registro de intent (rotable sin redesplegar) |
| Nodeit bootstrap | `0xf73e…5da4` | Deposita stake y opera el daemon |

`minStake` inicial: **40 USDC** en testnet (100 USDC en mainnet). El guardian
puede cambiarlo conforme la red madura, pero **solo con 7 días de aviso
on-chain** y nunca a cero: nadie se encuentra con el mínimo cambiado por
sorpresa.

**Fuente canónica de direcciones** (la que deben leer SDKs y paneles):
[`contracts/deployments/sepolia.json`](contracts/deployments/sepolia.json).

> 🔜 **Auditoría externa y despliegue a mainnet pendientes.** No lo uses con
> dinero real todavía.

---

## Qué es CoatiPay

- Un **protocolo de enrutamiento de pagos** con nodeits operados por la comunidad
- **SDKs compatibles con Stripe** para JavaScript, Python y PHP
- Soporte nativo para **x402** — micropagos para agentes de IA
- **USDC en Base** como capa de liquidación (Polygon y Solana en la hoja de ruta)
- Contratos para el registro de nodeits, el staking y la liquidación on-chain
- Documentación y soporte en **español e inglés**

## Qué no es CoatiPay

- **Un banco.** Los fondos van directo del pagador al comercio. CoatiPay nunca
  custodia dinero.
- **Una pasarela fiat.** No hay Visa, Mastercard ni transferencias. Convive con
  las herramientas que ya usas.
- **Un proyecto de token.** No existe un token CoatiPay. Los nodeits ganan USDC.
  Sin especulación.
- **Un reemplazo universal de Stripe.** Es una capa de enrutamiento USDC abierta;
  úsala junto a lo que ya tienes.

---

## Cómo funciona

```
El comercio integra el SDK
        │
        ▼
Se crea el PaymentIntent  →  queda en la cola de los nodeits
        │
        ▼
El pagador firma una autorización ERC-3009 (una firma, no una transacción:
        │                                    no necesita ETH para gas)
        ▼
El nodeit presenta la firma al SettlementHub, que paga al comercio en el acto
        │              y acredita las comisiones (el nodeit NUNCA custodia los fondos)
        ▼
La API lee el pago de la cadena y dispara el webhook
```

Los nodeits depositan stake en USDC para participar. Ese stake es su fianza y la
barrera contra identidades falsas: compromete capital propio, sale con un aviso
de 7 días y **nadie puede confiscarlo**. **Ningún comité decide quién entra** —
lo decide el protocolo.

---

## Comisión y reparto

**1.5% (150 bps)** sobre cada pago liquidado. El comercio recibe el **98.5%** en
la misma transacción del pago; el resto queda acreditado on-chain a quien le
toca, que lo cobra cuando quiere con `claim()`:

| Destino | Del pago total |
|---|---|
| **Comercio** | **98.5%** |
| Nodeit que liquida | 1.05% |
| Treasury del protocolo | 0.45% |

Son $15 por cada $1,000, frente a ~$29 de una pasarela de tarjeta. Sin alta, sin
cuota mensual, sin mínimos.

Si el emisor de USDC bloquea a un nodeit o a la tesorería, los pagos siguen: su
comisión espera acreditada hasta que se desbloquee.

Estos números viven **solo** en `SettlementHub.sol`; lo que ves en TypeScript se
genera desde ahí y el CI falla si se desincronizan.

---

## Empezar

**¿Eres comercio?** No clones nada: instala un SDK.

```bash
npm install @lacasoft/coatipay-sdk    # JavaScript / TypeScript
pip install coatipay-sdk              # Python
composer require lacasoft/coatipay-sdk # PHP
```

```js
import { CoatiPay } from '@lacasoft/coatipay-sdk'

const relay = new CoatiPay({ apiKey: process.env.COATIPAY_SECRET_KEY })

const intent = await relay.paymentIntents.create({
  amount: 10_000_000,        // 10.00 USDC (6 decimales)
  currency: 'usdc',
  chain: 'base',
  metadata: { order_id: 'order_123' },
})
```

Y el webhook como fuente de verdad:

```js
app.post('/webhooks/coatipay', (req, res) => {
  const event = relay.webhooks.verify(
    req.body,                      // body CRUDO
    req.headers['x-signature'],
    process.env.COATIPAY_WEBHOOK_SECRET,
  )
  if (event.type === 'payment_intent.settled') fulfillOrder(event.data.metadata.order_id)
  res.sendStatus(200)
})
```

**¿Vas a auditar o extender el protocolo?**

```bash
git clone --recurse-submodules https://github.com/lacasoft/coatipay-protocol
cd coatipay-protocol/contracts && forge build && forge test
```

Las dependencias de Foundry son submódulos — de ahí el `--recurse-submodules`.

---

## x402 — pagos para agentes de IA

```js
app.addHook('preHandler', relay.x402.middleware({
  price: 300_000,   // 0.30 USDC por request
  currency: 'usdc',
  chain: 'base',
}))
```

Cualquier cliente que hable x402 —incluidos agentes de IA vía MCP— puede pagar y
consumir tu endpoint de forma autónoma. Las pasarelas tradicionales no sostienen
pagos tan pequeños: su comisión mínima los hace inviables.

---

## Correr un nodeit

El **registro es sin permisos**: `NodeRegistry.register()` no tiene whitelist ni
aprobación, y cualquier dirección con stake suficiente puede registrarse. El
registro, el stake y las reglas de liquidación viven en contratos públicos y
auditables, en este mismo repositorio.

**El daemon es público:**
[`coatipay-node`](https://github.com/lacasoft/coatipay-node). Se autentica
firmando cada llamada con la llave del operador —la misma con la que te
registraste—, y el API recupera esa dirección y la comprueba contra el registro.
No hay secreto que pedir ni alta que aprobar: tu identidad se demuestra, no se
declara.

Para que el API te dé trabajo necesitas estar **registrado y activo** y mantener
el **stake por encima del mínimo**. Si retiras el stake dejas de recibir
liquidaciones aunque sigas registrado: el stake es la credencial que te habilita.

Quien opere un nodeit gana el **70% de la comisión** (1.05% de cada pago que
enruta), en USDC y on-chain.

---

## Terminología

El protocolo define una red de **nodos**. **nodeit** es la implementación de
referencia. Cualquier daemon compatible puede registrarse como nodo; el nuestro
se llama nodeit. En este README digo "nodeit" porque hablo de la implementación
concreta; en [`PROTOCOL.md`](PROTOCOL.md) e
[`INFRASTRUCTURE.md`](INFRASTRUCTURE.md) digo "nodo" porque describen el concepto
abstracto.

---

## Documentación

| Documento | Qué cubre |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | Especificación del protocolo |
| [`INFRASTRUCTURE.md`](INFRASTRUCTURE.md) | Arquitectura y profundización técnica |
| [`WHITEPAPER.md`](WHITEPAPER.md) | Visión, economía y posicionamiento |
| [`ROADMAP.md`](ROADMAP.md) | Hoja de ruta por fases |
| [`COMPLIANCE.md`](COMPLIANCE.md) | Posición regulatoria y no-custodia |
| [`docs/en/`](docs/en) | English versions |

## Repositorios

**Para integrar pagos** — instala un SDK, no clones nada:

- [JavaScript / TypeScript](https://github.com/lacasoft/coatipay-js-sdk)
- [Python](https://github.com/lacasoft/coatipay-python-sdk)
- [PHP](https://github.com/lacasoft/coatipay-php-sdk)

**Para operar infraestructura:**

- [`coatipay-node`](https://github.com/lacasoft/coatipay-node) — el daemon del nodeit

## Mercados iniciales

**México** es el mercado de lanzamiento — transición digital activa y demanda
real de alternativas a las comisiones tradicionales. **España** es el segundo,
como puente natural del corredor Europa–LATAM. Argentina, Colombia y Chile en
Fase 2.

## Contribuir y seguridad

Lee [CONTRIBUTING.md](CONTRIBUTING.md). Para vulnerabilidades **no abras un
issue**: escribe a **security@coatipay.com** ([SECURITY.md](SECURITY.md)).

Issues y PRs en **español o inglés**, como prefieras.

## Licencia

Apache-2.0 — ver [LICENSE](LICENSE).
