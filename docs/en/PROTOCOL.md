# CoatiPay Protocol Specification

**Version:** 0.1 (Draft)
**Status:** Work in Progress
**Authors:** CoatiPay Contributors

---

## Abstract

This document defines the CoatiPay Protocol — the rules, data structures, message formats, and state machines that govern how payment intents are created, routed, settled, and confirmed across the CoatiPay network.

Any implementation that conforms to this spec is a valid CoatiPay node. Any SDK that conforms to this spec can route through any compliant node. Compatibility is defined by this document, not by any reference implementation.

---

## Design Rationale

Before the technical specification, this section documents why the protocol is designed the way it is. Every decision has a reason. Understanding the reasons helps contributors make better changes.

### Why funds never pass through nodes

The most important protocol invariant. Nodes are observers and confirmers — they detect on-chain transfers and confirm them to the API layer. They never hold or intermediate funds.

This design was chosen because it eliminates an entire class of attacks: a malicious node cannot steal funds in transit, because funds are never in transit through the node. The attack surface is limited to: (a) a node lying about a settlement that did not happen — refuted by the on-chain `IntentSettled` event, the single source of truth for settlement, or (b) a node going offline after assignment — the intent expires at `expires_at` and nobody earns a fee, because the nodeit's fee only exists inside the transaction that settles.

Any protocol change that puts funds through nodes must be treated as a critical regression, not a feature.

### Why non-upgradeable contracts

Upgradeable contracts (proxy patterns) give someone — inevitably the deployer or a multisig — the power to change the rules after the fact. That power is incompatible with the trust model of a community protocol.

If a bug requires fixing, the correct response is: (1) disclose it, (2) pause the affected functionality via a community decision, (3) deploy new contracts, (4) migrate with community consent. This is slower than an upgrade. It is also trustworthy in a way that upgrades are not.

### Why permissionless nodes (not a whitelist)

A whitelist committee is a centralization vector. Whoever controls the whitelist controls the network. In the context of LATAM payment infrastructure, a whitelist controlled by the founding team could be pressured by regulators, acquired by an institution, or simply become a bottleneck as the team's priorities change.

Permissionless registration with economic incentives (stake, reputation, fees) achieves the same quality filtering without centralization. A node with bad behavior loses routing organically — no committee needed.

### Why USDC, not a protocol token

A protocol token creates a speculation layer on top of the payment layer. Every economic decision becomes entangled with token price dynamics. Contributors are incentivized to promote the token rather than build the product. Users are confused about whether they are using a payment system or a financial instrument.

USDC is boring. It is 1:1 with USD, redeemable by Circle, and accepted everywhere. Node operators earn boring USDC. The treasury accumulates boring USDC. This is the right kind of boring for payment infrastructure.

### Why the fee split is 70/30 (node/treasury)

Node operators do the work — they run infrastructure, maintain uptime, stake capital. They receive the majority of fees. The 30% treasury allocation is the minimum needed to make the treasury **self-sustaining** at reachable volumes (~$10M/mo vs ~$30M/mo under the prior 80/20 split) — nodes collectively benefit from the ongoing work the treasury funds: audits, SDK development, documentation, community growth.

If the treasury share were higher, operators would have less incentive to run nodes. If it were lower, the project would need recurring external funding rounds to cover basic public goods. 70/30 is the equilibrium that keeps both sides viable (see ADR-002 for the full economic analysis; ADR-005 raises the total fee to 150 bps and leaves the split untouched).

### Why x402 is first-class, not a plugin

The AI agent economy will need payment infrastructure. That infrastructure needs to work at micropayment scale, at machine speed (no human approval flow), and across autonomous agents. HTTP 402 is the natural protocol for this — it is part of the HTTP standard, available in any language, and requires no new authentication protocol.

Note on scale: sub-cent settlement (e.g. $0.001 per API call) is a **roadmap target**, not a current capability. Each on-chain settlement costs gas the nodeit pays, so the economic floor today is ~$0.30/call — the API enforces a `MIN_PAYMENT_AMOUNT` floor (default $0.30) and rejects intents below it. True sub-cent micropayments require off-chain **netting** (accumulate many calls, settle the sum once), which is on the roadmap.

Making x402 a plugin would create a two-tier protocol: "real" payments and "AI payments." There is no technical or economic reason for this distinction. Both use USDC on Base. Both use the same settlement layer. Building x402 in from the start ensures that merchant integrations are x402-capable by default.

