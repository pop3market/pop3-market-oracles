# Bridge & Infrastructure

Oracle infrastructure for the Diamond proxy on Unichain. The cross-chain oracle (UMA) runs on Polygon and delivers results via two bridge modes: **automatic** (LayerZero V2) and **manual** (off-chain relayer). The on-chain oracle (ChainlinkPriceResolver) is deployed directly on Unichain and calls the Diamond without bridging.

## Automatic Mode (LayerZero — recommended)

```
Polygon                                  LayerZero V2                 Unichain

UmaOracleAdapter ──▶ LzCrossChainSender ═══════════════════════▶ LzCrossChainReceiver
                              │                                          │
                         1. settleQuestion()                        BridgeReceiver
                         2. relayResolved{value: fee}()                  │
                                                                    Diamond proxy
```

Settlement and relay are **two separate calls** by design:
1. `settleQuestion(questionId)` — settles locally (not payable, no relay)
2. `relayResolved{value: fee}(questionId)` — sends the result cross-chain via LayerZero (payable)

Both steps are permissionless after the operator delay window expires. Call `quoteCrossChainFee(questionId)` on the adapter to estimate the LayerZero fee before calling `relayResolved`.

## Manual Mode (off-chain relayer)

```
Polygon                         Off-chain                    Unichain

UmaOracleAdapter ──▶ emit QuestionResolved ──▶ Relayer ──▶ BridgeReceiver ──▶ Diamond
```

Call `settleQuestion()` to resolve locally. The relayer watches `QuestionResolved` events and calls `BridgeReceiver.relayOracleAnswer()` on Unichain. No `relayResolved()` call needed. The owner configures the relay via `setCrossChainRelay(address)` (set to `address(0)` to disable LayerZero relay).

> For full adapter documentation (constructors, functions, roles), see [01_uma-oracle.md](01_uma-oracle.md).

---

## Contracts

### LzCrossChainSender (Polygon)

> Both `LzCrossChainSender` and `LzCrossChainReceiver` are defined in a single file: `src/LzCrossChainRelay.sol`.

Shared LayerZero V2 sender. Both adapters call this to send answers cross-chain to Unichain. Only whitelisted adapters can send.

**Key Functions:**
- `sendAnswer(bytes32 questionId, bytes32 requestId, bool outcome, address refundAddress)` — Send answer via LayerZero (adapter-only, payable)
- `quoteFee(bytes32 questionId, bytes32 requestId, bool outcome)` — Estimate LayerZero fee
- `addAdapter(address)` / `removeAdapter(address)` — Manage authorized adapters (owner-only)
- `setPeer(bytes32 peer)` — Set trusted receiver on Unichain (owner-only). `dstEid` is immutable (set in constructor)
- `setOptions(bytes memory options)` — Set default gas options for destination execution (owner-only)

**Constructor:**

```solidity
LzCrossChainSender(
    address _endpoint,      // LayerZero Endpoint V2 on Polygon
    uint32 _dstEid,         // LayerZero endpoint ID for Unichain
    address _owner,         // Contract owner
    bytes memory _defaultOptions // LayerZero executor options (gas for destination)
)
```

**Roles:**

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `setPeer`, `setOptions`, `addAdapter`, `removeAdapter`, `proposeOwner`, `acceptOwnership` |
| **Adapter(s)** | UmaOracleAdapter | `sendAnswer` |

### LzCrossChainReceiver (Unichain)

Receives answers from Polygon via LayerZero V2 and forwards them to the BridgeReceiver. Validates that messages come from the trusted peer (LzCrossChainSender on Polygon).

Includes **self-healing relay recovery**: if forwarding to BridgeReceiver fails (e.g., question already relayed), the failed relay is stored. On each subsequent incoming message, the receiver automatically retries one stored failure before processing the new message.

