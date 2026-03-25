# UMA Oracle

Submits prediction market questions to UMA's Optimistic Oracle V3 for decentralized resolution on **Polygon**. Uses the `ASSERT_TRUTH2` identifier. Results are relayed cross-chain to the Diamond on Unichain via LayerZero V2 (automatic) or an off-chain relayer (manual).

## Complete Resolution Flow

Cross-chain: Polygon (UMA) → LayerZero → Unichain (Diamond).

```
                       SETUP (owner/operator/resolver)
                       ═══════════════════════════════
                                    │
                                    ▼
                      Authorized caller (market creator)
                                    │
                                    │  ① On Diamond (Unichain):
                                    │     prepareMarket()
                                    │     openMarket()
                                    │     prepareQuestion() → returns questionId
                                    │
                                    │  ② On UmaOracleAdapter (Polygon):
                                    │     USDC.approve(adapter, bondAmount)
                                    │     initializeQuestion(questionId, claim,
                                    │       bond, liveness, operatorDelay)
                                    │     → submits assertion to UMA OOv3
                                    │     → bond transferred: caller → adapter → UMA
                                    │
                                    ▼
              ┌──────────────────────────────────────────┐
              │            TRADING PERIOD                │
              │  Users place orders on Diamond (Unichain)│
              │  UMA challenge window running (Polygon)  │
              └─────────────────────┬────────────────────┘
                                    │
                                    ▼
                       UMA CHALLENGE WINDOW (Polygon)
                       ══════════════════════════════
                                    │
                                    ▼
              Liveness period (default 2 hours)
              Anyone can dispute the assertion during this window.
                                    │
                     ┌──────────────┴───────────────┐
                     ▼                              ▼
            ┌─────────────────┐          ┌───────────────────┐
            │ NO DISPUTE      │          │ DISPUTED          │
            │ (normal ~99%)   │          │ (rare)            │
            │                 │          │                   │
            │ Liveness expires│          │ UMA calls         │
            │ with no         │          │ assertionDisputed-│
            │ challenge.      │          │ Callback() on     │
            │                 │          │ adapter (event    │
            │ Assertion is    │          │ only, no state    │
            │ accepted, but   │          │ change)           │
            │ does NOT auto-  │          │                   │
            │ settle. Someone │          │ Escalates to UMA  │
            │ must call       │          │ DVM (token vote)  │
            │ settleQuestion()│          │                   │
            │ to trigger it.  │          │ DVM rules:        │
            │                 │          │  Truthful →       │
            │ Bond: returned  │          │   asserter wins   │
            │ to asserter     │          │   disputer's bond │
            │                 │          │  Not truthful →   │
            │                 │          │   disputer wins   │
            │                 │          │   asserter's bond │
            │                 │          │                   │
            │                 │          │ UMA calls         │
            │                 │          │ assertionResolved-│
            │                 │          │ Callback() with   │
            │                 │          │ DVM verdict       │
            └────────┬────────┘          └────────┬──────────┘
                     │                            │
                     └──────────────┬─────────────┘
                                    │
                                    │  ┌──────────────────────────────────┐
                                    │  │ NOTE: Only if not yet resolved,  │
                                    │  │ liveness not expired, and no     │
                                    │  │ active dispute — owner/operator/ │
                                    │  │ resolver can                     │
                                    │  │ cancelQuestion() → resets adapter│
                                    │  │ state. UMA assertion continues   │
                                    │  │ independently, bond recovered    │
                                    │  │ via reclaimBond() after UMA      │
                                    │  │ settles. Callbacks return        │
                                    │  │ gracefully for cancelled         │
                                    │  │ questions (no revert).           │
                                    │  └──────────────────────────────────┘
                                    │
                                    ▼
                           SETTLEMENT (Polygon)
                           ════════════════════
                                    │
                                    ▼
                     liveness expired (or DVM resolved)
                                    │
                     ┌──────────────┴───────────────┐
                     ▼                              ▼
            ┌─────────────────┐          ┌───────────────────┐
            │ OPERATOR DELAY  │          │ NO OPERATOR       │
            │ (0 to liveness) │          │ DELAY (= 0)       │
            │                 │          │                   │
            │ Only operator/  │          │ Anyone can settle │
            │ owner/resolver  │          │ immediately       │
            │ can settle      │          └────────┬──────────┘
            │                 │                   │
            └────────┬────────┘                   │
                     │ delay expires              │
                     ▼                            │
            Anyone can call                       │
            settleQuestion()                      │
                     │                            │
                     └──────────────┬─────────────┘
                                    │
                                    ▼
              ┌──────────────────────────────────────────┐
              │ settleQuestion(questionId)               │
              │                                          │
              │  1. Calls UMA OOv3.settleAssertion()     │
              │  2. UMA calls assertionResolvedCallback()│
              │     on adapter → callback stores outcome:│
              │       truthful = YES wins                │
              │       not truthful = NO wins             │
              │     (duplicate callbacks emit            │
              │      DuplicateCallbackIgnored & return)  │
              │  3. Bond returned to winner by UMA       │
              └─────────────────────┬────────────────────┘
                                    │
                                    ▼
                  CROSS-CHAIN RELAY (Polygon → Unichain)
                  ══════════════════════════════════════
                                    │
                                    ▼
                Settlement and relay are TWO SEPARATE TXs.
                This prevents front-runners from blocking relay.
                                    │
                     ┌──────────────┴───────────────┐
                     ▼                              ▼
            ┌─────────────────┐          ┌───────────────────┐
            │ AUTOMATIC       │          │ MANUAL            │
            │ (LayerZero)     │          │ (off-chain)       │
            │                 │          │                   │
            │ quoteCrossChain │          │ Off-chain relayer │
            │ Fee() → LZ fee  │          │ watches           │
            │                 │          │ QuestionResolved  │
            │ relayResolved   │          │ events and calls  │
            │ {value: fee}    │          │ BridgeReceiver    │
            │ (questionId)    │          │ .relayOracleAnswer│
            │                 │          │ () on Unichain    │
            │ Anyone can call │          │                   │
            │ (payable)       │          │ No relayResolved  │
            │                 │          │ call needed       │
            └────────┬────────┘          └────────┬──────────┘
                     │                            │
                     └──────────────┬─────────────┘
                                    │
                                    ▼
              ┌──────────────────────────────────────────┐
              │ Relay chain (both modes end here):       │
              │                                          │
              │  1. LzCrossChainReceiver or relayer      │
              │     → BridgeReceiver routes by requestId:│
              │     a) requestId ≠ 0:                    │
              │        relayOracleAnswer() → Diamond     │
              │        .registerOracleRequest()          │
              │        .reportPayouts()                  │
              │     b) requestId = 0:                    │
              │        relayOutcome() → Diamond          │
              │        .reportOutcome()                  │
              │  2. Double-relay prevention at TWO       │
              │     layers: relayed[] in adapter AND     │
              │     relayed[] in BridgeReceiver          │
              └─────────────────────┬────────────────────┘
                                    │
                                    │  ┌──────────────────────────────────┐
                                    │  │ If LZ relay fails, LzCrossChain  │
                                    │  │ Receiver stores it in _failed    │
                                    │  │ Relays[]. Self-heals by retrying │
                                    │  │ ONE failed entry per incoming LZ │
                                    │  │ message (round-robin). Owner can │
                                    │  │ also retryFailedRelay() / remove │
                                    │  │ FailedRelay() manually           │
                                    │  └──────────────────────────────────┘
                                    │
                                    ▼
                      DIAMOND RESOLUTION (Unichain)
                      ═════════════════════════════
                                    │
                                    ▼
                    Diamond receives reportPayouts()
                    or reportOutcome() (see relay routing)
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

| Phase | Who | Where | Action | Permissionless? |
|-------|-----|-------|--------|-----------------|
| **Setup** | Operator/owner/resolver | Unichain + Polygon | Create market on Diamond + submit assertion to UMA (with bond) | No — authorized callers only |
| **Trading** | Users | Unichain | Place orders, trade YES/NO tokens | Yes |
| **UMA challenge** | Anyone | Polygon | Dispute the assertion (bond escalation → DVM). Bond goes to winner | Yes |
| **Cancel** | Owner/operator/resolver | Polygon | `cancelQuestion()` + retry — only if not yet resolved, liveness not expired, and no active dispute. Callbacks return gracefully. Bond recovered via `reclaimBond()` | No — authorized callers only |
| **Settlement** | Owner/operator/resolver → Anyone | Polygon | `settleQuestion()` → calls UMA `settleAssertion()` → triggers `assertionResolvedCallback()` which stores outcome | After operator delay |
| **Relay (auto)** | Anyone | Polygon → Unichain | `quoteCrossChainFee()` then `relayResolved()` → LayerZero → BridgeReceiver → Diamond | Yes (pays LZ fee) |
| **Relay (manual)** | Relayer | Polygon → Unichain | Off-chain relayer watches events → calls `BridgeReceiver.relayOracleAnswer()` directly | No — whitelisted relayer |
| **Resolution delay** | — | Unichain | Waiting period (default 24h) before finalization | — |
| **Flagging** | Market/protocol owner | Unichain | `flagQuestion()` to block resolution — anytime before resolved | No — owners only |
| **Resolution** | Anyone | Unichain | `resolveQuestion()` on Diamond → finalizes to CTF | Yes — after delay + no flag |
| **Emergency** | Protocol owner | Unichain | `emergencyResolveQuestion()` (with or without flag) or `closeMarket()` | No — protocol owner only |
| **Redemption** | Users | Unichain | Redeem winning positions for collateral | Yes |

## Contract: UmaOracleAdapter

### Key Functions

#### Lifecycle

- `initializeQuestion(questionId, claim, bond, liveness, operatorDelay)` → `bytes32 assertionId` — Submit a question to UMA. Callable by owner, any operator, or resolver group member (`NotQuestionAuthorized`). Reverts if: `questionId` is `bytes32(0)` (`InvalidQuestionId`), `claim` is empty (`EmptyClaimData`), question already initialized (`QuestionAlreadyInitialized`), bond below UMA minimum (`BondBelowMinimum`), liveness below `minLiveness` (`LivenessTooShort`), or `operatorDelay > liveness` (`DelayTooLong`). Bond is transferred from caller → adapter → UMA. Returns the UMA assertion ID
- `settleQuestion(questionId)` — Triggers UMA's `settleAssertion()`, which calls back `assertionResolvedCallback()` to store the outcome (not payable). Reverts if: question not initialized (`QuestionNotInitialized`), already resolved (`QuestionAlreadyResolved`), or caller unauthorized during operator delay window (`OperatorWindowActive`). During `operatorDelay` window after liveness expires, only owner/operator/resolver can call. After the delay, anyone can call
- `relayResolved(questionId)` — Relay an already-settled question cross-chain via LayerZero (anyone can call, payable). Must be called separately after `settleQuestion()`. Reverts if: question not initialized (`QuestionNotInitialized`), not yet resolved (`QuestionNotResolved`), already relayed (`QuestionAlreadyRelayed`), relay not configured (`RelayNotConfigured`), or `msg.value == 0` (`InsufficientRelayFee`)
- `cancelQuestion(questionId)` — Cancel a question and allow retry with the same questionId. Callable by owner, any operator, or resolver group member. Reverts if: question not initialized (`QuestionNotInitialized`), already resolved (`QuestionAlreadyResolved`), caller unauthorized (`NotQuestionAuthorized`), under active UMA dispute (`CannotCancelDisputedQuestion`), or liveness already expired (`CannotCancelExpiredAssertion`). Deletes question state but tracks the old assertion in `cancelledAssertions[]` for bond recovery
- `reclaimBond(index)` — Settle a cancelled assertion on UMA to recover the asserter's bond (permissionless). Reverts if `index` is out of bounds (`IndexOutOfBounds`). Uses swap-and-pop on the `cancelledAssertions[]` array. Safe to call even if UMA already settled the assertion externally

#### UMA Callbacks

- `assertionResolvedCallback(assertionId, assertedTruthfully)` — UMA callback, stores the result. Returns gracefully (no revert) for cancelled/unknown assertions to prevent blocking UMA settlement and bond recovery. Emits `DuplicateCallbackIgnored` if called twice for the same assertion
- `assertionDisputedCallback(assertionId)` — Handles disputes (escalates to UMA DVM). Returns gracefully for cancelled/unknown assertions

#### View Functions

- `quoteCrossChainFee(questionId)` — Estimate LayerZero fee for cross-chain relay. Returns 0 if relay not configured or question not initialized
- `getQuestion(questionId)` — Returns the full `QuestionData` struct for a question
- `isResolved(questionId)` — Returns whether a question has been resolved
- `getQuestionByAssertion(assertionId)` — Reverse lookup: assertion ID → question ID
- `cancelledAssertionsCount()` — Returns the number of cancelled assertions pending bond recovery

#### Resolver Group Management

- `setResolverGroup(groupId, members, authorized)` — Add or remove members from a named resolver group (owner or operator only). Reverts if `groupId` is `bytes32(0)` (`ZeroGroupId`) or any member is `address(0)` (`ZeroAddress`)
- `assignQuestionGroup(questionId, groupId)` — Assign a resolver group to a question, granting its members initialize/settle/cancel rights (owner or operator only)

### Constructor

```solidity
UmaOracleAdapter(
    address _oov3,          // UMA OOv3 address on Polygon
    address _bondCurrency,  // Bond token (e.g., USDC)
    uint256 _defaultBond,   // Default bond amount (e.g., 250e6 = 250 USDC)
    uint64 _defaultLiveness,// Default challenge window (e.g., 7200 = 2 hours)
    uint64 _minLiveness,    // Minimum allowed liveness (e.g., 1800 = 30 minutes)
    address _owner,         // Contract owner
    address _operator       // Initial authorized operator
)
```

**Validations:** Reverts if any address is `address(0)`, if `_defaultBond == 0`, or if `_defaultLiveness < _minLiveness`. Sets `isOperator[_operator] = true`.

## Usage Flow

### 1. Create market + question on Diamond (Unichain)

```solidity
// Market creator calls on Diamond (BridgeReceiver must be the market's oracle)
MarketManagementFacet(diamond).prepareMarket(...);
SetupFacet(diamond).openMarket(...);
MarketManagementFacet(diamond).prepareQuestion(...);
// Returns questionId
```

### 2. Submit to UMA (Polygon) — owner/operator/resolver

```solidity
// Approve bond
USDC.approve(adapter, 250e6);

