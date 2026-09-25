# Changelog

## 0.1.1 — 2026-09-25

### Changed

- **Protocol fee constants now reflect ADR-005.** `0.1.0` still shipped the
  pre-ADR-005 values, so anything installing this package read a fee the
  contract no longer charges.

  | | 0.1.0 | 0.1.1 |
  |---|---|---|
  | `PROTOCOL_FEE_BPS` | 100 | **150** |
  | `TREASURY_SHARE_BPS` | 30 | **45** |
  | `OPERATOR_SHARE_BPS` | 70 | **105** |

  The 70/30 split between routing node and treasury is unchanged; the merchant
  now receives **98.5%**.

  These values are generated from `SettlementHub.sol` and guarded by a CI drift
  gate — they are never written by hand. The gap was that the package was not
  republished after the contract changed, not that the values diverged in the
  repository.

  ADR-005:
  https://github.com/lacasoft/coatipay-protocol/blob/master/audits/adr/005-comision-al-1-5-por-ciento.md
