# Settle EVM Router

[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-blue.svg)](https://soliditylang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Security Policy](https://img.shields.io/badge/security-policy-red.svg)](SECURITY.md)

The on-chain primitive for Settle on EVM chains. A single transaction pulls funds
from the customer, sends 99.5% to the merchant, and 0.5% to Settle's treasury.

- **Atomic split.** No router custody. No clawback path.
- **Fee capped at 1% in code.** Even the owner cannot exceed `MAX_FEE_BPS = 100`.
- **USDT-compatible.** Uses `SafeERC20` so non-standard ERC-20s work.
- **Three payment paths.** Plain `approve`, EIP-2612 `permit`, EIP-3009 `transferWithAuthorization`.
- **UUPS upgradeable.** Owner is intended to be a TimelockController fronted by a 2-of-3 Safe.

## Live deployments

| Network | Safe (owner) | Router proxy | Notes |
|---|---|---|---|
| Base mainnet | [`0x751F93dedfd27c54c9f192f27d95C5aBA42a2e8d`](https://basescan.org/address/0x751F93dedfd27c54c9f192f27d95C5aBA42a2e8d) | (deploying) | Settle Treasury, 2-of-3 multisig |
| Base Sepolia (testnet) | — | — | not deployed yet |
| Ethereum mainnet | — | — | v1.5+ — opt-in for orders ≥ $1k |

```
contracts/evm/
├── foundry.toml
├── src/
│   ├── SettleRouter.sol
│   └── interfaces/IERC3009.sol
├── test/
│   ├── SettleRouter.t.sol         (unit, 27 tests)
│   ├── SettleRouter.fuzz.t.sol    (fuzz, 4 properties × 256 runs)
│   └── mocks/
│       ├── MockERC20.sol           (configurable decimals)
│       ├── MockUSDT.sol            (no-bool-return ERC-20)
│       ├── MockERC20Permit.sol     (EIP-2612)
│       └── MockERC3009.sol         (EIP-3009)
├── script/
│   └── Deploy.s.sol
└── lib/
    ├── forge-std/
    └── openzeppelin-contracts-upgradeable/  (v5.0.2; bundles openzeppelin-contracts)
```

## Setup

```bash
# 1. Install foundry if you don't already have it
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. Install dependencies (already done if you cloned with submodules)
cd contracts/evm
forge install
```

## Test

```bash
forge test -vv          # run all tests
forge test --gas-report # see per-function gas
forge snapshot          # update .gas-snapshot baseline
```

All 31 tests pass. Typical `payInvoice` costs **~104k gas** end-to-end through
the proxy (cold storage writes for first-time recipients dominate).

## Deploy to Base Sepolia

Five commands, end-to-end. Assumes Foundry is installed and the working
directory is `contracts/evm`. Treat every secret below as testnet-only —
none of these keys should ever hold mainnet value.

### 1. Generate (or import) a deployer EOA

A throwaway Sepolia key is fine — there's no production risk on testnet.

```bash
# Fresh key (foundry writes the address + private key to stdout)
cast wallet new

# Save it to a local .env (NOT committed — see .gitignore)
cat > .env <<'EOF'
DEPLOYER_PRIVATE_KEY=0xabc...     # paste the private key from `cast wallet new`
DEPLOYER_ADDRESS=0xdef...         # paste the matching address
EOF
chmod 600 .env
```

The repo's `.gitignore` already excludes `contracts/evm/.env`. Do NOT commit
the file even by accident — `git status` should never list it. If you'd
rather not have a private key on disk, replace step 4 with
`--interactive` (Forge will prompt) or `--account <name>` after
`cast wallet import`.

### 2. Fund the deployer with Base Sepolia ETH

A successful deploy + verification costs ~0.005 Sepolia ETH. Faucets,
roughly in order of reliability as of 2026-04:

- https://www.alchemy.com/faucets/base-sepolia
- https://www.quicknode.com/faucets/base/base-sepolia
- https://thirdweb.com/base-sepolia-testnet?tab=faucet

Drop the deployer address (`$DEPLOYER_ADDRESS` from step 1) into one of
the above and wait ~30 s for the drip. Confirm with:

```bash
cast balance "$DEPLOYER_ADDRESS" --rpc-url https://sepolia.base.org
# expect a non-zero result, e.g. 100000000000000000  (= 0.1 ETH)
```

### 3. Set the deploy env vars

The Forge script reads `PRIVATE_KEY`, `OWNER`, `FEE_RECIPIENT`,
`INITIAL_FEE_BPS` (see `script/Deploy.s.sol`). Map your deployer key into
`PRIVATE_KEY` and add the testnet fee recipient + Basescan key:

```bash
# Continuing from step 1 — append to the same .env
cat >> .env <<'EOF'
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY                 # forge reads this name
OWNER=0x...                                       # EOA you control on testnet
FEE_RECIPIENT=0x...                               # multisig if you have one;
                                                  # otherwise a fresh EOA — testnet, no real risk
INITIAL_FEE_BPS=50                                # 0.5%
BASESCAN_API_KEY=...                              # https://basescan.org/myapikey
ETHERSCAN_API_KEY=$BASESCAN_API_KEY               # foundry.toml reads this name
EOF

# Load it into the current shell
set -a; source .env; set +a
```

### 4. Deploy via Forge

```bash
forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast --verify \
    --etherscan-api-key "$BASESCAN_API_KEY" \
    -vvv
```

The script prints the **proxy address** (this is what clients call) and the
**implementation address** (only relevant for upgrades). Save the proxy:

```bash
export ROUTER_PROXY=0x...   # from the script's "Proxy (use this address)" line
```

### 5. Post-deploy verification

Read state directly from the proxy and confirm initialisation took:

```bash
cast call "$ROUTER_PROXY" "feeBps()(uint16)"        --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: 50

cast call "$ROUTER_PROXY" "feeRecipient()(address)" --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: $FEE_RECIPIENT (lower-cased)

cast call "$ROUTER_PROXY" "paused()(bool)"          --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: false

cast call "$ROUTER_PROXY" "owner()(address)"        --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: $OWNER
```

Then load the proxy on Basescan and confirm the source is verified +
"Read as Proxy" exposes `feeBps`, `feeRecipient`, `owner`, `paused`:

  https://sepolia.basescan.org/address/$ROUTER_PROXY#readProxyContract

### Verify the split works on testnet

Once the router is live, smoke-test the 99.5 / 0.5 split with a `MockERC20`.
This is what we ship for the unit suite, so deploying it on testnet is
mechanical. Five commands.

```bash
# Wallet you'll act as the customer from. Could be the deployer; for clarity
# we use a separate test wallet.
export PAYER_PRIVATE_KEY=$PRIVATE_KEY
export PAYER=$DEPLOYER_ADDRESS
export MERCHANT=0x...   # any EOA you control or can read; check its balance
                        # before/after to see the 99.5 land

# 1. Deploy a MockERC20 with 6 decimals (USDC-like) and mint 1000 to PAYER.
forge create test/mocks/MockERC20.sol:MockERC20 \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PAYER_PRIVATE_KEY" \
    --constructor-args "Mock USDC" "mUSDC" 6 \
    --broadcast
export TOKEN=0x...    # paste the deployed address

cast send "$TOKEN" "mint(address,uint256)" "$PAYER" 1000000000 \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" --private-key "$PAYER_PRIVATE_KEY"
# 1000 * 10**6 = 1_000_000_000 — that's 1000 mUSDC

# 2. Approve 100 mUSDC to the router.
cast send "$TOKEN" "approve(address,uint256)" "$ROUTER_PROXY" 100000000 \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" --private-key "$PAYER_PRIVATE_KEY"

# 3. Pay invoice — bytes32 invoiceId can be anything unique; expectedFeeBps
#    must match the router's current feeBps (50 from step 5).
INVOICE_ID=0x$(openssl rand -hex 32)
cast send "$ROUTER_PROXY" \
    "payInvoice(bytes32,address,address,uint256,uint16)" \
    "$INVOICE_ID" "$MERCHANT" "$TOKEN" 100000000 50 \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" --private-key "$PAYER_PRIVATE_KEY"

# 4. Confirm merchant got 99.5 mUSDC (= 99_500_000 base units).
cast call "$TOKEN" "balanceOf(address)(uint256)" "$MERCHANT" \
    --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: 99500000  (assuming MERCHANT had 0 balance before)

# 5. Confirm fee recipient got 0.5 mUSDC (= 500_000 base units).
cast call "$TOKEN" "balanceOf(address)(uint256)" "$FEE_RECIPIENT" \
    --rpc-url "$BASE_SEPOLIA_RPC_URL"
# expected: 500000   (assuming FEE_RECIPIENT had 0 balance before)
```

The on-chain `InvoicePaid` event also encodes both legs of the split — the
unit tests assert this, and Basescan will render the topics under the tx
in the proxy's "Events" tab.

### Mainnet deployment

The CEO has decided not to commission a paid audit before launch. Instead the
risk is mitigated by: free static analysis (Slither / Mythril / Aderyn — see
`audit/`), an open-sourced contracts repo, a 2-of-3 Safe + 48-hour timelock
ownership model, and a $20k–$50k Immunefi bounty live on day one. The
specific procedures live in:

- `SETUP-MULTISIG.md` — Safe + TimelockController deploy + ownership transfer.
- `SETUP-BOUNTY.md` — Immunefi program creation, scope, payout tiers.
- `SECURITY.md` — public-facing reporting policy.

End-to-end, mainnet deploy is:

1. Run all three static analysis tools (`audit/slither.txt`, `audit/mythril.txt`, `audit/aderyn.md`). Every above-medium finding must be either fixed with a regression test or dismissed with a one-line rationale in `audit/REVIEWED.md`.
2. Open-source the repo (see "Open-sourcing & subtree publish" below).
3. Run the deploy script with `--rpc-url base` (same shape as the testnet steps above) **with `OWNER` set to a temporary deployer EOA** — easier to recover from a misconfig than directly handing to the timelock.
4. Follow `SETUP-MULTISIG.md` to deploy the Safe + TimelockController and transfer ownership to the timelock.
5. Verify with `cast call $ROUTER_PROXY "owner()(address)"` — must equal the TimelockController.
6. Activate the Immunefi program (`SETUP-BOUNTY.md`).

## Pre-mainnet checklist

- [x] Foundry tests passing (31)
- [x] Slither / Mythril / Aderyn run — outputs in `audit/slither.txt`, `audit/mythril.txt`, `audit/aderyn.md`; review log in `audit/REVIEWED.md`
- [x] Code open-sourced at https://github.com/ringgroup/settle-contracts
- [x] Multisig setup procedure documented (`SETUP-MULTISIG.md`)
- [x] Immunefi bounty setup procedure documented (`SETUP-BOUNTY.md`, `SECURITY.md`)
- [ ] Multisig deployed (manual — user does, see `SETUP-MULTISIG.md`)
- [ ] Bounty live (manual — user does, see `SETUP-BOUNTY.md`)
- [ ] Mainnet deploy (manual — user does, after the above)

## Open-sourcing & subtree publish

`SettleRouter` lives in this monorepo at `contracts/evm/`, but it is mirrored
to a public repo at https://github.com/ringgroup/settle-contracts so external
auditors and bounty hunters can read the source without seeing our backend.
The monorepo is the **single source of truth**; the public repo is a
mechanical projection of `contracts/evm/`.

To publish a fresh snapshot of `contracts/evm/` to the public repo, from the
root of this monorepo:

```bash
# Re-derive the contracts-only branch from the current main.
git subtree split --prefix=contracts/evm -b contracts-public

# Push it to the public repo. First time only: --set-upstream.
git push https://github.com/ringgroup/settle-contracts.git contracts-public:main

# Clean up the local split branch (it's regenerated each publish).
git branch -D contracts-public
```

The subtree command rewrites history so each public-repo commit corresponds
1:1 with the monorepo commit that touched `contracts/evm/`. Authorship is
preserved.

## Other chains (sprint 5)

- **Solana program** — written in Anchor. Deferred to sprint 5.
- **Tron router** — TVM port of this contract. Deferred to sprint 5.

## Audit-readiness notes

A reasonable auditor would flag:

1. **`setFeeBps` front-running.** A merchant submitting a payment can race a
   pending `setFeeBps` tx. The `expectedFeeBps` parameter on every `payInvoice*`
   call mitigates this — the customer signs the exact fee they expect, and the
   tx reverts if it changes mid-flight. The 48-hour timelock on mainnet makes
   this a non-issue in practice (fee changes are public for two days first).
2. **Reentrancy posture.** All payment paths are `nonReentrant`. The contract
   accepts arbitrary ERC-20s, so we don't trust token implementations.
   USDC/USDT specifically are not reentrant.
3. **`payInvoiceWithPermit` try/catch.** The `permit` call is wrapped in a
   try/catch so a front-runner who consumed the permit nonce cannot grief the
   user — payment still succeeds if the existing allowance is sufficient.
   Auditors will want to confirm this is the intended behavior.
4. **No invoice replay protection at the contract level.** The same `invoiceId`
   could be paid twice (or never). This is *intentional*: the off-chain Settle
   backend tracks invoice state and only calls/relays once. If that boundary
   matters, the backend must enforce it.
5. **No transaction cap at the contract level.** The $500k hard cap from
   `BRAND.md` is enforced off-chain at invoice-creation time, not on-chain.
   Auditors should confirm the BRAND/architecture team is comfortable with this.
6. **Truncation on fee.** Integer division rounds the fee *down*; merchant
   receives the dust. Verified by `testFuzz_splitConservesValue`.
7. **Storage gap.** `__gap[48]` reserves slots for future upgrades. If new
   inherited contracts add storage, the gap shrinks accordingly.
8. **`MAX_FEE_BPS` is `constant`.** It cannot be raised by upgrade *without*
   the audit catching it — the symbol is referenced everywhere a fee bound is
   needed, so an upgrade that changes it is a single-line diff.
