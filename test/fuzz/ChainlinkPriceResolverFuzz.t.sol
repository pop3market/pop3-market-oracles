// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ChainlinkPriceResolver} from "../../src/ChainlinkPriceResolver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @title ChainlinkPriceResolverFuzzTest
/// @notice Stateless fuzz tests for ChainlinkPriceResolver — validates correctness properties
///         for create functions, settlement outcomes, and admin operations across random inputs.
contract ChainlinkPriceResolverFuzzTest is Test {
    address constant OWNER = address(0xABCD);
    address constant OPERATOR = address(0x7777);

    uint256 constant MAX_STALENESS = 3600;
    uint64 constant MAX_OPERATOR_DELAY = 3600;
    uint16 constant PHASE_ID = 1;

    ChainlinkPriceResolver resolver;
    MockDiamondOracle diamond;
    MockChainlinkAggregator feed;

    function setUp() public {
        diamond = new MockDiamondOracle();
        feed = new MockChainlinkAggregator(8);
        resolver = new ChainlinkPriceResolver(address(diamond), MAX_STALENESS, MAX_OPERATOR_DELAY, OWNER, OPERATOR);

        vm.prank(OWNER);
        resolver.addFeed(address(feed));

        vm.warp(100);
    }

    function _encodeRound(uint16 phaseId, uint64 aggRound) internal pure returns (uint80) {
        return (uint80(phaseId) << 64) | uint80(aggRound);
    }

    // ═══════════════════════════════════════════════════════
    // UP_DOWN OUTCOME PROPERTY
    // ═══════════════════════════════════════════════════════

    /// @notice For any startPrice and endPrice, UP_DOWN outcome is:
    ///         YES iff endPrice >= startPrice.
    function testFuzz_settleUpDown_outcomeProperty(int256 startPrice, int256 endPrice) public {
        // Bound to valid positive prices
        startPrice = bound(startPrice, 1, type(int128).max);
        endPrice = bound(endPrice, 1, type(int128).max);

        uint64 startTime = 1000;
        uint64 endTime = 2000;

        // Set up feed rounds
        feed.setRoundData(_encodeRound(PHASE_ID, 1), startPrice, startTime, startTime);
        feed.setRoundData(_encodeRound(PHASE_ID, 2), endPrice, endTime, endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 2));

        bytes32 qId = keccak256(abi.encode("fuzz-ud", startPrice, endPrice));

        vm.prank(OPERATOR);
        resolver.createUpDown(qId, address(feed), startTime, endTime, 0);

        vm.warp(endTime);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.outcome, endPrice >= startPrice);
    }

    // ═══════════════════════════════════════════════════════
    // ABOVE_THRESHOLD OUTCOME PROPERTY
    // ═══════════════════════════════════════════════════════

    /// @notice For any price and threshold (both positive), ABOVE_THRESHOLD outcome is:
    ///         YES iff price >= threshold.
    function testFuzz_settleAboveThreshold_outcomeProperty(int256 price, int256 threshold) public {
        price = bound(price, 1, type(int128).max);
        threshold = bound(threshold, 1, type(int128).max);

        uint64 endTime = 2000;

        feed.setRoundData(_encodeRound(PHASE_ID, 1), price, endTime, endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256(abi.encode("fuzz-at", price, threshold));

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), endTime, threshold, 0);

        vm.warp(endTime);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.outcome, price >= threshold);
    }

    // ═══════════════════════════════════════════════════════
    // IN_RANGE OUTCOME PROPERTY
    // ═══════════════════════════════════════════════════════

    /// @notice For any price and valid [lower, upper) range, IN_RANGE outcome is:
    ///         YES iff lower <= price < upper.
    function testFuzz_settleInRange_outcomeProperty(int256 price, int256 lower, int256 upper) public {
        price = bound(price, 1, type(int128).max);
        lower = bound(lower, 0, type(int128).max - 1);
        upper = bound(upper, lower + 1, type(int128).max);

        uint64 endTime = 2000;

        feed.setRoundData(_encodeRound(PHASE_ID, 1), price, endTime, endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256(abi.encode("fuzz-ir", price, lower, upper));

        vm.prank(OPERATOR);
        resolver.createInRange(qId, address(feed), endTime, lower, upper, 0);

        vm.warp(endTime);
        resolver.settleQuestion(qId);

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.outcome, price >= lower && price < upper);
    }

    // ═══════════════════════════════════════════════════════
    // CREATE REVERTS
    // ═══════════════════════════════════════════════════════

    /// @notice Non-authorized callers always revert on create.
    function testFuzz_create_nonAuthorizedReverts(address caller) public {
        vm.assume(caller != OPERATOR && caller != OWNER);
        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotQuestionAuthorized.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 200, 300, 0);
    }

    /// @notice createUpDown: endTime <= startTime always reverts.
    function testFuzz_createUpDown_invalidTimeRange(uint64 startTime, uint64 endTime) public {
        vm.assume(startTime > 0);
        vm.assume(endTime <= startTime);
        vm.assume(endTime > uint64(block.timestamp)); // avoid the other revert

        // endTime <= startTime should revert (but endTime <= timestamp would revert first)
        // Since we need endTime > timestamp AND endTime <= startTime, and timestamp=100,
        // this means startTime >= endTime > 100
        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidTimeRange.selector);
        resolver.createUpDown(keccak256("q"), address(feed), startTime, endTime, 0);
    }

    /// @notice createAboveThreshold: non-positive threshold always reverts.
    function testFuzz_createAboveThreshold_invalidThreshold(int256 threshold) public {
        threshold = bound(threshold, type(int256).min, 0);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidThreshold.selector);
        resolver.createAboveThreshold(keccak256("q"), address(feed), 200, threshold, 0);
    }

    /// @notice createInRange: negative lowerBound always reverts.
    function testFuzz_createInRange_negativeLowerBound(int256 lower) public {
        lower = bound(lower, type(int256).min, -1);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 200, lower, 100e8, 0);
    }

    /// @notice createInRange: upperBound <= lowerBound always reverts.
    function testFuzz_createInRange_invalidRange(int256 lower, int256 upper) public {
        lower = bound(lower, 0, type(int128).max);
        upper = bound(upper, type(int256).min, lower);

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.InvalidRange.selector);
        resolver.createInRange(keccak256("q"), address(feed), 200, lower, upper, 0);
    }

    // ═══════════════════════════════════════════════════════
    // OPERATOR DELAY
    // ═══════════════════════════════════════════════════════

    /// @notice Any operatorDelay > maxOperatorDelay reverts with DelayTooLong.
    function testFuzz_create_delayTooLong(uint64 delay) public {
        delay = uint64(bound(uint256(delay), uint256(MAX_OPERATOR_DELAY) + 1, type(uint64).max));

        vm.prank(OPERATOR);
        vm.expectRevert(ChainlinkPriceResolver.DelayTooLong.selector);
        resolver.createUpDown(keccak256("q"), address(feed), 200, 300, delay);
    }

    /// @notice During operator delay, non-operator non-owner always reverts.
    function testFuzz_settle_operatorDelayBlocksPublic(uint64 delay, uint64 timeAfterEnd) public {
        delay = uint64(bound(uint256(delay), 1, MAX_OPERATOR_DELAY));
        timeAfterEnd = uint64(bound(uint256(timeAfterEnd), 0, uint256(delay) - 1));

        uint64 endTime = 2000;

        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, endTime, endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        bytes32 qId = keccak256(abi.encode("fuzz-delay", delay, timeAfterEnd));

        vm.prank(OPERATOR);
        resolver.createAboveThreshold(qId, address(feed), endTime, 40000e8, delay);

        vm.warp(uint256(endTime) + uint256(timeAfterEnd));
        vm.prank(address(0xDEAD));
        vm.expectRevert(ChainlinkPriceResolver.OperatorWindowActive.selector);
        resolver.settleQuestion(qId);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN FUZZ
    // ═══════════════════════════════════════════════════════

    /// @notice Non-owner callers always revert on admin functions.
    function testFuzz_admin_nonOwnerReverts(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.addFeed(address(0x1234));

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.removeFeed(address(feed));

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.setMaxStaleness(1);

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.addOperator(address(0x1234));

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.setDiamond(address(0x1234));

        vm.prank(caller);
        vm.expectRevert(ChainlinkPriceResolver.NotOwner.selector);
        resolver.proposeOwner(address(0x1234));
    }

    /// @notice Any non-zero maxStaleness can be set by owner.
    function testFuzz_setMaxStaleness_success(uint256 staleness) public {
        staleness = bound(staleness, 1, type(uint256).max);
        vm.prank(OWNER);
        resolver.setMaxStaleness(staleness);
        assertEq(resolver.maxStaleness(), staleness);
    }

    /// @notice Constructor rejects zero addresses.
    function testFuzz_constructor_rejectsZeroAddresses(address d, address o, address op) public {
        bool anyZero = d == address(0) || o == address(0) || op == address(0);
        if (anyZero) {
            vm.expectRevert(ChainlinkPriceResolver.ZeroAddress.selector);
            new ChainlinkPriceResolver(d, MAX_STALENESS, MAX_OPERATOR_DELAY, o, op);
        } else {
            ChainlinkPriceResolver r = new ChainlinkPriceResolver(d, MAX_STALENESS, MAX_OPERATOR_DELAY, o, op);
            assertEq(address(r.diamond()), d);
            assertEq(r.owner(), o);
            assertTrue(r.isOperator(op));
        }
    }
}
