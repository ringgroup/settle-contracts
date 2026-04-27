# Settle EVM Router

The on-chain primitive for Settle on EVM chains. A single transaction pulls funds
from the customer, sends 99.5% to the merchant, and 0.5% to Settle's treasury.

- **Atomic split.** No router custody. No clawback path.
- **Fee capped at 1% in code.** Even the owner cannot exceed `MAX_FEE_BPS = 100`.
- **USDT-compatible.** Uses `SafeERC20` so non-standard ERC-20s work.
- **Three payment paths.** Plain `approve`, EIP-2612 `permit`, EIP-3009 `transferWithAuthorization`.
- **UUPS upgradeable.** Owner is intended to be a TimelockController fronted by a 2-of-3 Safe.

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

You will need:

1. **A funded deployer key.** Get Base Sepolia ETH from
   https://www.alchemy.com/faucets/base-sepolia or
   https://faucet.quicknode.com/base/sepolia.
2. **An owner address.** For testnet iteration this can be a plain EOA you
   control. For mainnet this MUST be a TimelockController whose proposers/executors
   are a 2-of-3 Safe (see `script/Deploy.s.sol` comments).
3. **A treasury address.** For testnet, an EOA. For mainnet, a Safe multisig.

### Commands

```bash
cd contracts/evm

# Required env
export PRIVATE_KEY=0x...                          # deployer (NOT owner)
export OWNER=0x...                                # router admin (timelock on mainnet)
export FEE_RECIPIENT=0x...                        # treasury
export INITIAL_FEE_BPS=50                         # optional, defaults to 50 (= 0.5%)

# Optional, for source verification on Basescan
export ETHERSCAN_API_KEY=...

# Dry run (no broadcast)
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia

# Deploy + verify
forge script script/Deploy.s.sol:Deploy \
    --rpc-url base_sepolia \
    --broadcast \
    --verify

# Deploy without verifying (faster iteration)
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast
```

The script prints both the **proxy address** (use this everywhere — it's what
clients call) and the **implementation address** (only relevant for upgrades).

### Mainnet deployment (post-audit)

Mainnet (Base) deployment is **deferred until external audit completes**. When
ready:

1. Deploy a 2-of-3 Gnosis Safe at https://app.safe.global (founder / cofounder / cold backup).
2. Deploy `TimelockController` with `minDelay = 172800` (48h), `proposers = [Safe]`,
   `executors = [Safe]`, `admin = address(0)`.
3. Set `OWNER = <TimelockController address>` and re-run the deploy script with
   `--rpc-url base`.

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
