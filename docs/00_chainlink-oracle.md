# Chainlink Price Oracle

Automatically settles price-based prediction markets using Chainlink price feeds. Deployed directly on **Unichain** — no bridge, no bonds, no disputes.

## Complete Resolution Flow

Everything happens on Unichain. No bridge involved.

```
                  SETUP (owner/operator/resolver)
                  ═════════════════════════════
                                  │
                                  ▼
                  Owner / Operator / Resolver group member
                                  │
                                  │  ① On Diamond:
                                  │     prepareMarket()
                                  │     openMarket()
                                  │     prepareQuestion() → returns questionId
                                  │
                                  │  ② On ChainlinkPriceResolver:
                                  │     createUpDown(questionId, ..., operatorDelay)
                                  │     createAboveThreshold(questionId, ..., operatorDelay)
                                  │     createInRange(questionId, ..., operatorDelay)
                                  │
                                  ▼
              ┌───────────────────────────────────────────┐
              │            TRADING PERIOD                 │
              │  Users place orders, market is active     │
              │  Waiting for endTime to pass...           │
              └─────────────────────┬─────────────────────┘
                                    │
                                    ▼
                    SETTLEMENT (ChainlinkPriceResolver)
                    ══════════════════════════════════
                                    │
                                    ▼
                             endTime reached
                                    │
                     ┌──────────────┴──────────────┐
                     ▼                             ▼
            ┌─────────────────┐          ┌───────────────────┐
            │ OPERATOR DELAY  │          │ NO OPERATOR       │
            │ (0 to maxDelay) │          │ DELAY (= 0)       │
            │                 │          │                   │
            │ Only operator/  │          │ Anyone can settle │
            │ owner/resolver  │          │ immediately       │
            │ can call        │          └────────┬──────────┘
            │ settleQuestion  │                   │
            │                 │                   │
            └────────┬────────┘                   │
                     │ delay expires              │
                     ▼                            │
            Anyone can call                       │
            settleQuestion()                      │
                     │                            │
                     └──────────────┬─────────────┘
                                    │
                                    │  ┌──────────────────────────────────┐
                                    │  │ NOTE: At ANY point before        │
                                    │  │ settling, operator/owner/        │
                                    │  │ resolver can cancelQuestion()    │
                                    │  │ → resets state, allows retry     │
                                    │  │ with new params                  │
                                    │  └──────────────────────────────────┘
                                    │
                                    ▼
              ┌─────────────────────────────────────────┐
              │ settleQuestion(questionId)              │
              │                                         │
              │  1. Binary search Chainlink rounds      │
              │     for target time(s)                  │
              │  2. Compute outcome (YES/NO)            │
              │  3. reportOutcome() → Diamond           │
              │     (atomic, same tx)                   │
              └─────────────────────┬───────────────────┘
                                    │
                                    ▼
                            DIAMOND RESOLUTION
                            ══════════════════
                                    │
                                    ▼
                     Diamond receives reportOutcome()
                                    │
                                    │  Records: reported=true, outcome,
                                    │  reportedAt=now
                                    │  Snapshots resolutionDelay
                                    │  (prevents retroactive shortening)
                                    │  Emits OutcomeReported
                                    │
                                    ▼
              ┌─────────────────────────────────────────┐
              │            RESOLUTION DELAY             │
              │            (default 24 hours)           │
              │                                         │
              │  resolveQuestion() blocked until delay  │
              │  expires. Delay = max(snapshotted,      │
              │  market delay, min delay).              │
              └─────────────────────┬───────────────────┘
                                    │
                                    │  Anytime before resolveQuestion()
                                    │  is called, market owner or protocol
                                    │  owner can intervene:
                                    │
                                    │  flagQuestion()
                                    │    → blocks resolution until unflagged
                                    │    → admin flags only removed by admin
                                    │
                                    │  After flag review, 3 options:
                                    │    a) unflagQuestion()
                                    │       → unblock, then resolve normally
                                    │    b) emergencyResolveQuestion()
                                    │       → override outcome, auto-clears
                                    │         flag (protocol owner only)
                                    │    c) closeMarket()
                                    │       → void ALL questions, [1,1]
                                    │         pro-rata (protocol owner only)
                                    │
                                    │  emergencyResolveQuestion() can also
                                    │  be called WITHOUT a flag
                                    │  (unconditional protocol owner override)
                                    │
                                    ▼
              ┌─────────────────────────────────────────┐
              │ resolveQuestion(questionId)             │
              │                                         │
              │  Checks: reported, not resolved,        │
              │          not flagged, delay expired     │
              │                                         │
              │  Anyone can call once all checks pass   │
              └─────────────────────┬───────────────────┘
                                    │
                                    ▼
                             FINALIZED ON CTF
                             ════════════════
                                    │
                                    ▼
                   Diamond calls CTF.reportPayouts()
                                    │
                                    │  Payouts:
                                    │  [1, 0] → YES wins
                                    │  [0, 1] → NO wins
                                    │  [1, 1] → Voided (pro-rata refund)
                                    │
                                    ▼
              ┌─────────────────────────────────────────┐
              │              REDEMPTION                 │
              │                                         │
              │  Users call RedemptionFacet to redeem   │
              │  winning positions for collateral       │
              │  (winner fee may apply)                 │
              └─────────────────────────────────────────┘
```