// Submit assertion
adapter.initializeQuestion(
    questionId,
    "q: title: Will BTC hit $100k before April 2026? "
    "description: Resolves YES if Bitcoin reaches $100,000 USD on any major exchange "
    "(Binance, Coinbase, Kraken) before April 1, 2026 00:00 UTC. "
    "res_data: p1: 0, p2: 1, p3: 0.5. "
    "Where p1 corresponds to YES, p2 to No, p3 to unknown/ambiguous.",
    0,    // use default bond (250 USDC)
    0,    // use default liveness (2 hours)
    1800  // 30min operator delay before permissionless settlement
);
```

### 3. Settle locally

```solidity
// During operator delay window — only owner/operator/resolver can settle
adapter.settleQuestion(questionId);

// After operator delay expires — anyone can call
adapter.settleQuestion(questionId);

// If something is wrong — cancel and retry (owner/operator/resolver only)
// Note: cannot cancel after liveness expires or during active UMA dispute
adapter.cancelQuestion(questionId);
// Bond from cancelled assertion can be recovered later (permissionless)
adapter.reclaimBond(0);
// Re-initialize with corrected parameters
adapter.initializeQuestion(questionId, correctedClaim, bond, liveness, operatorDelay);
```

### 4. Relay cross-chain (anyone can call, separate step)

```solidity
// Quote the LayerZero fee
uint256 fee = adapter.quoteCrossChainFee(questionId);