**Key Functions:**
- `lzReceive(origin, guid, message, ...)` — Called by LayerZero Endpoint (endpoint-only). Uses try/catch to prevent nonce channel blockage
- `setPeer(srcEid, peer)` — Set trusted sender on Polygon (owner-only)
- `retryFailedRelay(index)` — Manually retry a failed relay by index (owner-only). Reverts if BridgeReceiver rejects, preserving the entry
- `removeFailedRelay(index)` — Remove a single failed relay without retrying (owner-only). Uses swap-and-pop for O(1) removal
- `failedRelayCount()` — Number of stored failed relays
- `getFailedRelay(index)` — Query a specific failed relay

**Constructor:**

```solidity
LzCrossChainReceiver(
    address _endpoint,       // LayerZero Endpoint V2 on Unichain
    address _bridgeReceiver, // BridgeReceiver contract on Unichain
    address _owner           // Contract owner
)
```

**Roles:**

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `setPeer`, `retryFailedRelay`, `removeFailedRelay`, `proposeOwner`, `acceptOwnership` |
| **LZ Endpoint** | LayerZero contract | `lzReceive` (validates trusted peer) |

### BridgeReceiver (Unichain)

Receives oracle answers (from LzCrossChainReceiver or manual relayers) and forwards them to the Diamond proxy. Oracle-agnostic — works with any source.

**Key Functions:**
- `relayOracleAnswer(bytes32 questionId, bytes32 requestId, bool outcome)` — Full path: registers requestId + reports payouts (relayer-only)
- `relayOutcome(bytes32 questionId, bool outcome)` — Simple path: calls `reportOutcome` directly (relayer-only)
- `addRelayer(address)` / `removeRelayer(address)` — Manage authorized relayers (owner-only)
- `setDiamond(address)` — Update Diamond proxy address (owner-only)

**Constructor:**

```solidity
BridgeReceiver(
    address _diamond,  // Diamond proxy address on Unichain
    address _owner,    // Contract owner
    address _relayer   // Initial authorized relayer
)
```

**Roles:**

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `addRelayer`, `removeRelayer`, `setDiamond`, `proposeOwner`, `acceptOwnership` |
| **Relayer(s)** | LzCrossChainReceiver and/or backend wallets | `relayOracleAnswer`, `relayOutcome` |

### ChainlinkPriceResolver (Unichain)

Settles price-based prediction markets using Chainlink price feeds. Deployed on Unichain — calls `Diamond.reportOutcome()` directly (no bridge needed). Supports three market types:

- **UP_DOWN** — "BTC Up or Down between 14:00–15:00 UTC?" → YES if endPrice >= startPrice
- **ABOVE_THRESHOLD** — "Will BTC be above $100k at March 31?" → YES if price >= threshold at endTime
- **IN_RANGE** — "Will BTC be between $95k–$100k at end of day?" → YES if lowerBound <= price < upperBound at endTime

**Key Functions:**
- `createUpDown(questionId, feed, startTime, endTime, operatorDelay)` — Create UP_DOWN question (owner/operator/resolver-group)
- `createAboveThreshold(questionId, feed, endTime, threshold, operatorDelay)` — Create ABOVE_THRESHOLD question (owner/operator/resolver-group)
- `createInRange(questionId, feed, endTime, lowerBound, upperBound, operatorDelay)` — Create IN_RANGE question (owner/operator/resolver-group)
- `settleQuestion(questionId)` — Resolve using Chainlink round data (permissionless after operator delay)
- `checkUpkeep(checkData)` / `performUpkeep(performData)` — Chainlink Automation integration for auto-settlement
- `cancelQuestion(questionId)` — Cancel an unresolved question (owner/operator/resolver-group)
- `addFeed(address)` / `removeFeed(address)` — Manage whitelisted Chainlink price feeds (owner-only)
- `addOperator(address)` / `removeOperator(address)` — Manage authorized operators (owner-only)
- `setResolverGroup(groupId, members, authorized)` — Manage named resolver groups (owner/operator-only)
- `assignQuestionGroup(questionId, groupId)` — Assign resolver group to a question (owner/operator-only)
- `setDiamond(address)` — Update Diamond proxy address (owner-only)
- `setMaxStaleness(uint256)` — Update max Chainlink data staleness (owner-only)
- `setMaxOperatorDelay(uint64)` — Update max operator delay (owner-only)