### Flow Summary

| Phase | Who | Action | Permissionless? |
|-------|-----|--------|-----------------|
| **Setup** | Owner / operator / resolver | Create market on Diamond + price question on Resolver | No — operator, owner, or resolver group member |
| **Trading** | Users | Place orders, trade YES/NO tokens | Yes |
| **Cancel** | Operator / owner / resolver | `cancelQuestion()` + retry — anytime before settlement | No — any operator, owner, or resolver group member |
| **Settlement** | Owner / operator / resolver → Anyone | `settleQuestion()` → reads Chainlink, reports to Diamond | After operator delay |
| **Resolution delay** | — | Waiting period (default 24h) before finalization | — |
| **Flagging** | Market/protocol owner | `flagQuestion()` to block resolution — anytime before resolved | No — owners only |
| **Resolution** | Anyone | `resolveQuestion()` on Diamond → finalizes to CTF | Yes — after delay + no flag |
| **Emergency** | Protocol owner | `emergencyResolveQuestion()` (with or without flag) or `closeMarket()` | No — protocol owner only |
| **Redemption** | Users | Redeem winning positions for collateral | Yes |

## Question Types

| Type | Example | Resolution |
|------|---------|------------|
| `UP_DOWN` | "BTC Up or Down 14:00-15:00?" | YES if endPrice >= startPrice |
| `ABOVE_THRESHOLD` | "BTC above $100k at March 31?" | YES if price >= threshold |
| `IN_RANGE` | "BTC between $95k-$100k?" | YES if lower <= price < upper |

## Contract: ChainlinkPriceResolver

### Key Functions

#### Question Creation

All creation functions share common validation: `questionId != bytes32(0)`, feed whitelisted, question not already created, `operatorDelay <= maxOperatorDelay`. Type-specific validations listed below.

- `createUpDown(questionId, feed, startTime, endTime, operatorDelay)` — Create directional market. Callable by operator, owner, or resolver group member. Validation: `startTime >= block.timestamp` and non-zero, `endTime > startTime`
- `createAboveThreshold(questionId, feed, endTime, threshold, operatorDelay)` — Create threshold market. Callable by operator, owner, or resolver group member. Validation: `threshold > 0`, `endTime > block.timestamp`
- `createInRange(questionId, feed, endTime, lowerBound, upperBound, operatorDelay)` — Create range market. Callable by operator, owner, or resolver group member. Validation: `lowerBound >= 0`, `upperBound > lowerBound`, `endTime > block.timestamp`

#### Settlement

- `settleQuestion(questionId)` — Settle via on-chain binary search across Chainlink phase history, compute outcome, and report to Diamond in one atomic transaction. During `operatorDelay` window after `endTime`, only operator/owner/resolver can call. After the delay, anyone can call. Protected by `nonReentrant`
- `checkUpkeep(checkData)` / `performUpkeep(performData)` — Chainlink Automation compatible (auto-settle after operator delay expires). `performUpkeep` is callable by anyone (not just Keepers) and protected by `nonReentrant`. Note: `checkUpkeep` iterates all pending questions — O(n) gas, may hit limits with large queues

#### Question Management

- `cancelQuestion(questionId)` — Cancel a question and allow retry with the same questionId. Resets all state via `delete`. Callable by owner, any authorized operator, or resolver group member assigned to the question. Does NOT call `diamond.reportOutcome()` — if no retry is performed, the market must be settled through an alternative path

#### View Functions

- `getQuestion(questionId)` — Returns the full `PriceQuestion` struct for a given questionId
- `isResolved(questionId)` — Returns `true` if the question has been settled
- `canResolve(questionId)` — Returns `true` if feed is set, not resolved, and `endTime` has passed. **Note:** does not account for `operatorDelay` — may return `true` even when `settleQuestion()` would revert for non-privileged callers during the delay window
- `getPendingCount()` — Number of unresolved questions

#### Feed Management (owner-only)

- `addFeed(feed)` — Whitelist a Chainlink price feed. Reverts if `feed == address(0)`. Idempotent — calling twice with the same feed succeeds (no-op, emits event again)
- `removeFeed(feed)` — Remove a feed from the whitelist. Only affects future question creation — existing questions with the removed feed can still be settled. No zero-address check. Emits event even if feed was not previously whitelisted

