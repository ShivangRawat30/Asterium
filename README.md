# Asterium — Self-Driving Yield Tournament Engine

A **fully autonomous, production-grade smart contract system** for BNB Chain that pools user capital, deploys it across yield-generating protocols, and scores performance in decentralized tournaments—**without admin keys, off-chain automation, or centralised governance**.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Core Architecture](#core-architecture)
3. [System Components](#system-components)
4. [Key Concepts](#key-concepts)
5. [Deployment Flow](#deployment-flow)
6. [User Flows](#user-flows)
7. [Rebalancing Logic](#rebalancing-logic)
8. [Tournament Scoring](#tournament-scoring)
9. [Security & Design Patterns](#security--design-patterns)
10. [Integration Guide](#integration-guide)
11. [Gas Considerations](#gas-considerations)

---

## Executive Summary

**Asterium** is a yield aggregation protocol that:

- **Pools user capital** in a single vault accepting USDT deposits
- **Deploys capital** to AsterDEX Earn (primary yield engine) and PancakeSwap LP using user-selected strategies
- **Rebalances lazily** during user transactions (no off-chain keepers or cron jobs)
- **Tracks performance** across 30-day epochs with on-chain peak/low metrics
- **Scores participants** using a formula: `Points = ROI × StrategyMultiplier × (1 − VaultDrawdown)`
- **Operates autonomously** with zero admin intervention, no upgradeable proxy, no owner functions

### Why Asterium?

- **Trustless competition**: Transparent scoring, user self-claims revenue
- **Capital efficiency**: Pooled model spreads gas costs; weighted rebalancing optimizes allocation
- **Durability**: No admin keys means protocol survives indefinitely
- **Composability**: Clean interfaces allow swapping yield sources (start with AsterDEX → can add others)

---

## Core Architecture

### Design Principles

```
┌─────────────────────────────────────────────────────────────┐
│                    VAULT (Share Accounting)                 │
│                    ├─ Pool deposits/withdrawals             │
│                    ├─ Track per-user shares                 │
│                    ├─ Manage epoch lifecycle                │
│                    └─ Trigger rebalances lazily             │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│            STRATEGY MANAGER (Protocol Layer)                │
│                    ├─ Hold & deploy USDT                    │
│                    ├─ Integrate AsterDEX Earn               │
│                    ├─ Integrate PancakeSwap LP              │
│                    └─ Rebalance on Vault signal             │
└──────────────────────┬──────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
    ┌──────────────┐          ┌──────────────┐
    │ AsterDEX Earn│          │ PancakeSwap  │
    │  (Primary)   │          │     LP       │
    └──────────────┘          └──────────────┘

┌─────────────────────────────────────────────────────────────┐
│           REBALANCER (Pure Math, Stateless)                 │
│                    └─ Compute target allocation             │
│                    └─ Decide move direction & amount        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│         TOURNAMENT (Self-Claim Scoring)                     │
│                    ├─ Read Vault epoch metrics              │
│                    ├─ Compute ROI & drawdown                │
│                    └─ User calls claimPoints(epoch)         │
└─────────────────────────────────────────────────────────────┘
```

### No Admin, No Owner

- **StrategyManager** has a `bindVault()` one-shot initializer → permanently locks the Vault address
- **Vault** has no `Ownable` import; no upgrade mechanism
- **Rebalancer** is pure-function, stateless, immutable
- **Tournament** reads from Vault; users self-claim
- ✓ No multisig, no timelock, no admin key recovery

---

## System Components

### 1. **Types.sol**
Shared enums and data structures:
- `Strategy`: Enum for Conservative, Balanced, Aggressive tiers
- `EpochData`: Peak, low, start/end share price per epoch
- `UserEpochEntry`: User snapshot at epoch registration

```solidity
enum Strategy {
    Conservative, // 80% AsterDEX · 20% LP — multiplier 1.0×
    Balanced,     // 50% / 50%  — multiplier 1.3×
    Aggressive    // 20% / 80%  — multiplier 1.6×
}
```

### 2. **Interfaces**

#### `IAsterDEXEarn.sol`
Adapter for AsterDEX Earn vault:
```solidity
function deposit(uint256 amount) external;
function withdraw(uint256 amount) external returns (uint256 withdrawn);
function balanceOf(address account) external view returns (uint256);
```

#### `IPancakeLPVault.sol`
Adapter for PancakeSwap single-sided liquidity:
```solidity
function addLiquidity(uint256 usdtAmount) external returns (uint256 lpTokens);
function removeLiquidity(uint256 usdtAmount) external returns (uint256 usdtReturned);
function getUnderlyingValue(address account) external view returns (uint256);
```

### 3. **Rebalancer.sol**
**Pure-function calculator** — no mutable state, no protocol interaction.

**Responsibilities:**
- Compute weighted-average target LP allocation from user strategy distribution
- Check current LP exposure vs. target
- Return rebalance instruction (direction, amount)

**Key Function:**
```solidity
function checkRebalance(
    uint256 totalAssets,
    uint256 currentLPAssets,
    uint256 targetLPBps
) external pure returns (RebalanceAction memory)
```

**Trigger Threshold:** If deviation exceeds **5% (500 bps)**, rebalance is needed.

### 4. **StrategyManager.sol**
**Capital manager** — holds all vault assets, interacts with yield protocols.

**Responsibilities:**
- Receive USDT deposits from users (via Vault)
- Deploy capital to AsterDEX Earn (on deposit)
- Execute rebalancing moves (AsterDEX ↔ LP)
- Withdraw capital on user redemptions

**Key Methods:**
```solidity
function deployCapital(uint256 amount) external onlyVault
function moveToLP(uint256 amount) external onlyVault
function moveToAsterDEX(uint256 amount) external onlyVault
function withdrawCapital(uint256 amount) external onlyVault
```

**Access Control:** `onlyVault` modifier — only bound Vault can mutate state.

**One-Time Binding:**
```solidity
function bindVault(address _vault) external
// Sets vault address once; reverts if already set
```

### 5. **Vault.sol**
**Share accounting and epoch lifecycle**.

**Responsibilities:**
- Accept USDT deposits, mint shares (1:1 on genesis, pro-rata after)
- Track user strategy allocations (Conservative/Balanced/Aggressive)
- Manage epoch lifecycle (finalization, peak/low tracking)
- Trigger rebalancing on user interactions
- Register users for tournament scoring

**Share Price Formula:**
```
sharePrice = (totalAssets × 1e18) / totalShares
```

**Key Methods:**
```solidity
function deposit(uint256 amount, Strategy strategy) external
function withdraw(uint256 shares) external
function changeStrategy(Strategy newStrategy) external
function ping() external // Heartbeat for epoch registration & rebalance
```

**Strategy Weight Tracking (No Loops):**
```solidity
uint256 public conservativeShares;
uint256 public balancedShares;
uint256 public aggressiveShares;
// Updated on each deposit/withdrawal, no user iteration
```

**Epoch Management:**
- Each epoch = 30 days
- Epochs auto-finalize when surpassed
- Peak/low updated on every vault interaction
- Users register on first action in an epoch (idempotent)

### 6. **Tournament.sol**
**Self-claim point scoring engine**.

**Responsibilities:**
- Read epoch metrics and user snapshots from Vault
- Compute ROI for each user per epoch
- Apply strategy multiplier
- Penalize for vault drawdown
- Let users call `claimPoints(epoch)` to receive points

**Scoring Formula:**
```
Points = ROI × StrategyMultiplier × (1 − VaultDrawdown)

Where:
  ROI = (endPrice − entryPrice) / entryPrice
  StrategyMultiplier = {10, 13, 16} / 10  = {1.0×, 1.3×, 1.6×}
  VaultDrawdown = (peak − low) / peak
  All math: 1e18 precision
```

**Key Methods:**
```solidity
function claimPoints(uint256 epoch) external returns (uint256 points)
function previewPoints(address user, uint256 epoch) external view returns (uint256)
```

**Self-Claim Guard:** Each user can claim per-epoch only once (`claimed[user][epoch]`).

---

## Key Concepts

### 1. Pooled Vault Model
All users' capital is **merged** into a single pool. No individual "slots" or position tracking.

- **Benefit**: Lower per-user gas cost, unified rebalancing
- **Share Model**: Users receive vault shares; value = (shares × sharePrice)
- **Not ERC-20**: Shares are internal accounting only (not transferable by default)

### 2. Share Price as NAV
```
sharePrice = totalAssets / totalShares
```

**Implications:**
- As yield accrues, `totalAssets` increases → existing shares grow in USDT value
- Withdrawals are proportional to share count

**Example:**
```
Initial:
  User deposits 1000 USDT
  totalAssets = 1000, totalShares = 1000
  sharePrice = 1.0

After yield:
  totalAssets = 1100 (100 USDT yield)
  totalShares = 1000 (unchanged)
  sharePrice = 1.1

User withdraws 500 shares:
  USDT received = (500 × 1100) / 1000 = 550 USDT ✓
```

### 3. Strategy Multipliers
Users select a **risk profile** at deposit time, which affects tournament scoring only (not capital allocation):

| Strategy | Earn % | LP % | Tournament Multiplier | Risk Appetite |
|---|---|---|---|---|
| Conservative | 80 | 20 | 1.0× | Low |
| Balanced | 50 | 50 | 1.3× | Medium |
| Aggressive | 20 | 80 | 1.6× | High |

**Rebalancing Target**: Vault computes weighted-average target LP allocation:
```
targetLPBps = (conservativeShares×2000 + balancedShares×5000 + aggressiveShares×8000)
              / totalShares
```

### 4. Lazy Rebalancing (User-Triggered)
**No off-chain jobs or keepers**. Rebalancing only happens during:
- `deposit()`
- `withdraw()`
- `changeStrategy()`
- `ping()` (explicit heartbeat)

**Process:**
1. Compute current LP exposure vs. weighted target
2. If deviation > 5%, move capital
3. Direction: over-exposed to LP → pull back to AsterDEX; under-exposed → push to LP

### 5. Epoch Lifecycle (30-Day Windows)
**Epoch Index**: Derived from `(currentTime − genesisTime) / 30 days`

**Epoch States:**
- **Active**: Users deposit/withdraw, peak/low tracked
- **Stale**: 30+ days old, awaiting finalization
- **Finalized**: End share price locked, users can claim points

**Finalization:**
- Automatic on any vault interaction after epoch end
- Catches up to 12 epochs per call (prevents unbounded gas)

**User Registration:**
- First action in epoch → snapshot user shares, entry price, strategy
- Idempotent: subsequent actions in same epoch preserve entry data

### 6. Tournament Scoring (Self-Claimed)
After an epoch ends, users call `Tournament.claimPoints(epoch)` to receive points.

```
Points = ROI × Multiplier × (1 − Drawdown)
```

---

## Deployment Flow

### Step 1: Deploy Core Contracts

```solidity
// Assuming USDT, AsterDEX, PancakeLP addresses are known

Rebalancer rb = new Rebalancer();

StrategyManager sm = new StrategyManager(
    USDT_ADDRESS,
    ASTER_DEX_ADDRESS,
    PANCAKE_LP_ADDRESS
);

Vault vault = new Vault(
    USDT_ADDRESS,
    address(sm),
    address(rb)
);

Tournament tournament = new Tournament(address(vault));

// Critical: Bind the Vault to StrategyManager
sm.bindVault(address(vault));
```

### Step 2: Verify State
```bash
# Check StrategyManager vault binding
cast call <SM_ADDRESS> "vault()" --rpc-url bsc_rpc

# Should output: <VAULT_ADDRESS>
```

### Step 3: Add to Frontend
- Store Vault, StrategyManager, Tournament addresses
- Queries: `Vault.sharePrice()`, `Vault.totalAssets()`, `Tournament.previewPoints()`
- Writes: `Vault.deposit()`, `Vault.withdraw()`, `Tournament.claimPoints()`

---

## User Flows

### Flow 1: Deposit & Earn
```
User → Vault.deposit(1000e6 USDT, Balanced)
  ├─ Check epoch, finalize stale epochs
  ├─ Calculate shares to mint
  ├─ Transfer USDT to StrategyManager
  ├─ Update vault balances, user strategy
  ├─ Register user for current epoch
  ├─ Deploy capital to AsterDEX Earn
  ├─ Check & execute rebalance if needed
  └─ Emit Deposited event
```

### Flow 2: Withdraw
```
User → Vault.withdraw(500 shares)
  ├─ Finalize stale epochs
  ├─ Calculate USDT payout: (500 shares × sharePrice)
  ├─ Update strategy weights
  ├─ Withdraw from StrategyManager
  ├─ Transfer USDT to user
  ├─ Check & execute rebalance if needed
  └─ Emit Withdrawn event
```

### Flow 3: Tournament Claim
```
After Epoch N ends (30+ days)

User → Tournament.claimPoints(N)
  ├─ Verify epoch finalized
  ├─ Fetch user's entry snapshot
  ├─ Compute ROI from entry price
  ├─ Fetch vault peak/low
  ├─ Compute drawdown penalty
  ├─ Apply strategy multiplier
  ├─ Calculate final points
  ├─ Update totalPoints[user]
  └─ Emit PointsClaimed event
```

---

## Rebalancing Logic

### How It Works

**Rebalancer is a pure-math contract** — receives total assets, current LP value, and target LP percentage; returns a rebalance instruction.

```solidity
Rebalancer.checkRebalance(
    totalAssets = 1000e6,
    currentLPAssets = 500e6,
    targetLPBps = 3000     // 30% in basis points
)
```

**Calculation:**
```
Current LP % = (500 / 1000) × 10000 = 5000 bps (50%)
Target LP %  = 3000 bps (30%)
Deviation    = 5000 − 3000 = 2000 bps

Is 2000 > 500 (threshold)? YES
→ Over-exposed to LP
→ Move excess back to AsterDEX

Amount to move = 500 − (1000 × 3000 / 10000)
               = 500 − 300 = 200e6 USDT
```

### Target Calculation (Weighted Average)

```solidity
targetLPBps = (
    conservativeShares × 2000 +    // 20% LP
    balancedShares × 5000 +        // 50% LP
    aggressiveShares × 8000        // 80% LP
) / totalShares
```

---

## Tournament Scoring

### Scoring Formula

```
Points = ROI × StrategyMultiplier × (1 − Drawdown)
```

**All arithmetic: 1e18 fixed-point precision.**

### Example Scenario

```
Entry price:        1.0 USDT/share
Exit price:         1.3 USDT/share
Vault peak:         1.4
Vault low:          1.2
User strategy:      Balanced (1.3× multiplier)

ROI = (1.3 − 1.0) / 1.0 = 0.3
Drawdown = (1.4 − 1.2) / 1.4 = 0.143
Points = 0.3 × 1.3 × (1 − 0.143) = 0.410
```

---

## Security & Design Patterns

### Reentrancy Protection
- All mutable functions use `nonReentrant` from OpenZeppelin

### SafeERC20 Usage
- All token transfers via `safeTransferFrom()` and `safeTransfer()`
- Handles non-standard USDT implementations

### No Iteration Over User Arrays
- Strategy weights tracked as running sums: `conservativeShares`, `balancedShares`, `aggressiveShares`
- O(1) rebalance calculation per transaction

### One-Time Binding
```solidity
function bindVault(address _vault) external {
    require(vault == address(0), "SM: vault already bound");
    vault = _vault;
}
```

### Epoch Catch-Up Bounded
- Max 12 epochs finalized per call → prevents unbounded gas

### Entry Price Snapshot (Idempotent)
- First action in epoch locks entry price
- Subsequent actions preserve entry data
- Prevents gaming by timing deposits

### Claim Guard
- Each user can claim per-epoch only once
- Mark as claimed early (check-effects-interactions)

### Pure Rebalancer (Stateless)
- No storage reads/writes
- Deterministic, testable
- Can be called by multiple contracts safely

---

## Integration Guide

### For Frontend: Deposit Flow

```typescript
const amount = ethers.parseUnits("1000", 6);  // 1000 USDT
const strategy = 1;  // Balanced

// Approve & deposit
await usdt.approve(vaultAddress, amount);
await vault.deposit(amount, strategy);

// Query new share balance
const shares = await vault.userShares(userAddress);
const value = (shares * await vault.sharePrice()) / 1e18n;
```

### For Frontend: Real-Time Metrics

```typescript
const price = await vault.sharePrice();
const aum = await vault.totalAssets();
const epoch = await vault.currentEpoch();
const epochData = await vault.getEpochData(epoch);
```

### For Frontend: Tournament Claim

```typescript
const epoch = 0;
const preview = await tournament.previewPoints(userAddress, epoch);
await tournament.claimPoints(epoch);
const totalPoints = await tournament.totalPoints(userAddress);
```

---

## Gas Considerations

### Optimizations

| Optimization | Benefit |
|---|---|
| No user iteration | O(1) per transaction, not O(n) |
| Running-sum weights | Avoid loop in rebalance calc |
| Lazy rebalancing | No off-chain keepers |
| Idempotent epoch register | Safe to call ping() multiple times |
| Epoch catch-up bounded | Max 12 epochs per tx |
| Pure Rebalancer | Stateless, cacheable logic |

### Estimated Gas Costs (BNB Chain)

| Operation | Gas (approx) | Notes |
|---|---|---|
| First deposit | 150k–200k | Epoch init, rebalance |
| Subsequent deposit | 120k–150k | Existing epoch |
| Withdraw | 120k–150k | Depends on LP liquidity |
| Change strategy | 100k–120k | No token movements |
| Ping | 80k–100k | Just epoch register + rebalance |
| Claim points | 70k–90k | Read-heavy, simple calc |

---

## Summary: Key Takeaways

| Aspect | Design |
|---|---|
| **Capital Model** | Pooled vault; users get shares; no individual positions |
| **Yield Sources** | AsterDEX Earn (primary) + PancakeSwap LP (secondary) |
| **Rebalancing** | Lazy, user-triggered; 5% deviation threshold |
| **Automation** | Zero off-chain logic; all in smart contracts |
| **Governance** | None; fully autonomous (no admin keys) |
| **Upgradeability** | None; immutable by design |
| **Scoring** | Self-claimed; formula = ROI × Multiplier × (1 − Drawdown) |
| **Epochs** | 30-day windows; finalized on-chain; users self-register |
| **Gas Efficiency** | No user loops; running-sum tracking; ~150k gas per deposit |
| **Security** | Reentrancy guards, SafeERC20, entry-price snapshots, claim guards |

---

## Questions?

- **How do I deploy?** → See [Deployment Flow](#deployment-flow)
- **How do points work?** → See [Tournament Scoring](#tournament-scoring)
- **When do rebalances happen?** → See [Rebalancing Logic](#rebalancing-logic)
- **Is there an admin?** → No; the protocol is fully autonomous
- **Can I add new yield sources?** → Yes; extend StrategyManager with new adapter methods

---

*Asterium v1.0 | BNB Chain | Solidity ^0.8.20*
