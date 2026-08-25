# CoatiPay — protocolo y contratos

Pagos en USDC **sin custodia** y **sin gas para quien paga**, liquidados on-chain
en Base. Este repositorio contiene la parte abierta y verificable del sistema:
los contratos que mueven el dinero y los tipos compartidos que describen el
protocolo.

**Apache-2.0** · sin token · sin preventa.

## Qué hay aquí

| Carpeta | Qué es |
|---|---|
| [`contracts/`](contracts) | Los contratos en Solidity, con Foundry |
| [`protocol/`](protocol) | `@lacasoft/coatipay-protocol` — tipos y constantes compartidas |

Los dos viven juntos a propósito: las constantes económicas se **generan** desde
el contrato, y el CI falla si se desincronizan.

## Cómo funciona un pago

1. Quien paga firma una autorización **ERC-3009** (`receiveWithAuthorization`).
   Es una firma, no una transacción: **no necesita ETH para gas**.
2. Un **nodeit** recoge esa firma y la presenta al `SettlementHub`.
3. El contrato mueve el USDC y reparte en un solo paso: el comercio cobra, el
   nodeit gana su parte por el trabajo, y una fracción va a tesorería.

El dinero nunca pasa por una cuenta de CoatiPay. No hay nada que custodiar.

## El reparto

La comisión del protocolo es de **100 puntos base — el 1%** del pago:

| Destino | Del pago total |
|---|---|
| Comercio | **99%** |
| Nodeit que liquida | 0.70% |
| Tesorería | 0.30% |

Estos números viven **solo** en `SettlementHub.sol`. Lo que ves en TypeScript se
genera desde ahí.

## Los contratos

| Contrato | Para qué |
|---|---|
| `SettlementHub` | Liquida el pago y reparte en una transacción |
| `NodeRegistry` | Registro sin permisos de los nodeits |
| `StakeManager` | Custodia el stake que respalda a cada nodeit |
| `DisputeResolver` | Arbitraje 3-de-5 y penalización por mal comportamiento |

Desplegados y **verificados en Basescan** sobre Base Sepolia. Direcciones y
enlaces en [`contracts/deployments/sepolia.json`](contracts/deployments/sepolia.json).

> ⚠️ **Todavía en testnet y sin auditar.** No lo uses con dinero real hasta que
> haya auditoría externa publicada.

## Empezar

```bash
git clone --recurse-submodules https://github.com/lacasoft/coatipay-protocol
cd coatipay-protocol/contracts && forge build && forge test
```

Las dependencias de Foundry son submódulos de git — de ahí el
`--recurse-submodules`.

## SDKs

Para integrar pagos no necesitas este repositorio, sino un SDK:

- [JavaScript / TypeScript](https://github.com/lacasoft/coatipay-js-sdk)
- [Python](https://github.com/lacasoft/coatipay-python-sdk)
- [PHP](https://github.com/lacasoft/coatipay-php-sdk)

## Contribuir y seguridad

Lee [CONTRIBUTING.md](CONTRIBUTING.md). Para vulnerabilidades **no abras un
issue**: escribe a **security@coatipay.com** ([SECURITY.md](SECURITY.md)).

Issues y PRs en **español o inglés**, como prefieras.
