# Audit findings — review log

One line per finding above informational severity. Real bugs get fixed in
`SettleRouter.sol` plus a regression test; false positives are dismissed
here with a short rationale.

## Slither

Run: 2026-04-27. Tool: `slither-analyzer` (latest pip). Output: `audit/slither.txt`.

Total findings: **2** (both informational; zero medium/high/critical).

- `naming-convention` on `__gap` (src/SettleRouter.sol#61) — **false positive**. `__gap` is the standard OpenZeppelin storage-gap name; the underscore prefix is the documented convention. Renaming would be wrong. Dismissed.
- `unused-state` on `__gap` (src/SettleRouter.sol#61) — **false positive**. `__gap` is *intentionally* unread state; its only job is to reserve 48 storage slots so future inherited contracts can add fields without colliding with this contract's storage layout. Dismissed.

No medium/high/critical findings. Nothing to fix.

## Mythril

Run: 2026-04-27. Tool: `mythril 0.24.8` (via pipx, Python 3.13). Output: `audit/mythril.txt`.

Total findings: **0**. The analysis completed successfully on the symbolic
execution of `SettleRouter.sol` (max depth 10) and reported "No issues were
detected." Settings used: `viaIR: true`, `optimizer: { enabled: true, runs:
200 }` — same as the production build (see `foundry.toml`).

## Aderyn

Run: 2026-04-27. Tool: `aderyn 0.1.9` (via cargo). Output: `audit/aderyn.md`.

Total findings: **1 High, 7 Low** (zero Critical or Medium).

### H-1 — Arbitrary `from` passed to `safeTransferFrom` (src/SettleRouter.sol#216)

**False positive.** Aderyn flags any `safeTransferFrom(arbitraryFrom, ...)`
call where `from` is not `msg.sender`. In `SettleRouter`:

- `payInvoice` and `payInvoiceWithPermit` pass `payer = msg.sender` into
  `_payInvoice` (lines 145, 168). The "arbitrary" address is in fact the
  caller, so the standard "anyone can drain a victim's allowance" attack
  path doesn't exist.
- `payInvoiceWithAuthorization` does *not* call `safeTransferFrom` at all
  (line 194 calls the EIP-3009 `transferWithAuthorization`, which the
  token verifies against the `from`-signed authorization). The Aderyn
  detector doesn't model EIP-3009.

Aderyn's heuristic is correct for vault-style contracts that take a
caller-supplied `from`; here every payment path either uses
`msg.sender` directly or is gated by an off-chain signature. Dismissed.

### Low findings — all dismissed

- **L-1: Centralization risk for trusted owners** — by design. The owner is a `TimelockController` fronted by a 2-of-3 Safe with a 48-hour public delay. This is the locked architecture (see `ARCHITECTURE.md`, "Locked properties"). Centralization is a feature, not a bug, for a fee router that needs to rotate the treasury and pause on incident. Dismissed.
- **L-2: Solidity pragma should be specific, not wide** (`^0.8.27`) — intentional. The `^` allows the contract to compile against future patch releases of 0.8.x, which we want. The deployment pin is in `foundry.toml` (`solc = "0.8.27"`), so production bytecode is reproducible regardless of the source pragma. Dismissed.
- **L-3: Event `FeeBpsUpdated` is missing `indexed` fields** — intentional. `FeeBpsUpdated` only fires from the owner (timelock) and only at most once per 48h. Off-chain consumers don't filter on the old/new bps values; they filter on the event signature itself. Adding `indexed` would burn gas with no listener benefit. Dismissed.
- **L-4: `nonReentrant` should occur before all other modifiers** — false positive. `whenNotPaused` is a pure check (`require(!paused())`); it does no external calls and cannot reenter. Order is irrelevant for safety here, and putting the guard first would be stylistic only. Dismissed.
- **L-5: PUSH0 not supported by all chains** — false positive for our target. Base supports PUSH0 (it's a Cancun-era L2). The contract is not deployed to pre-Shanghai chains. Dismissed.
- **L-6: Empty block** — `_authorizeUpgrade` is *required* to be empty when access control is supplied solely by the `onlyOwner` modifier (UUPS pattern). The empty body is the OpenZeppelin-recommended idiom. Dismissed.
- **L-7: Large literal `10_000` could use scientific notation** — style preference. `10_000` (with the underscore separator) is clearer than `1e4` for a basis-point denominator that is *exactly* 10,000, not "approximately 1×10⁴". Dismissed.

No High/Medium fixes required. Eight findings in total, all dismissed with rationale above.
