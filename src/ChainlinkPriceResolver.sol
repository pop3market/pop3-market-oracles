// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

import {IChainlinkAggregatorV3} from "./interfaces/IChainlinkAggregatorV3.sol";
import {IDiamondOracle} from "./interfaces/IDiamondOracle.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  ChainlinkPriceResolver
/// @notice Deployed on **Unichain**. Automatically settles price-based prediction markets
///         using Chainlink price feeds. No bonds, no disputes, no bridge — fully on-chain.
///
/// @dev Supports three market types:
///
///      1. UP_DOWN — "BTC Up or Down between 14:00-15:00 UTC?"
///         Resolves YES if endPrice >= startPrice, NO otherwise.
///
///      2. ABOVE_THRESHOLD — "Will BTC be above $100k at March 31?"
///         Resolves YES if price >= threshold at endTime, NO otherwise.
///
///      3. IN_RANGE — "Will BTC be between $95k-$100k at end of day?"
///         Resolves YES if lowerBound <= price < upperBound at endTime, NO otherwise.
///
///      Settlement uses Chainlink's historical round data to find the prices closest
///      to the configured timestamps. Both start and end prices are read at settlement
///      time — no price is captured at question creation.
///
///      This contract is whitelisted as an oracle on the Diamond via addOracle().
///      It calls Diamond.reportOutcome() directly — no BridgeReceiver needed.
///
/// @author Pop3 Market
contract ChainlinkPriceResolver is ReentrancyGuard {
    using SafeCastLib for uint256;
    // ═══════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════

    /// @dev Caller is not the contract owner.
    error NotOwner();
    /// @dev Caller is not the pending proposed owner.
    error NotProposedOwner();
    /// @dev Caller is not an authorized operator.
    error NotOperator();
    /// @dev A required address parameter is the zero address.
    error ZeroAddress();
    /// @dev A question with this ID already exists (feed != address(0)).
    error QuestionAlreadyCreated();
    /// @dev No question exists for this ID (feed == address(0)).
    error QuestionNotCreated();
    /// @dev The question has already been resolved.
    error QuestionAlreadyResolved();
    /// @dev block.timestamp is still before the question's endTime.
    error EndTimeNotReached();
    /// @dev startTime/endTime validation failed (zero, endTime <= startTime, or already passed).
    error InvalidTimeRange();
    /// @dev Threshold must be strictly positive for ABOVE_THRESHOLD questions.
    error InvalidThreshold();
    /// @dev lowerBound must be >= 0 and upperBound must be > lowerBound for IN_RANGE questions.
    error InvalidRange();
    /// @dev The Chainlink price feed address is not in allowedFeeds.
    error FeedNotWhitelisted();
    /// @dev The price data is older than maxStaleness seconds relative to the target time.
    error StalePriceData();
    /// @dev Chainlink returned a non-positive price (answer <= 0).
    error InvalidPrice();
    /// @dev No valid Chainlink round found for the target timestamp.
    error RoundNotFound();
    /// @dev The address is already an authorized operator.
    error AlreadyOperator();
    /// @dev The address is not currently an authorized operator.
    error NotAuthorizedOperator();
    /// @dev The operator delay exceeds the maximum allowed (maxOperatorDelay).
    error DelayTooLong();
    /// @dev The operator review window is still active. Only operator/owner/resolver can settle during this period.
    error OperatorWindowActive();
    /// @dev Caller is not authorized to act on this question. Must be owner, operator, or a
    ///      member of the resolver group assigned to this questionId (see `questionGroup`).
    error NotQuestionAuthorized();
    /// @dev The resolver group ID must not be bytes32(0).
    error InvalidGroupId();

    // ═══════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════

    /// @notice The type of price question.
    enum QuestionType {
        UP_DOWN, // YES if endPrice >= startPrice
        ABOVE_THRESHOLD, // YES if price >= threshold at endTime
        IN_RANGE // YES if lowerBound <= price < upperBound at endTime
    }

    // ═══════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when a price question is created.
    event PriceQuestionCreated(
        bytes32 indexed questionId,
        address indexed feed,
        QuestionType questionType,
        uint64 startTime,
        uint64 endTime,
        int256 threshold,
        int256 upperBound,
        address indexed creator,
        uint64 operatorDelay
    );

    /// @notice Emitted when a price question is resolved.
    event PriceQuestionResolved(
        bytes32 indexed questionId,
        bool outcome,
        QuestionType questionType,
        address indexed feed,
        int256 startPrice,
        int256 endPrice,
        uint80 startRoundId,
        uint80 endRoundId,
        address indexed resolver
    );

    /// @notice Emitted when a feed is whitelisted or removed.
    event FeedUpdated(address indexed feed, bool allowed, address indexed caller);

    /// @notice Emitted when an operator is added or removed.
    event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);

    /// @notice Emitted when max staleness is updated.
    event MaxStalenessUpdated(uint256 oldMaxStaleness, uint256 newMaxStaleness, address indexed caller);

    /// @notice Emitted when a question is cancelled by the owner, operator, or resolver group member.
    event PriceQuestionCancelled(
        bytes32 indexed questionId,
        address indexed canceller,
        address indexed feed,
        QuestionType questionType,
        address creator
    );

    /// @notice Emitted when a member is added/removed from a resolver group.
    event ResolverGroupUpdated(
        bytes32 indexed groupId, address indexed member, bool authorized, address indexed caller
    );

    /// @notice Emitted when a resolver group is assigned to a question.
    event QuestionGroupAssigned(
        bytes32 indexed questionId, bytes32 indexed groupId, bytes32 previousGroupId, address indexed caller
    );

    /// @notice Emitted when the Diamond address is updated.
    event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed caller);

    /// @notice Emitted when a new owner is proposed.
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the max operator delay is updated.
    event MaxOperatorDelayUpdated(uint64 oldMaxDelay, uint64 newMaxDelay, address indexed caller);

    // ═══════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════

    /// @notice Full configuration and state for a price-based prediction market question.
    /// @dev The `threshold` field is overloaded:
    ///      - ABOVE_THRESHOLD: target price (YES if price >= threshold)
    ///      - IN_RANGE: lower bound (YES if threshold <= price < upperBound)
    ///      - UP_DOWN: unused (always 0)
    struct PriceQuestion {
        address feed; /// @dev Chainlink price feed address (e.g., BTC/USD aggregator).
        QuestionType qType; /// @dev Resolution logic selector: UP_DOWN, ABOVE_THRESHOLD, or IN_RANGE.
        uint64 startTime; /// @dev Timestamp for start price lookup. Only used by UP_DOWN (0 for other types).
        uint64 endTime; /// @dev Timestamp for end price lookup / resolution trigger.
        int256 threshold; /// @dev Price threshold. Meaning depends on qType (see struct-level @dev).
        int256 upperBound; /// @dev Upper price bound. Only used by IN_RANGE (0 for other types).
        bool resolved; /// @dev True after _settleInternal() completes successfully.
        bool outcome; /// @dev true = YES wins, false = NO wins. Only valid when resolved == true.
        int256 startPrice; /// @dev Start price from Chainlink. Populated at resolution time, not creation.
        int256 endPrice; /// @dev End price from Chainlink. Populated at resolution time, not creation.
        address creator; /// @dev Address that created this question. Stored for event emission and record-keeping.
        uint64 operatorDelay; /// @dev Seconds after endTime during which only operator/owner/resolver can settle. 0 = permissionless immediately.
    }

    // ═══════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════

    /// @notice The Diamond proxy on Unichain.
    IDiamondOracle public diamond;

    /// @notice Contract owner.
    address public owner;

    /// @notice Proposed new owner (two-step transfer).
    address public proposedOwner;

    /// @notice Maximum allowed staleness for Chainlink price data (in seconds).
    /// @dev If the price was updated more than maxStaleness seconds ago, resolution reverts.
    uint256 public maxStaleness;

    /// @notice Owner-configurable max operator delay for new questions.
    uint64 public maxOperatorDelay;

    /// @notice Whitelisted Chainlink price feeds.
    mapping(address => bool) public allowedFeeds;

    /// @notice Authorized operators — can create price questions.
    mapping(address => bool) public isOperator;

    /// @notice Question ID → price question data.
    mapping(bytes32 => PriceQuestion) public questions;

    /// @notice List of pending (unresolved) question IDs for Chainlink Automation.
    bytes32[] public pendingQuestions;

    /// @notice Index of each question in pendingQuestions (for O(1) removal).
    mapping(bytes32 => uint256) internal pendingIndex;

    /// @notice Named resolver groups — reusable sets of trusted addresses (e.g., a resolution team).
    /// @dev Groups are managed by owner/operators via `setResolverGroup()`. Multiple questions can
    ///      share the same group, and adding/removing members applies to all linked questions instantly.
    mapping(bytes32 => mapping(address => bool)) public resolverGroups;

    /// @notice Question → resolver group assignment.
    /// @dev Set via `assignQuestionGroup()`. Members of the assigned group can create,
    ///      settle (during operator delay), and cancel the question. bytes32(0) = no group assigned.
    ///      Resolvers are trusted parties (e.g., the market creator on Unichain who created the market
    ///      that this questionId belongs to). Cancel-then-recreate is allowed by design since resolvers
    ///      own their markets and the event trail provides full auditability.
    mapping(bytes32 => bytes32) public questionGroup;

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _diamond The Diamond proxy address on Unichain.
    /// @param _maxStaleness Maximum allowed price staleness in seconds (e.g., 3600 = 1 hour).
    /// @param _maxOperatorDelay Maximum operator delay operators can set per question (e.g., 3600 = 1 hour).
    /// @param _owner Contract owner.
    /// @param _operator Initial authorized operator.
    constructor(address _diamond, uint256 _maxStaleness, uint64 _maxOperatorDelay, address _owner, address _operator) {
        if (_diamond == address(0) || _owner == address(0) || _operator == address(0)) {
            revert ZeroAddress();
        }
        if (_maxStaleness == 0) revert StalePriceData();
        diamond = IDiamondOracle(_diamond);
        maxStaleness = _maxStaleness;
        maxOperatorDelay = _maxOperatorDelay;
        owner = _owner;
        isOperator[_operator] = true;

        emit DiamondUpdated(address(0), _diamond, _owner);
        emit MaxStalenessUpdated(0, _maxStaleness, _owner);
        emit MaxOperatorDelayUpdated(0, _maxOperatorDelay, _owner);
        emit OwnershipTransferred(address(0), _owner);
        emit OperatorUpdated(_operator, true, _owner);
    }

    // ═══════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ═══════════════════════════════════════════════════════
    // CREATE PRICE QUESTIONS
    // ═══════════════════════════════════════════════════════

    /// @notice Create an Up/Down price question.
    /// @dev Resolves YES if the price at endTime >= price at startTime.
    /// @param questionId The Diamond's question ID (from prepareQuestion).
    /// @param feed Chainlink price feed address (must be whitelisted).
    /// @param startTime Timestamp for the start price.
    /// @param endTime Timestamp for the end price. Must be > startTime.
    /// @param operatorDelay Seconds after endTime during which only operator/owner/resolver can settle. 0 = permissionless immediately.
    function createUpDown(bytes32 questionId, address feed, uint64 startTime, uint64 endTime, uint64 operatorDelay)
        external
    {
        if (!isOperator[msg.sender] && msg.sender != owner && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        if (questionId == bytes32(0)) revert QuestionNotCreated();
        if (!allowedFeeds[feed]) revert FeedNotWhitelisted();
        if (questions[questionId].feed != address(0)) revert QuestionAlreadyCreated();
        if (startTime == 0 || startTime < uint64(block.timestamp)) revert InvalidTimeRange();
        if (endTime <= startTime) revert InvalidTimeRange();
        if (operatorDelay > maxOperatorDelay) revert DelayTooLong();

        questions[questionId] = PriceQuestion({
            feed: feed,
            qType: QuestionType.UP_DOWN,
            startTime: startTime,
            endTime: endTime,
            threshold: 0,
            upperBound: 0,
            resolved: false,
            outcome: false,
            startPrice: 0,
            endPrice: 0,
            creator: msg.sender,
            operatorDelay: operatorDelay
        });
        _addPending(questionId);

        emit PriceQuestionCreated(
            questionId, feed, QuestionType.UP_DOWN, startTime, endTime, 0, 0, msg.sender, operatorDelay
        );
    }

    /// @notice Create an Above Threshold price question.
    /// @dev Resolves YES if the price at endTime >= threshold.
    /// @param questionId The Diamond's question ID.
    /// @param feed Chainlink price feed address (must be whitelisted).
    /// @param endTime Timestamp when to check the price.
    /// @param threshold The target price (in feed's decimals, e.g., 100000e8 for $100k BTC).
    /// @param operatorDelay Seconds after endTime during which only operator/owner/resolver can settle. 0 = permissionless immediately.
    function createAboveThreshold(
        bytes32 questionId,
        address feed,
        uint64 endTime,
        int256 threshold,
        uint64 operatorDelay
    ) external {
        if (!isOperator[msg.sender] && msg.sender != owner && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        if (questionId == bytes32(0)) revert QuestionNotCreated();
        if (!allowedFeeds[feed]) revert FeedNotWhitelisted();
        if (questions[questionId].feed != address(0)) revert QuestionAlreadyCreated();
        if (endTime <= uint64(block.timestamp)) revert InvalidTimeRange();
        if (threshold <= 0) revert InvalidThreshold();
        if (operatorDelay > maxOperatorDelay) revert DelayTooLong();

        questions[questionId] = PriceQuestion({
            feed: feed,
            qType: QuestionType.ABOVE_THRESHOLD,
            startTime: 0,
            endTime: endTime,
            threshold: threshold,
            upperBound: 0,
            resolved: false,
            outcome: false,
            startPrice: 0,
            endPrice: 0,
            creator: msg.sender,
            operatorDelay: operatorDelay
        });
        _addPending(questionId);

        emit PriceQuestionCreated(
            questionId, feed, QuestionType.ABOVE_THRESHOLD, 0, endTime, threshold, 0, msg.sender, operatorDelay
        );
    }

    /// @notice Create an In Range price question.
    /// @dev Resolves YES if lowerBound <= price < upperBound at endTime.
    /// @param questionId The Diamond's question ID.
    /// @param feed Chainlink price feed address (must be whitelisted).
    /// @param endTime Timestamp when to check the price.
    /// @param lowerBound Lower bound (inclusive, in feed's decimals).
    /// @param upperBound Upper bound (exclusive, in feed's decimals).
    /// @param operatorDelay Seconds after endTime during which only operator/owner/resolver can settle. 0 = permissionless immediately.
    function createInRange(
        bytes32 questionId,
        address feed,
        uint64 endTime,
        int256 lowerBound,
        int256 upperBound,
        uint64 operatorDelay
    ) external {
        if (!isOperator[msg.sender] && msg.sender != owner && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        if (questionId == bytes32(0)) revert QuestionNotCreated();
        if (!allowedFeeds[feed]) revert FeedNotWhitelisted();
        if (questions[questionId].feed != address(0)) revert QuestionAlreadyCreated();
        if (endTime <= uint64(block.timestamp)) revert InvalidTimeRange();
        if (lowerBound < 0 || upperBound <= lowerBound) revert InvalidRange();
        if (operatorDelay > maxOperatorDelay) revert DelayTooLong();

        questions[questionId] = PriceQuestion({
            feed: feed,
            qType: QuestionType.IN_RANGE,
            startTime: 0,
            endTime: endTime,
            threshold: lowerBound,
            upperBound: upperBound,
            resolved: false,
            outcome: false,
            startPrice: 0,
            endPrice: 0,
            creator: msg.sender,
            operatorDelay: operatorDelay
        });
        _addPending(questionId);

        emit PriceQuestionCreated(
            questionId, feed, QuestionType.IN_RANGE, 0, endTime, lowerBound, upperBound, msg.sender, operatorDelay
        );
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Settle a price question using on-chain binary search.
    /// @dev Finds the Chainlink rounds closest to the target timestamps via O(log n) binary
    ///      search, computes the outcome, and reports it to the Diamond in one atomic transaction.
    ///      During the operator delay window after endTime, only operator/owner/resolver can call.
    ///      After the delay, anyone can call (permissionless).
    /// @param questionId The question to settle.
    function settleQuestion(bytes32 questionId) external nonReentrant {
        _settleInternal(questionId);
    }

    // ═══════════════════════════════════════════════════════
    // CHAINLINK AUTOMATION
    // ═══════════════════════════════════════════════════════

    /// @notice Chainlink Automation: check if any pending questions need settling.
    /// @dev Called off-chain by Chainlink Automation nodes. Iterates through pending
    ///      questions and returns the first one that's ready. Gas-intensive but free
    ///      (off-chain simulation).
    /// @param checkData Not used — pass empty bytes.
    /// @return upkeepNeeded True if at least one question is ready to settle.
    /// @return performData Encoded questionId to settle.
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        checkData; // silence unused param warning
        for (uint256 i = 0; i < pendingQuestions.length; i++) {
            bytes32 qId = pendingQuestions[i];
            PriceQuestion storage q = questions[qId];
            // Only flag as ready after operator delay has passed (Automation is not an operator)
            uint256 resolveAfter = uint256(q.endTime) + uint256(q.operatorDelay);
            if (!q.resolved && block.timestamp >= resolveAfter) {
                return (true, abi.encode(qId));
            }
        }
        return (false, "");
    }

    /// @notice Chainlink Automation: settle a question identified by checkUpkeep.
    /// @dev Called on-chain by Chainlink Automation nodes when checkUpkeep returns true.
    ///      Uses binary search internally — no round ID hints needed.
    /// @param performData Encoded questionId from checkUpkeep.
    function performUpkeep(bytes calldata performData) external nonReentrant {
        bytes32 questionId = abi.decode(performData, (bytes32));
        _settleInternal(questionId);
    }

    /// @dev Shared settlement logic for settleQuestion() and performUpkeep().
    ///      Steps:
    ///        1. Validate: question exists, not resolved, endTime reached
    ///        2. Enforce operator delay window
    ///        3. Binary-search Chainlink rounds for the closest price at endTime
    ///        4. For UP_DOWN: also binary-search for the closest price at startTime
    ///        5. Evaluate outcome based on question type
    ///        6. Mark resolved, remove from pending list, report to Diamond
    ///
    ///      All prices are read at settlement time — nothing is captured at creation.
    ///      This prevents stale-price manipulation at question creation time.
    function _settleInternal(bytes32 questionId) internal {
        PriceQuestion storage q = questions[questionId];
        if (q.feed == address(0)) revert QuestionNotCreated();
        if (q.resolved) revert QuestionAlreadyResolved();
        if (block.timestamp < q.endTime) revert EndTimeNotReached();

        // Enforce operator review window — only owner, operators, or resolvers can settle during the delay
        if (q.operatorDelay > 0 && block.timestamp < uint256(q.endTime) + uint256(q.operatorDelay)) {
            if (msg.sender != owner && !isOperator[msg.sender] && !_isResolver(questionId, msg.sender)) {
                revert OperatorWindowActive();
            }
        }

        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(q.feed);

        // Find end round via binary search
        uint80 endRoundId = _findClosestRound(feed, q.endTime);
        int256 endPrice = _getPrice(feed, endRoundId, q.endTime);
        q.endPrice = endPrice;

        bool outcome;
        uint80 startRoundId;

        if (q.qType == QuestionType.UP_DOWN) {
            startRoundId = _findClosestRound(feed, q.startTime);
            int256 startPrice = _getPrice(feed, startRoundId, q.startTime);
            q.startPrice = startPrice;
            outcome = endPrice >= startPrice;
        } else if (q.qType == QuestionType.ABOVE_THRESHOLD) {
            outcome = endPrice >= q.threshold;
        } else {
            outcome = endPrice >= q.threshold && endPrice < q.upperBound;
        }

        q.resolved = true;
        q.outcome = outcome;
        _removePending(questionId);

        diamond.reportOutcome(questionId, outcome);

        emit PriceQuestionResolved(
            questionId, outcome, q.qType, q.feed, q.startPrice, endPrice, startRoundId, endRoundId, msg.sender
        );
    }

    // ═══════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════

    /// @dev Read and validate a Chainlink price. Checks positivity, completeness, and staleness.
    ///      Used after _findClosestRound which guarantees updatedAt <= targetTime.
    function _getPrice(IChainlinkAggregatorV3 feed, uint80 roundId, uint64 targetTime) internal view returns (int256) {
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert RoundNotFound();
        if (targetTime - updatedAt > maxStaleness) revert StalePriceData();
        return answer;
    }

    /// @dev Binary search for the Chainlink round closest to (and before/at) a target timestamp.
    ///      Searches within the current phase. If the target is in a previous phase, decrements
    ///      the phaseId and searches there.
    ///
    ///      O(log n) — ~20 iterations max for 1M rounds per phase. Each iteration reads one round.
    function _findClosestRound(IChainlinkAggregatorV3 feed, uint64 targetTime) internal view returns (uint80) {
        // Get latest round and extract phase info
        (uint80 latestRoundId,,, uint256 latestUpdatedAt,) = feed.latestRoundData();
        uint16 phaseId = uint256(latestRoundId >> 64).toUint16();
        uint64 latestAggRound = uint256(latestRoundId & type(uint64).max).toUint64();

        // If latest round is before target, it's the closest
        if (latestUpdatedAt <= targetTime) {
            return latestRoundId;
        }

        // Binary search within the current phase
        uint80 result = _binarySearchPhase(feed, phaseId, 1, latestAggRound, targetTime);

        // If found in current phase, return it
        if (result != 0) return result;

        // If not found (target is before this phase), try previous phases
        while (phaseId > 1) {
            phaseId--;
            // Find the last round of the previous phase by probing
            uint64 prevPhaseLastRound = _findLastRoundInPhase(feed, phaseId);
            if (prevPhaseLastRound == 0) continue;

            result = _binarySearchPhase(feed, phaseId, 1, prevPhaseLastRound, targetTime);
            if (result != 0) return result;
        }

        revert RoundNotFound();
    }

    /// @dev Binary search within a single Chainlink phase.
    ///      Returns the roundId of the last round with updatedAt <= targetTime.
    ///      Returns 0 if no round in this phase is before targetTime.
    function _binarySearchPhase(IChainlinkAggregatorV3 feed, uint16 phaseId, uint64 low, uint64 high, uint64 targetTime)
        internal
        view
        returns (uint80)
    {
        // Check if any round in this phase is before targetTime
        uint80 lowRoundId = (uint80(phaseId) << 64) | uint80(low);
        (,,, uint256 lowUpdatedAt,) = feed.getRoundData(lowRoundId);
        if (lowUpdatedAt == 0 || lowUpdatedAt > targetTime) {
            return 0; // Entire phase is after target
        }

        // Binary search for the last round with updatedAt <= targetTime
        uint64 result = low;
        while (low <= high) {
            uint64 mid = low + (high - low) / 2;
            uint80 midRoundId = (uint80(phaseId) << 64) | uint80(mid);

            // Try to read this round — may not exist if there are gaps
            // mid >= 1 always (low starts at 1 from all call sites and only increases)
            try feed.getRoundData(midRoundId) returns (uint80, int256, uint256, uint256 midUpdatedAt, uint80) {
                if (midUpdatedAt == 0) {
                    // Incomplete round — treat as non-existent, search lower
                    high = mid - 1;
                } else if (midUpdatedAt <= targetTime) {
                    result = mid; // Valid candidate, search higher for closer
                    low = mid + 1;
                } else {
                    // After target, search lower
                    high = mid - 1;
                }
            } catch {
                // Round doesn't exist — search lower
                high = mid - 1;
            }
        }

        return (uint80(phaseId) << 64) | uint80(result);
    }

    /// @dev Find the last valid round in a Chainlink phase by exponential probing.
    ///      Returns 0 if the phase has no valid rounds.
    function _findLastRoundInPhase(IChainlinkAggregatorV3 feed, uint16 phaseId) internal view returns (uint64) {
        // Exponential probe to find an upper bound
        uint64 probe = 1;
        uint64 lastValid = 0;

        while (probe < type(uint64).max / 2) {
            uint80 probeRoundId = (uint80(phaseId) << 64) | uint80(probe);
            try feed.getRoundData(probeRoundId) returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
                if (updatedAt == 0) break; // Incomplete — stop
                lastValid = probe;
                probe *= 2; // Double the probe
            } catch {
                break; // Round doesn't exist — stop
            }
        }

        if (lastValid == 0) return 0;

        // Binary search between lastValid and probe for the exact last round
        uint64 low = lastValid;
        uint64 high = probe;
        while (low < high) {
            uint64 mid = low + (high - low + 1) / 2;
            uint80 midRoundId = (uint80(phaseId) << 64) | uint80(mid);
            try feed.getRoundData(midRoundId) returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
                if (updatedAt != 0) {
                    low = mid; // Valid, search higher
                } else {
                    high = mid - 1; // Invalid, search lower
                }
            } catch {
                high = mid - 1;
            }
        }

        return low;
    }

    /// @dev Add a questionId to the pending list. Called by create functions.
    function _addPending(bytes32 questionId) internal {
        pendingIndex[questionId] = pendingQuestions.length;
        pendingQuestions.push(questionId);
    }

    /// @dev Remove a questionId from the pending list. Called by _settleInternal().
    ///      Uses swap-and-pop for O(1) removal.
    function _removePending(bytes32 questionId) internal {
        uint256 index = pendingIndex[questionId];
        uint256 lastIndex = pendingQuestions.length - 1;

        if (index != lastIndex) {
            bytes32 lastQuestionId = pendingQuestions[lastIndex];
            pendingQuestions[index] = lastQuestionId;
            pendingIndex[lastQuestionId] = index;
        }

        pendingQuestions.pop();
        delete pendingIndex[questionId];
    }

    // ═══════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════

    /// @notice Get the full question data.
    /// @param questionId The question to query.
    /// @return The price question struct.
    function getQuestion(bytes32 questionId) external view returns (PriceQuestion memory) {
        return questions[questionId];
    }

    /// @notice Check if a question has been resolved.
    /// @param questionId The question to check.
    /// @return True if resolved.
    function isResolved(bytes32 questionId) external view returns (bool) {
        return questions[questionId].resolved;
    }

    /// @notice Check if a question is ready to settle (endTime has passed).
    /// @dev Does not account for operatorDelay — non-operators may still be blocked
    ///      during the delay window even when this returns true.
    /// @param questionId The question to check.
    /// @return True if endTime has passed and question is not yet resolved.
    function canResolve(bytes32 questionId) external view returns (bool) {
        PriceQuestion storage q = questions[questionId];
        return q.feed != address(0) && !q.resolved && block.timestamp >= q.endTime;
    }

    /// @notice Get the number of pending (unresolved) questions.
    /// @return The count of pending questions.
    function getPendingCount() external view returns (uint256) {
        return pendingQuestions.length;
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — FEEDS
    // ═══════════════════════════════════════════════════════

    /// @notice Whitelist a Chainlink price feed.
    /// @param feed The feed address (e.g., BTC/USD on Unichain).
    function addFeed(address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        allowedFeeds[feed] = true;
        emit FeedUpdated(feed, true, msg.sender);
    }

    /// @notice Remove a Chainlink price feed from the whitelist.
    /// @param feed The feed address to remove.
    function removeFeed(address feed) external onlyOwner {
        allowedFeeds[feed] = false;
        emit FeedUpdated(feed, false, msg.sender);
    }

    /// @notice Update the maximum allowed staleness for price data.
    /// @param _maxStaleness New max staleness in seconds.
    function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
        if (_maxStaleness == 0) revert StalePriceData();
        uint256 old = maxStaleness;
        maxStaleness = _maxStaleness;
        emit MaxStalenessUpdated(old, _maxStaleness, msg.sender);
    }

    /// @notice Update the maximum allowed operator delay.
    /// @param _maxOperatorDelay New max operator delay in seconds. 0 disables operator delay for new questions.
    function setMaxOperatorDelay(uint64 _maxOperatorDelay) external onlyOwner {
        uint64 old = maxOperatorDelay;
        maxOperatorDelay = _maxOperatorDelay;
        emit MaxOperatorDelayUpdated(old, _maxOperatorDelay, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — QUESTION MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Cancel a question and allow retry with the same questionId.
    /// @dev Resets all state for this questionId, allowing the operator to call
    ///      createUpDown/createAboveThreshold/createInRange again with corrected params.
    ///      Only works before resolution. Callable by owner, any authorized operator,
    ///      or resolver group member assigned to the question.
    ///      WARNING: Does not call diamond.reportOutcome() — if no retry is performed,
    ///      the market must be settled through an alternative path.
    /// @param questionId The question to cancel.
    function cancelQuestion(bytes32 questionId) external {
        PriceQuestion storage q = questions[questionId];
        if (q.feed == address(0)) revert QuestionNotCreated();
        if (q.resolved) revert QuestionAlreadyResolved();
        if (msg.sender != owner && !isOperator[msg.sender] && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        _removePending(questionId);
        address feed = q.feed;
        QuestionType qType = q.qType;
        address creator = q.creator;
        delete questions[questionId];
        emit PriceQuestionCancelled(questionId, msg.sender, feed, qType, creator);
    }

    // ═══════════════════════════════════════════════════════
    // RESOLVER GROUP MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Add or remove members from a resolver group. Only owner or operators can call.
    /// @dev Groups are reusable — multiple questions can share the same groupId.
    ///      Adding/removing members applies instantly to all questions linked to that group.
    /// @param groupId The group identifier (e.g., keccak256("resolution-team-alpha")).
    /// @param members Array of addresses to add or remove.
    /// @param authorized True to add, false to remove.
    function setResolverGroup(bytes32 groupId, address[] calldata members, bool authorized) external {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotOperator();
        if (groupId == bytes32(0)) revert InvalidGroupId();
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            resolverGroups[groupId][members[i]] = authorized;
            emit ResolverGroupUpdated(groupId, members[i], authorized, msg.sender);
        }
    }

    /// @notice Assign a resolver group to a question. Only owner or operators can call.
    /// @dev Members of the assigned group can create, settle (during delay), and cancel.
    ///      Pass bytes32(0) to unassign.
    /// @param questionId The question to assign a group to.
    /// @param groupId The resolver group to assign (bytes32(0) to unassign).
    function assignQuestionGroup(bytes32 questionId, bytes32 groupId) external {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotOperator();
        bytes32 previousGroupId = questionGroup[questionId];
        questionGroup[questionId] = groupId;
        emit QuestionGroupAssigned(questionId, groupId, previousGroupId, msg.sender);
    }

    /// @dev Check if an address is an authorized resolver for a question via its group.
    function _isResolver(bytes32 questionId, address account) internal view returns (bool) {
        bytes32 groupId = questionGroup[questionId];
        return groupId != bytes32(0) && resolverGroups[groupId][account];
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — OPERATORS
    // ═══════════════════════════════════════════════════════

    /// @notice Authorize a new operator.
    /// @param operator The address to authorize.
    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (isOperator[operator]) revert AlreadyOperator();
        isOperator[operator] = true;
        emit OperatorUpdated(operator, true, msg.sender);
    }

    /// @notice Revoke an operator's authorization.
    /// @param operator The address to revoke.
    function removeOperator(address operator) external onlyOwner {
        if (!isOperator[operator]) revert NotAuthorizedOperator();
        isOperator[operator] = false;
        emit OperatorUpdated(operator, false, msg.sender);
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
