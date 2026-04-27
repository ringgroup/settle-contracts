# SETUP-BOUNTY.md

Step-by-step procedure to launch the Settle bug bounty on Immunefi
(https://immunefi.com). Done **once**, before mainnet launch. The
program goes live the same day the multisig takes ownership of the
router (see `SETUP-MULTISIG.md`).

## Pool size

Total pool: **$20,000–$50,000** USDC, sourced from the treasury Safe.

Tier breakdown (per finding):

| Severity  | Payout    | Rationale                                                |
|-----------|-----------|----------------------------------------------------------|
| Critical  | $20,000   | Fund loss, permanent freeze, unauthorised owner takeover |
| High      | $5,000    | Temporary fund freeze, owner-action bypass               |
| Medium    | $1,000    | Fee-rounding misuse, event-mismatch, gas griefing        |
| Low       | $200      | Style, documentation, minor disclosure                   |

Funded from the multisig in USDC at payout time. The pool is *advertised*
as up to $50k cumulative; individual payouts are capped at the table
above.

## Scope

**In scope:**
- `SettleRouter` proxy + implementation on Base mainnet (address
  published in the public repo's README at deploy time).
- Source code in `https://github.com/ringgroup/settle-contracts` —
  vulnerabilities discovered statically count as long as they are
  reachable via the deployed proxy.

**Out of scope** — these have their own report channel
(`hi@settle.xxx` with `[SECURITY]` subject):
- Vercel infra, the marketing site (`settle.xxx`).
- The hosted MCP server (`mcp.settle.xxx`) and its tools.
- The off-chain backend, including invoice creation, OFAC screening,
  webhook delivery, key rotation.
- Third-party dependencies (OpenZeppelin contracts, Foundry).
- Phishing / social engineering of the team.
- Spam, DOS, brute-force on user accounts.

## Disclosure

90-day responsible disclosure window from first contact. The reporter
must not publish the issue, share with third parties, or exploit the
bug on mainnet during that window. We commit to:

1. Acknowledge within 48 hours.
2. Triage (validate severity, decide payout tier) within 7 days.
3. Patch within 30 days for Critical/High, 60 days for Medium, 90 days
   for Low.
4. Pay the bounty in USDC from the treasury Safe within 14 days of
   patch confirmation.
5. Publish a post-mortem on `settle.xxx/blog` after the patch ships.

## Signup procedure

1. **Create a project on Immunefi.**
   - Sign in at https://immunefi.com/dashboard with the founder GitHub.
   - Click **Create project** → **Settle**.
   - Project type: **Smart contract**, chain: **Base**.
2. **Fill the program template.** Copy this file's "Scope" and
   "Disclosure" sections verbatim into the Immunefi template; copy the
   "Pool size" table into the rewards section.
3. **Verify the multisig.** Immunefi requires a verified treasury for
   payouts. Submit the Safe address from `SETUP-MULTISIG.md` step 1.
4. **Publish.** Go live the same day mainnet deploy lands.
5. **Link the program.** Update `SECURITY.md` with the Immunefi URL
   (`https://immunefi.com/bounty/settle`) and push to the public repo.

## Hall of fame

We publicly thank every reporter (with their consent) on
`settle.xxx/security/hall-of-fame`. White-hats who request anonymity
are acknowledged as "anonymous researcher" with the disclosure date and
severity tier.

## Operational notes

- **Never** hand-edit the multisig threshold to expedite a payout. If
  two signers can't be reached, the bounty waits — payout speed is not
  worth threshold compromise.
- Critical findings get a **draft fix** + **regression test** in the
  monorepo before the public patch lands. The fix is staged on a branch
  with restricted access until the on-chain timelock has executed the
  upgrade.
- The treasury Safe must hold at least $50k USDC at all times. Top up
  monthly from collected fees if balance drops below threshold.
