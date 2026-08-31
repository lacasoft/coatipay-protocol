# CoatiPay Roadmap

> "La pregunta no es si el mundo se digitaliza. Eso ya está pasando.
> La pregunta es quién va a ser dueño de esa infraestructura."

> **Update (2026-04-18):** Phase 1 milestone complete — Base Sepolia deploy live with source-verified contracts. See `packages/contracts/deployments/sepolia.json`.

---

## Why This Roadmap Exists

In April 2026, two things happened in the same week:

- BlackRock's CEO Larry Fink arrived at Mexico's Palacio Nacional, days after Mexico announced the elimination of cash — mandatory digital payments at 100% of gas stations and toll booths by end of 2026.
- CoinShares, Europe's largest crypto asset manager with $6B under management and 34% ETP market share, listed on Nasdaq under ticker CSHR.

These are not isolated events. They are preparation. Institutional capital is positioning itself — with government contracts, stock exchange listings, and regulatory frameworks — to own the digital payment infrastructure of the next decade.

CoatiPay's roadmap is a direct response to that positioning. Not in opposition — institutional adoption of crypto is net positive for the ecosystem. But in parallel. Because when an institution builds payment rails, someone else owns them. When a community builds payment rails, no one does.

The window to build community-owned infrastructure before institutional standards become entrenched is not years. It is months.

---

## Guiding Principles

**LATAM-first.** Mexico is the launch market. Spain is the second market. The rest of LATAM follows. The problem hurts most where Stripe charges more, reaches worse, and where the shift from cash to digital is being imposed by government mandate — not organic adoption.

**Under the institutions, not against them.** When a Mexican bank wants to offer USDC payments using BlackRock's IBIT ETF as collateral, it will need a payment routing layer. CoatiPay can be that layer. The institution will not want to build it. It will want to integrate it. CoatiPay must be ready.

**Speed over perfection.** The market is being defined now. A working v1 in the hands of real merchants in Mexico City matters more than a perfect v2 in a GitHub repo.

**Community is the moat.** The only durable competitive advantage over institutional alternatives is a community of nodeit operators, contributors, and merchants that no single entity controls. Every roadmap decision must prioritize growing that community.

---

## Phase 1 — Foundation

**Goal:** Get the protocol deployed, working, externally audited, and live on mainnet. Phase 1 closes when CoatiPay can take real merchants — not before.

> **Strategic update (2026-05-09) — Luis Campos (LACA-SOFT):**
>
> The original Phase 1 plan included "First merchant in production" as a closing milestone. That was my framing mistake. **No real merchant is going to integrate a payment system on testnet** — Sepolia transactions are toys for developers, not cash flow for a store. I assumed merchant traction could happen pre-mainnet and that's not realistic.
>
> The correct sequence is:
>
> ```
> Capital → External audit → Mainnet deploy → First merchant
> ```
>
> Mainnet without an audit is irresponsible. Merchants without mainnet is fiction. So "first merchant" moves to Phase 2 — it lands the moment mainnet is deployable and the merchant's funds are actually at stake. Phase 1 now closes with the external audit contracted/completed and the Base mainnet deploy executed.

### Technical Milestones