#### Operator Management (owner-only)

- `addOperator(operator)` — Authorize a new operator. Reverts if already authorized
- `removeOperator(operator)` — Revoke operator authorization. Reverts if not currently authorized

#### Resolver Group Management

- `setResolverGroup(groupId, members[], authorized)` — Add or remove members from a resolver group. Callable by owner or any operator. `groupId` must not be `bytes32(0)`, members must not be `address(0)`
- `assignQuestionGroup(questionId, groupId)` — Assign a resolver group to a question. Callable by owner or any operator. Pass `bytes32(0)` to unassign. Note: does not validate that the questionId exists — groups can be pre-assigned before question creation

#### Configuration (owner-only)

- `setDiamond(address)` — Update Diamond proxy address. Reverts if `address(0)`
- `setMaxOperatorDelay(maxDelay)` — Update the maximum operator delay operators can set per question. Does not affect existing questions
- `setMaxStaleness(maxStaleness)` — Update the maximum allowed price staleness. **Warning:** retroactively affects all pending questions — lowering this value may cause in-flight settlements to revert with `StalePriceData`

#### Ownership (two-step transfer)

- `proposeOwner(newOwner)` — Propose a new owner (owner-only). Reverts if `address(0)`
- `acceptOwnership()` — Accept ownership (must be called by the proposed owner)

### Constructor

```solidity
ChainlinkPriceResolver(
    address _diamond,           // Diamond proxy on Unichain
    uint256 _maxStaleness,      // Max allowed price staleness (e.g., 3600 = 1 hour)
    uint64 _maxOperatorDelay,   // Max operator delay operators can set per question (e.g., 3600 = 1 hour)
    address _owner,             // Contract owner
    address _operator           // Initial authorized operator
)
```

**Constructor validation:** `_diamond`, `_owner`, and `_operator` must not be `address(0)` (reverts `ZeroAddress`). `_maxStaleness` must not be 0 (reverts `StalePriceData`). `_maxOperatorDelay` can be 0 (disables operator delay for new questions).

## Resolver Groups

Resolver groups are reusable, named sets of addresses that can be assigned to questions. Members of a question's assigned resolver group gain the same authorization as operators for that specific question — they can create, settle (during operator delay), and cancel it.

### How It Works

1. **Create a group**: Owner or operator calls `setResolverGroup(groupId, members, true)` to add members
2. **Assign to question**: Owner or operator calls `assignQuestionGroup(questionId, groupId)` to link a group
3. **Members act**: Group members can now `create*`, `settleQuestion` (during delay), and `cancelQuestion` for that question
4. **Modify membership**: Call `setResolverGroup(groupId, members, false)` to revoke — changes apply instantly to all linked questions
5. **Unassign**: Call `assignQuestionGroup(questionId, bytes32(0))` to remove group access

### Key Properties

- Groups are identified by `bytes32 groupId` — reusable across multiple questions
- `bytes32(0)` is the sentinel value meaning "no group assigned"
- Multiple questions can share the same group
- Membership changes apply instantly to all questions linked to that group
- Groups can be pre-assigned to a questionId before the question is created

## Resolution Methods

| Method | Gas | Off-chain needed? | Trigger |
|--------|-----|-------------------|---------|
| `settleQuestion()` binary search | ~52k gas (~20 reads) | No — fully on-chain | Manual (anyone) |
| `performUpkeep()` via Chainlink Automation | ~52k gas (~20 reads) | No — Chainlink Keepers auto-trigger | Automatic |

Both methods use timestamp-based settlement — prices are read from Chainlink historical rounds via binary search across phase history, not at question creation time. Both are protected by OpenZeppelin's `ReentrancyGuard` (`nonReentrant` modifier). `performUpkeep()` is callable by anyone (not just Chainlink Keepers) — the operator delay check in the shared internal settlement logic is the only access control.

**Chainlink Automation:** The contract implements `checkUpkeep()` and `performUpkeep()` for Chainlink Automation compatibility. When registered as an upkeep, Chainlink Keepers automatically call `performUpkeep()` when any pending question is ready to settle (after the operator delay expires). Note: `checkUpkeep()` iterates all pending questions in an O(n) loop — with a very large pending queue this may exceed gas limits for Keeper simulations. Chainlink Automation is not yet available on Unichain — the interface is ready for when it launches.

## Usage Flow

### 1. Create market + question on Diamond (Unichain)

```solidity
// Market creator calls on Diamond (ChainlinkPriceResolver must be the market's oracle)
MarketManagementFacet(diamond).prepareMarket(...);
SetupFacet(diamond).openMarket(...);
MarketManagementFacet(diamond).prepareQuestion(...);
// Returns questionId
```

