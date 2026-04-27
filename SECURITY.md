# Security Policy

Settle's on-chain router (`SettleRouter`) is a 2-of-3 multisig + 48-hour
timelock-controlled UUPS proxy on Base. We do not custody user funds;
every payment splits atomically into the merchant's payout and the
treasury fee in a single transaction. There is no clawback path.

## Reporting a vulnerability

We pay bounties for valid findings. Please use whichever channel fits
your finding best.

### Preferred — Immunefi

https://immunefi.com/bounty/settle

Immunefi handles triage, escrow, and payout. This is the **only** path
that pays a bounty.

### Backup — direct email

`hi@settle.xxx` with subject prefix `[SECURITY]`.

Use this if Immunefi is down or your finding isn't smart-contract scope
(e.g. a Vercel infra issue, an OAuth flaw in the dashboard, an MCP
server bug). We will redirect you to Immunefi if your finding is in
scope there.

Encrypt sensitive details with our PGP key
(https://settle.xxx/.well-known/pgp.asc) for findings rated Critical
or High.

## What we pay

Pool: $20,000 – $50,000 USDC from the treasury Safe. Per-finding cap:

| Severity  | Payout   |
|-----------|----------|
| Critical  | $20,000  |
| High      | $5,000   |
| Medium    | $1,000   |
| Low       | $200     |

Severity is determined by the Immunefi standard
(https://immunefi.com/severity/). See `SETUP-BOUNTY.md` for our scope
and timelines.

## In scope

- `SettleRouter` proxy + implementation on Base mainnet (addresses
  published in the README of this repo).
- Source code in this repository.

## Out of scope

These have their own reporting flow (`hi@settle.xxx` with `[SECURITY]`,
no bounty unless escalated):

- The marketing site (`settle.xxx`) and Vercel infra.
- The hosted MCP server (`mcp.settle.xxx`) and its tools.
- The off-chain backend (invoice creation, OFAC screening, webhook
  delivery, key rotation).
- Third-party dependencies (OpenZeppelin, Foundry).
- Phishing, social engineering, spam, brute-force.

## Responsible disclosure

90 days from first contact. Don't publish, don't share, don't exploit
on mainnet during that window. We will:

1. Acknowledge within 48 hours.
2. Triage within 7 days.
3. Patch in 30 / 60 / 90 days (Critical/High / Medium / Low).
4. Pay the bounty within 14 days of patch confirmation.
5. Publish a post-mortem.

## Hall of fame

With your consent, we publicly thank you on
`settle.xxx/security/hall-of-fame`. White-hats who prefer anonymity are
listed as "anonymous researcher" with the disclosure date and severity
tier.