- [x] Smart contracts: `NodeRegistry.sol`, `StakeManager.sol`, `SettlementHub.sol` — three deployed contracts
- [x] Foundry test suite: 147 tests (131 unit + 16 invariant/fuzz), all green, across the contracts
- [x] Deploy script: `Deploy.s.sol` ready for Base Sepolia
- [x] Nodeit daemon: Fastify HTTP API, routes scaffolded
- [x] REST API: payment intents, webhooks, x402 routes scaffolded
- [x] SDK JS: `@lacasoft/coatipay-sdk` with payment intents, webhooks, x402 middleware
- [x] GitHub Actions CI: typecheck + test + build + Foundry
- [x] **Deploy contracts to Base Sepolia** — completed 2026-04-18 (see `packages/contracts/deployments/sepolia.json`)
- [x] PostgreSQL persistence in API (`packages/api/src/lib/db.ts` + `repository.ts`)
- [x] HMAC signing in nodeit daemon (`packages/node/src/lib/hmac.ts`, 60s window)
- [x] Gasless ERC-3009 settlement: the payer signs a `ReceiveWithAuthorization` authorization and `SettlementHub.sol` pulls the USDC and splits it atomically on-chain (98.5% merchant / 1.05% nodeit / 0.45% treasury)
- [x] x402 on-chain payment verification + replay protection (atomic Redis `SET NX` + tx_hash in DB)
- [x] Webhook delivery with Redis-backed retry queue
- _Note:_ "Routing engine reading nodeits from `NodeRegistry.sol` via viem" was moved to Phase 2 — with only one nodeit registered, on-chain discovery yields the same result as the `BOOTSTRAP_NODE_ENDPOINT` fallback. See Phase 2 > Technical Milestones.

### Market Milestones