### 2. Create price question on ChainlinkPriceResolver (Unichain)

```solidity
// Up/Down market: "BTC Up or Down between 14:00-15:00 UTC?"
priceResolver.createUpDown(questionId, btcUsdFeed, startTime, endTime, 1800); // 30min operator delay

// Threshold market: "BTC above $100k at end of March?"
priceResolver.createAboveThreshold(questionId, btcUsdFeed, endTime, 100_000e8, 1800);

// Range market: "BTC between $95k-$100k?"
priceResolver.createInRange(questionId, btcUsdFeed, endTime, 95_000e8, 100_000e8, 1800);

// No operator delay (permissionless immediately):
priceResolver.createUpDown(questionId, btcUsdFeed, startTime, endTime, 0);
```

### 3. Settle after end time

```solidity
// During operator delay window — only operator/owner/resolver can settle
priceResolver.settleQuestion(questionId);

// After operator delay expires — anyone can call
priceResolver.settleQuestion(questionId);

// If something is wrong — cancel and retry (operator/owner/resolver)
priceResolver.cancelQuestion(questionId);
priceResolver.createUpDown(questionId, correctFeed, startTime, endTime, 1800);
```

### 4. Finalize on Diamond (anyone can call, after resolution delay)

```solidity
ResolutionFacet(diamond).resolveQuestion(questionId);
```

## Resolution Timeline

| Step | Duration | Cost |
|------|----------|------|
| Create price question | 1 tx | ~$0.01 gas |
| Time range passes | Configurable (5min to weeks) | — |
| Operator review window | Configurable (0 to `maxOperatorDelay`) | — |
| Settle (binary search) | 1 tx | ~$0.01-0.05 gas |
| Diamond resolution delay | 24 hours | — |
| Finalize | 1 tx | ~$0.01 gas |
| **Total** | **~24 hours + time range + operator delay** | **~$0.03-0.07** |

## Roles & Permissions

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `addFeed`, `removeFeed`, `setMaxStaleness`, `setMaxOperatorDelay`, `setDiamond`, `cancelQuestion`, `addOperator`, `removeOperator`, `proposeOwner`, `acceptOwnership`, `setResolverGroup`, `assignQuestionGroup`, all create/settle functions |
| **Operator(s)** | Whitelisted market creators | `createUpDown`, `createAboveThreshold`, `createInRange`, `cancelQuestion` (any question), `settleQuestion` (during operator delay window), `setResolverGroup`, `assignQuestionGroup` |
| **Resolver group** | Per-question authorized members | `createUpDown`, `createAboveThreshold`, `createInRange`, `cancelQuestion`, `settleQuestion` (during operator delay window) — only for questions assigned to their group |
| **Anyone** | Public | `settleQuestion` (after operator delay), `performUpkeep` (after operator delay), `checkUpkeep`, `canResolve`, `getQuestion`, `isResolved`, `getPendingCount` |
| **Chainlink Automation** | Chainlink Keepers (when available) | `checkUpkeep` (off-chain), `performUpkeep` (on-chain, after operator delay) |

## Security Model

- **Feed whitelist** — only approved Chainlink feeds can be used for price questions. Removing a feed only blocks future question creation; existing questions with the removed feed can still be settled
- **Stale price protection** — reverts if Chainlink price data is older than `maxStaleness` from the target time. Note: `setMaxStaleness` applies retroactively to all pending questions
- **Binary search settlement** — `settleQuestion()` uses O(log n) binary search across Chainlink phase history to find the closest round to each target timestamp, handling phase transitions automatically
- **Price validation** — checks positivity (`answer > 0`), completeness (`updatedAt != 0`), and staleness before settling
- **Double-settle prevention** — each question can only be settled once
- **Reentrancy protection** — `settleQuestion` and `performUpkeep` are protected by OpenZeppelin's `ReentrancyGuard` (`nonReentrant` modifier), in addition to following the CEI (checks-effects-interactions) pattern — state is set before the external call to Diamond
- **Operator delay** — configurable per-question delay after `endTime` during which only the operator/owner/resolver group can settle, giving time to review feed data and cancel if needed. After the delay, settlement becomes permissionless
- **Question cancellation with retry** — owner, any authorized operator, or resolver group member can cancel via `cancelQuestion()`. Uses `delete` to fully reset state, allowing re-creation with the same `questionId` and corrected parameters (different feed, timestamps, thresholds). Does not call `diamond.reportOutcome()`
- **Input validation** — all creation functions validate: `questionId != bytes32(0)`, feed whitelisted, question not already created, time constraints, `operatorDelay <= maxOperatorDelay`. Type-specific: UP_DOWN requires `startTime` in the future; ABOVE_THRESHOLD requires `threshold > 0`; IN_RANGE requires `lowerBound >= 0` and `upperBound > lowerBound`
