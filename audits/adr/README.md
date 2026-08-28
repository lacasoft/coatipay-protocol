# Architecture Decision Records (ADRs)

This directory holds the formal record of significant architectural decisions for
CoatiPay. Each record is dated and immutable: ADRs are superseded, never rewritten
(ADR-003 supersedes part of ADR-002). Because of that, the records below still use
**OpenRelay**, the project's original and internal name, throughout their text — the
decisions they describe are the ones behind the contracts in this repository. Each ADR captures **what** we decided, **why**, and **what alternatives we considered**.

ADRs are immutable: once Accepted, they are not edited. If a decision is reversed, a new ADR is created that supersedes the old one.

## Index

| # | Title | Status | Date | Supersedes |
|---|---|---|---|---|
| [001](./001-settlement-contract.md) | Settlement Contract for trustless on-chain payment splitting | 🟢 Accepted | 2026-05-14 | — |

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

## Spanish summaries

Each ADR has a brief Spanish executive summary at the top. The full body is in English (for international auditors).