- [x] First bootstrap nodeit registered on-chain and running in production — team-operated, operator [`0xf73e...5da4`](https://sepolia.basescan.org/address/0xf73e2E5a4493d8a4C28e6f88c14a396C82395da4) separated from deployer, 40 USDC staked serving live traffic — re-registered 2026-05-09 after the tanda-C redeploy, tx [`0x6ffe...5ef6`](https://sepolia.basescan.org/tx/0x6ffe0c08deb2649813cf46b63bf5089b2d486061eb7de87ea0a9b78372635ef6).
- [ ] Public testnet announcement in Spanish-language developer communities (target: attract auditors and devs, NOT merchants — see strategic note above)
- [x] Repository public on GitHub under `lacasoft` ([github.com/lacasoft/coatipay-protocol](https://github.com/lacasoft/coatipay-protocol))

### Mainnet Milestones (Phase 1 closing)

- [ ] Capital raised for external smart-contract audit
  - Estimated cost: $20-50k USD (Spearbit/Cantina/OpenZeppelin tier) or $5-15k (independent auditor)
  - Funding paths to explore: Base ecosystem grants, Optimism RetroPGF, small angel round, self-funding
- [ ] External audit contracted — `NodeRegistry.sol`, `StakeManager.sol`, `SettlementHub.sol`, `Pausable.sol` (~990 LOC Solidity, 140 Foundry tests)
- [ ] Audit findings remediated and verified with re-audit
- [ ] Deploy to **Base mainnet** with `minStake = 100 USDC` (anti-Sybil floor documented in the whitepaper)
- [ ] Bootstrap nodeit operational on mainnet (same daemon, mainnet contracts)
- [ ] `packages/contracts/deployments/mainnet.json` published with canonical addresses + linked audit report

### Community Milestones

- [ ] First external contributor PR merged
- [ ] Nodeit operator documentation complete in Spanish and English

---

## Phase 2 — Real traction on mainnet

**Goal:** First real merchant processing USDC payments on mainnet. Permissionless nodeit registration open to anyone. First community nodeits in Mexico and Spain.

> **Change (2026-05-09):** "First merchant pilot" moved into this phase from Phase 1. Reason: pre-mainnet (Phase 1) has no real economic value for a merchant — testnet USDC is play money. Only when mainnet is live and audited does it make sense to onboard the first production merchant. This phase opens when Phase 1 closes (mainnet deployed).

### Technical Milestones

- [ ] Permissionless nodeit registration via `NodeRegistry.sol` on Base mainnet
- [ ] Full routing engine: on-chain nodeit discovery, score caching, parallel racing
- [ ] Nodeit reputation system: on-chain score visible via `/v1/nodeits`
- [x] Python SDK: `coatipay-sdk` published on PyPI
- [ ] PHP SDK: `lacasoft/coatipay-sdk` on Packagist
- [ ] Merchant dashboard: Next.js + shadcn/ui
- [ ] WooCommerce plugin (critical for Mexican merchant adoption)

### Market Milestones

- [ ] **First merchant pilot on mainnet** (Mexico) — first time CoatiPay processes real USDC for a real sale. Item that originally sat in Phase 1 before the 2026-05-09 reframe.
- [ ] First community nodeit in Mexico (non-team operator)
- [ ] First community nodeit in Spain
- [ ] First WooCommerce store using CoatiPay in production

### Community Milestones

- [ ] First contributor bounty paid from treasury
- [ ] 10+ external contributors
- [ ] Community call cadence established (monthly, in Spanish)
- [ ] Nodeit operator guide translated: Spanish, English, Portuguese

---

## Phase 3 — Ecosystem

**Goal:** Multi-chain. Go SDK for AI agents. Institutional compatibility layer. Treasury self-sustaining.

### Technical Milestones

- [ ] Polygon USDC support
- [ ] Solana USDC support
- [ ] Go SDK: `github.com/lacasoft/coatipay-go-sdk`
  - Critical for AI agent infrastructure (MCP, autonomous agents)
  - This is the primary x402 consumer in 2026+
- [ ] **Institutional compatibility layer**
  - CoatiPay as routing layer for institutional products
  - Documented API for banks and asset managers to integrate
  - No custody, no KYC on CoatiPay side — institution handles that
- [ ] Public treasury dashboard
  - Real-time fee accumulation visible to anyone
  - Bounty allocation transparent and on-chain
- [ ] The network no longer depends on the core team's bootstrap nodeits
  - Community nodeits can handle all routing on their own
  - The core team keeps operating nodeits and participating in the protocol; its bootstrap nodeits are no longer a single point of failure

### Market Milestones

- [ ] 10+ active community nodeits on Base mainnet
- [ ] 3+ countries in LATAM with production merchants
- [ ] First institutional partner using CoatiPay as routing layer
- [ ] v1.0 declared (see criteria below)

### Community Milestones

- [ ] First governance vote on protocol change
- [ ] 50+ contributors across all packages
- [ ] Dedicated community nodeits in MX, ES, AR, CO
- [ ] First developer conference talk about CoatiPay in Spanish

---

## v1.0 Declaration Criteria

Version 1.0 will be declared when all three conditions are simultaneously true:

1. Smart contracts audited by an independent firm and deployed to Base mainnet
2. At least 10 independent community nodeits active on the network
3. SDK used in at least one production merchant deployment

These are public, verifiable, and non-negotiable. No version inflation.

---

## What Is Not On This Roadmap

**Fiat gateway.** Stripe processes Visa and Mastercard because it has banking licenses in 50 countries. CoatiPay will never have that — and does not need it. Merchants who need fiat should use Stripe for fiat and CoatiPay for crypto. These are complementary, not competitive.

**A protocol token.** There will never be a RELAY token. Nodeit operators earn USDC. Contributors earn reputation and voice. Introducing a speculative token would corrupt the incentive structure and attract the wrong community.

**Upgradeability in the core contracts.** The three contracts are non-upgradeable by design. Any protocol change that requires contract modification goes through a full audit cycle and a new deployment — not an upgrade. This is a feature, not a limitation.

**KYC/AML compliance layer.** CoatiPay does not process identity. That is the merchant's responsibility under their jurisdiction. CoatiPay provides payment routing; compliance is upstream.

---

## The Urgency

The institutional positioning described above is not a future threat — it is a present reality. CoinShares is already on Nasdaq. BlackRock is already in Palacio Nacional. Mexico's cash elimination timeline is 2026.

Every month that CoatiPay does not have a working nodeit network and at least one production merchant is a month where the institutional narrative becomes the only one available.

The community has the technical advantage — open source, a low fee fixed on-chain, no gatekeepers. The institutions have the capital advantage — regulation, distribution, government relationships.

The only way the community wins is by moving faster than the institutions expect.

---

*This roadmap is a living document. Changes are proposed via GitHub issues tagged `roadmap`. Approved changes are merged with a version bump and a dated changelog entry.*

*Last updated: April 2026*
