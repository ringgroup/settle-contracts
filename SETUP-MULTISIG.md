# SETUP-MULTISIG.md

Step-by-step procedure to put `SettleRouter` behind a 2-of-3 Safe + 48-hour
TimelockController on Base mainnet. Run this **once**, before mainnet
launch. Every command below is the exact thing to paste into a terminal
with the relevant env vars set; expected output and rollback are listed
under each step.

Assumes:
- Foundry is installed (`forge --version` returns ≥ 0.2.0).
- `cast` is on the path.
- You have a hardware-wallet-backed signer for each of the three Safe
  owners (founder / cofounder / cold backup). No hot keys.
- `BASE_RPC_URL` points at Base mainnet.

```bash
export BASE_RPC_URL=https://mainnet.base.org   # or your own provider
```

---

## Step 1 — Create the 2-of-3 Safe on Base

We use Gnosis Safe (https://app.safe.global) because it's the standard,
audited, and supported by every major hardware wallet.

1. Open https://app.safe.global in a browser already logged into the
   *founder* wallet (hardware-backed).
2. Top-right network selector → **Base**.
3. Click **Create new Safe**.
4. Name: `Settle Treasury`. Click **Next**.
5. Add three owners:
   - Founder hardware wallet
   - Cofounder hardware wallet
   - Cold backup (hardware wallet held off-site by a non-employee)
6. Threshold: **2 of 3**. Click **Next**.
7. Review and **Create**. Sign the deployment tx with the founder key.

**Expected output:** the Safe UI shows a fresh address. Save it:

```bash
export SAFE_ADDRESS=0x...   # paste from the Safe UI
```

Sanity check on-chain:

```bash
cast call "$SAFE_ADDRESS" "getOwners()(address[])" --rpc-url "$BASE_RPC_URL"
# expected: array of three owner addresses
cast call "$SAFE_ADDRESS" "getThreshold()(uint256)" --rpc-url "$BASE_RPC_URL"
# expected: 2
```

**Rollback:** there's nothing to undo — the Safe doesn't yet own anything.
Just create another Safe if you got an owner wrong.

---

## Step 2 — Deploy `TimelockController`

OpenZeppelin's `TimelockController` is the canonical 48-hour delay
contract. Source:
https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/governance/TimelockController.sol

Constructor args:
- `minDelay` = `172800` (48 hours, in seconds)
- `proposers` = `[SAFE_ADDRESS]`
- `executors` = `[SAFE_ADDRESS]`
- `admin` = `address(0)` — **critical**: passing zero means the timelock
  is self-administered. Any other value would let the admin bypass the
  delay.

Deploy from a hardware-wallet-backed deployer EOA (any address with ETH
on Base):

```bash
export DEPLOYER_PK=0x...   # ledger-derived key; consider --interactive instead

forge create lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController \
    --rpc-url "$BASE_RPC_URL" \
    --private-key "$DEPLOYER_PK" \
    --constructor-args 172800 "[$SAFE_ADDRESS]" "[$SAFE_ADDRESS]" 0x0000000000000000000000000000000000000000 \
    --broadcast \
    --verify \
    --etherscan-api-key "$BASESCAN_API_KEY"
```

**Expected output:** Forge prints `Deployed to: 0x...`. Save it:

```bash
export TIMELOCK_ADDRESS=0x...
```

Sanity check on-chain:

```bash
cast call "$TIMELOCK_ADDRESS" "getMinDelay()(uint256)" --rpc-url "$BASE_RPC_URL"
# expected: 172800

# PROPOSER_ROLE = keccak256("PROPOSER_ROLE")
cast call "$TIMELOCK_ADDRESS" \
    "hasRole(bytes32,address)(bool)" \
    0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1 \
    "$SAFE_ADDRESS" \
    --rpc-url "$BASE_RPC_URL"
# expected: true
```

**Rollback:** if the timelock is misconfigured, deploy a new one. The old
one isn't owning anything yet so it's harmless leftover bytecode.

---

## Step 3 — Transfer `SettleRouter` ownership to the timelock

The router is currently owned by the deployer EOA. We hand off ownership
to the timelock with a single call.

```bash
# Transfer ownership.
cast send "$ROUTER_PROXY" \
    "transferOwnership(address)" \
    "$TIMELOCK_ADDRESS" \
    --rpc-url "$BASE_RPC_URL" \
    --private-key "$DEPLOYER_PK"
```

**Expected output:** `status 1 (success)` in the cast tx receipt.

`OwnableUpgradeable` is single-step (not the two-step variant), so
the transfer takes effect immediately. There is no `acceptOwnership`
to call.

**Rollback:** if you transferred to the wrong address, you cannot
unilaterally undo this — the new owner has full control. The recovery
path is to use the timelock+Safe to call `transferOwnership` to a
corrected address. If you transferred to a contract that *can't* call
`transferOwnership` back, the contract is bricked. **Triple-check
`$TIMELOCK_ADDRESS` before sending this tx.**

---

## Step 4 — Verify ownership

```bash
cast call "$ROUTER_PROXY" "owner()(address)" --rpc-url "$BASE_RPC_URL"
# expected: $TIMELOCK_ADDRESS (lower-cased)
```

If the address printed equals `$TIMELOCK_ADDRESS`, the router is now
owned by the timelock, which is in turn controlled by the 2-of-3 Safe.
Any future `setFeeBps`, `setFeeRecipient`, `pause`, `unpause`, or
upgrade requires:

1. Two of the three Safe signers approve a `TimelockController.schedule`
   tx.
2. 48 hours pass.
3. Two of the three Safe signers approve a `TimelockController.execute`
   tx.

This is the locked state described in `ARCHITECTURE.md`.

---

## Operational notes

- **Never** add the deployer EOA as a Safe owner. Cycle the deployer key
  out of any sensitive role after step 4.
- **Never** lower the timelock `minDelay` without an emergency rationale
  documented and posted publicly (see `BRAND.md` on the public-discount
  policy on rug-resistance).
- The `pause()` function still respects the 48-hour delay — there is no
  emergency bypass. This is a deliberate trade-off: a 48-hour
  exploitable bug is worse than a 48-hour delay to pause, in our threat
  model, because we do not custody funds.
