# CoatiPay Infrastructure Guide

*Everything you need to become a technical expert on CoatiPay. This document covers architecture, component internals, transaction lifecycle, economic model, security, deployment, and integration in full depth.*

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Component Map](#2-component-map)
3. [Settlement Layer](#3-settlement-layer)
4. [Smart Contract Layer](#4-smart-contract-layer)
5. [Routing Engine](#5-routing-engine)
6. [API Layer](#6-api-layer)
7. [Node Daemon](#7-node-daemon)
8. [SDK Layer](#8-sdk-layer)
9. [x402 Protocol](#9-x402-protocol)
10. [Transaction Lifecycle](#10-transaction-lifecycle)
11. [Economic Model](#11-economic-model)
12. [Security Model](#12-security-model)
13. [Node Operation Guide](#13-node-operation-guide)
14. [Merchant Integration Guide](#14-merchant-integration-guide)
15. [Deployment Guide](#15-deployment-guide)
16. [Comparative Analysis](#16-comparative-analysis)
17. [Invariants and Guarantees](#17-invariants-and-guarantees)

---

## 1. System Overview

CoatiPay is a five-layer payment routing system. Each layer has a single, well-defined responsibility and communicates with adjacent layers through documented interfaces.

```
┌──────────────────────────────────────────────────────────┐
│  SDK Layer                                               │
│  @lacasoft/coatipay-sdk (TS) · coatipay-sdk (Py) · coatipay-sdk (PHP)  │
│  x402 middleware for Fastify · Next.js · Express         │
├──────────────────────────────────────────────────────────┤
│  API Layer                                               │
│  Fastify REST API · PostgreSQL · Redis                   │
│  Routing Engine · Webhook Delivery · Auth                │
├──────────────────────────────────────────────────────────┤
│  Routing Layer                                           │
│  Node discovery · Score computation · Intent assignment  │
├──────────────────────────────────────────────────────────┤
│  Protocol Layer (on-chain)                               │
│  NodeRegistry · StakeManager · DisputeResolver · SettlementHub │
├──────────────────────────────────────────────────────────┤
│  Settlement Layer                                        │
│  Base (USDC) — live · Polygon / Solana — roadmap        │
└──────────────────────────────────────────────────────────┘
```

**The non-negotiable invariant across all layers:**
Funds flow directly from payer to merchant. No layer, component, or node holds funds at any point. Nodes observe, confirm, and earn fees from the settled amount — they are never in the fund path.

---

## 2. Component Map


### Package dependency graph

```
@lacasoft/coatipay-protocol          (public — types, constants, errors)
    ├── @lacasoft/coatipay-sdk       (public — JS/TS SDK)
    └── the platform                 (private — API, dashboard, nodeit)

coatipay-sdk (PyPI)      ─┐
lacasoft/coatipay-sdk    ─┴─ independent: they reimplement the protocol
  (Packagist, PHP)             in their own language

contracts/  (Solidity)   ── independent of the TS packages
```

### How the code is split

The protocol and the SDKs are **public**; the implementation CoatiPay operates is
**private**. An integrator never clones anything — they install an SDK.

```
lacasoft/coatipay-protocol        🌐 public   ← you are here
├── contracts/                       Solidity + Foundry
│   ├── src/
│   │   ├── SettlementHub.sol        settles and splits
│   │   ├── NodeRegistry.sol         nodeit registry
│   │   ├── StakeManager.sol         stake custody
│   │   ├── DisputeResolver.sol      3-of-5 arbitration
│   │   └── Pausable.sol
│   ├── test/                        197 tests (unit, fuzz, invariants)
│   └── deployments/sepolia.json     canonical addresses
└── protocol/                        @lacasoft/coatipay-protocol
    └── src/
        ├── types/                   PaymentIntent, NodeInfo, WebhookEvent, x402
        ├── constants.ts             generated from SettlementHub.sol
        └── errors.ts                CoatiPaySDKError, error codes

lacasoft/coatipay-js-sdk          🌐 public   @lacasoft/coatipay-sdk
lacasoft/coatipay-python-sdk      🌐 public   coatipay-sdk (PyPI)
lacasoft/coatipay-php-sdk         🌐 public   lacasoft/coatipay-sdk (Packagist)

lacasoft/openrelay-platform       🔒 private
├── packages/api/                    merchant API (Fastify)
├── packages/dashboard/              panel and checkout (Next.js)
└── packages/node/                   nodeit daemon
```

> **Why the platform is private.** The dashboard and checkout are phishing
> surface: a faithful copy of the payment panel is a ready-made fraud tool. The
> protocol — what has to be auditable and verifiable — is exactly what is open.


---

## 3. Settlement Layer

### 3.1 Why Base + USDC

Base is an L2 on Ethereum backed by Coinbase. It was selected as the primary settlement layer for three reasons:

**Fees.** Transactions on Base cost ~$0.001–0.005 in gas — orders of magnitude below Ethereum mainnet (where a small payment would cost $2–5 in gas), which is what makes small payments practical at all. Honest floor: the node keeps 0.7% of the fee and pays that gas, so per-call settlement breaks even around **~$0.30/call**, and the node never settles below that. True sub-cent micropayments need off-chain netting (accumulate many calls, settle the sum once) — on the roadmap.

**x402 ecosystem.** The x402 protocol (HTTP 402 Payment Required for machine-to-machine payments) was designed with Base as the primary chain. The reference implementation from x402.org targets Base Sepolia for testing.

**USDC liquidity.** Circle's USDC on Base has deep liquidity, is redeemable 1:1 for USD, and is the standard unit of account for business-to-business crypto transactions.

### 3.2 USDC contract address

```
Base mainnet:  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
Base Sepolia:  0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

### 3.3 Amount representation

All USDC amounts in CoatiPay use 6-decimal micro-units:

```
1 USDC         = 1,000,000 micro-units
$10.00 USDC    = 10,000,000
$0.001 USDC    = 1,000
$100.00 USDC   = 100,000,000
```

**Never confuse units.** Every API endpoint, SDK method, and smart contract function uses micro-units. The only place human-readable amounts appear is in the merchant dashboard display layer.

### 3.4 Lightning — out of scope

Lightning was **considered and dropped** (out of scope): it will not be implemented, and the chain enum no longer includes it. CoatiPay settles exclusively on EVM/USDC — Base today, with Polygon and Solana on the roadmap (see §3.1).

### 3.5 Chain confirmations required

| Chain | Confirmations | Typical time |
|---|---|---|
| Base | 1 | ~2 seconds |
| Ethereum mainnet (future) | 12 | ~2.5 minutes |

---

## 4. Smart Contract Layer

Four non-upgradeable contracts on Base define all on-chain protocol rules: `NodeRegistry`, `StakeManager`, `DisputeResolver`, and `SettlementHub` (all extend a shared `Pausable` base).

### Deployment status

The first Phase-B5 testnet deployment was completed on **Base Sepolia (chainId 84532)**. All four contracts are live and source-verified on Basescan. The canonical source of truth for deployed addresses, block, commit hash, and constructor parameters is `contracts/deployments/sepolia.json` — that JSON is what the API, node daemon, and any integrator read. Mainnet remains blocked by the pending external audit.

### Design principles

- **Non-upgradeable:** No proxy patterns and no fund-moving admin keys — no one can move funds or rewrite state. There **is** an emergency pause (the shared `Pausable` base) controlled by a guardian (a 3-of-5 multisig, not a single key), which gates registration and new-write operations but does not stop in-flight settlements; the guardian is held by the Foundation (no migration to on-chain governance is committed). What is audited is what runs. If a bug requires a fix, the correct response is a new deployment with an RFC-approved migration path.
- **Minimal surface:** Each contract does exactly one thing. No cross-concerns.
- **USDC-denominated:** All stake, fees, and slashing are in USDC. No protocol token.
- **Event-driven:** All state changes emit events. The off-chain routing engine and node daemon rely on event logs, not polling.

---

### 4.1 NodeRegistry.sol

**Responsibility:** Permissionless node registration and discovery.

**State:**
```solidity
mapping(address => Node) private _nodes;
address[] private _activeOperators;
```

**Key functions:**

`register(string endpoint)`
- Callable by anyone who **already deposited** stake. 3-tx flow: `usdc.approve(stakeManager, amount)` → `stakeManager.deposit(amount)` → `register(endpoint)`
- Requires `staked >= minStake` (100 USDC on mainnet · 40 USDC on Sepolia testnet — adjustable by the guardian via `setMinStake`, increase-only). **Does NOT transfer USDC**: it only verifies the stake on-chain via `StakeManager.getStakeInfo()` (least-privilege — the registry moves no funds)
- Pushes operator to `_activeOperators`
- Emits `NodeRegistered`

`deactivate()`
- Removes operator from `_activeOperators`
- Does NOT release stake — must go through StakeManager
- Emits `NodeDeactivated`

`getActiveNodes() → address[]`
- Returns all active operator addresses
- Used by the routing engine to discover candidates

**Events the routing engine listens to:**
```
NodeRegistered(address indexed operator, string endpoint, uint256 stake)
NodeUpdated(address indexed operator, string endpoint)
NodeDeactivated(address indexed operator)
```

**Security invariants:**
- An address cannot register twice (checked via `registeredAt != 0`)
- Stake is held by StakeManager, not NodeRegistry — registry has no token balance
- `getActiveNodes()` is O(n) — acceptable for Phase 1, needs pagination in Phase 3

---

### 4.2 StakeManager.sol

**Responsibility:** USDC stake custody, withdrawal timelock, and slashing.

**State:**
```solidity
mapping(address => StakeInfo) private _stakes;

struct StakeInfo {
    uint256 staked;
    uint256 pendingWithdrawal;
    uint256 unlockAt;
}
```

**The withdrawal timelock:**

The 7-day timelock between `requestWithdrawal()` and `executeWithdrawal()` is the primary protection against node exit scams. Without it, a malicious node could:
1. Accept a large payment intent
2. Fail to route it properly
3. Immediately withdraw all stake before the merchant opens a dispute

With the timelock, the merchant has 7 days to open a dispute after settlement. The dispute window and the withdrawal timelock are intentionally equal — they create a closed system where a node cannot withdraw before a dispute can be resolved.

**Slashing mechanics:**

When `DisputeResolver` calls `slash(operator, amount, disputeId)`:
1. The function checks `staked + pendingWithdrawal` as the total slashable amount
2. It reduces `staked` first, then `pendingWithdrawal` if staked is insufficient
3. The slash amount is capped at the total available — slashing can never create negative balances
4. Slashed funds remain in the contract and are tracked for treasury withdrawal (Phase 2 feature)

**Access control:**
- `depositFor()` — only callable by `nodeRegistry` address (set at deploy, immutable)
- `slash()` — only callable by `disputeResolver` address (set at deploy, immutable)
- `deposit()`, `requestWithdrawal()`, `executeWithdrawal()` — callable by any registered operator

---

### 4.3 DisputeResolver.sol

**Responsibility:** Dispute adjudication and stake slashing decisions.

**Lifecycle:**

```
Open → NodeResponded → Resolved (MerchantWins or NodeWins)
Open → (48h passes without response) → Expired → Slashed
```

**Voting mechanics (Phase 1):**

Disputes are resolved by a 3-of-5 multisig. Each arbiter calls `vote(disputeId, outcome)`. When 3 votes for the same outcome accumulate, `_resolve()` is triggered automatically. This avoids requiring a separate execution step.

Key design choices:
- **Concurrent voting:** All 5 arbiters can vote in any order. The threshold triggers resolution automatically.
- **No vote changes:** Once an arbiter votes, their vote is immutable (checked via `arbiterVotes[disputeId][msg.sender] != None`).
- **Expired = MerchantWins:** If a node fails to respond within 48 hours, `expireDispute()` can be called by anyone. An expired dispute triggers slashing without arbiter votes. This prevents nodes from ignoring disputes to avoid slashing.

**Evidence storage:**

Evidence is stored as IPFS CIDs (content-addressed hashes), not as on-chain data. This keeps contract storage costs low while making evidence publicly auditable — anyone can retrieve the IPFS content for any dispute.

**On the arbiter set:**

The multisig arbiters are managed by the Foundation; there is no committed replacement by on-chain governance. If `vote()` logic ever needs to change, it would be via a new deployment with an RFC-approved migration.

---

### 4.4 SettlementHub.sol

**Responsibility:** Trustless on-chain settlement and atomic fee split. This is the contract that **moves the funds** — it pulls the payer's USDC and splits it on-chain (merchant + node operator + treasury) in a single transaction, replacing the prior "operator-side daemon forwards funds" trust model.

**Fee split (atomic, on-chain):** for any `amount`, the contract sends 99% to the merchant, 0.7% to the node operator, and 0.3% to the treasury, in the same transaction. The fee constants are `public constant` — not configurable, no way to change the fee post-deploy:

```solidity
uint16  public constant PROTOCOL_FEE_BPS   = 100;  // 1.0% total fee
uint16  public constant OPERATOR_SHARE_BPS = 70;   // 0.7% to node operator
uint16  public constant TREASURY_SHARE_BPS = 30;   // 0.3% to treasury
uint256 public constant MAX_BATCH_SIZE     = 50;   // batch cap (x402)
```

**Three pay paths** — the gasless ERC-3009 path is the Phase 1 path:
- `payIntent` — approve + pay
- `payIntentWithPermit` — EIP-2612
- `payIntentWithAuthorization` — **ERC-3009 gasless** (the payer signs a `ReceiveWithAuthorization` authorization off-chain; the nodeit submits it and pays the gas) + `payIntentBatchWithAuthorization` for batch x402 (up to `MAX_BATCH_SIZE = 50`)

`IntentSettled` is the **source of truth** for settlement — the off-chain event watcher observes it and marks the intent `settled`. `SettlementHub` uses `nonReentrant` on every pay path and follows Checks-Effects-Interactions.

### 4.5 Contract deployment order

Due to circular dependencies (Registry needs StakeManager, StakeManager needs Registry address), contracts are deployed in this order:

```
1. Deploy StakeManager (with deployer address as placeholder for both registry and resolver)
2. Deploy DisputeResolver (with real StakeManager address)
3. Deploy NodeRegistry (with real StakeManager address)
4. Deploy SettlementHub (with usdc, treasury, and the real guardian in its constructor)
```

The placeholder addresses in StakeManager are never called maliciously — the deployer wallet has no special permissions in the contract logic. This is a known Phase 1 limitation with a documented migration path to a factory pattern in Phase 2.

---

## 5. Routing Engine — Phase 2 (planned, not implemented)

> **Status:** The multi-node routing engine described in this section **is not implemented.** Today the network operates with a single bootstrap nodeit: each intent goes to an API queue and is settled by that nodeit via ERC-3009 (see §7 and §10), with no nodeit discovery, no scoring, and no racing. Candidate discovery from `NodeRegistry.sol`, reputation scoring, and parallel racing are a **Phase 2** feature. The spec is kept here as a design reference for that phase.

When multiple nodeits are registered on-chain, the API layer will select a nodeit per intent using the algorithm below.

### 5.1 Node score formula

```
Score = (uptime_weight   × 0.30)
      + (speed_weight    × 0.30)
      + (stake_weight    × 0.20)
      + (disputes_weight × 0.20)

Where:
  uptime_weight   = node.uptime_30d  (0.0–1.0, from /info endpoint)

  speed_weight    = 1 - (node.avg_settlement_ms / MAX_SETTLEMENT_MS)
                   MAX_SETTLEMENT_MS = 30,000ms
                   Capped at 0.0 (never negative)

  stake_weight    = min(node.stake / TARGET_STAKE, 1.0)
                   TARGET_STAKE = 10,000 USDC = 10,000,000,000 micro-units
                   A node with 100 USDC (minimum) has stake_weight = 0.01
                   A node with 10,000+ USDC has stake_weight = 1.0

  disputes_weight = disputes_won / max(disputes_total, 1)
                   New nodes with 0 disputes get disputes_weight = 1.0
                   (benefit of the doubt, corrected by uptime and stake)
```

**Interpretation:** The score weights uptime and speed equally at 30% each because reliability and performance are the primary merchant concerns. Stake (20%) reflects skin in the game — a node willing to stake more is economically aligned with good behavior. Dispute history (20%) is a trust signal that grows over time.

### 5.2 Hard filters (applied before scoring)

Nodes that fail any hard filter are excluded from routing regardless of score:

| Filter | Condition |
|---|---|
| On-chain registration | Not in NodeRegistry |
| Active flag | `active = false` in registry |
| Chain support | Does not list requested chain in `/health` |
| Capacity | `/health` returns `capacity < 0.1` |
| Latency | Round-trip to `/health` > 5 seconds |
| Dispute lock | Has open dispute in `Open` status |
| Merchant whitelist | Not in merchant's `node_whitelist` (if set) |
| Merchant blacklist | In merchant's `node_blacklist` (if set) |
| Minimum stake | Below merchant's `min_stake` preference |
| Minimum score | Below merchant's `min_score` preference |

### 5.3 Parallel racing algorithm

```typescript
async function routeIntent(intent, candidates): Promise<RouteResult | null> {
  // 1. Apply hard filters
  const eligible = candidates
    .filter(c => passesHardFilters(c, intent, merchantPrefs))
    .sort((a, b) => b.score - a.score)
    .slice(0, ROUTING_CANDIDATES)  // top 5

  if (eligible.length === 0) return null

  // 2. Race concurrent assignment requests
  const results = await Promise.allSettled(
    eligible.map(c => assignToNode(c.node.endpoint, intent))
  )

  // 3. Return first accepted response
  for (const result of results) {
    if (result.status === 'fulfilled') return result.value
  }

  return null  // all candidates rejected
}
```

**Why parallel, not sequential:** If the top-scored nodeit is temporarily at capacity, sequential routing would wait for a timeout before trying the next candidate. Parallel racing distributes the ERC-3009 authorization to several candidates at once, and the first nodeit to land the on-chain settlement wins the fee.

**Rejection handling:** If a candidate nodeit does not pick up or settle the authorization, the next candidate does. If no candidate settles, the intent stays `created` until `expires_at`.

### 5.4 Score caching

Scores are cached in Redis with a 60-second TTL. This means:
- Node scores are refreshed at most once per minute
- Stale scores persist for up to 60 seconds after a node changes status
- The routing engine does NOT re-fetch scores for every intent — it uses the cached value

The 60-second TTL is a deliberate balance between freshness and performance. At scale, re-computing scores for every intent from live node `/info` data would be prohibitively expensive.

---

## 6. API Layer

### 6.1 Tech stack

| Concern | Choice | Reason |
|---|---|---|
| Framework | Fastify 4 | 3× faster than Express. Native JSON schema validation. Better plugin system. |
| Database | PostgreSQL 16 | JSONB for metadata. Native TIMESTAMPTZ. ACID guarantees. |
| Cache | Redis 7 | Score caching. Rate limiting. x402 replay protection. |
| Validation | Zod | Runtime type safety at all API boundaries. |
| Auth | API key (Bearer) | Simplest viable auth for developer tooling. |

### 6.2 Authentication

Every API request (except health check) requires an `Authorization: Bearer <key>` header.

Key formats:
```
pk_live_xxx   Public key — read-only (GET endpoints)
sk_live_xxx   Secret key — full access (POST, DELETE)
pk_test_xxx   Public key — testnet
sk_test_xxx   Secret key — testnet
```

Keys are stored in `api_keys.key_hash` as **HMAC-SHA256 with a server-side pepper** (see `lib/auth-hash.ts`). The plaintext key is returned once at creation and never stored. If lost, the key must be regenerated.

> **Manual revocation (current procedure).** No revocation endpoint exists
> yet; revoking a key today is a two-step operation:
>
> ```sql
> UPDATE api_keys SET revoked_at = now() WHERE id = 'key_xxx';
> ```
> ```bash
> redis-cli DEL "cache:auth:<key_hash>"
> ```
>
> The second step is mandatory: the auth lookup is cached
> (`AUTH_CACHE_TTL_SECONDS`, default 60s) and without the `DEL` the revoked
> key keeps being accepted until the TTL expires. When the revocation
> endpoint exists, it will perform both steps atomically.

### 6.3 Database schema summary

```sql
merchants           -- merchant accounts, wallet addresses, routing prefs
api_keys            -- hashed API keys with prefix metadata
payment_intents     -- full intent lifecycle with status machine
webhook_endpoints   -- registered webhook URLs with event subscriptions
webhook_deliveries  -- delivery attempts, retry state, response codes
disputes            -- dispute lifecycle with IPFS evidence CIDs
x402_payments_used  -- tx_hash uniqueness table for replay protection
```

The full schema (baseline) lives at `packages/api/src/lib/schema.sql`,
written with `IF NOT EXISTS` everywhere so it can be re-applied safely.
Incremental changes on top of that baseline go through a versioned
migration system in `packages/api/migrations/`, applied with
`pnpm migrate` (en la plataforma). The runner tracks each version
in the `schema_migrations` table and runs every file in its own
transaction. See `packages/api/migrations/README.md`.

### 6.4 Rate limiting

Rate limiting is applied globally per API key via Redis:
- 100 requests per minute for standard keys
- Limit headers returned on every response (`X-RateLimit-Remaining`, etc.)
- 429 responses include `Retry-After` header

### 6.5 Webhook delivery

Webhooks are delivered with exponential backoff retry:

```
Attempt 1:   immediate
Attempt 2:   30 seconds
Attempt 3:   5 minutes
Attempt 4:   30 minutes
Attempt 5:   2 hours
Attempt 6:   12 hours
After 6 failures: marked as failed, no more retries
```

Webhook payloads are signed with HMAC-SHA256:
```
Header: X-Signature: t=<timestamp>,v1=<hmac_hex>
HMAC input: <timestamp>.<payload_json>
```

Merchants verify signatures using `relay.webhooks.verify(payload, signature, secret)`.

---

## 7. Node Daemon

### 7.1 What a node does

The nodeit daemon is an HTTP server that:
1. Registers on-chain in `NodeRegistry.sol` at startup
2. Exposes two public routes: `/health` and `/info`
3. Polls the API's ERC-3009 authorization queue and claims pending ones
4. Submits `payIntentWithAuthorization` to `SettlementHub.sol` (paying the gas) for each claimed authorization
5. Confirms the settlement via the on-chain `IntentSettled` event and notifies the API
6. Maintains its own local store of settled intents for auditing

### 7.2 Node routes in detail

**`GET /health`** — public liveness
```json
{
  "status": "ok",
  "version": "0.1.0",
  "operator": "0x...",
  "chains": ["base"],
  "capacity": 0.87
}
```
`capacity` is a float 0–1 representing the nodeit's available headroom. It is consumed by the Phase 2 multi-node routing engine (see §5).

**`GET /info`** — public reputation metrics
```json
{
  "operator": "0x...",
  "version": "0.1.0",
  "uptime_30d": 0.997,
  "avg_settlement_ms": 4200,
  "total_settled": 8432,
  "stake": "5000000000"
}
```
`stake` is returned as a string to avoid JavaScript BigInt precision issues.

`/health` and `/info` are the only HTTP endpoints the daemon exposes. Settlement does not happen through an HTTP route on the nodeit (see §7.3).

### 7.3 ERC-3009 Settlement (internal)

Settlement is not triggered by an exposed HTTP endpoint on the nodeit, but by an internal loop in the daemon:

1. The payer signs an EIP-712 `ReceiveWithAuthorization` authorization off-chain with their own wallet. The SDK sends it to the API, which queues it.
2. The nodeit daemon polls that queue, claims a pending authorization, and submits `payIntentWithAuthorization` to `SettlementHub.sol`. **The nodeit pays the gas for this transaction.**
3. `SettlementHub.sol` pulls the payer's USDC and splits it atomically on-chain (99% merchant, 0.7% nodeit, 0.3% treasury) and emits `IntentSettled`.
4. An event watcher confirms the settlement by reading the `IntentSettled` event and the API marks the intent as `settled`.

There is no HMAC authentication between the API and the nodeit: the nodeit consumes the API queue and settlement is validated on-chain, not by a request signature. The merchant never defines a payment address — the USDC moves from payer to merchant within the contract's atomic transaction.

### 7.4 ERC-3009 payment model

CoatiPay settles payments with the **ERC-3009 (`ReceiveWithAuthorization`)** standard, not with per-intent derived payment addresses.

The payer signs an EIP-712 authorization off-chain — a structure including `from`, `to`, `value`, `validAfter`, `validBefore`, and a unique `nonce` — using their own wallet. That signature authorizes `SettlementHub.sol` to pull exactly that amount of USDC from the payer when the contract presents it on-chain.

This entirely eliminates the need for a unique payment address per intent and HD wallet derivation:

- There is no per-intent derived address — the payer pays from their own wallet.
- The authorization's `value` fixes the exact amount; the contract rejects any mismatch. It is not possible for a payer to pay the wrong amount and claim a different intent.
- The `nonce` is consumed on-chain on first use, which prevents authorization replay.
- The payment is **gasless for the payer**: the nodeit submits the transaction and pays the gas.

---

## 8. SDK Layer

### 8.1 Design philosophy

The SDK is designed to feel identical to Stripe's SDK for developers who have used Stripe. Same patterns: resource classes, async/await, webhook verification, error handling. The goal is zero friction for migration.

### 8.2 Request flow

```typescript
const relay = new CoatiPay({ apiKey: 'sk_live_xxx' })

// Creates a PaymentIntents resource instance
// All resource instances share the same HTTP client and config

await relay.paymentIntents.create(params)
// → POST https://api.coatipay.com/v1/payment_intents
// → Authorization: Bearer sk_live_xxx
// → Content-Type: application/json
// → CoatiPay-Version: 0.1
```

### 8.3 Error handling

```typescript
try {
  const intent = await relay.paymentIntents.create({ ... })
} catch (e) {
  if (e instanceof CoatiPaySDKError) {
    console.log(e.code)    // 'invalid_api_key'
    console.log(e.message) // 'Missing or malformed Authorization header.'
    console.log(e.doc_url) // 'https://docs.coatipay.com/errors/invalid_api_key'
  }
}
```

All API errors are instances of `CoatiPaySDKError`. Network errors (timeout, DNS failure) are re-thrown as standard `Error` instances — the SDK does not swallow network failures.

### 8.4 Host configuration

The SDK points at CoatiPay's API by default; `baseUrl` is only for test
environments or internal instances.

```typescript
const relay = new CoatiPay({ apiKey: 'sk_live_xxx' })
// baseUrl defaults to 'https://api.coatipay.com'
```

---

## 9. x402 Protocol

### 9.1 What x402 is

x402 is an implementation of HTTP 402 Payment Required for machine-to-machine payments. It allows any HTTP server to require a micropayment before serving a response, and any HTTP client (including AI agents) to make that payment autonomously.

This is the payment primitive that makes AI agent economies possible. An agent that needs data from a premium API can pay for it without human intervention, credit cards, or subscriptions.

### 9.2 The x402 HTTP flow

```
Step 1 — Agent requests resource:
  GET /api/premium-data HTTP/1.1
  Host: merchant.example.com

Step 2 — Server responds with 402:
  HTTP/1.1 402 Payment Required
  Content-Type: application/json

  {
    "x402Version": 1,
    "accepts": [{
      "scheme": "exact",
      "network": "base",
      "maxAmountRequired": "1000",
      "resource": "https://merchant.example.com/api/premium-data",
      "description": "Premium data access",
      "mimeType": "application/json",
      "payTo": "0x...",              // merchant wallet on Base
      "maxTimeoutSeconds": 300,
      "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",  // USDC
      "extra": { "name": "USDC", "version": "2" }
    }]
  }

Step 3 — Agent constructs and signs a USDC transfer on Base

Step 4 — Agent retries with payment proof:
  GET /api/premium-data HTTP/1.1
  Host: merchant.example.com
  X-PAYMENT: <base64_encoded_payment_payload>

Step 5 — Server verifies payment on-chain via CoatiPay API:
  POST /v1/x402/verify
  { "payment": "<X-PAYMENT value>", "amount": 1000, "chain": "base" }

Step 6 — Server serves the resource:
  HTTP/1.1 200 OK
  X-PAYMENT-RESPONSE: <verification_result>
  Content-Type: application/json

  { "data": "premium content" }
```

### 9.3 Replay protection

The x402 verification endpoint stores each verified `tx_hash` in the `x402_payments_used` PostgreSQL table. Subsequent requests with the same `tx_hash` are rejected with `402 Payment Required` — the agent must make a new on-chain payment.

This is also cached in Redis for performance: the first verification writes to both PostgreSQL and Redis. Subsequent checks hit Redis first. Redis TTL is 24 hours (longer than Base's finality window).

### 9.4 Micropayment thresholds

> **Phase-2 design (not implemented).** Amount-based routing depends on the multi-node routing engine (roadmap) — today every payment settles directly. Also note the economic floor (~$0.30/call): the `price: 1000` ($0.001) example is below it and would be rejected.

Intended design: small payments use direct on-chain verification (the node-assignment/routing/confirmation overhead isn't justified); larger payments route through the node network.
```typescript
// (Phase-2 design) amount < 10,000 → direct ; amount >= 10,000 → routed
relay.x402.middleware({ price: 1000 })  // $0.001 → direct (below floor — illustrative)
relay.x402.middleware({ price: 50000 }) // $0.05  → routed
```

---

## 10. Transaction Lifecycle

### 10.1 Complete flow from SDK call to webhook

```
[Merchant code]
  relay.paymentIntents.create({ amount: 10_000_000, ... })
        │
        ▼
[POST /v1/payment_intents]   status: created
  API validates request
  Generates ID: pi_xxx
  Stores in PostgreSQL
        │
        ▼
[Payer signs the ERC-3009 authorization]
  The payer signs an EIP-712 ReceiveWithAuthorization
  authorization off-chain with their own wallet
  (from, to, value, validAfter, validBefore, nonce)
  The SDK sends the signature to the API
        │
        ▼
[API queues the authorization]
  The ERC-3009 authorization enters the settlement queue
        │
        ▼
[Nodeit daemon polls the queue]
  Claims the pending authorization
  Submits payIntentWithAuthorization to SettlementHub.sol
  (the nodeit pays the gas)
        │
        ▼
[SettlementHub.sol — atomic on-chain transaction]
  Pulls the payer's USDC via ERC-3009
  Splits the amount on-chain:
    99.0% → merchant wallet
     0.7% → nodeit (OPERATOR_SHARE_BPS = 70)
     0.3% → treasury (TREASURY_SHARE_BPS = 30)
  Emits the IntentSettled event
        │
        ▼
[Event watcher confirms]      status: settled
  Reads the IntentSettled event on-chain
  API marks the intent as settled in PostgreSQL
  Queues webhook delivery
        │
        ▼
[Webhook delivered to merchant]
  POST merchant's registered webhook URL
  Body: { id: 'evt_xxx', type: 'payment_intent.settled', data: { intent } }
  Signed with HMAC-SHA256
  Merchant fulfills order on verification
```

> **Note — routing:** The flow above describes the current model: a single bootstrap nodeit polls the queue. Selecting a nodeit among several candidates by score is the Phase 2 multi-node routing engine (see §5).

### 10.2 State machine transitions (canonical)

```
created → settled
  Triggered: the on-chain IntentSettled event is confirmed
  Condition: SettlementHub.sol settled the intent atomically

created → expired
  Triggered: the expires_at timestamp is reached
  Condition: the intent did not reach settled

created → cancelled
  Triggered: the merchant cancels the intent
  Condition: the intent is not yet settled

created → failed
  Triggered: the on-chain settlement did not complete
  Condition: the ERC-3009 authorization was rejected by the contract

settled → disputed
  Triggered: merchant calls dispute endpoint
  Condition: within 7 days of settled_at
```

**These transitions are exhaustive and exclusive.** No transition exists outside this table. Any code that attempts an unlisted transition must be treated as a bug.

---

## 11. Economic Model

### 11.1 Fee flow per transaction

For a $100.00 USDC payment:

```
Payer authorizes:  $100.000000 USDC via ERC-3009 ReceiveWithAuthorization signature

On-chain:          SettlementHub.sol pulls the payer's USDC and splits it
                   atomically in a single transaction (no intermediary
                   payment_address — the USDC goes straight from payer to merchant)

Merchant receives: $99.000000 USDC
Node receives:     $00.700000 USDC (70% of 1.0% fee)
Treasury receives: $00.300000 USDC (30% of 1.0% fee)
```

For a $0.001 USDC x402 micropayment (illustrative — this is BELOW the economic
floor: the node's $0.0000070 share can't cover ~$0.003 of gas, so the node would
not settle this individually; sub-cent needs netting):
```
Total fee:     $0.0000100 (1.0% of $0.001)
Node receives: $0.0000070
Treasury:      $0.0000030
```

The protocol fee itself is purely proportional (1.0%, no flat component), but each on-chain settlement costs the nodeit gas it pays out of its 0.7% share, so an **individual** on-chain settlement only breaks even around **~$0.30/call** — and the API enforces a `MIN_PAYMENT_AMOUNT` floor (default $0.30), rejecting intents below it. True sub-cent micropayments are viable only with off-chain **netting** (accumulate many calls, settle the sum once), which is on the roadmap. Even so, CoatiPay's proportional model beats traditional processors whose flat fee (~$0.30 *per* transaction) makes small payments uneconomical at any volume.

### 11.2 Node profitability model

A node operator can estimate expected earnings:

```
monthly_volume    = transactions_per_day × avg_amount × 30
monthly_gross_fee = monthly_volume × 0.01
node_earnings     = monthly_gross_fee × 0.70

Example: 1,000 tx/day, avg $50
  monthly_volume    = $1,500,000
  monthly_gross_fee = $15,000
  node_earnings     = $10,500/month in USDC
```

Costs for a basic node:
```
VPS (2 vCPU, 2GB RAM):  ~$20/month
Minimum stake (100 USDC mainnet · 40 USDC testnet): one-time, recoverable
Base gas for registration: ~$0.005
```

The profitability threshold is around $3,000 of monthly volume (≈300 transactions at $10, or 60 at $50) — the point where node earnings cover the VPS cost. Well below what any active merchant would generate.

### 11.3 Treasury model

The treasury accumulates 30% of all protocol fees from the hosted network. Phase 1 usage:
- Security audits (required before mainnet)
- Contributor bounties
- Core development costs

Treasury allocation is decided by the Foundation; the balance is publicly visible on-chain (and via a planned public dashboard).

---

## 12. Security Model

### 12.1 Threat model by actor

**Malicious node operator**

*Threat:* Settle an intent and divert the funds to an address other than the merchant's.
*Mitigation:* The split is executed by `SettlementHub.sol` in an atomic on-chain transaction — the nodeit does not control the destination of the funds. The merchant address is fixed in the intent (it comes from the API layer) and the contract sends 99% to that wallet. The nodeit only submits the transaction and pays the gas; it cannot touch or redirect the USDC.

*Threat:* Accept work and then go offline without settling the intent.
*Mitigation:* 7-day stake withdrawal timelock. Merchant can open a dispute within 7 days. Unresponded disputes trigger automatic slashing via `expireDispute()`.

**Sybil attack (many fake nodes)**

*Threat:* Create hundreds of low-quality nodes to capture routing volume.
*Mitigation:* Minimum 100 USDC stake per node makes Sybil attacks costly ($100 per node). A node with minimum stake has `stake_weight = 0.01` — it would need very high uptime and speed to compete with well-staked nodes. At 100 fake nodes, the attack costs $10,000 in locked USDC.

**Merchant key compromise**

*Threat:* Attacker steals merchant's secret API key and creates payment intents pointing to their wallet.
*Mitigation:* The merchant wallet address is configured at the account level, not per-intent. A compromised API key cannot change the destination wallet — it can only create intents, view history, and register webhooks. Wallet changes require re-authentication.

**x402 replay attack**

*Threat:* Reuse a payment proof for multiple API calls.
*Mitigation:* Each `tx_hash` is stored in `x402_payments_used` on first use. Subsequent attempts with the same `tx_hash` are rejected. Redis caches recent hashes for performance. PostgreSQL is the durable store.

**ERC-3009 authorization replay**

*Threat:* Reuse a signed `ReceiveWithAuthorization` authorization to pull funds from the payer more than once.
*Mitigation:* Each authorization carries a unique `nonce` that `SettlementHub.sol` consumes on-chain on first use. Any attempt to present the same authorization again is rejected by the contract. The authorization also bounds its validity window via `validAfter`/`validBefore`.

**Double-spend**

*Threat:* The payer signs an authorization and then attempts a chain reorganization to reverse the settlement.
*Mitigation:* Settlement is an atomic `SettlementHub.sol` transaction; the intent only moves to `settled` when the `IntentSettled` event is confirmed on-chain. Base's L2 architecture makes reorganizations past 1 block extremely unlikely. For high-value transactions, merchants can wait for additional confirmations before fulfilling.

### 12.2 What is explicitly out of scope

- **Merchant key management** — the merchant's responsibility
- **Payer wallet security** — the payer's responsibility
- **KYC/AML compliance** — the merchant's responsibility under their jurisdiction
- **PCI DSS** — not applicable; no card data is processed

### 12.3 Smart contract invariants

These invariants must be preserved across all contract upgrades (deployments) and can be used by auditors to verify correctness:

1. `StakeManager.totalStaked() >= sum of all slashable amounts` — the contract never creates negative balances
2. `NodeRegistry.getActiveNodes()` never contains an address with `active = false`
3. `DisputeResolver`: a dispute can only be resolved once (checked via `status != Resolved && status != Expired`)
4. `StakeManager`: a withdrawal cannot be executed before `unlockAt` (timelock is strictly enforced)
5. `DisputeResolver`: an arbiter cannot vote twice on the same dispute

### 12.4 Audit requirements

All four contracts (`NodeRegistry`, `StakeManager`, `DisputeResolver`, `SettlementHub`, plus the shared `Pausable` base) require full security audits before Base mainnet deployment:
- Static analysis (Slither, Mythril)
- Manual review by at least two independent security researchers
- Fuzzing with forge test --fuzz-runs 10000
- Economic attack simulation

Audit reports will be published at `/audits` in the repository. The community should treat any mainnet deployment without a published audit as untrustworthy.

---

## 13. Node Operation Guide

### 13.1 Minimum requirements

| Resource | Minimum | Recommended for production |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 2 GB |
| Storage | 10 GB SSD | 50 GB SSD |
| Network | 100 Mbps | 1 Gbps |
| Uptime SLA | 99% | 99.9% |
| USDC stake | 100 USDC (mainnet) · 40 USDC (testnet) | 1,000+ USDC |
| Base RPC | Public (rate limited) | Dedicated (Alchemy, QuickNode) |

### 13.2 Running a nodeit

**The network is permissionless and the daemon is public:**
[`coatipay-node`](https://github.com/lacasoft/coatipay-node).

No whitelist, no approval, no secret to ask us for:

- **On-chain registration** (`NodeRegistry.register`) accepts any address with
  enough stake.
- **Stake** and slashing rules live in public, auditable contracts in this repo.
- **Reputation** is computed from on-chain data.
- **Authentication** against the API is by **operator signature**: the daemon
  signs every call with the key it registered with, and the API recovers that
  address and checks it against `NodeRegistry`. An operator can only act as
  itself, because it cannot sign with someone else's key.

To receive work you must be **registered and active** **and** keep your **bonded
stake above the minimum**. Both matter: `NodeRegistry` only checks stake **at
registration time**, so a node can stay `active` after withdrawing — and with no
stake there is no economic guarantee behind its behaviour.

```bash
# 1. Deposit the stake — register() does NOT pull USDC for you
#    USDC.approve(StakeManager, 40_000_000)
#    StakeManager.deposit(40_000_000)

# 2. Register the endpoint — it verifies you already hold >= minStake
#    NodeRegistry.register("https://your-node.example.com")

# 3. Start the daemon (see the coatipay-node README)
#    docker run -d --env-file .env ghcr.io/lacasoft/node:latest
```

### 13.3 Rotating the operator identity

There is no shared secret to rotate. The daemon signs with
`NODE_OPERATOR_PRIVATE_KEY`, which **is** its on-chain identity.

Changing it is not a credential rotation — it is switching nodes. The path goes
through the registry: register the new address with its own stake, let it start
taking work, then withdraw the old one. Until the new address is registered and
staked, the API will not hand it settlements.

Guard that key the way you would guard the wallet backing your stake, because
that is exactly what it is.

### 13.4 Monitoring recommendations

Metrics to track:
- `uptime_pct` — 30-day rolling uptime percentage
- `avg_settlement_ms` — rolling average settlement time
- `intents_claimed` — ERC-3009 authorizations claimed from the API queue
- `intents_settled` — intents successfully confirmed
- `intents_failed` — intents that could not be settled
- `disputes_open` — current open disputes (should be 0)
- `stake_balance` — current USDC stake (alert if approaching minimum)

Recommended alerting:
- `uptime_pct < 0.99` — investigate immediately (score impact)
- `disputes_open > 0` — respond within 48 hours or lose the dispute
- `stake_balance < 200_000_000` (200 USDC) — top up stake

### 13.5 Evidence preparation for disputes

If a merchant opens a dispute against your node, you have 48 hours to respond with counter-evidence. Maintain logs of:
- All intent assignments (intent_id, amount, merchant_address, assigned_at)
- All on-chain transactions (tx_hash, block_number, settled_at, amount)
- Node uptime logs
- Any error logs around the disputed time window

Package this as a JSON file and upload to IPFS. The IPFS CID is your counter-evidence.

---

## 14. Merchant Integration Guide

### 14.1 Routing preferences

```typescript
// Merchants can configure routing via API key settings
{
  routing: {
    mode: 'auto',           // 'auto' | 'whitelist' | 'blacklist'
    node_whitelist: [],     // only use these node operators
    node_blacklist: [],     // never use these node operators
    min_stake: 500_000_000, // minimum 500 USDC stake
    min_score: 0.8,         // minimum node score
  }
}
```

### 14.3 Webhook best practices

```typescript
// Always verify webhook signatures
app.post('/webhooks/coatipay', express.raw({ type: 'application/json' }), (req, res) => {
  let event
  try {
    event = relay.webhooks.verify(
      req.body.toString(),
      req.headers['x-signature'],
      process.env.WEBHOOK_SECRET
    )
  } catch (e) {
    // Invalid signature — reject immediately
    return res.status(400).send('Invalid signature')
  }

  // Idempotency: use event.id to deduplicate
  if (await db.eventProcessed(event.id)) {
    return res.status(200).send('Already processed')
  }

  // Process the event
  switch (event.type) {
    case 'payment_intent.settled':
      await fulfillOrder(event.data.metadata.orderId)
      break
    case 'payment_intent.failed':
      await notifyCustomer(event.data.metadata.orderId, 'payment_failed')
      break
    case 'dispute.opened':
      await alertMerchantTeam(event.data)
      break
  }

  // Respond quickly — process async if needed
  res.status(200).send('OK')
})
```

**Critical:** CoatiPay retries webhooks up to 6 times. Without idempotency checks, you will process events multiple times.

---

## 15. Deployment Guide

### 15.1 Local development

This repository holds the **protocol and the contracts**:

```bash
cd contracts && forge test -vvv
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast

cd protocol && npm install && npm run build
npm run check:fee-constants   # fails on drift with SettlementHub.sol
```

The **API, dashboard and nodeit daemon** do not live here (see §2). To take
payments you need none of this — install an SDK.

### 15.2 Testnet deployment (Base Sepolia)

The reference Base Sepolia deploy is already live (2026-04-18) — the canonical addresses are in `contracts/deployments/sepolia.json`. The steps below are for operators who want their own independent Sepolia deploy; to just point a node/API at the existing deploy, read that JSON directly.

```bash
# 1. Get testnet USDC
# Bridge from Ethereum Sepolia or use a faucet

# 2. Configure deployment .env
DEPLOYER_PRIVATE_KEY=0x...
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e  # Base Sepolia USDC
TREASURY_ADDRESS=0x...
ARBITER_1=0x...
ARBITER_2=0x...
ARBITER_3=0x...
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# 3. Deploy contracts
cd packages/contracts
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 4. Copy output contract addresses to root .env
NODE_REGISTRY_ADDRESS=0x...
STAKE_MANAGER_ADDRESS=0x...
DISPUTE_RESOLVER_ADDRESS=0x...

# 5. Start API and Node with testnet config
```

### 15.3 Production deployment

For production deployment, additional considerations:

**Node daemon:**
- Run behind nginx with TLS (Let's Encrypt)
- Use a dedicated Base RPC (Alchemy or QuickNode)
- Configure alerts for downtime and dispute events
- Store HMAC secret in a secrets manager (not in .env file)

**API layer:**
- PostgreSQL with automated backups (daily minimum)
- Redis with persistence enabled (AOF)
- Rate limiting tuned to expected traffic
- API keys stored as HMAC-SHA256 with pepper (never store plaintext)

**Monitoring:**
- Health check endpoint monitored externally (e.g., UptimeRobot)
- Alerting on settlement failures and dispute events
- PostgreSQL slow query log enabled

---

## 16. Comparative Analysis

### 16.1 CoatiPay vs. Stripe

| | CoatiPay | Stripe |
|---|---|---|
| Transaction fee | 1.0% | 2.9% + $0.30 |
| Minimum transaction | ~$0.30 (economic floor; sub-cent needs netting — roadmap) | ~$0.50 (fees make smaller uneconomic) |
| Fiat support | No | Yes (Visa, MC, ACH) |
| Crypto support | USDC, BTC | Limited |
| x402 (AI agents) | Native | No |
| Open source | Yes | No |
| Mexico coverage | Full | Limited (some products) |
| Setup time | 1–2 hours | 30 minutes |
| Compliance (KYC/AML) | Merchant responsibility | Stripe handles it |

**When to use Stripe:** When you need fiat (credit cards, bank transfers) or need someone else to handle compliance. Stripe and CoatiPay are complementary — many merchants should use both.

**When to use CoatiPay:** When you accept crypto, need zero fees, need micropayments, are building AI agent infrastructure, or are in a market where Stripe doesn't reach.

### 16.2 CoatiPay vs. BTCPay Server

| | CoatiPay | BTCPay Server |
|---|---|---|
| Primary asset | USDC (stablecoin) | BTC |
| x402 support | Native | No |
| Community network | Yes (nodeits earn fees) | No |
| SDK DX | Stripe-like | More complex |
| LATAM focus | Explicit | General |
| Lightning | No (out of scope) | Yes (mature) |
| Stablecoin support | Primary focus | Secondary |

BTCPay Server is the closest precedent to CoatiPay. CoatiPay is essentially "BTCPay Server for USDC and the AI agent era."

### 16.3 CoatiPay vs. Institutional alternatives (BlackRock, CoinShares products)

| | CoatiPay | Institutional |
|---|---|---|
| Ownership | Community / no one | Shareholders |
| Fees | 0–1.0% | TBD (typically 0.5–2%) |
| Censorable | No (permissionless nodes) | Yes (regulatory compliance) |
| Auditable | Fully (open source) | Partially |
| AI agent native | Yes | No |
| Regulatory clarity | Lower (merchant's problem) | Higher (institution handles) |
| Trust model | Protocol-enforced | Institution-enforced |

**The coexistence case:** CoatiPay is positioned to be the routing layer beneath institutional products, not to compete for institutional clients. A bank deploying a BlackRock crypto product needs payment routing — CoatiPay can provide that routing without the institution needing to control the rails.

---

## 17. Invariants and Guarantees

These are the properties that CoatiPay guarantees to all participants. They must be preserved across all protocol versions, implementations, and deployments.

### For merchants

1. Funds received in the merchant wallet are yours — no party can recall or freeze them after settlement
2. The dispute window is always exactly 7 days after settlement — this cannot be shortened by any node or arbiter
3. Your API key is never transmitted in logs or error messages — only the key prefix is stored for identification
4. Webhook signatures are computed over the exact payload — any modification invalidates the signature

### For node operators

1. Stake can only be slashed by `DisputeResolver` — no other contract or address can reduce your stake
2. Withdrawal timelock is exactly 7 days — this cannot be extended or shortened by any party
3. A dispute that is not responded to in 48 hours results in automatic slashing — you cannot avoid this by going offline
4. Your routing capacity is respected — if you return `capacity < 0.1`, the routing engine will not assign you new intents

### For payers

1. Payments go to the merchant wallet — not to a custodial account that could be frozen
2. x402 payments are verified on-chain — a server cannot claim payment was invalid for a confirmed on-chain transfer

### For the protocol

1. There is no admin key that can move funds, upgrade, or rewrite the state of the deployed contracts. The one privileged action is an **emergency pause** (the `Pausable` base) held by a 3-of-5 guardian multisig — it gates registration and new writes but cannot move funds, stop in-flight settlements, or change the rules
2. The fee split (70/30 node/treasury, 100 bps total — see ADR-002) is encoded in the protocol (`SettlementHub.sol` constants) and cannot be changed without a new deployment
3. The minimum stake (`minStake`) is a state variable adjustable by the guardian via `NodeRegistry.updateMinStake()`, but the contract **rejects decreases** — increase-only. This lets the network raise the anti-Sybil floor as it matures (initial value: 100 USDC on mainnet, 40 USDC on Sepolia testnet) without invalidating already-registered operators.
4. All node registrations are permissionless — no whitelist committee can block a node from joining

---

*This document reflects the state of CoatiPay at v0.1. It is updated with every significant architectural decision.*

*For questions, open a GitHub discussion. For security issues, email security@coatipay.com.*
