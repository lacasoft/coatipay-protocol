# Architecture Decision Records (ADRs)

This directory holds the formal record of significant architectural decisions for
CoatiPay. Each record is dated and immutable: ADRs are superseded, never rewritten
(ADR-003 supersedes part of ADR-002). Because of that, the records below still use
**OpenRelay**, the project's original and internal name, throughout their text — the
decisions they describe are the ones behind the contracts in this repository. Each ADR captures **what** we decided, **why**, and **what alternatives we considered**.

ADRs are immutable: once Accepted, they are not edited. If a decision is reversed, a new ADR is created that supersedes the old one.

For the current fee values, consult ADR-005; older fee figures in ADR-001 through ADR-004 are historical.

## Index

| # | Title | Status | Date | Supersedes |
|---|---|---|---|---|
| [001](./001-settlement-contract.md) | Settlement Contract for trustless on-chain payment splitting | 🟢 Accepted | 2026-05-14 | — |
| [002](./002-fee-structure-and-gas-abstraction.md) | Fee structure recalibration + gas abstraction strategy | 🟢 Accepted | 2026-05-14 | Fee values superseded by ADR-005; gas abstraction decision retained |
| [003](./003-gas-abstraction-via-erc3009.md) | Gas abstraction via ERC-3009 | 🟢 Accepted | 2026-05-14 | ADR-002 §2.2; fee values superseded by ADR-005 |
| [004](./004-auth-binding-y-retirada-de-disputas.md) | Atadura de la autorización al intent, y retirada del sistema de disputas | 🟢 Aceptado | 2026-08-29 | ADR-001 §3.10; ADR-002 §2.1 (slashing); fee values superseded by ADR-005 |
| [005](./005-comision-al-1-5-por-ciento.md) | Comisión del protocolo del 1.0% al 1.5% | 🟢 Aceptado | 2026-08-31 | ADR-002 §2.1 (fee values) |
| [006](./006-firmas-del-pagador-y-despliegue-erc6492.md) | Verificar todas las firmas del pagador, y ejecutar solo el despliegue que la política permite | 🟢 Aceptado | 2026-09-26 | — (off-chain only; fixes the ERC-6492 path of ADR-003) |
| [007](./007-liquidaciones-leidas-de-la-cadena.md) | La API lee de la cadena qué se pagó; el nodeit no informa de nada | 🟢 Aceptado | 2026-09-27 | — (off-chain only; replaces the node-side event watcher of ADR-003) |
| [008](./008-stake-minimo-exigido-al-repartir-trabajo.md) | El stake mínimo se exige al repartir el trabajo, no en el contrato | 🟢 Aceptado | 2026-10-06 | — (off-chain only; no contract changes) |

## Status legend

- 🟡 **Proposed**: Under discussion. Subject to change.
- 🟢 **Accepted**: Decision made. Code follows this ADR.
- 🔴 **Rejected**: Considered but not adopted. Kept for institutional memory.
- ⚫ **Superseded**: Replaced by a newer ADR (linked).

## Why ADRs

Auditors, investors, and future contributors need to understand **why** the protocol is the way it is. Code shows **what**; ADRs show **the reasoning behind it**. This avoids:

- "Cargo-culting": copying patterns without understanding why
- "Chesterton's Fence": removing a constraint someone added for a now-forgotten reason
- "Audit waste": auditors asking "why did you do X?" when the answer is in code archaeology

## Language

ADR-001 to ADR-003 are written in English, with a brief Spanish executive summary
at the top. From ADR-004 on, records are written in Spanish, the project's
working language; the audit scope document summarizes their decisions in English
for auditors.
