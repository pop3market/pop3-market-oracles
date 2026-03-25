# Pop3 Oracle Bridge

Oracle infrastructure for [Pop3 Market](https://pop3market.com). Two oracle systems:

1. **Cross-chain oracle** (UMA) on Polygon → LayerZero V2 → Diamond on Unichain. For subjective markets ("Will Trump win?").
2. **On-chain price oracle** (Chainlink) on Unichain directly. For price markets ("BTC Up/Down?"). No bridge needed.

## Scope

| Metric | Value |
|--------|-------|
| **Solidity version** | `0.8.26` |
| **Compiler settings** | `via_ir=true`, optimizer 200 runs, EVM target `cancun` |
| **Source contracts** | 5 |
| **Interfaces** | 5 |
| **Total nSLOC** | 1,283 |

## Architecture

### Price Markets — Chainlink (Unichain, no bridge)

```
Unichain only

ChainlinkPriceResolver                      Diamond proxy
  │                                              │
  │ createUpDown / createAboveThreshold /        │
  │ createInRange                                │
  │                                              │
  │ [time passes...]                             │
  │                                              │
  │ settleQuestion()                             │
  │   → binary search Chainlink rounds           │
  │   → reportOutcome(questionId, outcome) ─────▶│
```

### Subjective Markets — UMA (Polygon → Unichain)

```
Polygon                                  LayerZero V2                 Unichain

UmaOracleAdapter ──▶ LzCrossChainSender ═══════════════════════▶ LzCrossChainReceiver
                              │                                          │
                         1. settleQuestion()                        BridgeReceiver
                         2. relayResolved{value: fee}()                  │
                                                                    Diamond proxy
```

## Documentation

| Document | Description |
|----------|-------------|
| [Chainlink Oracle](docs/00_chainlink-oracle.md) | Price market settlement — question types, usage flow, resolution, security |
| [UMA Oracle](docs/01_uma-oracle.md) | Subjective markets via UMA OOv3 — bonds, disputes, usage flow, security |
| [Bridge & Infrastructure](docs/02_bridge-and-infrastructure.md) | LayerZero bridge, BridgeReceiver, deployment guide, key addresses, comparison |
| [Events](docs/03_events.md) | Complete event reference for all contracts — indexer guidelines, lifecycle flows, shared patterns |

## File Structure

```
src/
├── interfaces/
│   ├── IChainlinkAggregatorV3.sol      — Chainlink price feed interface
│   ├── IDiamondOracle.sol              — Diamond's oracle-facing functions
│   ├── ILayerZeroEndpointV2.sol        — LayerZero V2 endpoint + receiver
│   ├── IOptimisticOracleV3.sol         — UMA OOv3 interface + callbacks
├── ChainlinkPriceResolver.sol          — Unichain: auto-settle price markets (no bridge)
├── UmaOracleAdapter.sol                — Polygon: UMA integration + LZ relay support
├── LzCrossChainRelay.sol               — LayerZero sender (Polygon) + receiver (Unichain)
└── BridgeReceiver.sol                  — Unichain: relays answers to Diamond
test/
├── unit/                               — Unit + integration tests per contract
├── fuzz/                               — Stateless fuzz tests (10K runs)
├── invariant/                          — Stateful invariant tests (2048 runs × 100 depth)
└── mocks/                              — Mock contracts (MockOOv3, etc.)
script/
├── MainnetDeployUnichain.s.sol         — Mainnet: deploy Unichain contracts
├── MainnetDeployPolygon.s.sol          — Mainnet: deploy Polygon contracts
├── MainnetConfigureBridge.s.sol        — Mainnet: configure LayerZero peers
├── TestnetDeploySepolia.s.sol          — Testnet: deploy oracle adapters on Sepolia
├── TestnetDeployUnichainSepolia.s.sol  — Testnet: deploy Unichain Sepolia contracts
├── TestnetDeployUnichainMockFeed.s.sol — Testnet: deploy mock Chainlink feeds on Unichain Sepolia
├── TestnetConfigureBridge.s.sol        — Testnet: configure LayerZero peers
├── TestnetEnd2EndChainlink.s.sol       — Testnet: end-to-end Chainlink oracle flow
├── TestnetEnd2EndUMA.s.sol             — Testnet: end-to-end UMA oracle flow
├── TestnetMockChainlinkFeed.sol        — Testnet: mock Chainlink price feed contract
└── TestnetMockDiamond.sol              — Testnet: mock Diamond contract for testing
```

## Getting Started

### Prerequisites

- [Foundry](https://github.com/foundry-rs/foundry) — follow the [installation guide](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v22+ — required for Hardhat
- [Hardhat](https://hardhat.org/) v3.1+ — used for coverage reports (installed via `npm install`)

### Setup

```bash
git clone https://github.com/pop3market/pop3-market-oracles.git && cd pop3-market-oracles
forge install
npm install
```

### Build

```bash
forge build
```

## Testing

```bash
# All tests
forge test

# By category
forge test --match-path "test/unit/*" -vvvv
forge test --match-path "test/fuzz/*" -vvvv
forge test --match-path "test/invariant/*" -vvvv

# By contract
forge test --match-path "test/unit/BridgeReceiver*" -vvvv
forge test --match-path "test/**/ChainlinkPriceResolver*" -vvvv
forge test --match-path "test/**/UmaOracleAdapter*" -vvvv
forge test --match-path "test/**/LzCrossChain*" -vvvv

# Save to files
npx hardhat test solidity --coverage  > "test/ResultsCoverage.md" &&
forge test --match-path "test/unit/*" 2>&1 > "test/ResultsUnit.md" &&
forge test --match-path "test/fuzz/*" 2>&1 > "test/ResultsFuzz.md" &&
forge test --match-path "test/invariant/*" 2>&1 > "test/ResultsInvariant.md"
```

### Coverage

```bash
npx hardhat test solidity --coverage
```

### Gas Profiling

| Command | Output |
|---------|--------|
| `forge test --gas-report` | Per-function min/avg/median/max table |
| `forge snapshot` | Per-test gas, saved to file for diffing |
| `forge snapshot --diff` | Compare current vs saved snapshot |
| `forge test -vvvv` | Full execution trace with gas per call |

### Contract Sizes

```bash
forge build --sizes
```

### Formatting

```bash
forge fmt
```

## Dependencies

- **forge-std** — Foundry testing framework
- **openzeppelin-contracts** — IERC20, SafeERC20, ERC20
- **solady** — SafeCastLib for gas-efficient safe integer casting

Managed as git submodules in `lib/`. Install with `forge install`.

## Licensing

Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.

This software is proprietary. See [LICENSE](LICENSE) for full terms.

**Exceptions:**
- `test/` — MIT (for auditor accessibility)
- `src/interfaces/` — MIT