**Constructor:**

```solidity
ChainlinkPriceResolver(
    address _diamond,          // Diamond proxy address on Unichain
    uint256 _maxStaleness,     // Max Chainlink data age in seconds (e.g., 3600)
    uint64 _maxOperatorDelay,  // Max operator delay in seconds (e.g., 3600)
    address _owner,            // Contract owner
    address _operator          // Initial authorized operator
)
```

**Roles:**

| Role | Who | Permissions |
|------|-----|-------------|
| **Owner** | Multisig or EOA | `addFeed`, `removeFeed`, `addOperator`, `removeOperator`, `setDiamond`, `setMaxStaleness`, `setMaxOperatorDelay`, `cancelQuestion`, `setResolverGroup`, `assignQuestionGroup`, `proposeOwner`, `acceptOwnership`, plus all Operator permissions |
| **Operator(s)** | Backend wallets | `createUpDown`, `createAboveThreshold`, `createInRange`, `cancelQuestion`, `setResolverGroup`, `assignQuestionGroup` |
| **Resolver Group** | Per-question members | `createUpDown`, `createAboveThreshold`, `createInRange`, `cancelQuestion` (only for questions assigned to their group) |

---

## Interfaces

| Interface | Used by | Purpose |
|-----------|---------|---------|
| `IChainlinkAggregatorV3.sol` | ChainlinkPriceResolver | Chainlink price feed interface |
| `IOptimisticOracleV3.sol` | UmaOracleAdapter | UMA OOv3 interface + callbacks |
| `ILayerZeroEndpointV2.sol` | LzCrossChainSender, LzCrossChainReceiver | LayerZero V2 endpoint + receiver |
| `IDiamondOracle.sol` | BridgeReceiver, ChainlinkPriceResolver | Diamond's oracle-facing functions |
| `IOptimisticOracleV3Callback` | UmaOracleAdapter | UMA callback interface for assertion resolution (inline in `IOptimisticOracleV3.sol`) |
| `ILayerZeroReceiver` | LzCrossChainReceiver | LayerZero receiver callback (inline in `ILayerZeroEndpointV2.sol`) |
| `ILzBridgeReceiver` | LzCrossChainReceiver | Minimal interface for calling BridgeReceiver relay functions (inline in `LzCrossChainRelay.sol`) |

---

## Key Events

Events used by relayers, monitoring systems, and off-chain infrastructure.

| Event | Contract | Emitted When |
|-------|----------|--------------|
| `QuestionResolved(questionId, assertionId, outcome, resolver)` | UmaOracleAdapter | Question settled locally on Polygon. Off-chain relayers watch this in manual mode |
| `AnswerSent(questionId, requestId, outcome, dstEid, guid, adapter, feePaid, refundAddress)` | LzCrossChainSender | Answer sent cross-chain via LayerZero |
| `RelayFailed(questionId, requestId, outcome, index, reason)` | LzCrossChainReceiver | Forwarding to BridgeReceiver failed; entry stored for retry |
| `RelayRecovered(questionId, requestId, outcome, index, newLength, manual)` | LzCrossChainReceiver | Previously failed relay successfully retried (auto or manual) |
| `AnswerRelayed(questionId, requestId, outcome, relayer)` | BridgeReceiver | Full-path relay completed (registerOracleRequest + reportPayouts) |
| `OutcomeRelayed(questionId, outcome, relayer)` | BridgeReceiver | Direct-path relay completed (reportOutcome) |
| `PriceQuestionCreated(questionId, feed, questionType, startTime, endTime, threshold, upperBound, creator, operatorDelay)` | ChainlinkPriceResolver | New price question registered on Unichain |
| `PriceQuestionResolved(questionId, outcome, questionType, feed, startPrice, endPrice, startRoundId, endRoundId, resolver)` | ChainlinkPriceResolver | Price question settled on Unichain |

