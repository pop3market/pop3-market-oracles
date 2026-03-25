// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ChainlinkPriceResolver} from "../../src/ChainlinkPriceResolver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @title ChainlinkPriceResolverTest
/// @notice Comprehensive unit + integration tests for ChainlinkPriceResolver.
///         Covers all branches: constructor, create functions, settlement, admin, views.
contract ChainlinkPriceResolverTest is Test {
    // ── Constants ──────────────────────────────────────────
    address constant OWNER = address(0xABCD);
    address constant OPERATOR = address(0x7777);
    address constant OPERATOR_2 = address(0x8888);
    address constant NEW_OWNER = address(0x9999);
    address constant RANDOM = address(0xBEEF);

    uint256 constant MAX_STALENESS = 3600; // 1 hour
    uint64 constant MAX_OPERATOR_DELAY = 3600; // 1 hour
    uint8 constant FEED_DECIMALS = 8;

    // Phase 1, aggregator round encoding
    uint16 constant PHASE_ID = 1;

    // ── State ──────────────────────────────────────────────
    ChainlinkPriceResolver resolver;
    MockDiamondOracle diamond;
    MockChainlinkAggregator feed;

    // ── Events (redeclared for vm.expectEmit) ──────────────
    event PriceQuestionCreated(
        bytes32 indexed questionId,
        address indexed feed,
        ChainlinkPriceResolver.QuestionType questionType,
        uint64 startTime,
        uint64 endTime,
        int256 threshold,
        int256 upperBound,
        address indexed creator,
        uint64 operatorDelay
    );
    event PriceQuestionResolved(
        bytes32 indexed questionId,
        bool outcome,
        ChainlinkPriceResolver.QuestionType questionType,
        address indexed feed,
        int256 startPrice,
        int256 endPrice,
        uint80 startRoundId,
        uint80 endRoundId,
        address indexed resolver
    );
    event FeedUpdated(address indexed feed, bool allowed, address indexed caller);
    event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);
    event MaxStalenessUpdated(uint256 oldMaxStaleness, uint256 newMaxStaleness, address indexed caller);
    event PriceQuestionCancelled(
        bytes32 indexed questionId,
        address indexed canceller,
        address indexed feed,
        ChainlinkPriceResolver.QuestionType questionType,
        address creator
    );
    event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed caller);
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MaxOperatorDelayUpdated(uint64 oldMaxDelay, uint64 newMaxDelay, address indexed caller);

    // ═══════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════

    function _encodeRound(uint16 phaseId, uint64 aggRound) internal pure returns (uint80) {
        return (uint80(phaseId) << 64) | uint80(aggRound);
    }

    /// @dev Sets up a simple feed with sequential rounds in phase 1.
    ///      10 rounds, 60s apart, starting at ts=1000, price=50000e8.
    function _setupSimpleFeed() internal {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        // Rounds: 1→t=1000, 2→t=1060, ..., 10→t=1540
    }

    /// @dev Create an UP_DOWN question with a simple future endTime.
    function _createUpDown(bytes32 qId, uint64 startTime, uint64 endTime) internal {
        vm.prank(OPERATOR);
        resolver.createUpDown(qId, address(feed), startTime, endTime, 0);
    }

    /// @dev Create an ABOVE_THRESHOLD question.
    function _createAboveThreshold(bytes32 qId, uint64 endTime, int256 threshold) internal {
        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), endTime, threshold, 0);
    }

    /// @dev Create an IN_RANGE question.
    function _createInRange(bytes32 qId, uint64 endTime, int256 lower, int256 upper) internal {
        vm.prank(OPERATOR);
        resolver.createInRange(qId, address(feed), endTime, lower, upper, 0);
    }

    // ═══════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════

    function setUp() public {
        diamond = new MockDiamondOracle();
        feed = new MockChainlinkAggregator(FEED_DECIMALS);
        resolver = new ChainlinkPriceResolver(address(diamond), MAX_STALENESS, MAX_OPERATOR_DELAY, OWNER, OPERATOR);

        // Whitelist the feed
        vm.prank(OWNER);
        resolver.addFeed(address(feed));

        // Set block timestamp to a base time
        vm.warp(500);
    }

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @notice Constructor sets all state correctly.
    function test_constructor_setsState() public view {
        assertEq(address(resolver.diamond()), address(diamond));
        assertEq(resolver.owner(), OWNER);
        assertEq(resolver.maxStaleness(), MAX_STALENESS);
        assertEq(resolver.maxOperatorDelay(), MAX_OPERATOR_DELAY);
        assertTrue(resolver.isOperator(OPERATOR));
    }

    /// @notice Constructor emits OwnershipTransferred and OperatorUpdated.
    function test_constructor_emitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), OWNER);
        vm.expectEmit(true, true, false, true);
        emit OperatorUpdated(OPERATOR, true, OWNER);
        new ChainlinkPriceResolver(address(diamond), MAX_STALENESS, MAX_OPERATOR_DELAY, OWNER, OPERATOR);
    }

    /// @notice Constructor reverts with ZeroAddress if diamond is zero.
    function test_constructor_revertsIfDiamondZero() public {
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        new ChainlinkPriceResolver(address(0), MAX_STALENESS, MAX_OPERATOR_DELAY, OWNER, OPERATOR);
    }

    /// @notice Constructor reverts with ZeroAddress if owner is zero.
    function test_constructor_revertsIfOwnerZero() public {
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        new ChainlinkPriceResolver(address(diamond), MAX_STALENESS, MAX_OPERATOR_DELAY, address(0), OPERATOR);
    }

    /// @notice Constructor reverts with ZeroAddress if operator is zero.
    function test_constructor_revertsIfOperatorZero() public {
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        new ChainlinkPriceResolver(address(diamond), MAX_STALENESS, MAX_OPERATOR_DELAY, OWNER, address(0));
    }

    /// @notice Constructor reverts with StalePriceData if maxStaleness is zero.
    function test_constructor_revertsIfMaxStalenessZero() public {
        vm.expectRevert(ChainlinkPriceResolver.StalePriceData.selector);
        new ChainlinkPriceResolver(address(diamond), 0, MAX_OPERATOR_DELAY, OWNER, OPERATOR);
    }

    // ═══════════════════════════════════════════════════════
    // createUpDown
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: createUpDown stores question data, adds to pending, emits event.
    function test_createUpDown_success() public {
        bytes32 qId = keccak256("ud1");

        vm.expectEmit(true, true, false, true);
        emit PriceQuestionCreated(
            qId, address(feed), ChainlinkPriceResolver.QuestionType.UP_DOWN, 600, 800, 0, 0, OPERATOR, 0
        );

        vm.prank(OPERATOR);
        resolver.createUpDown(qId, address(feed), 600, 800, 0);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(q.feed, address(feed));
        assertEq(uint256(q.qType), uint256(ChainlinkPriceResolver.QuestionType.UP_DOWN));
        assertEq(q.startTime, 600);
        assertEq(q.endTime, 800);
        assertEq(q.threshold, 0);
        assertEq(q.upperBound, 0);
        assertFalse(q.resolved);
        assertEq(q.creator, OPERATOR);
        assertEq(q.operatorDelay, 0);
        assertEq(resolver.getPendingCount(), 1);
    }

    /// @notice createUpDown reverts if caller is not an operator.
    function test_createUpDown_revertsIfNotOperator() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 600, 800, 0);
    }

    /// @notice createUpDown reverts if feed is not whitelisted.
    function test_createUpDown_revertsIfFeedNotWhitelisted() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.FeedNotWhitelisted.selector);
        resolver.createUpDown(keccak256("q"), address(0x1234), 600, 800, 0);
    }

    /// @notice createUpDown reverts if questionId already exists.
    function test_createUpDown_revertsIfAlreadyCreated() public {
        bytes32 qId = keccak256("dup");
        _createUpDown(qId, 600, 800);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionAlreadyCreated.selector);
        resolver.createUpDown(qId, address(feed), 600, 800, 0);
    }

    /// @notice createUpDown reverts if startTime is zero.
    function test_createUpDown_revertsIfStartTimeZero() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 0, 800, 0);
    }

    /// @notice createUpDown reverts if endTime <= startTime.
    function test_createUpDown_revertsIfEndTimeLteStartTime() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 600, 600, 0);
    }

    /// @notice createUpDown reverts if endTime is in the past.
    function test_createUpDown_revertsIfEndTimeInPast() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 100, 400, 0);
    }

    /// @notice createUpDown reverts if operatorDelay exceeds maxOperatorDelay.
    function test_createUpDown_revertsIfDelayTooLong() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.DelayTooLong.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 600, 800, MAX_OPERATOR_DELAY + 1);
    }

    /// @notice createUpDown succeeds with operatorDelay at exactly maxOperatorDelay.
    function test_createUpDown_succeedsAtMaxDelay() public {
        vm.prank(OPERATOR);
        resolver.createUpDown(keccak256("q"), address(feed), 600, 800, MAX_OPERATOR_DELAY);
        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(keccak256("q"));
        assertEq(q.operatorDelay, MAX_OPERATOR_DELAY);
    }

    // ═══════════════════════════════════════════════════════
    // createAboveThreshold
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: createAboveThreshold stores question data correctly.
    function test_createAboveThreshold_success() public {
        bytes32 qId = keccak256("at1");
        int256 threshold = 100_000e8;

        vm.expectEmit(true, true, false, true);
        emit PriceQuestionCreated(
            qId, address(feed), ChainlinkPriceResolver.QuestionType.ABOVE_THRESHOLD, 0, 800, threshold, 0, OPERATOR, 0
        );

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 800, threshold, 0);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(uint256(q.qType), uint256(ChainlinkPriceResolver.QuestionType.ABOVE_THRESHOLD));
        assertEq(q.startTime, 0);
        assertEq(q.endTime, 800);
        assertEq(q.threshold, threshold);
    }

    /// @notice createAboveThreshold reverts if threshold is zero.
    function test_createAboveThreshold_revertsIfThresholdZero() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidThreshold.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 800, 0, 0);
    }

    /// @notice createAboveThreshold reverts if threshold is negative.
    function test_createAboveThreshold_revertsIfThresholdNegative() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidThreshold.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 800, -1, 0);
    }

    /// @notice createAboveThreshold reverts if endTime is in the past.
    function test_createAboveThreshold_revertsIfEndTimeInPast() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 400, 100e8, 0);
    }

    /// @notice createAboveThreshold reverts if feed not whitelisted.
    function test_createAboveThreshold_revertsIfFeedNotWhitelisted() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.FeedNotWhitelisted.selector);
        resolver.createAboveThreshold(keccak256("q"), address(0x1234), 800, 100e8, 0);
    }

    /// @notice createAboveThreshold reverts if questionId already exists.
    function test_createAboveThreshold_revertsIfAlreadyCreated() public {
        bytes32 qId = keccak256("at-dup");
        _createAboveThreshold(qId, 800, 100e8);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionAlreadyCreated.selector);
        resolver.createAboveThreshold(qId, address(feed), 800, 100e8, 0);
    }

    /// @notice createAboveThreshold reverts if operatorDelay too long.
    function test_createAboveThreshold_revertsIfDelayTooLong() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.DelayTooLong.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 800, 100e8, MAX_OPERATOR_DELAY + 1);
    }

    // ═══════════════════════════════════════════════════════
    // createInRange
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: createInRange stores question data correctly.
    function test_createInRange_success() public {
        bytes32 qId = keccak256("ir1");

        vm.expectEmit(true, true, false, true);
        emit PriceQuestionCreated(
            qId, address(feed), ChainlinkPriceResolver.QuestionType.IN_RANGE, 0, 800, 90_000e8, 100_000e8, OPERATOR, 0
        );

        vm.prank(OPERATOR);
        resolver.createInRange(qId, address(feed), 800, 90_000e8, 100_000e8, 0);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(uint256(q.qType), uint256(ChainlinkPriceResolver.QuestionType.IN_RANGE));
        assertEq(q.threshold, 90_000e8);
        assertEq(q.upperBound, 100_000e8);
    }

    /// @notice createInRange reverts if lowerBound is negative.
    function test_createInRange_revertsIfLowerBoundNegative() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 800, -1, 100e8, 0);
    }

    /// @notice createInRange reverts if upperBound == lowerBound.
    function test_createInRange_revertsIfUpperEqLower() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 800, 100e8, 100e8, 0);
    }

    /// @notice createInRange reverts if upperBound < lowerBound.
    function test_createInRange_revertsIfUpperLtLower() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 800, 200e8, 100e8, 0);
    }

    /// @notice createInRange allows lowerBound == 0 (valid).
    function test_createInRange_succeedsWithZeroLowerBound() public {
        vm.prank(OPERATOR);
        resolver.createInRange(keccak256("q"), address(feed), 800, 0, 100e8, 0);
        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(keccak256("q"));
        assertEq(q.threshold, 0);
    }

    /// @notice createInRange reverts if endTime in past.
    function test_createInRange_revertsIfEndTimeInPast() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 400, 90e8, 100e8, 0);
    }

    /// @notice createInRange reverts if feed not whitelisted.
    function test_createInRange_revertsIfFeedNotWhitelisted() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.FeedNotWhitelisted.selector);
        resolver.createInRange(keccak256("q"), address(0x1234), 800, 90e8, 100e8, 0);
    }

    /// @notice createInRange reverts if operatorDelay too long.
    function test_createInRange_revertsIfDelayTooLong() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.DelayTooLong.selector);
        resolver.createInRange(keccak256("q"), address(feed), 800, 90e8, 100e8, MAX_OPERATOR_DELAY + 1);
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — UP_DOWN
    // ═══════════════════════════════════════════════════════

    /// @notice Settle UP_DOWN: endPrice >= startPrice → YES.
    function test_settleUpDown_yesOutcome() public {
        // Round 1: t=1000, price=50000e8 (start price)
        // Round 5: t=1240, price=55000e8 (end price, higher)
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        feed.setRoundData(_encodeRound(PHASE_ID, 5), 55000e8, 1240, 1240);

        bytes32 qId = keccak256("ud-yes");
        // startTime=1000, endTime=1240
        _createUpDown(qId, 1000, 1240);

        vm.warp(1240);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertTrue(q.outcome); // endPrice(55000) >= startPrice(50000) → YES
        assertEq(q.startPrice, 50000e8);
        assertEq(q.endPrice, 55000e8);
    }

    /// @notice Settle UP_DOWN: endPrice < startPrice → NO.
    function test_settleUpDown_noOutcome() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        // Set round 5 to have a lower price
        feed.setRoundData(_encodeRound(PHASE_ID, 5), 45000e8, 1240, 1240);

        bytes32 qId = keccak256("ud-no");
        _createUpDown(qId, 1000, 1240);

        vm.warp(1240);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertFalse(q.outcome); // endPrice(45000) < startPrice(50000) → NO
    }

    /// @notice Settle UP_DOWN: endPrice == startPrice → YES (>= comparison).
    function test_settleUpDown_equalPricesIsYes() public {
        // Both start and end at same price
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ud-eq");
        _createUpDown(qId, 1000, 1240);

        vm.warp(1240);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.outcome); // 50000 >= 50000 → YES
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — ABOVE_THRESHOLD
    // ═══════════════════════════════════════════════════════

    /// @notice Settle ABOVE_THRESHOLD: price >= threshold → YES.
    function test_settleAboveThreshold_yesOutcome() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("at-yes");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.outcome); // 50000 >= 40000 → YES
    }

    /// @notice Settle ABOVE_THRESHOLD: price < threshold → NO.
    function test_settleAboveThreshold_noOutcome() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("at-no");
        _createAboveThreshold(qId, 1000, 60000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertFalse(q.outcome); // 50000 < 60000 → NO
    }

    /// @notice Settle ABOVE_THRESHOLD: price == threshold → YES.
    function test_settleAboveThreshold_exactThreshold() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("at-exact");
        _createAboveThreshold(qId, 1000, 50000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.outcome); // 50000 >= 50000 → YES
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — IN_RANGE
    // ═══════════════════════════════════════════════════════

    /// @notice Settle IN_RANGE: lowerBound <= price < upperBound → YES.
    function test_settleInRange_yesOutcome() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ir-yes");
        _createInRange(qId, 1000, 45000e8, 55000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.outcome); // 45000 <= 50000 < 55000 → YES
    }

    /// @notice Settle IN_RANGE: price < lowerBound → NO.
    function test_settleInRange_belowRange() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ir-below");
        _createInRange(qId, 1000, 55000e8, 60000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertFalse(q.outcome); // 50000 < 55000 → NO
    }

    /// @notice Settle IN_RANGE: price >= upperBound → NO (exclusive upper bound).
    function test_settleInRange_atUpperBound() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ir-upper");
        _createInRange(qId, 1000, 45000e8, 50000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertFalse(q.outcome); // 50000 >= 50000 (upper bound is exclusive) → NO
    }

    /// @notice Settle IN_RANGE: price == lowerBound → YES (inclusive lower bound).
    function test_settleInRange_atLowerBound() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ir-lower");
        _createInRange(qId, 1000, 50000e8, 60000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.outcome); // 50000 >= 50000 && 50000 < 60000 → YES
    }

    /// @notice Settle IN_RANGE: price above range → NO.
    function test_settleInRange_aboveRange() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 qId = keccak256("ir-above");
        _createInRange(qId, 1000, 40000e8, 45000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertFalse(q.outcome); // 50000 >= 45000 upper bound → NO
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — REVERTS
    // ═══════════════════════════════════════════════════════

    /// @notice settleQuestion reverts if question doesn't exist.
    function test_settleQuestion_revertsIfNotCreated() public {
        vm.expectRevert(ChainlinkPriceResolver.QuestionNotCreated.selector);
        resolver.settleQuestion(keccak256("nonexistent"));
    }

    /// @notice settleQuestion reverts if already resolved.
    function test_settleQuestion_revertsIfAlreadyResolved() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("resolved");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        vm.expectRevert(ChainlinkPriceResolver.QuestionAlreadyResolved.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice settleQuestion reverts if endTime not reached.
    function test_settleQuestion_revertsIfEndTimeNotReached() public {
        bytes32 qId = keccak256("early");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(999);
        vm.expectRevert(ChainlinkPriceResolver.EndTimeNotReached.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice Settlement reports to Diamond and removes from pending list.
    function test_settleQuestion_reportsAndRemovesPending() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("report");
        _createAboveThreshold(qId, 1000, 40000e8);

        assertEq(resolver.getPendingCount(), 1);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        // Diamond received the outcome
        assertEq(diamond.reportOutcomeCallCount(), 1);
        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, qId);
        assertTrue(outO);

        // Pending list is now empty
        assertEq(resolver.getPendingCount(), 0);
    }

    /// @notice Settlement emits PriceQuestionResolved event.
    function test_settleQuestion_emitsEvent() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("event");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);

        // Note: We check the event is emitted (not exact values for round IDs since binary search)
        vm.expectEmit(true, false, false, false);
        emit PriceQuestionResolved(
            qId,
            true,
            ChainlinkPriceResolver.QuestionType.ABOVE_THRESHOLD,
            address(feed),
            0,
            50000e8,
            0,
            0,
            address(this)
        );

        resolver.settleQuestion(qId);
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — OPERATOR DELAY
    // ═══════════════════════════════════════════════════════

    /// @notice During operator delay window, non-operator non-owner cannot settle.
    function test_settleQuestion_operatorDelayBlocksPublic() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("delay");

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 1000, 40000e8, 300); // 300s delay

        // At endTime (1000), within delay window (until 1300)
        vm.warp(1000);
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.OperatorWindowActive.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice During operator delay window, operator CAN settle.
    function test_settleQuestion_operatorCanSettleDuringDelay() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("delay-op");

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 1000, 40000e8, 300);

        vm.warp(1000);
        vm.prank(OPERATOR);
        resolver.settleQuestion(qId);

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    /// @notice During operator delay window, owner CAN settle.
    function test_settleQuestion_ownerCanSettleDuringDelay() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("delay-owner");

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 1000, 40000e8, 300);

        vm.warp(1000);
        vm.prank(OWNER);
        resolver.settleQuestion(qId);

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    /// @notice After operator delay expires, anyone can settle.
    function test_settleQuestion_publicAfterDelayExpires() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("delay-expired");

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 1000, 40000e8, 300);

        // After delay window (endTime=1000, delay=300, so resolveAfter=1300)
        vm.warp(1300);
        vm.prank(RANDOM);
        resolver.settleQuestion(qId);

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    /// @notice Zero operatorDelay means anyone can settle immediately after endTime.
    function test_settleQuestion_zeroDelayIsPermissionless() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("no-delay");
        _createAboveThreshold(qId, 1000, 40000e8); // delay = 0

        vm.warp(1000);
        vm.prank(RANDOM);
        resolver.settleQuestion(qId);

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — STALE PRICE / INVALID PRICE
    // ═══════════════════════════════════════════════════════

    /// @notice Settlement reverts with StalePriceData if price is too old.
    function test_settleQuestion_revertsIfStalePrice() public {
        // Round at t=100 is too stale for target at t=5000 (staleness 4900 > 3600)
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, 100, 100);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256("stale");
        _createAboveThreshold(qId, 5000, 40000e8);

        vm.warp(5000);
        vm.expectRevert(ChainlinkPriceResolver.StalePriceData.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice Settlement reverts with InvalidPrice if Chainlink returns price <= 0.
    function test_settleQuestion_revertsIfInvalidPrice() public {
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 0, 1000, 1000);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256("invalid-price");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        vm.expectRevert(ChainlinkPriceResolver.InvalidPrice.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice Settlement reverts with InvalidPrice if Chainlink returns negative price.
    function test_settleQuestion_revertsIfNegativePrice() public {
        feed.setRoundData(_encodeRound(PHASE_ID, 1), -1, 1000, 1000);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256("neg-price");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        vm.expectRevert(ChainlinkPriceResolver.InvalidPrice.selector);
        resolver.settleQuestion(qId);
    }

    /// @notice Settlement reverts with RoundNotFound if updatedAt is 0 (incomplete round).
    function test_settleQuestion_revertsIfIncompleteRound() public {
        // updatedAt = 0 means incomplete
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, 1000, 0);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256("incomplete");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        vm.expectRevert(ChainlinkPriceResolver.RoundNotFound.selector);
        resolver.settleQuestion(qId);
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT — NO ROUND BEFORE TARGET
    // ═══════════════════════════════════════════════════════

    /// @notice Settlement reverts with RoundNotFound when all rounds are after the target.
    ///         The binary search finds no round with updatedAt <= targetTime.
    function test_settleQuestion_revertsIfAllRoundsAfterTarget() public {
        // Only round is after the target time — binary search returns 0, falls through to revert
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, 2000, 2000);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256("after-target");
        _createAboveThreshold(qId, 1500, 40000e8);

        vm.warp(1500);
        vm.expectRevert();
        resolver.settleQuestion(qId);
    }

    // ═══════════════════════════════════════════════════════
    // CHAINLINK AUTOMATION
    // ═══════════════════════════════════════════════════════

    /// @notice checkUpkeep returns false when no pending questions.
    function test_checkUpkeep_noPending() public view {
        (bool needed, bytes memory data) = resolver.checkUpkeep("");
        assertFalse(needed);
        assertEq(data.length, 0);
    }

    /// @notice checkUpkeep returns false when question endTime not reached.
    function test_checkUpkeep_notReady() public {
        _createAboveThreshold(keccak256("q"), 1000, 40000e8);
        vm.warp(999);
        (bool needed,) = resolver.checkUpkeep("");
        assertFalse(needed);
    }

    /// @notice checkUpkeep returns true when question is ready (endTime passed, no delay).
    function test_checkUpkeep_ready() public {
        bytes32 qId = keccak256("ready");
        _createAboveThreshold(qId, 1000, 40000e8);
        vm.warp(1000);
        (bool needed, bytes memory data) = resolver.checkUpkeep("");
        assertTrue(needed);
        assertEq(abi.decode(data, (bytes32)), qId);
    }

    /// @notice checkUpkeep respects operatorDelay — returns false during delay window.
    function test_checkUpkeep_respectsOperatorDelay() public {
        bytes32 qId = keccak256("delay-check");
        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), 1000, 40000e8, 300);

        // At endTime but within delay
        vm.warp(1000);
        (bool needed,) = resolver.checkUpkeep("");
        assertFalse(needed);

        // After delay
        vm.warp(1300);
        (bool needed2,) = resolver.checkUpkeep("");
        assertTrue(needed2);
    }

    /// @notice performUpkeep decodes and settles the question.
    function test_performUpkeep_settlesQuestion() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("perform");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.performUpkeep(abi.encode(qId));

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    // ═══════════════════════════════════════════════════════
    // cancelQuestion
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can cancel any unresolved question.
    function test_cancelQuestion_byOwner() public {
        bytes32 qId = keccak256("cancel-owner");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.expectEmit(true, true, true, true);
        emit PriceQuestionCancelled(
            qId, OWNER, address(feed), ChainlinkPriceResolver.QuestionType.ABOVE_THRESHOLD, OPERATOR
        );

        vm.prank(OWNER);
        resolver.cancelQuestion(qId);

        // Question data is deleted — feed should be address(0)
        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(q.feed, address(0));
        assertEq(resolver.getPendingCount(), 0);
    }

    /// @notice Creator (active operator) can cancel their own question.
    function test_cancelQuestion_byCreator() public {
        bytes32 qId = keccak256("cancel-creator");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.prank(OPERATOR);
        resolver.cancelQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(q.feed, address(0));
    }

    /// @notice Non-creator operator cannot cancel another operator's question.
    /// @notice Any operator can cancel any question (global trust).
    function test_cancelQuestion_succeedsForAnyOperator() public {
        bytes32 qId = keccak256("cancel-wrong-op");
        _createAboveThreshold(qId, 1000, 40000e8); // Created by OPERATOR

        // Add another operator
        vm.prank(OWNER);
        resolver.addOperator(OPERATOR_2);

        // OPERATOR_2 is an operator but not the creator — succeeds (global trust)
        vm.prank(OPERATOR_2);
        resolver.cancelQuestion(qId);
    }

    /// @notice Revoked operator cannot cancel their previously created question.
    function test_cancelQuestion_revertsIfRevokedOperator() public {
        bytes32 qId = keccak256("cancel-revoked");
        _createAboveThreshold(qId, 1000, 40000e8); // Created by OPERATOR

        // Remove operator
        vm.prank(OWNER);
        resolver.removeOperator(OPERATOR);

        // OPERATOR is the creator but no longer an active operator
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.cancelQuestion(qId);
    }

    /// @notice Random address cannot cancel.
    function test_cancelQuestion_revertsIfRandom() public {
        bytes32 qId = keccak256("cancel-random");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.cancelQuestion(qId);
    }

    /// @notice Cannot cancel a non-existent question.
    function test_cancelQuestion_revertsIfNotCreated() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.QuestionNotCreated.selector);
        resolver.cancelQuestion(keccak256("nonexistent"));
    }

    /// @notice Cannot cancel an already resolved question.
    function test_cancelQuestion_revertsIfResolved() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("cancel-resolved");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.QuestionAlreadyResolved.selector);
        resolver.cancelQuestion(qId);
    }

    /// @notice After cancellation, the same questionId can be recreated.
    function test_cancelQuestion_allowsRecreation() public {
        bytes32 qId = keccak256("cancel-recreate");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.prank(OWNER);
        resolver.cancelQuestion(qId);

        // Can now recreate with new params
        _createAboveThreshold(qId, 2000, 60000e8);
        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertEq(q.endTime, 2000);
        assertEq(q.threshold, 60000e8);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — FEEDS
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can add a feed.
    function test_addFeed_success() public {
        address newFeed = address(0x1234);
        vm.expectEmit(true, true, false, true);
        emit FeedUpdated(newFeed, true, OWNER);

        vm.prank(OWNER);
        resolver.addFeed(newFeed);
        assertTrue(resolver.allowedFeeds(newFeed));
    }

    /// @notice addFeed reverts if zero address.
    function test_addFeed_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        resolver.addFeed(address(0));
    }

    /// @notice addFeed reverts if not owner.
    function test_addFeed_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.addFeed(address(0x1234));
    }

    /// @notice Owner can remove a feed.
    function test_removeFeed_success() public {
        vm.expectEmit(true, true, false, true);
        emit FeedUpdated(address(feed), false, OWNER);

        vm.prank(OWNER);
        resolver.removeFeed(address(feed));
        assertFalse(resolver.allowedFeeds(address(feed)));
    }

    /// @notice removeFeed reverts if not owner.
    function test_removeFeed_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.removeFeed(address(feed));
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — STALENESS
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can update max staleness.
    function test_setMaxStaleness_success() public {
        vm.expectEmit(true, false, false, true);
        emit MaxStalenessUpdated(MAX_STALENESS, 7200, OWNER);

        vm.prank(OWNER);
        resolver.setMaxStaleness(7200);
        assertEq(resolver.maxStaleness(), 7200);
    }

    /// @notice setMaxStaleness reverts if zero.
    function test_setMaxStaleness_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.StalePriceData.selector);
        resolver.setMaxStaleness(0);
    }

    /// @notice setMaxStaleness reverts if not owner.
    function test_setMaxStaleness_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.setMaxStaleness(7200);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — OPERATOR DELAY
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can update max operator delay.
    function test_setMaxOperatorDelay_success() public {
        vm.expectEmit(true, false, false, true);
        emit MaxOperatorDelayUpdated(MAX_OPERATOR_DELAY, 7200, OWNER);

        vm.prank(OWNER);
        resolver.setMaxOperatorDelay(7200);
        assertEq(resolver.maxOperatorDelay(), 7200);
    }

    /// @notice setMaxOperatorDelay can be set to zero (disables operator delay for new questions).
    function test_setMaxOperatorDelay_zeroAllowed() public {
        vm.prank(OWNER);
        resolver.setMaxOperatorDelay(0);
        assertEq(resolver.maxOperatorDelay(), 0);
    }

    /// @notice setMaxOperatorDelay reverts if not owner.
    function test_setMaxOperatorDelay_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.setMaxOperatorDelay(7200);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — OPERATORS
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can add an operator.
    function test_addOperator_success() public {
        vm.expectEmit(true, true, false, true);
        emit OperatorUpdated(OPERATOR_2, true, OWNER);

        vm.prank(OWNER);
        resolver.addOperator(OPERATOR_2);
        assertTrue(resolver.isOperator(OPERATOR_2));
    }

    /// @notice addOperator reverts if zero address.
    function test_addOperator_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        resolver.addOperator(address(0));
    }

    /// @notice addOperator reverts if already operator.
    function test_addOperator_revertsIfAlready() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.AlreadyOperator.selector);
        resolver.addOperator(OPERATOR);
    }

    /// @notice addOperator reverts if not owner.
    function test_addOperator_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.addOperator(OPERATOR_2);
    }

    /// @notice Owner can remove an operator.
    function test_removeOperator_success() public {
        vm.expectEmit(true, true, false, true);
        emit OperatorUpdated(OPERATOR, false, OWNER);

        vm.prank(OWNER);
        resolver.removeOperator(OPERATOR);
        assertFalse(resolver.isOperator(OPERATOR));
    }

    /// @notice removeOperator reverts if not an operator.
    function test_removeOperator_revertsIfNotOperator() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.NotAuthorizedOperator.selector);
        resolver.removeOperator(RANDOM);
    }

    /// @notice removeOperator reverts if not owner.
    function test_removeOperator_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.removeOperator(OPERATOR);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — DIAMOND
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can set diamond.
    function test_setDiamond_success() public {
        MockDiamondOracle newDiamond = new MockDiamondOracle();
        vm.expectEmit(true, true, true, false);
        emit DiamondUpdated(address(diamond), address(newDiamond), OWNER);

        vm.prank(OWNER);
        resolver.setDiamond(address(newDiamond));
        assertEq(address(resolver.diamond()), address(newDiamond));
    }

    /// @notice setDiamond reverts if zero.
    function test_setDiamond_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        resolver.setDiamond(address(0));
    }

    /// @notice setDiamond reverts if not owner.
    function test_setDiamond_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.setDiamond(address(0x1234));
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — OWNERSHIP
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can propose new owner.
    function test_proposeOwner_success() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipProposed(OWNER, NEW_OWNER);

        vm.prank(OWNER);
        resolver.proposeOwner(NEW_OWNER);
        assertEq(resolver.proposedOwner(), NEW_OWNER);
    }

    /// @notice proposeOwner reverts if zero.
    function test_proposeOwner_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        resolver.proposeOwner(address(0));
    }

    /// @notice proposeOwner reverts if not owner.
    function test_proposeOwner_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.proposeOwner(NEW_OWNER);
    }

    /// @notice Proposed owner can accept.
    function test_acceptOwnership_success() public {
        vm.prank(OWNER);
        resolver.proposeOwner(NEW_OWNER);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(OWNER, NEW_OWNER);

        vm.prank(NEW_OWNER);
        resolver.acceptOwnership();

        assertEq(resolver.owner(), NEW_OWNER);
        assertEq(resolver.proposedOwner(), address(0));
    }

    /// @notice acceptOwnership reverts if not proposed owner.
    function test_acceptOwnership_revertsIfNotProposed() public {
        vm.prank(OWNER);
        resolver.proposeOwner(NEW_OWNER);

        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotProposedOwner.selector);
        resolver.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /// @notice getQuestion returns default struct for non-existent question.
    function test_getQuestion_nonExistent() public view {
        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(keccak256("none"));
        assertEq(q.feed, address(0));
    }

    /// @notice isResolved returns false for unresolved and true for resolved.
    function test_isResolved() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("isres");
        _createAboveThreshold(qId, 1000, 40000e8);

        assertFalse(resolver.isResolved(qId));

        vm.warp(1000);
        resolver.settleQuestion(qId);
        assertTrue(resolver.isResolved(qId));
    }

    /// @notice canResolve returns correct states.
    function test_canResolve() public {
        bytes32 qId = keccak256("canres");
        _createAboveThreshold(qId, 1000, 40000e8);

        // Before endTime
        assertFalse(resolver.canResolve(qId));

        // At endTime
        vm.warp(1000);
        assertTrue(resolver.canResolve(qId));

        // Non-existent
        assertFalse(resolver.canResolve(keccak256("none")));
    }

    /// @notice canResolve returns false after resolution.
    function test_canResolve_falseAfterResolved() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        bytes32 qId = keccak256("canres-resolved");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);
        assertFalse(resolver.canResolve(qId));
    }

    /// @notice getPendingCount tracks add/remove correctly.
    function test_getPendingCount() public {
        assertEq(resolver.getPendingCount(), 0);

        _createAboveThreshold(keccak256("p1"), 1000, 40000e8);
        assertEq(resolver.getPendingCount(), 1);

        _createAboveThreshold(keccak256("p2"), 2000, 40000e8);
        assertEq(resolver.getPendingCount(), 2);

        // Cancel one
        vm.prank(OWNER);
        resolver.cancelQuestion(keccak256("p1"));
        assertEq(resolver.getPendingCount(), 1);
    }

    // ═══════════════════════════════════════════════════════
    // PENDING LIST — SWAP AND POP
    // ═══════════════════════════════════════════════════════

    /// @notice Removing from the middle of pending list correctly swaps the last element.
    function test_pendingList_swapAndPop() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 q1 = keccak256("p1");
        bytes32 q2 = keccak256("p2");
        bytes32 q3 = keccak256("p3");

        _createAboveThreshold(q1, 1000, 40000e8);
        _createAboveThreshold(q2, 1060, 40000e8);
        _createAboveThreshold(q3, 1120, 40000e8);

        assertEq(resolver.getPendingCount(), 3);

        // Settle q1 (at index 0) — q3 should be swapped to index 0
        vm.warp(1000);
        resolver.settleQuestion(q1);

        assertEq(resolver.getPendingCount(), 2);
        // q3 should now be at index 0, q2 at index 1
        assertEq(resolver.pendingQuestions(0), q3);
        assertEq(resolver.pendingQuestions(1), q2);
    }

    /// @notice Removing the last element doesn't need swapping.
    function test_pendingList_removeLast() public {
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);

        bytes32 q1 = keccak256("p1");
        bytes32 q2 = keccak256("p2");

        _createAboveThreshold(q1, 1000, 40000e8);
        _createAboveThreshold(q2, 1060, 40000e8);

        // Settle q2 (last element)
        vm.warp(1060);
        resolver.settleQuestion(q2);

        assertEq(resolver.getPendingCount(), 1);
        assertEq(resolver.pendingQuestions(0), q1);
    }

    // ═══════════════════════════════════════════════════════
    // INTEGRATION
    // ═══════════════════════════════════════════════════════

    /// @notice Full lifecycle: create UP_DOWN → wait → settle → verify Diamond call.
    function test_integration_fullLifecycleUpDown() public {
        // Setup: price goes from 50000 to 55000
        feed.setupSequentialRounds(PHASE_ID, 10, 50000e8, 1000, 60);
        feed.setRoundData(_encodeRound(PHASE_ID, 5), 55000e8, 1240, 1240);

        bytes32 qId = keccak256("lifecycle");
        _createUpDown(qId, 1000, 1240);

        assertEq(resolver.getPendingCount(), 1);
        assertFalse(resolver.isResolved(qId));

        vm.warp(1240);
        assertTrue(resolver.canResolve(qId));

        resolver.settleQuestion(qId);

        assertTrue(resolver.isResolved(qId));
        assertEq(resolver.getPendingCount(), 0);

        // Diamond was notified
        assertEq(diamond.reportOutcomeCallCount(), 1);
        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, qId);
        assertTrue(outO); // 55000 >= 50000 → YES
    }

    /// @notice Multiple questions: create 3, settle 2, cancel 1.
    function test_integration_multipleQuestions() public {
        feed.setupSequentialRounds(PHASE_ID, 20, 50000e8, 1000, 60);

        bytes32 q1 = keccak256("multi1");
        bytes32 q2 = keccak256("multi2");
        bytes32 q3 = keccak256("multi3");

        _createAboveThreshold(q1, 1000, 40000e8);
        _createAboveThreshold(q2, 1060, 60000e8);
        _createAboveThreshold(q3, 1120, 40000e8);

        assertEq(resolver.getPendingCount(), 3);

        // Settle q1 (YES)
        vm.warp(1000);
        resolver.settleQuestion(q1);
        assertTrue(resolver.getQuestion(q1).outcome);

        // Cancel q2
        vm.prank(OWNER);
        resolver.cancelQuestion(q2);

        // Settle q3 (YES)
        vm.warp(1120);
        resolver.settleQuestion(q3);

        assertEq(resolver.getPendingCount(), 0);
        assertEq(diamond.reportOutcomeCallCount(), 2);
    }

    /// @notice Ownership transfer then new owner manages operators.
    function test_integration_ownershipAndOperatorManagement() public {
        // Transfer ownership
        vm.prank(OWNER);
        resolver.proposeOwner(NEW_OWNER);
        vm.prank(NEW_OWNER);
        resolver.acceptOwnership();

        // New owner adds new operator
        vm.prank(NEW_OWNER);
        resolver.addOperator(OPERATOR_2);

        // New operator creates a question
        vm.prank(OPERATOR_2);
        resolver.createAboveThreshold(keccak256("new-op"), address(feed), 1000, 40000e8, 0);

        // Old owner cannot admin
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.addOperator(address(0xDEAD));
    }

    /// @notice _findClosestRound returns latest round when it's before target.
    function test_findClosestRound_latestBeforeTarget() public {
        // Latest round at t=800, target at t=1000 → should return latest directly
        feed.setLatestRound(_encodeRound(PHASE_ID, 5), 50000e8, 800, 800);
        // Also set round 1 for binary search entry
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, 100, 100);

        bytes32 qId = keccak256("latest-before");
        _createAboveThreshold(qId, 1000, 40000e8);

        vm.warp(1000);
        resolver.settleQuestion(qId);

        assertTrue(resolver.getQuestion(qId).resolved);
    }

    // ═══════════════════════════════════════════════════════
    // COVERAGE — MULTI-PHASE BINARY SEARCH
    // ═══════════════════════════════════════════════════════

    /// @notice createInRange reverts with QuestionAlreadyCreated for duplicate questionId.
    ///         Covers line 333 (IN_RANGE-specific duplicate check).
    function test_createInRange_revertsIfAlreadyCreated() public {
        bytes32 qId = keccak256("ir-dup");
        _createInRange(qId, 1000, 40000e8, 60000e8);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionAlreadyCreated.selector);
        resolver.createInRange(qId, address(feed), 1000, 40000e8, 60000e8, 0);
    }

    /// @notice Settlement finds the correct round via binary search when many contiguous
    ///         rounds exist. Exercises the binary search loop in _binarySearchPhase:
    ///         "midUpdatedAt <= targetTime" (search higher) and "midUpdatedAt > targetTime" (search lower).
    function test_settle_binarySearchFindsCorrectRound() public {
        // 20 contiguous rounds, 60s apart. Target falls between round 8 (t=1420) and round 9 (t=1480).
        feed.setupSequentialRounds(PHASE_ID, 20, 50000e8, 1000, 60);
        // Override round 8 with a distinct price so we can verify it was selected
        feed.setRoundData(_encodeRound(PHASE_ID, 8), 51234e8, 1420, 1420);

        // Target time 1450 — round 8 (t=1420) is the last round at or before target
        bytes32 qId = keccak256("bsearch-mid");
        _createAboveThreshold(qId, 1450, 50000e8);

        vm.warp(1450);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 51234e8); // round 8 was selected
        assertTrue(q.outcome); // 51234 >= 50000
    }

    /// @notice Settlement across Chainlink phase transition. The target timestamp
    ///         falls in phase 1 but the latest round is in phase 2. The binary search
    ///         must fall back to the previous phase.
    ///         Covers lines 497-504 (_findClosestRound previous phase loop),
    ///         lines 557-592 (_findLastRoundInPhase exponential probe + binary search).
    function test_settle_multiPhaseFallback() public {
        uint16 phase1 = 1;
        uint16 phase2 = 2;

        // Phase 1: rounds at t=1000..1300 (4 rounds, 100s apart)
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 41000e8, 1100, 1100);
        feed.setRoundData(_encodeRound(phase1, 3), 42000e8, 1200, 1200);
        feed.setRoundData(_encodeRound(phase1, 4), 43000e8, 1300, 1300);

        // Phase 2: starts at t=2000 (after a gap)
        feed.setRoundData(_encodeRound(phase2, 1), 55000e8, 2000, 2000);
        feed.setRoundData(_encodeRound(phase2, 2), 56000e8, 2100, 2100);
        feed.setLatestRoundId(_encodeRound(phase2, 2));

        // Target at t=1250 — falls in phase 1 (between round 2 and 3)
        // The search starts in phase 2, finds nothing before 1250, then falls back to phase 1
        bytes32 qId = keccak256("multi-phase");
        _createAboveThreshold(qId, 1250, 41500e8);

        vm.warp(1250);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        // Closest round before t=1250 in phase 1 is round 2 (t=1200, price=42000e8)
        assertEq(q.endPrice, 42000e8);
        assertTrue(q.outcome); // 42000 >= 41500
    }

    /// @notice Settlement where the binary search encounters non-existent rounds (gaps)
    ///         in the middle of a phase. The catch branch in _binarySearchPhase (lines 545-548)
    ///         handles this by searching lower.
    function test_settle_binarySearchWithGaps() public {
        // Sparse rounds: only 1, 5, 10 exist — rounds 2-4, 6-9 are gaps
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 45000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(PHASE_ID, 5), 50000e8, 1200, 1200);
        feed.setRoundData(_encodeRound(PHASE_ID, 10), 55000e8, 1500, 1500);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 10));

        // Target at t=1300 — round 5 (t=1200) is closest, binary search must skip gaps
        bytes32 qId = keccak256("gaps");
        _createAboveThreshold(qId, 1300, 49000e8);

        vm.warp(1300);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 50000e8);
        assertTrue(q.outcome); // 50000 >= 49000
    }

    /// @notice _findLastRoundInPhase exponential probing: phase has rounds at 1,2,3 only.
    ///         Probe doubles: 1(exists) → 2(exists) → 4(not exists) → binary search [2,4] → 3.
    ///         Covers the exponential probe loop (lines 562-569) and the refinement binary search
    ///         (lines 578-592) including the catch branch at line 587-588.
    function test_settle_findLastRoundInPhase_exponentialProbe() public {
        uint16 phase1 = 1;
        uint16 phase2 = 2;

        // Phase 1: only 3 rounds
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 41000e8, 1100, 1100);
        feed.setRoundData(_encodeRound(phase1, 3), 42000e8, 1200, 1200);
        // Round 4 does NOT exist — probe will hit the catch branch

        // Phase 2: latest is far in the future
        feed.setRoundData(_encodeRound(phase2, 1), 60000e8, 3000, 3000);
        feed.setLatestRoundId(_encodeRound(phase2, 1));

        // Target at t=1150 — in phase 1, between round 2 (t=1100) and round 3 (t=1200)
        bytes32 qId = keccak256("exp-probe");
        _createAboveThreshold(qId, 1150, 40500e8);

        vm.warp(1150);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 41000e8); // round 2 at t=1100
        assertTrue(q.outcome); // 41000 >= 40500
    }

    /// @notice Multi-phase where the first previous phase has no valid rounds (skip it).
    ///         Covers the `prevPhaseLastRound == 0` continue branch (line 501).
    function test_settle_multiPhase_skipEmptyPhase() public {
        uint16 phase1 = 1;
        uint16 phase3 = 3;

        // Phase 1: has rounds
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 41000e8, 1100, 1100);

        // Phase 2: completely empty (no rounds at all) — _findLastRoundInPhase returns 0
        // (round 1 doesn't exist, so exponential probe immediately breaks)

        // Phase 3: latest round, way after target
        feed.setRoundData(_encodeRound(phase3, 1), 60000e8, 3000, 3000);
        feed.setLatestRoundId(_encodeRound(phase3, 1));

        // Target at t=1050 — phase 3 is after, phase 2 is empty (skip), phase 1 has the answer
        bytes32 qId = keccak256("skip-empty");
        _createAboveThreshold(qId, 1050, 39500e8);

        vm.warp(1050);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 40000e8); // phase 1, round 1 at t=1000
        assertTrue(q.outcome); // 40000 >= 39500
    }

    /// @notice UP_DOWN question that exercises multi-phase for the startTime lookup.
    ///         startPrice is in phase 1, endPrice is in phase 2.
    ///         Verifies both _findClosestRound calls use phase fallback correctly.
    function test_settle_upDown_multiPhaseStartAndEnd() public {
        uint16 phase1 = 1;
        uint16 phase2 = 2;

        // Phase 1: rounds at t=1000-1200
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 42000e8, 1200, 1200);

        // Phase 2: rounds at t=2000+
        feed.setRoundData(_encodeRound(phase2, 1), 50000e8, 2000, 2000);
        feed.setRoundData(_encodeRound(phase2, 2), 51000e8, 2100, 2100);
        feed.setLatestRoundId(_encodeRound(phase2, 2));

        // startTime=1100 (phase 1), endTime=2050 (phase 2)
        bytes32 qId = keccak256("ud-multi-phase");
        _createUpDown(qId, 1100, 2050);

        vm.warp(2050);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        // startPrice = round 1 of phase 1 (t=1000, price=40000)
        assertEq(q.startPrice, 40000e8);
        // endPrice = round 1 of phase 2 (t=2000, price=50000)
        assertEq(q.endPrice, 50000e8);
        assertTrue(q.outcome); // 50000 >= 40000 → YES
    }

    /// @notice Binary search with an incomplete round (updatedAt == 0 mid-search).
    ///         Covers the `midUpdatedAt == 0` branch in _binarySearchPhase (lines 533-536).
    function test_settle_binarySearch_incompleteRoundMidSearch() public {
        // Round 1 (valid), round 2 (incomplete: updatedAt=0), round 3 (valid, after target)
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 45000e8, 1000, 1000);
        // Round 2 exists but is incomplete (updatedAt = 0)
        feed.setRoundData(_encodeRound(PHASE_ID, 2), 48000e8, 1100, 0);
        feed.setRoundData(_encodeRound(PHASE_ID, 3), 50000e8, 1300, 1300);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 3));

        // Target at t=1200 — round 2 is incomplete (skip it), round 1 is the valid candidate
        bytes32 qId = keccak256("incomplete-mid");
        _createAboveThreshold(qId, 1200, 44000e8);

        vm.warp(1200);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 45000e8); // round 1 at t=1000
        assertTrue(q.outcome); // 45000 >= 44000
    }

    /// @notice _findLastRoundInPhase with an incomplete round (updatedAt=0) during
    ///         exponential probing. The probe should stop when it encounters the
    ///         incomplete round, and the valid rounds before it remain discoverable.
    ///         Covers line 565: `if (updatedAt == 0) break;` in exponential probe.
    function test_settle_findLastRound_incompleteRoundStopsProbe() public {
        uint16 phase1 = 1;
        uint16 phase2 = 2;

        // Phase 1: round 1 is valid, round 2 is incomplete (updatedAt=0)
        // The exponential probe starts at 1 (valid, lastValid=1), doubles to 2 (incomplete, break).
        // Then binary search refines between 1 and 2 — finds round 1 is the last valid.
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 41000e8, 1100, 0); // exists but incomplete

        // Phase 2: latest round, after target
        feed.setRoundData(_encodeRound(phase2, 1), 60000e8, 3000, 3000);
        feed.setLatestRoundId(_encodeRound(phase2, 1));

        // Target at t=1050 — falls in phase 1
        bytes32 qId = keccak256("incomplete-probe");
        _createAboveThreshold(qId, 1050, 39000e8);

        vm.warp(1050);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 40000e8); // round 1
        assertTrue(q.outcome); // 40000 >= 39000
    }

    /// @notice _findLastRoundInPhase with incomplete rounds during the refinement
    ///         binary search. After exponential probing finds the upper bound, the
    ///         refinement encounters an incomplete round (updatedAt=0) and narrows downward.
    ///         Covers line 585: `high = mid - 1;` (updatedAt == 0 in refinement).
    function test_settle_findLastRound_incompleteRoundInRefinement() public {
        uint16 phase1 = 1;
        uint16 phase2 = 2;

        // Phase 1: rounds 1-3 are valid, round 4 is incomplete (updatedAt=0), round 5+ don't exist.
        // Exponential probe: 1(valid,lastValid=1) → 2(valid,lastValid=2) → 4(incomplete,break)
        // Refinement binary search between [2, 4]:
        //   mid = 2 + (4-2+1)/2 = 4 → incomplete(updatedAt=0) → high=3
        //   mid = 2 + (3-2+1)/2 = 3 → valid → low=3
        //   low == high == 3 → return 3
        feed.setRoundData(_encodeRound(phase1, 1), 40000e8, 1000, 1000);
        feed.setRoundData(_encodeRound(phase1, 2), 41000e8, 1100, 1100);
        feed.setRoundData(_encodeRound(phase1, 3), 42000e8, 1200, 1200);
        feed.setRoundData(_encodeRound(phase1, 4), 43000e8, 1300, 0); // exists but incomplete

        // Phase 2: latest round
        feed.setRoundData(_encodeRound(phase2, 1), 60000e8, 3000, 3000);
        feed.setLatestRoundId(_encodeRound(phase2, 1));

        // Target at t=1150 — in phase 1, between round 2 (t=1100) and round 3 (t=1200)
        bytes32 qId = keccak256("refine-incomplete");
        _createAboveThreshold(qId, 1150, 40500e8);

        vm.warp(1150);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.endPrice, 41000e8); // round 2 at t=1100
        assertTrue(q.outcome); // 41000 >= 40500
    }

    // ═══════════════════════════════════════════════════════
    // RESOLVER GROUPS
    // ═══════════════════════════════════════════════════════

    address constant RESOLVER_1 = address(0xA001);
    address constant RESOLVER_2 = address(0xA002);
    bytes32 constant GROUP_ID = keccak256("team-alpha");

    /// @notice setResolverGroup adds members and emits events.
    function test_setResolverGroup_addsMembers() public {
        address[] memory members = new address[](2);
        members[0] = RESOLVER_1;
        members[1] = RESOLVER_2;

        vm.prank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);

        assertTrue(resolver.resolverGroups(GROUP_ID, RESOLVER_1));
        assertTrue(resolver.resolverGroups(GROUP_ID, RESOLVER_2));
        assertFalse(resolver.resolverGroups(GROUP_ID, RANDOM));
    }

    /// @notice setResolverGroup removes members with authorized=false.
    function test_setResolverGroup_removesMembers() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.setResolverGroup(GROUP_ID, members, false);
        vm.stopPrank();

        assertFalse(resolver.resolverGroups(GROUP_ID, RESOLVER_1));
    }

    /// @notice setResolverGroup reverts for non-owner/non-operator.
    function test_setResolverGroup_revertsIfUnauthorized() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOperator.selector);
        resolver.setResolverGroup(GROUP_ID, members, true);
    }

    /// @notice setResolverGroup reverts for zero groupId.
    function test_setResolverGroup_revertsIfZeroGroupId() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.InvalidGroupId.selector);
        resolver.setResolverGroup(bytes32(0), members, true);
    }

    /// @notice assignQuestionGroup links a question to a group.
    function test_assignQuestionGroup_success() public {
        bytes32 qId = keccak256("resolver-q");

        vm.prank(OWNER);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        assertEq(resolver.questionGroup(qId), GROUP_ID);
    }

    /// @notice assignQuestionGroup reverts for non-owner/non-operator.
    function test_assignQuestionGroup_revertsIfUnauthorized() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotOperator.selector);
        resolver.assignQuestionGroup(keccak256("q"), GROUP_ID);
    }

    /// @notice Resolver can createUpDown after group assignment.
    function test_resolver_canCreateUpDown() public {
        bytes32 qId = keccak256("resolver-ud");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        resolver.createUpDown(qId, address(feed), 600, 800, 0);

        assertEq(resolver.getQuestion(qId).creator, RESOLVER_1);
    }

    /// @notice Resolver can createAboveThreshold after group assignment.
    function test_resolver_canCreateAboveThreshold() public {
        bytes32 qId = keccak256("resolver-at");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        resolver.createAboveThreshold(qId, address(feed), 800, 50000e8, 0);

        assertEq(resolver.getQuestion(qId).creator, RESOLVER_1);
    }

    /// @notice Resolver can createInRange after group assignment.
    function test_resolver_canCreateInRange() public {
        bytes32 qId = keccak256("resolver-ir");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        resolver.createInRange(qId, address(feed), 800, 40000e8, 50000e8, 0);

        assertEq(resolver.getQuestion(qId).creator, RESOLVER_1);
    }

    /// @notice Resolver cannot create without group assignment.
    function test_resolver_cannotCreateWithoutGroup() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);

        vm.prank(RESOLVER_1);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createUpDown(keccak256("no-group"), address(feed), 600, 800, 0);
    }

    /// @notice createUpDown reverts for questionId == bytes32(0).
    function test_createUpDown_revertsIfZeroQuestionId() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionNotCreated.selector);
        resolver.createUpDown(bytes32(0), address(feed), 600, 800, 0);
    }

    /// @notice createAboveThreshold reverts if caller is not authorized.
    function test_createAboveThreshold_revertsIfNotAuthorized() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 800, 50000e8, 0);
    }

    /// @notice createInRange reverts if caller is not authorized.
    function test_createInRange_revertsIfNotAuthorized() public {
        vm.prank(RANDOM);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createInRange(keccak256("q"), address(feed), 800, 40000e8, 50000e8, 0);
    }

    /// @notice setResolverGroup reverts for zero address member.
    function test_setResolverGroup_revertsIfZeroMember() public {
        address[] memory members = new address[](1);
        members[0] = address(0);

        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
        resolver.setResolverGroup(GROUP_ID, members, true);
    }

    /// @notice createAboveThreshold reverts for questionId == bytes32(0).
    function test_createAboveThreshold_revertsIfZeroQuestionId() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionNotCreated.selector);
        resolver.createAboveThreshold(bytes32(0), address(feed), 800, 50000e8, 0);
    }

    /// @notice createInRange reverts for questionId == bytes32(0).
    function test_createInRange_revertsIfZeroQuestionId() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.QuestionNotCreated.selector);
        resolver.createInRange(bytes32(0), address(feed), 800, 40000e8, 50000e8, 0);
    }

    /// @notice Resolver can cancelQuestion for their authorized question.
    function test_resolver_canCancelQuestion() public {
        bytes32 qId = keccak256("resolver-cancel");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        resolver.createAboveThreshold(qId, address(feed), 800, 50000e8, 0);

        vm.prank(RESOLVER_1);
        resolver.cancelQuestion(qId);

        assertEq(resolver.getQuestion(qId).feed, address(0)); // deleted
    }

    /// @notice Removing member from group revokes access.
    function test_resolverGroup_removalRevokesAccess() public {
        bytes32 qId = keccak256("revoke-test");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId, GROUP_ID);
        resolver.setResolverGroup(GROUP_ID, members, false);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createUpDown(qId, address(feed), 600, 800, 0);
    }

    /// @notice Multiple questions can share the same resolver group.
    function test_resolverGroup_sharedAcrossQuestions() public {
        bytes32 qId1 = keccak256("shared-q1");
        bytes32 qId2 = keccak256("shared-q2");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        resolver.setResolverGroup(GROUP_ID, members, true);
        resolver.assignQuestionGroup(qId1, GROUP_ID);
        resolver.assignQuestionGroup(qId2, GROUP_ID);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        resolver.createAboveThreshold(qId1, address(feed), 800, 50000e8, 0);

        vm.prank(RESOLVER_1);
        resolver.createUpDown(qId2, address(feed), 600, 800, 0);

        assertEq(resolver.getQuestion(qId1).creator, RESOLVER_1);
        assertEq(resolver.getQuestion(qId2).creator, RESOLVER_1);
    }
}
