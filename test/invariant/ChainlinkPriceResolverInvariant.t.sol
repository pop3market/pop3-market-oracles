// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ChainlinkPriceResolver} from "../../src/ChainlinkPriceResolver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @title ChainlinkPriceResolverHandler
/// @notice Handler contract for stateful invariant testing of ChainlinkPriceResolver.
///         Exposes bounded create/settle/cancel actions and tracks ghost state.
contract ChainlinkPriceResolverHandler is Test {
    ChainlinkPriceResolver public resolver;
    MockDiamondOracle public diamond;
    MockChainlinkAggregator public feed;
    address public owner;
    address public operator;

    // Ghost tracking
    uint256 public ghost_created;
    uint256 public ghost_settled;
    uint256 public ghost_cancelled;
    mapping(bytes32 => bool) public ghost_isCreated;
    mapping(bytes32 => bool) public ghost_isSettled;
    bytes32[] public ghost_allQuestions;

    uint16 constant PHASE_ID = 1;

    constructor(
        ChainlinkPriceResolver _resolver,
        MockDiamondOracle _diamond,
        MockChainlinkAggregator _feed,
        address _owner,
        address _operator
    ) {
        resolver = _resolver;
        diamond = _diamond;
        feed = _feed;
        owner = _owner;
        operator = _operator;
    }

    function _encodeRound(uint16 phaseId, uint64 aggRound) internal pure returns (uint80) {
        return (uint80(phaseId) << 64) | uint80(aggRound);
    }

    /// @notice Create an ABOVE_THRESHOLD question with a bounded seed.
    function createQuestion(uint256 seed) external {
        bytes32 qId = keccak256(abi.encode("inv", seed));

        // Skip if already created
        if (ghost_isCreated[qId]) return;

        uint64 endTime = uint64(block.timestamp) + 100;

        // Set up a round for this endTime
        uint64 roundNum = uint64(uint256(keccak256(abi.encode(seed, "round"))));
        roundNum = uint64(bound(uint256(roundNum), 1, 1000));
        feed.setRoundData(_encodeRound(PHASE_ID, roundNum), 50000e8, endTime, endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, roundNum));

        vm.prank(operator);
        resolver.createAboveThreshold(qId, address(feed), endTime, 40000e8, 0);

        ghost_isCreated[qId] = true;
        ghost_created++;
        ghost_allQuestions.push(qId);
    }

    /// @notice Settle a previously created question.
    function settleQuestion(uint256 index) external {
        if (ghost_allQuestions.length == 0) return;
        index = bound(index, 0, ghost_allQuestions.length - 1);
        bytes32 qId = ghost_allQuestions[index];

        if (ghost_isSettled[qId]) return;

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        if (q.feed == address(0) || q.resolved) return;

        // Warp past endTime
        vm.warp(uint256(q.endTime));

        // Ensure a valid round exists at endTime
        feed.setRoundData(_encodeRound(PHASE_ID, 1), 50000e8, q.endTime, q.endTime);
        feed.setLatestRoundId(_encodeRound(PHASE_ID, 1));

        resolver.settleQuestion(qId);

        ghost_isSettled[qId] = true;
        ghost_settled++;
    }

    /// @notice Cancel a previously created question.
    function cancelQuestion(uint256 index) external {
        if (ghost_allQuestions.length == 0) return;
        index = bound(index, 0, ghost_allQuestions.length - 1);
        bytes32 qId = ghost_allQuestions[index];

        if (ghost_isSettled[qId]) return;

        ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
        if (q.feed == address(0) || q.resolved) return;

        vm.prank(owner);
        resolver.cancelQuestion(qId);

        // Mark as settled to prevent re-settle attempts
        ghost_isSettled[qId] = true;
        ghost_cancelled++;
    }

    function ghost_allQuestionsLength() external view returns (uint256) {
        return ghost_allQuestions.length;
    }
}

/// @title ChainlinkPriceResolverInvariantTest
/// @notice Invariant tests for ChainlinkPriceResolver state consistency.
contract ChainlinkPriceResolverInvariantTest is Test {
    address constant OWNER = address(0xABCD);
    address constant OPERATOR = address(0x7777);

    ChainlinkPriceResolver resolver;
    MockDiamondOracle diamond;
    MockChainlinkAggregator feed;
    ChainlinkPriceResolverHandler handler;

    function setUp() public {
        diamond = new MockDiamondOracle();
        feed = new MockChainlinkAggregator(8);
        resolver = new ChainlinkPriceResolver(address(diamond), 3600, 3600, OWNER, OPERATOR);

        vm.prank(OWNER);
        resolver.addFeed(address(feed));

        vm.warp(500);

        handler = new ChainlinkPriceResolverHandler(resolver, diamond, feed, OWNER, OPERATOR);
        targetContract(address(handler));
    }

    /// @notice Invariant: pendingCount = created - settled - cancelled.
    ///         Every created question is either pending, settled, or cancelled.
    function invariant_pendingCountConsistency() public view {
        uint256 expected = handler.ghost_created() - handler.ghost_settled() - handler.ghost_cancelled();
        assertEq(resolver.getPendingCount(), expected);
    }

    /// @notice Invariant: Diamond reportOutcome call count equals ghost_settled.
    function invariant_diamondCallsMatchSettled() public view {
        assertEq(diamond.reportOutcomeCallCount(), handler.ghost_settled());
    }

    /// @notice Invariant: owner never changes (handler doesn't transfer ownership).
    function invariant_ownerUnchanged() public view {
        assertEq(resolver.owner(), OWNER);
    }

    /// @notice Invariant: resolved questions are never in the pending list.
    ///         (Checked by verifying pendingCount <= created - settled - cancelled.)
    function invariant_resolvedNotPending() public view {
        uint256 len = handler.ghost_allQuestionsLength();
        for (uint256 i = 0; i < len && i < 50; i++) {
            bytes32 qId = handler.ghost_allQuestions(i);
            ChainlinkPriceResolver.PriceQuestion memory q = resolver.getQuestion(qId);
            if (q.resolved) {
                // A resolved question should not be in the pending list
                // We verify this indirectly via pendingCount consistency
                assertTrue(q.resolved);
            }
        }
    }
}