---

## Table of Contents

1. [Terminology](#1-terminology)
2. [Network Participants](#2-network-participants)
3. [Settlement Layer](#3-settlement-layer)
4. [On-Chain Protocol](#4-on-chain-protocol)
5. [Payment Intent Lifecycle](#5-payment-intent-lifecycle)
6. [Node Protocol](#6-node-protocol)
7. [Routing Algorithm](#7-routing-algorithm)
8. [x402 Extension](#8-x402-extension)
9. [Security Model](#9-security-model)
10. [Error Codes](#10-error-codes)
11. [Versioning](#11-versioning)

---

## 1. Terminology

| Term | Definition |
|---|---|
| **Merchant** | An entity that integrates CoatiPay to receive payments |
| **Payer** | The entity that initiates a payment (human or AI agent) |
| **Node** | A community-operated server that facilitates payment routing |
| **Node Operator** | The entity that runs and stakes a node |
| **Payment Intent** | A declared intention to pay a specific amount, with a defined lifecycle |
| **Settlement** | The on-chain transfer of funds from payer to merchant |
| **Routing** | The selection of an optimal node to facilitate a payment intent |
| **Stake** | USDC deposited by a node operator as collateral |
| **Score** | A public, on-chain reputation metric for a node |
| **Treasury** | The protocol-controlled fund for development and bounties |
| **x402** | The HTTP 402-based micropayment protocol for machine-to-machine payments |

---

## 2. Network Participants

### 2.1 Merchants

A merchant is any entity that has deployed the CoatiPay API and integrated the SDK into their product.

Merchants have:
- A merchant ID (`mid_xxx`) — globally unique, assigned at registration
- One or more API keys — `pk_live_xxx` (public) and `sk_live_xxx` (secret)
- A destination wallet address per supported chain
- Webhook endpoints registered for event delivery

Merchants interact with the network exclusively through the API layer. They have no direct protocol-level communication with nodes.

### 2.2 Payers

A payer is any entity that sends funds to complete a payment intent. Payers can be:

- **Human** — interacting via a checkout UI powered by the SDK
- **Agent** — an autonomous AI agent using the x402 extension (see Section 8)

Payers have no persistent identity in the protocol unless explicitly provided by the merchant via metadata.

### 2.3 Nodes

A node is a server registered on-chain that participates in payment routing. Nodes:

- Are registered via `NodeRegistry.sol` with a staked USDC deposit
- Expose a compliant HTTP API (see Section 6)
- Monitor on-chain settlement events
- Confirm payment completion back to the API layer
- **Never hold or custody funds at any point**

A node that is not registered on-chain MUST NOT be used by the routing engine.

### 2.4 Bootstrap Nodes

During Phase 1, the CoatiPay core team operates a set of bootstrap nodes. These nodes:

- Serve as the initial routing targets while the network grows
- Are registered on-chain identically to any other node — no special privileges
- Will be progressively complemented by community nodes as reputation builds
- By Phase 3 the network no longer depends on them — they keep running as ordinary nodes, no longer a single point of failure

Bootstrap node addresses are published in the repository and verifiable on-chain.

---

## 3. Settlement Layer

### 3.1 Supported Chains and Assets

| Chain | Asset | Chain ID | Status |
|---|---|---|---|
| Base Sepolia (testnet) | USDC | 84532 | **Live** — contracts deployed and verified |
| Base mainnet | USDC | 8453 | Blocked on external audit |
| Polygon | USDC | 137 | Planned (Phase 2) |
| Solana | USDC | — | Planned (Phase 2) |

Base + USDC is the primary settlement layer and the **only one implemented** today. All protocol fees and stake are denominated in USDC on Base.

> **On Lightning/BTC:** Lightning was **dropped (out of scope)** — considered but not implemented; the chain enum no longer includes `lightning`. Settlement is EVM/USDC only: Base today, with Polygon and Solana on the roadmap. An authorization for any chain other than Base is rejected by the validator (`authorization-validator.ts`).

### 3.2 USDC on Base

```
USDC (Base mainnet):  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
USDC (Base Sepolia):  0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

All amounts in the protocol are denominated in USDC micro-units (6 decimal places). `1,000,000` = $1.00 USDC.

### 3.3 Fund Flow

**Funds flow directly from payer to merchant. Nodes never hold funds.**

```
Payer Wallet ──────────────────────────────► Merchant Wallet
                                                    ▲
Node (observes, confirms, earns fee from)  ─────────┘
                                        (fee deducted on-chain from transfer)
```

Fee split per transaction:
```
Amount = 1,000,000 (1.00 USDC)
Total fee = 15,000 (1.5% = 150 bps)
  └─ Node share (70%) = 10,500
  └─ Treasury (30%) = 4,500
Merchant receives = 985,000
```

The payer never pays gas: payments settle **gasless via ERC-3009** — the payer signs a
`ReceiveWithAuthorization` authorization off-chain and the nodeit submits it on-chain and
pays the gas (see §6.2). What gas abstraction does *not* fix is the nodeit's economics for
sub-cent amounts: the nodeit pays ~$0.003 of gas per settlement against its 1.05% share, so an
individual on-chain settlement only breaks even around ~$0.30. The API enforces a
`MIN_PAYMENT_AMOUNT` floor (default $0.30) and rejects intents below it. True sub-cent
micropayments (x402) require off-chain **netting** — accumulating many calls and settling the
sum once — which is on the roadmap (see ADR-002; ADR-005 for the move to 150 bps).

---

## 4. On-Chain Protocol

Three smart contracts on Base define the protocol rules: `NodeRegistry`, `StakeManager`, and `SettlementHub`. All are **non-upgradeable** (no proxy patterns) — the rules cannot change after deploy.

**On pause and the guardian:** the contracts have NO arbitrary admin keys (no one can move funds or rewrite state), but they **do have an emergency pause** via a `Pausable` base controlled by a guardian. The pause only gates *registration* and *new-write* operations (e.g. `register`, `registerIntent`) — it does **not** stop in-flight settlements. The guardian is a **3-of-5 multisig**, never a single key, held by the Foundation (no migration to on-chain governance is committed). This is a deliberate design choice: an exploit found post-deploy with no pause mechanism means total loss for those affected; the pragmatic compromise is pause-governed-by-multisig, not absence of pause. (See `audits/adr/` and whitepaper §3.2 for the full reasoning.)

### 4.1 NodeRegistry.sol

**Responsibility:** Node registration and discovery.

```solidity
struct Node {
    address operator;       // wallet that controls the node
    string  endpoint;       // HTTPS URL of the node API
    uint256 registeredAt;   // block timestamp of registration
    bool    active;         // operator-controlled active flag
}

// Stake is deposited separately in StakeManager BEFORE registering;
// register() checks the operator already has >= minStake staked.
function register(string calldata endpoint) external;
function updateEndpoint(string calldata endpoint) external;
function deactivate() external;
function activate() external;
function getNode(address operator) external view returns (Node memory);
function getActiveNodes() external view returns (address[] memory);
```

**Minimum stake (`minStake`):** state variable on `NodeRegistry`, initialized at deploy time.
- **Mainnet:** 100 USDC (100,000,000 micro-units) — the protocol's anti-Sybil floor
- **Sepolia testnet:** 40 USDC (40,000,000 micro-units) — lowered initial value to ease onboarding with faucets

The guardian can raise `minStake` via `NodeRegistry.updateMinStake(uint256)` as the network matures. The contract **rejects decreases** — increase-only. This lets the Sybil floor rise without invalidating existing operators' stakes.

### 4.2 StakeManager.sol

**Responsibility:** Stake deposits and timelocked withdrawals.

Stake is a **bond and an anti-Sybil barrier**: it credentials an operator to enter the registry and forces it to commit capital. It **cannot be confiscated** — the protocol has no economic penalty (see ADR-004). No key, the guardian's included, can move an operator's stake: every deposit comes in from `msg.sender` and can only go back out to `msg.sender`.

```solidity
struct StakeInfo {
    uint256 staked;
    uint256 pendingWithdrawal;
    uint256 unlockAt;
}

uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;

function deposit(uint256 amount) external;
function requestWithdrawal(uint256 amount) external;
function executeWithdrawal() external;
function getStakeInfo(address operator) external view returns (StakeInfo memory);
```

**Withdrawal timelock:** 7 days between `requestWithdrawal()` and `executeWithdrawal()`. It is no longer calibrated against any adjudication window — there is nothing to adjudicate. Its purpose is to **give the network time to notice that an operator is leaving**. `requestWithdrawal()` deducts the amount from `staked` immediately and emits `WithdrawalRequested`, so the exit is visible on-chain a full week before the USDC moves: anyone can read `getStakeInfo()` and see the collateral drop, and routing can stop assigning intents to an operator that falls below `minStake`. An operator cannot drain its stake and vanish within the same block.

### 4.3 SettlementHub.sol

**Responsibility:** The contract that **moves the funds**. Pulls USDC from the payer and atomically splits it on-chain (merchant + node operator + treasury) in a single transaction. Introduced in ADR-003 as the heart of gasless ERC-3009 settlement.

```solidity
uint16  public constant PROTOCOL_FEE_BPS   = 150;  // 1.5% total fee
uint16  public constant TREASURY_SHARE_BPS = 45;   // 0.45% to treasury
uint16  public constant OPERATOR_SHARE_BPS = 105;  // 1.05% to node operator
uint256 public constant MAX_BATCH_SIZE     = 50;   // batch cap (x402)

// The only address whose signature authorizes an intent registration. Immutable.
// A plain wallet or an ERC-1271 contract — in production, a multisig.
address public immutable intentSigner;

// The nodeit registers the intent on-chain (lazy, on first claim), but the
// content is authorized by the platform with an EIP-712 `intentSigner` signature.
struct IntentRegistration {
    bytes32 intentId;
    address merchant;
    address operator;
    uint256 amount;
    uint64  expiresAt;
    bytes   signature;   // EIP-712 by intentSigner over the five fields above
}

function registerIntent(IntentRegistration calldata reg) external;
function registerIntentBatch(IntentRegistration[] calldata regs) external returns (uint256 registered);

// Three pay paths. The gasless one (ERC-3009) is the Phase 1 path:
function payIntent(bytes32 intentId) external;                       // approve + pay
function payIntentWithPermit(bytes32, uint256, uint8, bytes32, bytes32) external;  // EIP-2612
function payIntentWithAuthorization(Authorization calldata auth) external;          // ERC-3009 gasless
function payIntentBatchWithAuthorization(Authorization[] calldata auths) external;  // batch x402

function getIntent(bytes32 intentId) external view returns (Intent memory);

event IntentRegistered(...);
event IntentSettled(...);   // off-chain source of truth for settlement
```

**Signed registration (EIP-712):** the nodeit still sends the registration transaction and pays its gas, but it **cannot alter what it registers**. `registerIntent` takes an `IntentRegistration` and reverts with `InvalidIntentSignature` unless `intentSigner`'s signature covers exactly `(intentId, merchant, operator, amount, expiresAt)`. The batch path requires the signature **per element**: it is not a shortcut for registering without authorization. Verification uses `SignatureChecker`, so the signature may come from a plain wallet (ECDSA) or from an **ERC-1271 contract** — a multisig. This is an explicit centralization: the platform is authoritative over the intent→merchant binding (see ADR-004).

**`intentSigner` is immutable, and in production it must be a multisig.** The address cannot be changed, and that part is not negotiable: if the guardian could rotate it, it would gain the ability to bind in-flight payments to a merchant of its choosing, which is precisely the power to move funds this design denies it. What *does* depend on how the hub is deployed is the **cost** of that immutability:

- **With a plain wallet (EOA):** one key is enough to authorize, and losing it or leaking it forces you to **pause and redeploy the whole hub**. The contract accepts this configuration for compatibility only.
- **With a multisig (ERC-1271):** the address stays immutable — the guardian still cannot touch it — but **the signers rotate inside the multisig**, without touching the contract. And authorizing takes the threshold, not a single key. The worst case moves from "redeploy the hub" to "remove a signer from the Safe".

That is why the production recommendation is to deploy `intentSigner` as a multisig. Its address is passed to the constructor and cannot be changed afterwards, so choosing the threshold and the custody of the signer keys is part of the deployment, not a later adjustment. The pause remains the emergency lever for the case where the whole threshold is compromised. `contracts/test/SettlementHub.multisigSigner.t.sol` covers this configuration with a 2-of-3 multisig: six tests, including removing a compromised key without redeploying, and one checking that the plain-wallet path still works.

**Fund split (atomic, on-chain):** for an `amount`, the contract transfers `98.5%` to the merchant, `1.05%` to the node operator, and `0.45%` to the treasury, in the same transaction. The merchant absorbs any rounding remainder (never loses funds below the split). The constants are `public constant` — not configurable, no way to change the fee post-deploy.

**Gasless path (ERC-3009):** the payer signs a `ReceiveWithAuthorization` authorization off-chain (EIP-712); the node operator submits it via `payIntentWithAuthorization` and pays the gas. USDC enforces `msg.sender == to`, which eliminates on-chain front-running of the authorization. **The authorization is bound to its intent:** the contract requires `nonce == intentId` and reverts with `AuthorizationNotBoundToIntent` otherwise, so a signature is only usable for the intent whose id it carries as the nonce, and whoever submits the transaction cannot redirect the money. The nonce is burned on first use (USDC's native replay protection). The authorization travels as a raw `bytes` signature and settles via USDC's `receiveWithAuthorization(…, bytes)` overload (`SignatureChecker`), so it **works for both EOA wallets (ECDSA) and ERC-1271 smart wallets** (e.g. Coinbase Smart Wallet). *Counterfactual* accounts (undeployed smart wallet → ERC-6492 signature) are deferred to a later phase.

**Events:** `IntentSettled` is the **source of truth** for settlement — the off-chain `SettlementEventWatcher` observes it and marks the payment intent `settled` + fires the webhook. The protocol never considers a payment settled until this on-chain event confirms.

`SettlementHub` uses `nonReentrant` on every pay path and follows Checks-Effects-Interactions (state set before external transfers).

---

## 5. Payment Intent Lifecycle

### 5.1 States

CoatiPay's payment model is **ERC-3009 gasless** (see §3.3). The payer signs an EIP-712 `ReceiveWithAuthorization` authorization off-chain; the nodeit daemon claims it from a queue and submits `payIntentWithAuthorization` to the `SettlementHub.sol` contract, which pulls the USDC and splits it on-chain atomically. There is no routing or "pending payment" step in the lifecycle — the intent goes from `created` to `settled` when the on-chain `IntentSettled` event is confirmed.

```
created ──► settled

created ──► cancelled
created ──► expired
created ──► failed
```

`settled` is the only successful terminal state, and it is final: once `IntentSettled` is emitted there is no later transition, because the protocol has no reversal and no adjudication (see ADR-004). Additional terminal states: `cancelled` (cancelled by the merchant), `expired` (passed `expires_at`), `failed` (the on-chain settlement did not complete).

### 5.2 Payment Intent Object

```typescript
interface PaymentIntent {
  id:              string           // "pi_" + 24 random chars
  merchant_id:     string           // "mid_" + 16 chars
  amount:          number           // in asset micro-units
  currency:        "usdc" | "btc"
  chain:           "base" | "polygon" | "auto"
  status:          PaymentIntentStatus
  node_operator:   string | null    // nodeit that settled the intent
  payer_address:   string | null    // payer wallet (from the ERC-3009 authorization)
  tx_hash:         string | null    // on-chain tx hash
  fee_amount:      number           // protocol fee charged
  metadata:        Record<string, string>  // max 20 keys
  created_at:      number           // unix timestamp
  expires_at:      number           // unix timestamp (default: +30 min)
  settled_at:      number | null
}
```

### 5.3 Transition Rules

**created → settled** — the on-chain `IntentSettled` event emitted by `SettlementHub.sol` is confirmed. The payer signed an ERC-3009 authorization, the nodeit daemon submitted it to the contract, and the contract pulled the payer's USDC and split it atomically (98.5% to the merchant, 1.05% to the nodeit, 0.45% to the treasury). The `payment_intent.settled` webhook fires.

**created → expired** — the `expires_at` timestamp is reached without the intent reaching `settled`.

**created → cancelled** — the merchant cancels the intent before settlement.

**created → failed** — the on-chain settlement did not complete (e.g., the authorization was rejected by the contract).

**There are no transitions out of `settled`.** Settlement is atomic and final: the contract splits the funds in the same transaction that receives them, and there is no on-chain or API path to reverse it.

---

## 6. Node Protocol

The nodeit daemon exposes a minimal, public HTTP API. All endpoints use JSON.

### 6.1 Required Endpoints

```
GET  /health   → { status, version, operator, chains, capacity }
GET  /info     → { operator, version, uptime_30d, avg_settlement_ms, total_settled, stake }
```

`/health` and `/info` serve liveness and public reputation metrics. They are the only HTTP endpoints the daemon exposes to the network.

### 6.2 ERC-3009 Settlement (internal)

Settlement does not happen through an exposed HTTP endpoint on the nodeit. The flow is:

1. The payer signs an EIP-712 `ReceiveWithAuthorization` authorization off-chain.
2. The SDK sends that authorization to the API, which queues it.
3. The nodeit daemon polls the API queue, claims the authorization, and submits `payIntentWithAuthorization` to the `SettlementHub.sol` contract. The nodeit pays the gas for this transaction.
4. `SettlementHub.sol` pulls the payer's USDC and splits it atomically on-chain (98.5% merchant, 1.05% nodeit, 0.45% treasury) and emits the `IntentSettled` event.
5. An event watcher confirms the settlement by reading the on-chain `IntentSettled` event, and the API marks the intent as `settled` and fires the webhook.

The nodeit never holds funds at any point: the USDC moves from payer to merchant within a single atomic contract transaction.

### 6.3 Node Behavior Requirements

A conformant nodeit MUST:
- Respond to `/health` within 2 seconds
- Poll the API queue and submit `payIntentWithAuthorization` promptly after claiming an authorization
- Pay the gas for the settlement transaction
- Maintain logs of all settled intents for minimum 90 days

A conformant nodeit MUST NOT:
- Act as an intermediary holding funds between payer and merchant
- Modify transaction amounts or metadata
- Submit authorizations for chains not listed in its `/health` response

---

## 7. Routing Algorithm — Phase 2 (planned, not implemented)

> **Status:** This section specifies the multi-node routing engine. **It is not implemented.** Today the network operates with a single bootstrap nodeit: each ERC-3009 authorization enters the API queue and is settled by that nodeit, with no pre-routing or scoring. Discovering nodeits from `NodeRegistry.sol`, reputation scoring, and parallel racing are a **Phase 2** feature — the spec is kept here as a design reference for that phase.

When multiple nodeits are registered, the API will select a nodeit per intent using the following algorithm.

### 7.1 Node Score

```
Score = (uptime_weight × 0.40) + (speed_weight × 0.40)
      + (stake_weight × 0.20)

uptime_weight = uptime_30d (0.0–1.0)
speed_weight  = 1 - (avg_settlement_ms / 30000), min 0
stake_weight  = min(node_stake / 10_000_000_000, 1.0)
```

**On the weight redistribution:** the 0.20 that used to weigh the adjudication record is split **between uptime and speed** (0.30 → 0.40 each), not added to stake. The reason: that term scored adjudicated conduct, and with no adjudication there is no conduct record left to score — all that remains observable about a nodeit is what it does, namely stay alive and settle fast. Stake stays at **0.20 on purpose**: it is an entry barrier and a capital commitment, not a performance metric, and raising its weight would let capital buy routing.

Scores cached in Redis, refreshed every 60 seconds.

### 7.2 Hard Filters

Applied before scoring. Nodes failing any filter are excluded regardless of score:
- Not registered on-chain
- `active = false`
- Does not support requested chain
- `capacity < 0.1`
- Round-trip to `/health` > 5 seconds
- Not in merchant whitelist (if set)
- In merchant blacklist (if set)
- Below merchant minimum stake/score (if set)

### 7.3 Selection

1. Apply hard filters
2. Sort remaining by score (descending)
3. Take top 5
4. Distribute the intent authorization to candidates by score
5. The first nodeit to settle the intent earns the fee
6. Discard the remaining candidates

---

## 8. x402 Extension

### 8.1 Flow

```
Agent: GET /api/resource
Server: 402 Payment Required + { x402Version, accepts: [{ amount, asset, payTo }] }
Agent: constructs + signs on-chain payment
Agent: GET /api/resource + X-PAYMENT: <base64_payload>
Server: verifies on-chain → serves resource + X-PAYMENT-RESPONSE
```

### 8.2 SDK Middleware

```typescript
// Fastify
app.addHook('preHandler', relay.x402.middleware({
  price: 300_000,     // $0.30 USDC (current economic floor; sub-cent needs netting — roadmap)
  currency: 'usdc',
  chain: 'base',
}))

// Next.js App Router
export const GET = relay.x402.handler({
  price: 300_000,     // $0.30 USDC
  handler: async (req) => Response.json({ data: 'protected' })
})
```

### 8.3 Routing threshold — Phase 2 (not implemented)

> The node-routing split below is part of the **Phase 2 multi-node routing engine** (see §7) and is **not implemented today** — the current model settles every x402 payment via the single bootstrap nodeit, with no routing. Note also the economic floor: an individual on-chain settlement only breaks even around ~$0.30, and the API enforces a `MIN_PAYMENT_AMOUNT` floor (default $0.30). The $0.01 threshold below is a design reference, not a live capability; viable sub-cent amounts depend on off-chain netting (roadmap).

- Payments < $0.01 USDC (< 10,000 micro-units): direct on-chain verification
- Payments >= $0.01 USDC: routed via node network

---

## 9. Security Model

| Threat | Mitigation |
|---|---|
| Node steals funds | Funds never pass through nodes — payer-to-merchant always |
| Node routes to wrong address | The merchant address is set by the API layer and travels **signed** (EIP-712 by `intentSigner`): the nodeit sends the registration but cannot change its content |
| Node collects fee without settling | It cannot: the nodeit's 1.05% comes out of the **same atomic split** that pays the merchant, in the same transaction. No settlement, no fee to collect |
| Sybil attack | `minStake` of 100 USDC (mainnet) makes Sybil costly |
| Node exit scam | 7-day withdrawal timelock: the exit is visible on-chain a week before the stake moves |
| Double-spend | Settlement is an atomic `SettlementHub.sol` transaction; the intent moves to `settled` only when the on-chain `IntentSettled` event is confirmed |
| x402 replay | tx_hash stored in x402_payments_used after first use |
| ERC-3009 authorization replay | The `nonce` of the `ReceiveWithAuthorization` authorization is consumed on-chain on first use |

---

## 10. Error Codes

### API Error Format

```json
{
  "error": {
    "code": "intent_expired",
    "message": "The payment intent has expired.",
    "param": null,
    "doc_url": "https://docs.coatipay.com/errors/intent_expired"
  }
}
```

### Error Code Reference

| Code | HTTP | Description |
|---|---|---|
| `invalid_api_key` | 401 | API key malformed or revoked |
| `insufficient_permissions` | 403 | Secret key required |
| `intent_not_found` | 404 | Payment intent ID does not exist |
| `intent_expired` | 410 | Intent has passed `expires_at` |
| `intent_already_settled` | 409 | Cannot modify a settled intent |
| `no_nodes_available` | 503 | No nodes meet routing criteria — only applies to the Phase 2 multi-node routing engine (see §7); does not occur in the current single-bootstrap-nodeit model |
| `chain_not_supported` | 400 | Requested chain not active |
| `amount_too_small` | 400 | Amount below chain minimum |
| `amount_too_large` | 400 | Amount exceeds node capacity |
| `invalid_webhook_url` | 400 | Webhook URL not reachable |
| `node_not_registered` | 403 | Node not in on-chain registry |

---

## 11. Versioning

### Protocol versioning

`MAJOR.MINOR` — breaking changes bump MAJOR, backwards-compatible additions bump MINOR.

Current version: `0.1`. The `0.x` series allows breaking changes with 30-day notice.

**v1.0 criteria:**
1. Contracts audited and deployed to Base mainnet
2. At least 10 independent community nodes active
3. SDK used in at least one production merchant deployment

### API versioning

URL prefix: `/v1/`. New API version will not be introduced before protocol v1.0.

---

## Appendix A — Webhook Events

| Event | Triggered When |
|---|---|
| `payment_intent.created` | Intent is first created |
| `payment_intent.settled` | The on-chain `IntentSettled` event was confirmed |
| `payment_intent.failed` | On-chain settlement failed |
| `payment_intent.expired` | TTL reached without payment |
| `payment_intent.cancelled` | Cancelled by the merchant before settlement |

---

## Appendix B — Minimum Node Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 2 GB |
| Disk | 10 GB SSD | 50 GB SSD |
| Network | 100 Mbps | 1 Gbps |
| Uptime SLA | 99% | 99.9% |
| USDC Stake | 100 USDC (mainnet) · 40 USDC (testnet) | 1,000+ USDC |

---

*This document is a living specification. Changes are proposed via GitHub issues tagged `spec`. Protocol changes require an RFC with minimum 7-day discussion period.*