> UmaOracleAdapter emits additional operational events beyond `QuestionResolved` — including `QuestionInitialized`, `QuestionDisputed`, `QuestionCancelled`, `QuestionSettled`, `QuestionRelayed`, and admin config events. See source code for the full list.

**Admin events** (emitted by all contracts on configuration changes):

| Event | Contracts |
|-------|-----------|
| `OwnershipProposed(currentOwner, proposedOwner)` | All |
| `OwnershipTransferred(previousOwner, newOwner)` | All |
| `AdapterUpdated(caller, adapter, authorized)` | LzCrossChainSender |
| `PeerSet(caller, eid, oldPeer, newPeer)` | LzCrossChainSender, LzCrossChainReceiver |
| `OptionsUpdated(caller, oldOptions, newOptions)` | LzCrossChainSender |
| `RelayerUpdated(relayer, authorized, actor)` | BridgeReceiver |
| `DiamondUpdated(previousDiamond, newDiamond, actor/caller)` | BridgeReceiver (`actor`), ChainlinkPriceResolver (`caller`) |
| `FeedUpdated(feed, allowed, caller)` | ChainlinkPriceResolver |
| `OperatorUpdated(operator, authorized, caller)` | ChainlinkPriceResolver |

---

## Deployment

Deployment uses Forge scripts with a four-phase approach. All scripts use two-step ownership: the deployer retains control during configuration, then proposes ownership to the multisig.

### Prerequisites

Copy `.env.example` to `.env` and fill in the required values:

```bash
cp .env.example .env
```

Key environment variables:
- `DEPLOYER_PRIVATE_KEY` — Deploying EOA
- `DIAMOND` — Diamond proxy address on Unichain
- `MULTISIG_ADDRESS` — Final owner (defaults to deployer if unset)
- `ETHERSCAN_API_KEY` — Single key works for all chains (etherscan v2 API)
- See `.env.example` for the full list

### Phase 1: Deploy Unichain

```bash
forge script script/MainnetDeployUnichain.s.sol:MainnetDeployUnichain \
  --rpc-url unichain \
  --broadcast --verify
```

Deploys:
1. `BridgeReceiver` — receives cross-chain answers
2. `LzCrossChainReceiver` — LayerZero receiver (auto-added as relayer on BridgeReceiver)
3. `ChainlinkPriceResolver` — price market settlement

**Default configuration (from deploy script):**

| Parameter | Value |
|-----------|-------|
| Chainlink max staleness | 1 hour |
| Chainlink max operator delay | 1 hour |

**Post-deployment (manual, requires Diamond owner):**
```bash
# Whitelist BridgeReceiver as oracle on Diamond
cast send $DIAMOND "addOracle(address)" <BRIDGE_RECEIVER> --rpc-url unichain --private-key $OWNER_KEY

# Whitelist ChainlinkPriceResolver as oracle on Diamond
cast send $DIAMOND "addOracle(address)" <CHAINLINK_RESOLVER> --rpc-url unichain --private-key $OWNER_KEY

# Whitelist Chainlink price feeds
cast send <CHAINLINK_RESOLVER> "addFeed(address)" <BTC_USD_FEED> --rpc-url unichain --private-key $OWNER_KEY
```

### Phase 2: Deploy Polygon

```bash
forge script script/MainnetDeployPolygon.s.sol:MainnetDeployPolygon \
  --rpc-url polygon \
  --broadcast --verify
```

Deploys:
1. `LzCrossChainSender` — LayerZero sender
2. `UmaOracleAdapter` — UMA integration (auto-linked to sender)

The adapter is automatically registered on the sender and configured with `setCrossChainRelay()`.

**Default configuration (from deploy script):**

| Parameter | Value |
|-----------|-------|
| UMA default bond | 250 USDC |
| UMA default liveness | 2 hours |
| UMA min liveness | 30 minutes |
| LZ destination gas limit | 200,000 |

