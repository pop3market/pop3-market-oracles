# 03 — Events Infrastructure

> Complete event reference for the Pop3 Market Oracle suite.
> Use this spec to build indexers, subgraphs, and analytics pipelines.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Enums in Events](#2-enums-in-events)
3. [UmaOracleAdapter Events](#3-umaoracleadapter-events)
4. [ChainlinkPriceResolver Events](#4-chainlinkpriceresolver-events)
5. [LzCrossChainSender Events](#5-lzcrosschainsender-events)
6. [LzCrossChainReceiver Events](#6-lzcrosschainreceiver-events)
7. [BridgeReceiver Events](#7-bridgereceiver-events)
8. [Shared Event Patterns](#8-shared-event-patterns)
9. [Event Flows by Lifecycle](#9-event-flows-by-lifecycle)
10. [Indexer Guidelines](#10-indexer-guidelines)

---

## 1. Overview

The oracle suite consists of 5 contracts deployed across two chains:

| Chain | Contract | Role |
|-------|----------|------|
| Polygon | `UmaOracleAdapter` | Assertion-based resolution via UMA Optimistic Oracle V3 |
| Polygon | `LzCrossChainSender` | Sends resolved answers to Unichain via LayerZero V2 |
| Unichain | `LzCrossChainReceiver` | Receives answers from Polygon, forwards to BridgeReceiver |
| Unichain | `BridgeReceiver` | Trusted relay that forwards answers to the Diamond (`relayOracleAnswer` → `registerOracleRequest` + `reportPayouts`; `relayOutcome` → `reportOutcome`) |
| Unichain | `ChainlinkPriceResolver` | Automated price-based settlement via Chainlink feeds |

**Total protocol-defined events: 50**

### Key Identifiers

| ID | Type | Description |
|---|---|---|
| `questionId` | `bytes32` | Pop3 market question identifier |
| `requestId` | `bytes32` | Diamond-side oracle request ID |
| `assertionId` | `bytes32` | UMA assertion identifier |
| `groupId` | `bytes32` | Resolver group identifier |
| `guid` | `bytes32` | LayerZero message GUID |
| `dstEid` / `srcEid` | `uint32` | LayerZero endpoint IDs |

---

## 2. Enums in Events

### QuestionType (ChainlinkPriceResolver)

```solidity
enum QuestionType {
    UP_DOWN,          // 0 — YES if endPrice >= startPrice
    ABOVE_THRESHOLD,  // 1 — YES if price >= threshold at endTime
    IN_RANGE          // 2 — YES if lowerBound <= price < upperBound at endTime
}
```

---

## 3. UmaOracleAdapter Events

**Source:** `src/UmaOracleAdapter.sol` — Polygon
**Integration:** UMA Optimistic Oracle V3

### Question Lifecycle

#### QuestionInitialized

Emitted when a new question is submitted to UMA as an assertion.

```solidity
event QuestionInitialized(
    bytes32 indexed questionId,
    bytes32 indexed assertionId,
    address indexed asserter,
    bytes    claim,
    uint256  bond,
    uint64   liveness,
    uint64   operatorDelay
);
```

**Emitted by:** `initializeQuestion()`

#### QuestionSettled

Emitted when the UMA assertion is settled (liveness expired without dispute, or DVM verdict received after dispute).

```solidity
event QuestionSettled(
    bytes32 indexed questionId,
    bytes32 indexed assertionId,
    address indexed settler
);
```

**Emitted by:** `settleQuestion()`

#### QuestionResolved

Emitted when the resolved outcome is recorded in the adapter's state.

```solidity
event QuestionResolved(
    bytes32 indexed questionId,
    bytes32 indexed assertionId,
    bool     outcome,
    address indexed resolver
);
```

**Emitted by:** `assertionResolvedCallback()`

#### QuestionDisputed

Emitted when a UMA assertion is disputed (escalated to UMA DVM).

```solidity
event QuestionDisputed(
    bytes32 indexed questionId,
    bytes32 indexed assertionId
);
```

**Emitted by:** `assertionDisputedCallback()`

#### QuestionCancelled

Emitted when a question is cancelled by the creator or an operator.

```solidity
event QuestionCancelled(
    bytes32 indexed questionId,
    bytes32 indexed assertionId,
    address indexed canceller,
    address  creator
);
```

**Emitted by:** `cancelQuestion()`

#### QuestionRelayed

Emitted when the resolved answer is forwarded to the cross-chain relay.

```solidity
event QuestionRelayed(
    bytes32 indexed questionId,
    bytes32 indexed assertionId,
    bool     outcome,
    address indexed relayer
);
```

**Emitted by:** `relayResolved()`

### Cancelled Assertion Callbacks

#### CancelledAssertionSettled

Emitted when an assertion callback fires for an already-cancelled question.

```solidity
event CancelledAssertionSettled(
    bytes32 indexed assertionId,
    bytes32 indexed questionId,
    bool     assertedTruthfully
);
```

**Emitted by:** `assertionResolvedCallback()`

#### CancelledAssertionDisputed

```solidity
event CancelledAssertionDisputed(
    bytes32 indexed assertionId,
    bytes32 indexed questionId
);
```

**Emitted by:** `assertionDisputedCallback()`

#### DuplicateCallbackIgnored

Emitted when UMA sends a duplicate resolved callback (already processed).

```solidity
event DuplicateCallbackIgnored(
    bytes32 indexed assertionId,
    bytes32 indexed questionId
);
```

**Emitted by:** `assertionResolvedCallback()`

### Bond Management

#### BondReclaimed

Emitted when the asserter's bond is reclaimed after settlement.

```solidity
event BondReclaimed(
    bytes32 indexed assertionId,
    bytes32 indexed questionId,
    address indexed caller,
    bool     settledByUs
);
```

**Emitted by:** `reclaimBond()`

### Configuration

```solidity
event DefaultBondUpdated(uint256 oldBond, uint256 newBond, address indexed caller);
event DefaultLivenessUpdated(uint64 oldLiveness, uint64 newLiveness, address indexed caller);
event MinLivenessUpdated(uint64 oldMinLiveness, uint64 newMinLiveness, address indexed caller);
event CrossChainRelayUpdated(address indexed previousRelay, address indexed newRelay, address indexed caller);
event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);
event ResolverGroupUpdated(bytes32 indexed groupId, address indexed member, bool authorized, address indexed caller);
event QuestionGroupAssigned(bytes32 indexed questionId, bytes32 indexed groupId, address indexed caller, bytes32 previousGroupId);
```

### Ownership

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## 4. ChainlinkPriceResolver Events

**Source:** `src/ChainlinkPriceResolver.sol` — Unichain
**Integration:** Chainlink Aggregator V3 price feeds

### Question Lifecycle

#### PriceQuestionCreated

Emitted when a new price-based question is registered.

```solidity
event PriceQuestionCreated(
    bytes32 indexed questionId,
    address indexed feed,
    QuestionType questionType,
    uint64   startTime,
    uint64   endTime,
    int256   threshold,
    int256   upperBound,
    address indexed creator,
    uint64   operatorDelay
);
```

**Emitted by:** `createUpDown()`, `createAboveThreshold()`, `createInRange()`

#### PriceQuestionResolved

Emitted when the price question is settled using Chainlink round data.

```solidity
event PriceQuestionResolved(
    bytes32 indexed questionId,
    bool     outcome,
    QuestionType questionType,
    address indexed feed,
    int256   startPrice,
    int256   endPrice,
    uint80   startRoundId,
    uint80   endRoundId,
    address indexed resolver
);
```

**Emitted by:** `_settleInternal()`

#### PriceQuestionCancelled

```solidity
event PriceQuestionCancelled(
    bytes32 indexed questionId,
    address indexed canceller,
    address indexed feed,
    QuestionType questionType,
    address  creator
);
```

**Emitted by:** `cancelQuestion()`

### Configuration

```solidity
event FeedUpdated(address indexed feed, bool allowed, address indexed caller);
event MaxStalenessUpdated(uint256 oldMaxStaleness, uint256 newMaxStaleness, address indexed caller);
event MaxOperatorDelayUpdated(uint64 oldMaxDelay, uint64 newMaxDelay, address indexed caller);
event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed caller);
event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);
event ResolverGroupUpdated(bytes32 indexed groupId, address indexed member, bool authorized, address indexed caller);
event QuestionGroupAssigned(bytes32 indexed questionId, bytes32 indexed groupId, bytes32 previousGroupId, address indexed caller);
```

### Ownership

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## 5. LzCrossChainSender Events

**Source:** `src/LzCrossChainRelay.sol` (sender portion) — Polygon
**Integration:** LayerZero V2

### Cross-Chain Messaging

#### AnswerSent

Emitted when an oracle answer is dispatched to Unichain via LayerZero.

```solidity
event AnswerSent(
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    uint32   dstEid,
    bytes32  guid,
    address indexed adapter,
    uint256  feePaid,
    address  refundAddress
);
```

**Emitted by:** `sendAnswer()`

### Configuration

```solidity
event AdapterUpdated(address indexed caller, address indexed adapter, bool authorized);
event PeerSet(address indexed caller, uint32 indexed dstEid, bytes32 oldPeer, bytes32 newPeer);
event OptionsUpdated(address indexed caller, bytes oldOptions, bytes newOptions);
```

### Ownership

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## 6. LzCrossChainReceiver Events

**Source:** `src/LzCrossChainRelay.sol` (receiver portion) — Unichain
**Integration:** LayerZero V2

### Cross-Chain Messaging

#### AnswerReceived

Emitted when an oracle answer arrives from Polygon via LayerZero.

```solidity
event AnswerReceived(
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    uint32  indexed srcEid,
    bytes32  sender,
    bytes32  guid,
    bool     relayed          // true if forwarded to BridgeReceiver successfully
);
```

**Emitted by:** `lzReceive()`

#### RelayFailed

Emitted when forwarding to BridgeReceiver reverts. The answer is stored for retry.

```solidity
event RelayFailed(
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    uint256  index,           // position in the failed relay array
    bytes    reason           // revert data
);
```

**Emitted by:** `lzReceive()`

#### RelayRecovered

Emitted when a previously failed relay is successfully retried (auto-heal or manual).

```solidity
event RelayRecovered(
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    uint256  index,
    uint256  newLength,       // remaining failed relays
    bool     manual           // true if retryFailedRelay(), false if auto-healed in lzReceive()
);
```

**Emitted by:** `lzReceive()` (self-heal), `retryFailedRelay()` (manual)

#### FailedRelayRemoved

Emitted when a failed relay entry is removed without retrying (admin cleanup).

```solidity
event FailedRelayRemoved(
    address indexed caller,
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    uint256  index,
    uint256  newLength
);
```

**Emitted by:** `removeFailedRelay()`

### Configuration

```solidity
event PeerSet(address indexed caller, uint32 indexed srcEid, bytes32 oldPeer, bytes32 newPeer);
```

### Ownership

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## 7. BridgeReceiver Events

**Source:** `src/BridgeReceiver.sol` — Unichain
**Role:** Trusted intermediary between cross-chain receivers and the Diamond proxy

### Answer Relay

#### AnswerRelayed

Emitted when an oracle answer is forwarded to the Diamond via `registerOracleRequest()` + `reportPayouts()`.

```solidity
event AnswerRelayed(
    bytes32 indexed questionId,
    bytes32 indexed requestId,
    bool     outcome,
    address indexed relayer
);
```

**Emitted by:** `relayOracleAnswer()`

#### OutcomeRelayed

Emitted when an outcome is relayed directly (without requestId matching).

```solidity
event OutcomeRelayed(
    bytes32 indexed questionId,
    bool     outcome,
    address indexed relayer
);
```

**Emitted by:** `relayOutcome()`

### Configuration

```solidity
event RelayerUpdated(address indexed relayer, bool authorized, address indexed actor);
event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed actor);
```

### Ownership

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## 8. Shared Event Patterns

Several events appear across multiple contracts with identical or near-identical signatures:

### OwnershipProposed / OwnershipTransferred

Present in all 5 contracts. Two-step ownership transfer pattern.

```solidity
event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

### OperatorUpdated

Present in: `UmaOracleAdapter`, `ChainlinkPriceResolver`

```solidity
event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);
```

### ResolverGroupUpdated / QuestionGroupAssigned

Present in: `UmaOracleAdapter`, `ChainlinkPriceResolver`

```solidity
event ResolverGroupUpdated(bytes32 indexed groupId, address indexed member, bool authorized, address indexed caller);
event QuestionGroupAssigned(bytes32 indexed questionId, bytes32 indexed groupId, bytes32 previousGroupId, address indexed caller);
```

**Note:** `UmaOracleAdapter` has a slightly different parameter order for `QuestionGroupAssigned` — `previousGroupId` comes after `caller`:

```solidity
// UmaOracleAdapter version
event QuestionGroupAssigned(bytes32 indexed questionId, bytes32 indexed groupId, address indexed caller, bytes32 previousGroupId);
```

### CrossChainRelayUpdated

Present in: `UmaOracleAdapter`

```solidity
event CrossChainRelayUpdated(address indexed previousRelay, address indexed newRelay, address indexed caller);
```

---

## 9. Event Flows by Lifecycle

### UMA Oracle Flow (Polygon → Unichain)

```
╔═══════════════════════════════════════════════════════════════╗
║  POLYGON                                                      ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 1. QuestionInitialized (UmaOracleAdapter)               │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               ▼                               ║
║                    [liveness period — 2h default]             ║
║                               │                               ║
║              ┌────────────────┴────────────────┐              ║
║              ▼                                 ▼              ║
║  ┌───────────────────────────┐   ┌──────────────────────────┐ ║
║  │ 2a. QuestionDisputed      │   │ 2b. No dispute           │ ║
║  │     → UMA DVM vote        │   │     → liveness expires   │ ║
║  │     → verdict callback    │   │                          │ ║
║  └─────────────┬─────────────┘   └────────────┬─────────────┘ ║
║                └────────────────┬──────────────┘              ║
║                                 ▼                             ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 3. settleQuestion() triggers callback:                  │  ║
║  │    • QuestionResolved  (callback from UMA)              │  ║
║  │    • QuestionSettled   (emitted after callback)         │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               ▼                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 4. QuestionRelayed (UmaOracleAdapter)                   │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               ▼                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 5. AnswerSent (LzCrossChainSender)                      │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               │                               ║
╚═══════════════════════════════╪═══════════════════════════════╝
                                │
                       ═══ LayerZero V2 ═══
                                │
╔═══════════════════════════════╪═══════════════════════════════╗
║  UNICHAIN                     │                               ║
╠═══════════════════════════════╪═══════════════════════════════╣
║                               ▼                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 6. AnswerReceived (LzCrossChainReceiver)                │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               │                               ║
║              ┌────────────────┴────────────────┐              ║
║              ▼                                 ▼              ║
║  ┌───────────────────────────┐   ┌──────────────────────────┐ ║
║  │ 7a. AnswerRelayed         │   │ 7b. RelayFailed          │ ║
║  │     (BridgeReceiver)      │   │     → RelayRecovered     │ ║
║  └───────────────────────────┘   └──────────────────────────┘ ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

### Chainlink Price Flow (Unichain only)

```
╔═══════════════════════════════════════════════════════════════╗
║  UNICHAIN                                                     ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 1. PriceQuestionCreated (ChainlinkPriceResolver)        │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               ▼                               ║
║                [wait for endTime + Chainlink round data]      ║
║                               │                               ║
║                               ▼                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 2. PriceQuestionResolved (ChainlinkPriceResolver)       │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               ▼                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ Diamond.reportOutcome() — called directly, no bridge    │  ║
║  └─────────────────────────────────────────────────────────┘  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

### Question Cancellation Flow

```
╔═══════════════════════════════════════════════════════════════╗
║  POLYGON (any adapter)                                        ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 1. QuestionCancelled (adapter)                          │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               │                               ║
║              [if UMA and assertion still live:]               ║
║                               │                               ║
║              ┌────────────────┴────────────────┐              ║
║              ▼                                 ▼              ║
║  ┌───────────────────────────┐   ┌──────────────────────────┐ ║
║  │ 2a. CancelledAssertion    │   │ 2b. CancelledAssertion   │ ║
║  │     Settled               │   │     Disputed             │ ║
║  │     (callback post-cancel)│   │     (dispute post-cancel)│ ║
║  └───────────────────────────┘   └──────────────────────────┘ ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

### Failed Relay Recovery Flow

```
╔═══════════════════════════════════════════════════════════════╗
║  UNICHAIN                                                     ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │ 1. RelayFailed (LzCrossChainReceiver)                   │  ║
║  └────────────────────────────┬────────────────────────────┘  ║
║                               │                               ║
║          [next lzReceive auto-heals OR manual retry]          ║
║                               │                               ║
║         ┌─────────────────────┼─────────────────────┐         ║
║         ▼                     ▼                     ▼         ║
║  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────┐  ║
║  │ 2a. Relay       │  │ 2b. Relay       │  │ 2c. FailedRe- │  ║
║  │     Recovered   │  │     Recovered   │  │     layRemoved│  ║
║  │  (auto-heal in  │  │  (manual, via   │  │  (admin clean │  ║
║  │   next lzRecv)  │  │  retryFailed()) │  │   up, no retry│  ║
║  └─────────────────┘  └─────────────────┘  └───────────────┘  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## 10. Indexer Guidelines

### Multi-Chain Monitoring

Indexers must monitor **two chains** and **five contract addresses**:

| Chain | Contracts to Monitor |
|-------|---------------------|
| Polygon | `UmaOracleAdapter`, `LzCrossChainSender` |
| Unichain | `ChainlinkPriceResolver`, `LzCrossChainReceiver`, `BridgeReceiver` |

### Linking Cross-Chain Events

The `questionId` is the primary key that links events across all contracts and chains. A single question's lifecycle spans multiple contracts:

```
questionId → UmaOracleAdapter.QuestionInitialized
           → UmaOracleAdapter.QuestionResolved
           → LzCrossChainSender.AnswerSent
           → LzCrossChainReceiver.AnswerReceived
           → BridgeReceiver.AnswerRelayed
```

The `requestId` links the oracle answer to the Diamond's oracle request registration.

### Recommended Indexed Entities

| Entity | Primary Key | Source Events |
|--------|------------|---------------|
| Question | `questionId` | `QuestionInitialized`, `PriceQuestionCreated` |
| Resolution | `questionId` | `QuestionResolved`, `PriceQuestionResolved` |
| Cross-Chain Message | `guid` | `AnswerSent`, `AnswerReceived` |
| Failed Relay | `(questionId, index)` | `RelayFailed`, `RelayRecovered`, `FailedRelayRemoved` |
| Operator | `(contract, operator)` | `OperatorUpdated` |
| Resolver Group | `(groupId, member)` | `ResolverGroupUpdated` |
| Feed | `feed` | `FeedUpdated` |

### Adapter-Specific External IDs

Each adapter maps `questionId` to an external oracle identifier:

| Adapter | External ID | Field Name |
|---------|------------|------------|
| UMA | UMA assertion ID | `assertionId` |
| Chainlink | Chainlink feed address | `feed` |

### Question State Machine

Track question status by accumulating events:

```
UNINITIALIZED
    → QuestionInitialized / PriceQuestionCreated → INITIALIZED
        → QuestionDisputed → DISPUTED (UMA only)
            → QuestionResolved (DVM verdict callback) → RESOLVED
        → QuestionCancelled / PriceQuestionCancelled → CANCELLED
        → QuestionResolved + QuestionSettled (same tx) → RESOLVED (UMA)
        → PriceQuestionResolved → RESOLVED (Chainlink)
            → QuestionRelayed → RELAYED (UMA)
                → AnswerSent → SENT
                    → AnswerReceived → RECEIVED
                        → AnswerRelayed → DELIVERED
                        → RelayFailed → FAILED
                            → RelayRecovered → DELIVERED
                            → FailedRelayRemoved → REMOVED
```

### Event Deduplication

- **UMA callbacks**: `DuplicateCallbackIgnored` signals a duplicate — safe to skip.
- **Cancelled assertions**: `CancelledAssertionSettled` / `CancelledAssertionDisputed` arrive for already-cancelled questions — do not re-open the question state.
- **LayerZero replays**: Check `guid` uniqueness in `AnswerReceived` to detect replays.

### Critical Notes

1. **`QuestionGroupAssigned` parameter order differs** between UMA and Chainlink adapters (see Section 8). Use ABI decoding, not positional assumptions.
2. **`RelayFailed.reason`** contains the raw revert bytes from BridgeReceiver — decode for diagnostics.
3. **`AnswerReceived.relayed`** is `false` when the relay to BridgeReceiver failed — always cross-check with `RelayFailed` in the same transaction.
4. **Chainlink questions skip the bridge** entirely — `PriceQuestionResolved` is the terminal event; the resolver calls the Diamond directly.
5. **Bond economics** (UMA bond) are in the initialization events — track for dispute/arbitration analysis.
6. **Config events fire in constructors** — index deployment transactions to capture initial configuration values.
