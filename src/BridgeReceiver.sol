// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

import {IDiamondOracle} from "./interfaces/IDiamondOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BridgeReceiver
/// @notice Deployed on **Unichain**. Receives oracle answers from an off-chain relayer
///         (or cross-chain messaging protocol) and forwards them to the Diamond proxy.
///
/// @dev Architecture:
///
///      Polygon (UmaOracleAdapter)           Unichain (this contract)
///        │                                      │
///        │  emit QuestionResolved               │
///        │         │                            │
///        │    [relayer watches event]           │
///        │         │                            │
///        │         └─── relayOracleAnswer() ──▶ │
///        │                                      │── registerOracleRequest() on Diamond
///        │                                      │── reportPayouts() on Diamond
///        │                                      │
///
///      This contract is whitelisted as an oracle on the Diamond via `addOracle()`.
///      It acts as a trusted intermediary between external oracle systems and the Diamond.
///
///      Security model:
///        - Only authorized relayers can call `relayOracleAnswer()`
///        - Only the owner can add/remove relayers
///        - The contract itself is the oracle address on the Diamond
///        - Answers are validated by UMA on Polygon before relay — this contract just delivers
///
///      This contract is oracle-agnostic. It works with UMA or any oracle
///      that produces a (questionId, bool outcome) result. The relayer just needs to call
///      `relayOracleAnswer()` with the correct data.
///
/// @author Pop3 Market
contract BridgeReceiver is ReentrancyGuard {
    // ═══════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════

    /// @dev Caller is not the contract owner.
    error NotOwner();
    /// @dev Caller is not the pending proposed owner.
    error NotProposedOwner();
    /// @dev Caller is not an authorized relayer.
    error NotRelayer();
    /// @dev A required address parameter is the zero address.
    error ZeroAddress();
    /// @dev The address is already an authorized relayer.
    error AlreadyRelayer();
    /// @dev The address is not currently an authorized relayer.
    error NotAuthorizedRelayer();
    /// @dev This questionId has already been relayed (prevents double-relay).
    error QuestionAlreadyRelayed();
    // ═══════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when an oracle answer is relayed to the Diamond.
    event AnswerRelayed(bytes32 indexed questionId, bytes32 indexed requestId, bool outcome, address indexed relayer);

    /// @notice Emitted when an oracle outcome is relayed directly (without requestId).
    event OutcomeRelayed(bytes32 indexed questionId, bool outcome, address indexed relayer);

    /// @notice Emitted when a relayer is added or removed.
    event RelayerUpdated(address indexed relayer, bool authorized, address indexed actor);

    /// @notice Emitted when the Diamond address is updated.
    event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed actor);

    /// @notice Emitted when a new owner is proposed.
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════

    /// @notice The Diamond proxy on Unichain.
    IDiamondOracle public diamond;

    /// @notice Contract owner (multisig recommended).
    address public owner;

    /// @notice Proposed new owner (two-step transfer).
    address public proposedOwner;

    /// @notice Authorized relayer addresses (backend wallets or bridge endpoints).
    mapping(address => bool) public isRelayer;

    /// @notice Tracks which questions have already been relayed (prevents double-relay).
    /// @dev No reset mechanism is needed. The `relayed` flag is set in the same transaction
    ///      as the Diamond settlement calls (`registerOracleRequest` + `reportPayouts`, or
    ///      `reportOutcome`). If the Diamond call reverts, the entire tx reverts and `relayed`
    ///      stays false — the relayer can retry naturally. If the Diamond call succeeds, the
    ///      question is already settled and re-relaying would be rejected by the Diamond anyway.
    ///      Therefore there is no state where `relayed == true` but the Diamond hasn't processed
    ///      the outcome.
    mapping(bytes32 => bool) public relayed;

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _diamond The Diamond proxy address on Unichain.
    /// @param _owner Contract owner (can manage relayers).
    /// @param _relayer Initial authorized relayer address (backend wallet).
    constructor(address _diamond, address _owner, address _relayer) {
        if (_diamond == address(0) || _owner == address(0) || _relayer == address(0)) {
            revert ZeroAddress();
        }
        diamond = IDiamondOracle(_diamond);
        owner = _owner;
        isRelayer[_relayer] = true;

        emit DiamondUpdated(address(0), _diamond, _owner);
        emit OwnershipTransferred(address(0), _owner);
        emit RelayerUpdated(_relayer, true, _owner);
    }

    // ═══════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        _;
    }

    // ═══════════════════════════════════════════════════════
    // RELAY — MAIN ENTRY POINT
    // ═══════════════════════════════════════════════════════

    /// @notice Relay an oracle answer from Polygon to the Diamond on Unichain.
    /// @dev Called by the authorized relayer after watching the QuestionResolved event
    ///      on the UmaOracleAdapter (Polygon). This function:
    ///        1. Registers the requestId → questionId mapping on the Diamond
    ///        2. Reports the payouts to the Diamond via reportPayouts()
    ///
    ///      The requestId is an arbitrary identifier linking this relay to the external
    ///      oracle system (e.g., UMA assertionId). It's used by the Diamond's
    ///      `reportPayouts(requestId, payouts)` path.
    ///
    /// @param questionId The Diamond's internal question ID.
    /// @param requestId The external oracle request ID (e.g., UMA assertionId).
    /// @param outcome true = YES wins ([1,0]), false = NO wins ([0,1]).
    function relayOracleAnswer(bytes32 questionId, bytes32 requestId, bool outcome) external nonReentrant onlyRelayer {
        // Prevent double-relay
        if (relayed[questionId]) revert QuestionAlreadyRelayed();
        relayed[questionId] = true;

        // Step 1: Register the requestId → questionId mapping on the Diamond.
        // This contract (BridgeReceiver) must be the whitelisted oracle on the Diamond
        // for the market that owns this questionId.
        diamond.registerOracleRequest(questionId, requestId);

        // Build CTF-compatible payouts array:
        //   payouts[0] = YES outcome token weight
        //   payouts[1] = NO outcome token weight
        // The Diamond's reportPayouts() uses these to resolve the CTF condition.
        uint256[] memory payouts = new uint256[](2);
        if (outcome) {
            payouts[0] = 1; // YES wins
            payouts[1] = 0;
        } else {
            payouts[0] = 0;
            payouts[1] = 1; // NO wins
        }
        diamond.reportPayouts(requestId, payouts);

        emit AnswerRelayed(questionId, requestId, outcome, msg.sender);
    }

    /// @notice Relay an oracle answer directly via reportOutcome (without requestId).
    /// @dev Unlike relayOracleAnswer(), this path skips requestId registration
    ///      and calls Diamond.reportOutcome(questionId, bool) directly. The Diamond
    ///      resolves the CTF condition internally. Use this for oracles (e.g.,
    ///      ChainlinkPriceResolver) that don't use a requestId mapping.
    /// @param questionId The Diamond's internal question ID.
    /// @param outcome true = YES wins, false = NO wins.
    function relayOutcome(bytes32 questionId, bool outcome) external nonReentrant onlyRelayer {
        // Prevent double-relay
        if (relayed[questionId]) revert QuestionAlreadyRelayed();
        relayed[questionId] = true;

        diamond.reportOutcome(questionId, outcome);

        emit OutcomeRelayed(questionId, outcome, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — RELAYER MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Authorize a new relayer address.
    /// @dev Reverts if the address is already a relayer to prevent accidental no-ops.
    /// @param relayer The address to authorize.
    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        if (isRelayer[relayer]) revert AlreadyRelayer();
        isRelayer[relayer] = true;
        emit RelayerUpdated(relayer, true, msg.sender);
    }

    /// @notice Revoke a relayer's authorization.
    /// @dev Reverts if the address is not a relayer to surface misconfiguration early.
    /// @param relayer The address to revoke.
    function removeRelayer(address relayer) external onlyOwner {
        if (!isRelayer[relayer]) revert NotAuthorizedRelayer();
        isRelayer[relayer] = false;
        emit RelayerUpdated(relayer, false, msg.sender);
    }

    /// @notice Update the Diamond proxy address.
    /// @param _diamond The new Diamond proxy address.
    function setDiamond(address _diamond) external onlyOwner {
        if (_diamond == address(0)) revert ZeroAddress();
        address previous = address(diamond);
        diamond = IDiamondOracle(_diamond);
        emit DiamondUpdated(previous, _diamond, msg.sender);
    }

    /// @notice Propose a new owner (two-step transfer).
    /// @param newOwner The proposed new owner address.
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        proposedOwner = newOwner;
        emit OwnershipProposed(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by the proposed owner).
    function acceptOwnership() external {
        if (msg.sender != proposedOwner) revert NotProposedOwner();
        address previousOwner = owner;
        owner = proposedOwner;
        proposedOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }
}