### Testnet Deployment

Testnet scripts mirror the mainnet flow on Sepolia → Unichain Sepolia. See `script/Testnet*.s.sol` for deploy, bridge configuration, and end-to-end test scripts (UMA, Chainlink). Testnet env vars are in `.env.testnet`.

### Phase 3: Configure Bridge

Must be run **before** the multisig calls `acceptOwnership()` — the deployer is still the owner at this point.

```bash
# On Polygon: trust the receiver on Unichain
forge script script/MainnetConfigureBridge.s.sol:ConfigureSenderMainnet \
  --rpc-url polygon \
  --broadcast

# On Unichain: trust the sender on Polygon
forge script script/MainnetConfigureBridge.s.sol:ConfigureReceiverMainnet \
  --rpc-url unichain \
  --broadcast
```

### Phase 4: Transfer Ownership

After bridge is configured, the multisig calls `acceptOwnership()` on each contract.

### Onboarding Market Creators

Market creators need to be whitelisted on **both chains**:

```bash
# Unichain — allow creating markets on Diamond (optional, only if creator whitelist is active)
cast send $DIAMOND "addCreator(address)" <CREATOR_ADDRESS> \
  --rpc-url unichain --private-key $OWNER_KEY

# Polygon — allow submitting resolutions
cast send <UMA_ADAPTER> "addOperator(address)" <CREATOR_POLYGON_ADDRESS> \
  --rpc-url polygon --private-key $OWNER_KEY
```

---

## Key Addresses

| Contract | Network | Address |
|----------|---------|---------|
| UMA OOv3 | Polygon | `0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D` |
| USDC (native) | Polygon | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` |
| LZ Endpoint V2 | Polygon | `0x1a44076050125825900e736c501f859c50fE728c` |
| LZ Endpoint V2 | Unichain | `0x6F475642a6e85809B1c36Fa62763669b1b48DD5B` |

## LayerZero Endpoint IDs

| Network | Mainnet EID | Testnet EID |
|---------|-------------|-------------|
| Unichain | 30320 | 40333 |
| Polygon | 30109 | 40267 |


Both adapters use the same LzCrossChainSender, LzCrossChainReceiver, and BridgeReceiver. The Diamond doesn't know or care which oracle resolved the question.

## Security Model

- **Adapter whitelist** — only registered adapters can send messages via LzCrossChainSender
- **LayerZero peer validation** — sender and receiver are cryptographically linked via `setPeer()`, preventing spoofed messages
- **Endpoint validation** — LzCrossChainReceiver only accepts calls from the LayerZero Endpoint contract
- **Self-healing relay** — LzCrossChainReceiver uses try/catch on forwarding to prevent nonce channel blockage; failed relays are stored and auto-retried on subsequent messages, manually retried via `retryFailedRelay()`, or removed without retrying via `removeFailedRelay()`
- **Relayer whitelist** — BridgeReceiver only accepts calls from authorized relayers (LzCrossChainReceiver or manual wallets)
- **Double-relay prevention** — each questionId can only be relayed once via BridgeReceiver
- **Diamond oracle check** — only whitelisted oracle contracts can report outcomes to the Diamond
- **Two-step ownership transfer** — `proposeOwner()` → `acceptOwnership()` prevents accidental lockout
- **Reentrancy guards** — `nonReentrant` (OpenZeppelin `ReentrancyGuard`) on all state-modifying externals: BridgeReceiver (`relayOracleAnswer`, `relayOutcome`), LzCrossChainReceiver (`lzReceive`, `retryFailedRelay`), ChainlinkPriceResolver (`settleQuestion`, `performUpkeep`). LzCrossChainSender does not use `ReentrancyGuard` — `sendAnswer` only forwards to the LayerZero Endpoint with no state updates after the external call
- **Upgradeable Diamond address** — `setDiamond()` on BridgeReceiver and ChainlinkPriceResolver allows updating the Diamond proxy without redeploying
