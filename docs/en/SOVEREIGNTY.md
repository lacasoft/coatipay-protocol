# Why CoatiPay Exists

*This document is not technical. It is the argument for why community-owned payment infrastructure matters in LATAM right now, and why the timing is not coincidental.*

---

## The Week That Defined the Question

In the first week of April 2026, two things happened simultaneously:

**In Mexico City:** The government announced that effective by end of 2026, 100% of gas stations and toll booths must accept digital payments. Cash, which still accounts for 80% of Mexican transactions, would be progressively displaced from the formal economy. Days later, Larry Fink — CEO of BlackRock, the asset management firm controlling $11 trillion — arrived at the Palacio Nacional for meetings with the federal government.

**In New York:** CoinShares, Europe's largest crypto asset manager with $6 billion under management and 34% of the European crypto ETP market share, listed on Nasdaq under the ticker CSHR. The listing marked the completion of a process that had been building for months: institutional crypto infrastructure moving from private markets to regulated public exchanges.

These events are not isolated. They are preparation.

---

## What "Preparation" Means

When CoinShares lists on Nasdaq and BlackRock meets with a government that is eliminating cash, what is being prepared is not just investment returns. What is being prepared is ownership of the rails.

Payment infrastructure is not neutral. It is not a commodity like electricity or water, even though it is treated that way in most conversations about fintech. Payment infrastructure determines:

- Who can transact and who cannot
- What transactions are permissible
- How much each transaction costs
- Who has visibility into economic activity
- Who profits from the velocity of money

When that infrastructure is owned by institutions — even well-intentioned ones — those decisions are made by institutions. When governments contract with institutions to build national payment systems, those decisions are made by whoever wrote the contract.

This is not speculation. It is the documented pattern: Ucrania's post-war reconstruction was managed by BlackRock. Panama's canal port infrastructure was acquired from Chinese interests and transferred to American capital. The playbook repeats.

---

## Why LATAM Is the Current Frontier

Latin America is the region where this tension is most acute and most urgent for several reasons.

**The transition is mandatory, not organic.** Mexico's digital payment shift is not driven by consumer preference — it is driven by government mandate with legal deadlines. This creates a captive market for whoever builds the infrastructure first. The question is not whether merchants will adopt digital payments; it is which rails they will be forced to use.

**Existing infrastructure is inadequate.** Stripe reaches Mexico but charges rates that make small-margin businesses economically unviable as digital merchants. Local alternatives (Clip, Conekta, OpenPay) have better local coverage but similar fee structures and are increasingly acquiring capital from the same institutional sources. There is no neutral option.

**The banked/unbanked gap is structural.** 80% of Mexican transactions are in cash — not because Mexicans prefer cash culturally, but because a significant portion of the population does not have access to banking services. Any digital payment infrastructure that requires a bank account to participate replicates the existing exclusion in digital form.

**The window is short.** Once institutional standards are set — once BlackRock's preferred protocols become what Mexican banks integrate, once CoinShares' infrastructure becomes what Spanish crypto ETF products route through — alternatives become harder to adopt, not easier. Network effects and regulatory capture compound quickly.

---

## What CoatiPay Is, Precisely

CoatiPay is not an alternative to institutional payment infrastructure. It is a layer beneath it.

When a Mexican bank integrates BlackRock's IBIT ETF products for retail customers, those customers will need to make payments with their digital assets. The bank will need a routing layer. That routing layer will either be:

(a) Built by the institution and controlled by the institution, or
(b) Integrated from an open protocol that no institution controls

CoatiPay is option (b). It is not positioned to fight BlackRock for government contracts. It is positioned to be the routing layer that even BlackRock's products could integrate — if the community builds it well enough and fast enough.

This is the same relationship that exists between Linux and the enterprises that run on it. Linux did not fight Microsoft for corporate contracts. It became the infrastructure that enterprises — including Microsoft — run their products on. CoatiPay can occupy that same position in payment routing.

---

## The Nodeit as Political Unit

Every CoatiPay nodeit is a small act of infrastructure sovereignty.

A developer in Guadalajara running a nodeit on a $20/month VPS is contributing to a network that no single entity controls. The USDC they earn as routing fees is compensation for real work — keeping infrastructure running, settling transactions, maintaining uptime. Their stake is real committed capital. Their reputation is computed publicly on a blockchain that no government or institution controls.

This is not a romantic notion. It is a technical description of what decentralized infrastructure actually means when implemented correctly:

- The nodeit operator in Mexico cannot be pressured by a US regulator to delist a merchant
- The nodeit operator in Spain cannot be acquired by an asset manager and repriced
- The routing algorithm cannot be modified to favor certain merchants over others without a public RFC and community consensus
- The smart contracts cannot be paused or modified by any individual or organization

This is what "no one owns the infrastructure" means in practice. It is not anarchism. It is infrastructure design.

---

## The Cost of Inaction

If CoatiPay — or projects like it — do not build working community infrastructure before institutional standards are set, the outcome is not status quo. The outcome is institutional lock-in.

Mexican merchants who adopt digital payments in 2026 will adopt whatever infrastructure is available, marketed, and endorsed by the government entities pushing the transition. If that is Stripe, they pay 2.9% forever. If that is a BlackRock-affiliated product, they pay whatever BlackRock's pricing team decides. If that is CoatiPay, they pay a fee that is a public constant of an on-chain contract — one they can verify before integrating, and that no pricing team can change unilaterally.

The difference compounds. A merchant processing $100,000/month pays $2,900 in fees to Stripe at its published 2.9% rate. On the CoatiPay community network they pay a fraction of that, fixed in [`SettlementHub.sol`](../../contracts/src/SettlementHub.sol) and split on-chain between the nodeit that settles the payment and the treasury. Over ten years the gap is capital that stays in the local economy rather than flowing to a firm on Fifth Avenue.

Multiplied across the merchants that Mexico's digital transition will create, the difference is not marginal. It is structural.

---

## The Responsibility

CoatiPay's community — everyone who runs a nodeit, contributes code, writes documentation, or spreads the word in developer communities — carries a responsibility that most open-source projects do not.

The technical work is real and must be excellent. Sloppy code does not protect anyone's economic sovereignty. A routing engine with bugs loses merchant funds. A smart contract with a vulnerability is worse than a centralized alternative. Security audits are not bureaucracy — they are the prerequisite for trust.

But beyond the technical work, the community carries a responsibility to move fast. Not to sacrifice quality — but to recognize that the window for building community alternatives is finite. Institutional infrastructure, once adopted at scale, is self-reinforcing. The time to offer an alternative is before adoption, not after.

This is why the roadmap is compressed. This is why Mexico and Spain are explicit targets, not afterthoughts. This is why the first merchant in production matters more than ten features on a backlog.

---

## The Answer

The question is who will own the digital payment infrastructure of LATAM.

The honest answer is: we do not know yet. It depends on who builds, who ships, who runs nodeits, and who convinces merchants to integrate before the defaults are set.

CoatiPay is the technical bet that the community can build fast enough and well enough to be a real option. Not the only option — but a real one. One where the merchant in Oaxaca, the developer in Bogotá, and the nodeit operator in Madrid are participants in infrastructure that serves them, not participants in infrastructure that extracts from them.

That is worth building. That is why this exists.

---

*CoatiPay is open source under the Apache License 2.0.*
*Contribute at: github.com/lacasoft/coatipay-protocol*
*Run a nodeit. Build the alternative.*