// Relay the settled result to Unichain via LayerZero
adapter.relayResolved{value: fee}(questionId);
```

Settlement and relay are **two separate transactions** by design. This prevents a front-runner from calling `settleQuestion()` and permanently blocking cross-chain delivery. During the operator delay window, only the owner/operator/resolver can settle — giving time to review the oracle answer and cancel if needed. If LayerZero relay is not needed (manual relayer mode), skip `relayResolved()` entirely.

### 5. Finalize on Diamond (anyone can call, after resolution delay)

```solidity
ResolutionFacet(diamond).resolveQuestion(questionId);
```

## Resolution Timeline

| Step | Duration | Cost |
|------|----------|------|
| Submit to UMA | 1 tx | ~$0.01 gas + bond (returned) |
| UMA challenge window | 2 hours | — |
| Operator review window | Configurable (0 to liveness) | — |
| Settle locally | 1 tx | ~$0.01 gas |
| Relay via LayerZero | 1 tx | ~$0.01 gas + ~$0.10-0.50 LZ fee |
| LayerZero delivery | ~2-5 min | — |
| Diamond resolution delay | 24 hours | — |
| Finalize | 1 tx | ~$0.01 gas |
| **Total** | **~26 hours + operator delay** | **~$0.15-0.55** |

## Bond Economics

The bond is paid by the **caller** of `initializeQuestion()` (owner, operator, or resolver). The caller is recorded as the question's `creator` and receives the bond back if not disputed.

| Scenario | Frequency | Cost to caller |
|----------|-----------|-----------------|
| No dispute (normal) | ~99% | Gas only (bond returned) |
| Dispute — asserter was right | Rare | Gas only (win disputer's bond) |
| Dispute — asserter was wrong | Rare | Loses bond |
| Dispute — escalates to DVM | Extremely rare | ~$150 final fee (Polygon) |

Recommended bond: **250 USDC**.

## Roles & Permissions

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `setDefaultBond`, `setDefaultLiveness`, `setMinLiveness`, `setCrossChainRelay`, `addOperator`, `removeOperator`, `proposeOwner`, `setResolverGroup`, `assignQuestionGroup`. Also: `initializeQuestion`, `cancelQuestion`, `settleQuestion` (during operator delay) |
| **Proposed Owner** | Address proposed by owner | `acceptOwnership` (completes two-step ownership transfer) |
| **Operator(s)** | Whitelisted market creators | `initializeQuestion` (must provide bond), `cancelQuestion` (any question, not just own), `settleQuestion` (during operator delay), `setResolverGroup`, `assignQuestionGroup` |
| **Resolver(s)** | Members of a question's assigned resolver group | `initializeQuestion`, `cancelQuestion`, `settleQuestion` (during operator delay) — scoped to questions with their group assigned |
| **Anyone** | Public | `settleQuestion` (after operator delay, not payable), `relayResolved` (payable, pays LZ fee), `quoteCrossChainFee`, `reclaimBond`, view functions |
| **UMA OOv3** | UMA contract | `assertionResolvedCallback`, `assertionDisputedCallback` |

## Security Model

- **Minimum liveness** — enforces a floor on the UMA challenge window, preventing dangerously short dispute periods
- **Minimum bond** — enforced by UMA's `getMinimumBond()`, ensuring economic security
- **Operator delay** — configurable per-question delay after oracle finalization during which only the owner/operator/resolver can settle. Anchored to UMA's `expirationTime`. Gives the operator time to review the oracle answer and cancel if needed. After the delay, settlement becomes permissionless. Max delay capped at the oracle's own liveness
- **Question cancellation with retry** — owner, any operator, or resolver group member can cancel via `cancelQuestion()`. Two hard guards prevent abuse: `CannotCancelDisputedQuestion` (blocks cancellation during active UMA dispute) and `CannotCancelExpiredAssertion` (blocks cancellation after liveness expires without dispute). Deletes question state and clears reverse mappings (`assertionToQuestion`), but tracks the old assertion in `cancelledAssertions[]` and `cancelledAssertionQuestion[]` for bond recovery via `reclaimBond()`. Allows re-initialization with the same `questionId` and corrected parameters
- **Bond recovery** — `reclaimBond(index)` is permissionless. Settles cancelled assertions on UMA (via try/catch for already-settled ones) and removes them from the tracking array via swap-and-pop
- **Graceful UMA callbacks** — `assertionResolvedCallback` and `assertionDisputedCallback` return silently (no revert) for cancelled/unknown assertions. This prevents blocking UMA's `settleAssertion`, ensuring bonds are always returned to the asserter after cancellation. Includes an `assertionId` mismatch guard for cancel + re-init scenarios. Duplicate callbacks for already-resolved questions emit `DuplicateCallbackIgnored` and return
- **Decoupled settlement and relay** — `settleQuestion()` triggers UMA settlement (not payable), `relayResolved()` sends cross-chain (payable). This two-step design prevents a front-runner from permanently blocking relay by calling settle first
- **Double-relay prevention** — Defense-in-depth: `relayed[questionId]` is checked in both `UmaOracleAdapter.relayResolved()` and `BridgeReceiver.relayOracleAnswer()`/`relayOutcome()`
- **Relay validation** — `relayResolved()` reverts if `crossChainRelay` is not configured (`address(0)`) or if no `msg.value` is provided, preventing stuck MATIC
- **Liveness consistency** — `defaultLiveness` >= `minLiveness`, enforced in constructor and setters
- **No pause mechanism** — The adapter has no emergency pause. All functions remain callable if access control passes. Emergency intervention is handled at the Diamond layer (maintenance mode, flagging, emergency resolution)
