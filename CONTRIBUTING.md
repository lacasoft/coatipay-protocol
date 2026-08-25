# Contribuir

Gracias por querer aportar. Este repositorio tiene dos partes: los **contratos**
en Solidity (`contracts/`) y el **paquete de tipos y constantes** en TypeScript
(`protocol/`).

Escribe en **español o inglés**, lo que te resulte natural. Ambos idiomas son
bienvenidos en issues y pull requests.

## Poner en marcha

Los contratos usan [Foundry](https://book.getfoundry.sh/) y sus dependencias son
submódulos de git, así que clona con ellos:

```bash
git clone --recurse-submodules https://github.com/lacasoft/coatipay-protocol
cd coatipay-protocol
```

Si ya lo clonaste sin submódulos: `git submodule update --init --recursive`.

```bash
# Contratos
cd contracts
forge build
forge test

# Paquete TypeScript
cd protocol
npm install
npm run build
npm run typecheck
```

## La regla que más importa

**Las constantes económicas viven SOLO en `contracts/src/SettlementHub.sol`.**

El archivo `protocol/src/fee-constants.generated.ts` se genera desde ahí y **no
se edita a mano**. Si cambias un valor en el contrato, regenera:

```bash
cd protocol && npm run generate:fee-constants
```

El CI corre `npm run check:fee-constants` y falla si los dos lados no coinciden.
Es a propósito: dos fuentes de verdad para un porcentaje de dinero es como se
pierde dinero.

## Antes de abrir el PR

```bash
cd contracts && forge test && forge fmt --check
cd protocol  && npm run typecheck && npm run build
```

Para cambios en contratos, incluye tests que cubran el caso que arreglas o
añades. Si tocas una invariante, di explícitamente cuál y por qué sigue
sosteniéndose.

## Sobre modificar los contratos desplegados

Los contratos en Base Sepolia están **verificados en Basescan**. Cambiar la
fuente —incluso un comentario— altera el hash de metadata y rompe la
correspondencia con el bytecode desplegado. Los PR que solo reformatean
comentarios en contratos ya desplegados no se aceptan.

## Seguridad

¿Encontraste una vulnerabilidad? **No abras un issue.** Escribe a
**security@coatipay.com** — ver [SECURITY.md](SECURITY.md).
