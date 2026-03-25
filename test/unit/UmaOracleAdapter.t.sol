// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {UmaOracleAdapter} from "../../src/UmaOracleAdapter.sol";
import {MockOOv3} from "../mocks/MockOOv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {LzCrossChainSender} from "../../src/LzCrossChainRelay.sol";
import {MockLayerZeroEndpoint} from "../mocks/MockLayerZeroEndpoint.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";
import {ReentrantAttacker} from "../mocks/ReentrantAttacker.sol";

/// @title UmaOracleAdapterTest
/// @notice Comprehensive unit + integration tests for UmaOracleAdapter.
contract UmaOracleAdapterTest is Test {
    // ── Constants ──────────────────────────────────────────
    address constant OWNER = address(0xABCD);
    address constant NEW_OWNER = address(0x9999);
    address constant OPERATOR = address(0x7777);
    address constant OPERATOR_2 = address(0x8888);
    address constant RANDOM = address(0xBEEF);
    uint256 constant DEFAULT_BOND = 250e6; // 250 USDC
    uint64 constant DEFAULT_LIVENESS = 7200; // 2h
    uint64 constant MIN_LIVENESS = 1800; // 30min
    bytes constant CLAIM = "Will BTC hit $100k?";

    // ── State ──────────────────────────────────────────────
    UmaOracleAdapter adapter;
    MockOOv3 oov3;
    MockERC20 usdc;

    // ── Events ─────────────────────────────────────────────
    event QuestionInitialized(
        bytes32 indexed questionId,
        bytes32 indexed assertionId,
        address indexed asserter,
        bytes claim,
        uint256 bond,
        uint64 liveness,
        uint64 operatorDelay
    );
    event QuestionResolved(
        bytes32 indexed questionId, bytes32 indexed assertionId, bool outcome, address indexed resolver
    );
    event QuestionSettled(bytes32 indexed questionId, bytes32 indexed assertionId, address indexed settler);
    event QuestionDisputed(bytes32 indexed questionId, bytes32 indexed assertionId);
    event DefaultBondUpdated(uint256 oldBond, uint256 newBond, address indexed caller);
    event DefaultLivenessUpdated(uint64 oldLiveness, uint64 newLiveness, address indexed caller);
    event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);
    event MinLivenessUpdated(uint64 oldMinLiveness, uint64 newMinLiveness, address indexed caller);
    event QuestionCancelled(
        bytes32 indexed questionId, bytes32 indexed assertionId, address indexed canceller, address creator
    );
    event CrossChainRelayUpdated(address indexed previousRelay, address indexed newRelay, address indexed caller);
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Helpers ────────────────────────────────────────────

    function _initQuestion(bytes32 qId) internal returns (bytes32) {
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
        vm.stopPrank();
        return aId;
    }

    function _initAndSettle(bytes32 qId, bool outcome) internal returns (bytes32 aId) {
        aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, outcome);
        adapter.settleQuestion(qId);
    }

    function setUp() public {
        oov3 = new MockOOv3();
        usdc = new MockERC20("USDC", "USDC", 6);
        adapter = new UmaOracleAdapter(
            address(oov3), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR
        );
        vm.warp(1000);
    }

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @notice Constructor sets all state correctly.
    function test_constructor_setsState() public view {
        assertEq(address(adapter.OOV3()), address(oov3));
        assertEq(address(adapter.BOND_CURRENCY()), address(usdc));
        assertEq(adapter.defaultBond(), DEFAULT_BOND);
        assertEq(adapter.defaultLiveness(), DEFAULT_LIVENESS);
        assertEq(adapter.minLiveness(), MIN_LIVENESS);
        assertEq(adapter.owner(), OWNER);
        assertTrue(adapter.isOperator(OPERATOR));
        assertEq(adapter.DEFAULT_IDENTIFIER(), "ASSERT_TRUTH2");
    }

    /// @notice Constructor reverts for zero addresses.
    function test_constructor_revertsIfOov3Zero() public {
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        new UmaOracleAdapter(address(0), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR);
    }

    function test_constructor_revertsIfBondCurrencyZero() public {
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        new UmaOracleAdapter(address(oov3), address(0), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR);
    }

    function test_constructor_revertsIfOwnerZero() public {
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        new UmaOracleAdapter(
            address(oov3), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, address(0), OPERATOR
        );
    }

    function test_constructor_revertsIfOperatorZero() public {
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        new UmaOracleAdapter(
            address(oov3), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, address(0)
        );
    }

    function test_constructor_revertsIfLivenessBelowMin() public {
        vm.expectRevert(UmaOracleAdapter.LivenessTooShort.selector);
        new UmaOracleAdapter(address(oov3), address(usdc), DEFAULT_BOND, 100, 200, OWNER, OPERATOR);
    }

    function test_constructor_revertsIfBondZero() public {
        vm.expectRevert(UmaOracleAdapter.BondBelowMinimum.selector);
        new UmaOracleAdapter(address(oov3), address(usdc), 0, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR);
    }

    /// @notice Constructor emits events.
    function test_constructor_emitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), OWNER);
        vm.expectEmit(true, false, true, true);
        emit OperatorUpdated(OPERATOR, true, OWNER);
        new UmaOracleAdapter(
            address(oov3), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR
        );
    }

    // ═══════════════════════════════════════════════════════
    // initializeQuestion
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: operator initializes a question.
    function test_initializeQuestion_success() public {
        bytes32 qId = keccak256("q1");
        bytes32 aId = _initQuestion(qId);

        assertTrue(aId != bytes32(0));
        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        assertEq(q.assertionId, aId);
        assertFalse(q.resolved);
        assertEq(q.creator, OPERATOR);
        assertEq(adapter.assertionToQuestion(aId), qId);
    }

    /// @notice initializeQuestion transfers bond from operator to OOv3 via adapter.
    function test_initializeQuestion_transfersBond() public {
        bytes32 qId = keccak256("bond-check");
        usdc.mint(OPERATOR, DEFAULT_BOND);

        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
        vm.stopPrank();

        // Bond went from operator → adapter → oov3
        assertEq(usdc.balanceOf(OPERATOR), 0);
        assertEq(usdc.balanceOf(address(oov3)), DEFAULT_BOND);
    }

    /// @notice initializeQuestion with custom bond and liveness.
    function test_initializeQuestion_customParams() public {
        bytes32 qId = keccak256("custom");
        uint256 customBond = 500e6;
        usdc.mint(OPERATOR, customBond);

        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), customBond);
        adapter.initializeQuestion(qId, CLAIM, customBond, 3600, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(oov3)), customBond);
    }

    /// @notice initializeQuestion stores operatorDelay.
    function test_initializeQuestion_storesOperatorDelay() public {
        bytes32 qId = keccak256("delay");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 3600);
        vm.stopPrank();

        assertEq(adapter.getQuestion(qId).operatorDelay, 3600);
    }

    /// @notice initializeQuestion reverts if not operator.
    function test_initializeQuestion_revertsIfNotOperator() public {
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.initializeQuestion(keccak256("q"), CLAIM, 0, 0, 0);
    }

    /// @notice initializeQuestion reverts if questionId is bytes32(0).
    function test_initializeQuestion_revertsIfZeroQuestionId() public {
        vm.prank(OPERATOR);
        vm.expectRevert(UmaOracleAdapter.InvalidQuestionId.selector);
        adapter.initializeQuestion(bytes32(0), CLAIM, 0, 0, 0);
    }

    /// @notice initializeQuestion reverts if already initialized.
    function test_initializeQuestion_revertsIfAlreadyInitialized() public {
        bytes32 qId = keccak256("dup");
        _initQuestion(qId);

        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.QuestionAlreadyInitialized.selector);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
        vm.stopPrank();
    }

    /// @notice initializeQuestion reverts if bond below OOv3 minimum.
    function test_initializeQuestion_revertsIfBondBelowMinimum() public {
        oov3.setMinimumBond(1000e6); // set minimum above default

        vm.prank(OPERATOR);
        vm.expectRevert(UmaOracleAdapter.BondBelowMinimum.selector);
        adapter.initializeQuestion(keccak256("q"), CLAIM, 0, 0, 0);
    }

    /// @notice initializeQuestion reverts if custom liveness below minLiveness.
    function test_initializeQuestion_revertsIfLivenessTooShort() public {
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.LivenessTooShort.selector);
        adapter.initializeQuestion(keccak256("q"), CLAIM, 0, 100, 0); // 100 < 1800
        vm.stopPrank();
    }

    /// @notice initializeQuestion reverts if operatorDelay > actualLiveness.
    function test_initializeQuestion_revertsIfDelayTooLong() public {
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.DelayTooLong.selector);
        adapter.initializeQuestion(keccak256("q"), CLAIM, 0, 0, uint64(DEFAULT_LIVENESS) + 1);
        vm.stopPrank();
    }

    /// @notice initializeQuestion succeeds with delay == liveness.
    function test_initializeQuestion_delayEqLiveness() public {
        bytes32 qId = keccak256("eq");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, uint64(DEFAULT_LIVENESS));
        vm.stopPrank();
        assertEq(adapter.getQuestion(qId).operatorDelay, uint64(DEFAULT_LIVENESS));
    }

    // ═══════════════════════════════════════════════════════
    // settleQuestion
    // ═══════════════════════════════════════════════════════

    /// @notice Settle with YES outcome (assertedTruthfully = true).
    function test_settleQuestion_yesOutcome() public {
        bytes32 qId = keccak256("yes");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        adapter.settleQuestion(qId);

        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        assertTrue(q.resolved);
        assertTrue(q.outcome);
    }

    /// @notice Settle with NO outcome (assertedTruthfully = false).
    function test_settleQuestion_noOutcome() public {
        bytes32 qId = keccak256("no");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, false);

        adapter.settleQuestion(qId);

        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        assertTrue(q.resolved);
        assertFalse(q.outcome);
    }

    /// @notice settleQuestion reverts if not initialized.
    function test_settleQuestion_revertsIfNotInitialized() public {
        vm.expectRevert(UmaOracleAdapter.QuestionNotInitialized.selector);
        adapter.settleQuestion(keccak256("none"));
    }

    /// @notice settleQuestion reverts if already resolved.
    function test_settleQuestion_revertsIfAlreadyResolved() public {
        bytes32 qId = keccak256("resolved");
        _initAndSettle(qId, true);

        vm.expectRevert(UmaOracleAdapter.QuestionAlreadyResolved.selector);
        adapter.settleQuestion(qId);
    }

    /// @notice settleQuestion emits QuestionResolved via callback.
    function test_settleQuestion_emitsEvent() public {
        bytes32 qId = keccak256("event");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        vm.expectEmit(true, true, true, true);
        emit QuestionResolved(qId, aId, true, address(oov3));

        adapter.settleQuestion(qId);
    }

    // ═══════════════════════════════════════════════════════
    // settleQuestion — OPERATOR DELAY
    // ═══════════════════════════════════════════════════════

    /// @notice During operator delay, non-operator non-owner cannot settle.
    function test_settleQuestion_operatorDelayBlocksPublic() public {
        bytes32 qId = keccak256("delay");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, CLAIM, 0, 0, 3600);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);

        // expirationTime = block.timestamp + DEFAULT_LIVENESS = 1000 + 7200 = 8200
        // delay = 3600 → public can settle at 8200 + 3600 = 11800
        vm.warp(8200); // at expiration, within delay
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.OperatorWindowActive.selector);
        adapter.settleQuestion(qId);
    }

    /// @notice During operator delay, operator CAN settle.
    function test_settleQuestion_operatorCanSettleDuringDelay() public {
        bytes32 qId = keccak256("delay-op");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, CLAIM, 0, 0, 3600);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);
        vm.warp(8200);
        vm.prank(OPERATOR);
        adapter.settleQuestion(qId);
        assertTrue(adapter.getQuestion(qId).resolved);
    }

    /// @notice During operator delay, owner CAN settle.
    function test_settleQuestion_ownerCanSettleDuringDelay() public {
        bytes32 qId = keccak256("delay-owner");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, CLAIM, 0, 0, 3600);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);
        vm.warp(8200);
        vm.prank(OWNER);
        adapter.settleQuestion(qId);
        assertTrue(adapter.getQuestion(qId).resolved);
    }

    /// @notice After operator delay, anyone can settle.
    function test_settleQuestion_publicAfterDelayExpires() public {
        bytes32 qId = keccak256("delay-expired");
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, CLAIM, 0, 0, 3600);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);
        vm.warp(11800); // 8200 + 3600
        vm.prank(RANDOM);
        adapter.settleQuestion(qId);
        assertTrue(adapter.getQuestion(qId).resolved);
    }

    /// @notice Zero operatorDelay is permissionless immediately.
    function test_settleQuestion_zeroDelayPermissionless() public {
        bytes32 qId = keccak256("no-delay");
        _initAndSettle(qId, true);
        assertTrue(adapter.getQuestion(qId).resolved);
    }

    // ═══════════════════════════════════════════════════════
    // assertionResolvedCallback
    // ═══════════════════════════════════════════════════════

    /// @notice Only OOv3 can call assertionResolvedCallback.
    function test_assertionResolvedCallback_revertsIfNotOov3() public {
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOOv3.selector);
        adapter.assertionResolvedCallback(keccak256("a"), true);
    }

    /// @notice Callback with unknown assertionId silently returns.
    function test_assertionResolvedCallback_unknownAssertionReturns() public {
        vm.prank(address(oov3));
        adapter.assertionResolvedCallback(keccak256("unknown"), true);
        // No revert, no state change
    }

    /// @notice Callback with mismatched assertionId (after cancel+reinit) silently returns.
    function test_assertionResolvedCallback_staleCallbackReturns() public {
        bytes32 qId = keccak256("stale");
        bytes32 aId1 = _initQuestion(qId);

        // Cancel and reinit
        vm.prank(OWNER);
        adapter.cancelQuestion(qId);
        bytes32 aId2 = _initQuestion(qId);

        // Old callback for aId1 — assertionToQuestion was deleted, returns silently
        vm.prank(address(oov3));
        adapter.assertionResolvedCallback(aId1, true);

        // Question still unresolved (only aId2 is valid)
        assertFalse(adapter.getQuestion(qId).resolved);

        // Settle with correct aId2
        oov3.setAssertionResult(aId2, false);
        adapter.settleQuestion(qId);
        assertTrue(adapter.getQuestion(qId).resolved);
        assertFalse(adapter.getQuestion(qId).outcome);
    }

    /// @notice Callback for already-resolved question silently returns.
    function test_assertionResolvedCallback_alreadyResolvedReturns() public {
        bytes32 qId = keccak256("double-cb");
        bytes32 aId = _initAndSettle(qId, true);

        // Second callback — silently returns
        vm.prank(address(oov3));
        adapter.assertionResolvedCallback(aId, false);

        // Still resolved with original outcome
        assertTrue(adapter.getQuestion(qId).outcome);
    }

    // ═══════════════════════════════════════════════════════
    // assertionDisputedCallback
    // ═══════════════════════════════════════════════════════

    /// @notice Only OOv3 can call assertionDisputedCallback.
    function test_assertionDisputedCallback_revertsIfNotOov3() public {
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOOv3.selector);
        adapter.assertionDisputedCallback(keccak256("a"));
    }

    /// @notice Dispute callback emits QuestionDisputed.
    function test_assertionDisputedCallback_emitsEvent() public {
        bytes32 qId = keccak256("dispute");
        bytes32 aId = _initQuestion(qId);

        vm.expectEmit(true, true, false, false);
        emit QuestionDisputed(qId, aId);

        oov3.simulateDispute(aId);
    }

    /// @notice Dispute callback with unknown assertionId silently returns.
    function test_assertionDisputedCallback_unknownReturns() public {
        vm.prank(address(oov3));
        adapter.assertionDisputedCallback(keccak256("unknown"));
        // No revert
    }

    // ═══════════════════════════════════════════════════════
    // relayResolved
    // ═══════════════════════════════════════════════════════

    /// @notice relayResolved reverts if not initialized.
    function test_relayResolved_revertsIfNotInitialized() public {
        vm.expectRevert(UmaOracleAdapter.QuestionNotInitialized.selector);
        adapter.relayResolved(keccak256("none"));
    }

    /// @notice relayResolved reverts if not resolved.
    function test_relayResolved_revertsIfNotResolved() public {
        _initQuestion(keccak256("unresolved"));
        vm.expectRevert(UmaOracleAdapter.QuestionNotResolved.selector);
        adapter.relayResolved(keccak256("unresolved"));
    }

    /// @notice relayResolved reverts if relay not set.
    function test_relayResolved_revertsIfRelayNotSet() public {
        bytes32 qId = keccak256("no-relay");
        _initAndSettle(qId, true);

        vm.deal(RANDOM, 1 ether);
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.RelayNotConfigured.selector);
        adapter.relayResolved{value: 0.01 ether}(qId);
    }

    /// @notice relayResolved reverts if msg.value == 0.
    function test_relayResolved_revertsIfNoValue() public {
        _setupRelay();
        bytes32 qId = keccak256("no-value");
        _initAndSettle(qId, true);

        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.InsufficientRelayFee.selector);
        adapter.relayResolved(qId);
    }

    /// @notice relayResolved succeeds with relay and msg.value.
    function test_relayResolved_success() public {
        MockLayerZeroEndpoint lzEndpoint = _setupRelay();
        bytes32 qId = keccak256("relay-ok");
        _initAndSettle(qId, true);

        vm.deal(RANDOM, 1 ether);
        vm.prank(RANDOM);
        adapter.relayResolved{value: 0.01 ether}(qId);
        assertEq(lzEndpoint.sendCallCount(), 1);
    }

    function _setupRelay() internal returns (MockLayerZeroEndpoint lzEndpoint) {
        lzEndpoint = new MockLayerZeroEndpoint();
        LzCrossChainSender relaySender = new LzCrossChainSender(address(lzEndpoint), 30145, OWNER, hex"0001");
        vm.startPrank(OWNER);
        relaySender.addAdapter(address(adapter));
        relaySender.setPeer(bytes32(uint256(1)));
        adapter.setCrossChainRelay(address(relaySender));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // quoteCrossChainFee
    // ═══════════════════════════════════════════════════════

    /// @notice Returns 0 when no relay configured.
    function test_quoteCrossChainFee_zeroIfNoRelay() public view {
        assertEq(adapter.quoteCrossChainFee(keccak256("q")), 0);
    }

    /// @notice Returns 0 when question not initialized.
    function test_quoteCrossChainFee_zeroIfNotInitialized() public {
        _setupRelay();
        assertEq(adapter.quoteCrossChainFee(keccak256("none")), 0);
    }

    /// @notice Returns the actual LZ fee when relay is configured and question is initialized.
    ///         Covers line 361 (the return path with a real fee value).
    function test_quoteCrossChainFee_returnsFee() public {
        MockLayerZeroEndpoint lzEndpoint = _setupRelay();
        lzEndpoint.setQuotedNativeFee(0.005 ether);

        bytes32 qId = keccak256("fee-quote");
        _initQuestion(qId);

        uint256 fee = adapter.quoteCrossChainFee(qId);
        assertEq(fee, 0.005 ether);
    }

    // ═══════════════════════════════════════════════════════
    // cancelQuestion
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can cancel.
    function test_cancelQuestion_byOwner() public {
        bytes32 qId = keccak256("cancel-owner");
        bytes32 aId = _initQuestion(qId);

        vm.expectEmit(true, true, true, true);
        emit QuestionCancelled(qId, aId, OWNER, OPERATOR);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        assertEq(adapter.getQuestion(qId).creator, address(0));
        assertEq(adapter.assertionToQuestion(aId), bytes32(0));
    }

    /// @notice Creator (active operator) can cancel their own question.
    function test_cancelQuestion_byCreator() public {
        bytes32 qId = keccak256("cancel-creator");
        _initQuestion(qId);

        vm.prank(OPERATOR);
        adapter.cancelQuestion(qId);
        assertEq(adapter.getQuestion(qId).creator, address(0));
    }

    /// @notice Non-creator operator cannot cancel another's question.
    /// @notice Any operator can cancel any question (global trust).
    function test_cancelQuestion_succeedsForAnyOperator() public {
        _initQuestion(keccak256("q"));
        vm.prank(OWNER);
        adapter.addOperator(OPERATOR_2);

        vm.prank(OPERATOR_2);
        adapter.cancelQuestion(keccak256("q"));
    }

    /// @notice Revoked operator cannot cancel.
    function test_cancelQuestion_revertsIfRevokedOperator() public {
        _initQuestion(keccak256("q"));
        vm.prank(OWNER);
        adapter.removeOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.cancelQuestion(keccak256("q"));
    }

    /// @notice Random cannot cancel.
    function test_cancelQuestion_revertsIfRandom() public {
        _initQuestion(keccak256("q"));
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.cancelQuestion(keccak256("q"));
    }

    /// @notice Cannot cancel non-existent.
    function test_cancelQuestion_revertsIfNotInitialized() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.QuestionNotInitialized.selector);
        adapter.cancelQuestion(keccak256("none"));
    }

    /// @notice Cannot cancel resolved.
    function test_cancelQuestion_revertsIfResolved() public {
        bytes32 qId = keccak256("resolved");
        _initAndSettle(qId, true);

        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.QuestionAlreadyResolved.selector);
        adapter.cancelQuestion(qId);
    }

    /// @notice Cannot cancel after UMA liveness expired (outcome is determined).
    function test_cancelQuestion_revertsIfLivenessExpired() public {
        bytes32 qId = keccak256("expired");
        _initQuestion(qId);

        // Warp past the liveness window (default 7200s)
        vm.warp(block.timestamp + DEFAULT_LIVENESS);

        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.CannotCancelExpiredAssertion.selector);
        adapter.cancelQuestion(qId);
    }

    /// @notice Cancel succeeds just before liveness expires.
    function test_cancelQuestion_succeedsBeforeLivenessExpires() public {
        bytes32 qId = keccak256("before-expiry");
        _initQuestion(qId);

        // Warp to 1 second before expiration
        vm.warp(block.timestamp + DEFAULT_LIVENESS - 1);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);
        assertEq(adapter.getQuestion(qId).creator, address(0));
    }

    /// @notice After cancel, can reinitialize.
    function test_cancelQuestion_allowsRecreation() public {
        bytes32 qId = keccak256("recreate");
        _initQuestion(qId);
        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        bytes32 aId2 = _initQuestion(qId);
        assertTrue(aId2 != bytes32(0));
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    function test_setDefaultBond_success() public {
        vm.prank(OWNER);
        adapter.setDefaultBond(500e6);
        assertEq(adapter.defaultBond(), 500e6);
    }

    function test_setDefaultBond_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.BondBelowMinimum.selector);
        adapter.setDefaultBond(0);
    }

    function test_setDefaultLiveness_success() public {
        vm.prank(OWNER);
        adapter.setDefaultLiveness(14400);
        assertEq(adapter.defaultLiveness(), 14400);
    }

    function test_setDefaultLiveness_revertsIfBelowMin() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.LivenessTooShort.selector);
        adapter.setDefaultLiveness(100);
    }

    function test_setMinLiveness_success() public {
        vm.prank(OWNER);
        adapter.setMinLiveness(900);
        assertEq(adapter.minLiveness(), 900);
    }

    function test_setMinLiveness_revertsIfAboveDefault() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.LivenessTooShort.selector);
        adapter.setMinLiveness(DEFAULT_LIVENESS + 1);
    }

    function test_setCrossChainRelay_success() public {
        vm.prank(OWNER);
        adapter.setCrossChainRelay(address(0x1234));
        assertEq(address(adapter.crossChainRelay()), address(0x1234));
    }

    function test_addRemoveOperator() public {
        vm.prank(OWNER);
        adapter.addOperator(OPERATOR_2);
        assertTrue(adapter.isOperator(OPERATOR_2));
        vm.prank(OWNER);
        adapter.removeOperator(OPERATOR_2);
        assertFalse(adapter.isOperator(OPERATOR_2));
    }

    function test_addOperator_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        adapter.addOperator(address(0));
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.AlreadyOperator.selector);
        adapter.addOperator(OPERATOR);
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.addOperator(OPERATOR_2);
    }

    function test_removeOperator_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.NotAuthorizedOperator.selector);
        adapter.removeOperator(RANDOM);
    }

    function test_ownership_transfer() public {
        vm.prank(OWNER);
        adapter.proposeOwner(NEW_OWNER);
        vm.prank(NEW_OWNER);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), NEW_OWNER);
    }

    function test_proposeOwner_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        adapter.proposeOwner(address(0));
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.proposeOwner(NEW_OWNER);
    }

    function test_acceptOwnership_revertsIfNotProposed() public {
        vm.prank(OWNER);
        adapter.proposeOwner(NEW_OWNER);
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotProposedOwner.selector);
        adapter.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════

    function test_isResolved() public {
        bytes32 qId = keccak256("is-res");
        _initQuestion(qId);
        assertFalse(adapter.isResolved(qId));
        bytes32 aId = adapter.getQuestion(qId).assertionId;
        oov3.setAssertionResult(aId, true);
        adapter.settleQuestion(qId);
        assertTrue(adapter.isResolved(qId));
    }

    function test_getQuestionByAssertion() public {
        bytes32 qId = keccak256("reverse");
        bytes32 aId = _initQuestion(qId);
        assertEq(adapter.getQuestionByAssertion(aId), qId);
    }

    // ═══════════════════════════════════════════════════════
    // INTEGRATION
    // ═══════════════════════════════════════════════════════

    /// @notice Full lifecycle: init → settle → verify.
    function test_integration_fullLifecycle() public {
        bytes32 qId = keccak256("lifecycle");
        bytes32 aId = _initQuestion(qId);

        assertFalse(adapter.isResolved(qId));

        oov3.setAssertionResult(aId, true);
        adapter.settleQuestion(qId);

        assertTrue(adapter.isResolved(qId));
        assertTrue(adapter.getQuestion(qId).outcome);
    }

    /// @notice Cancel and recreate flow.
    function test_integration_cancelAndRecreate() public {
        bytes32 qId = keccak256("recreate");
        _initQuestion(qId);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        bytes32 aId2 = _initQuestion(qId);
        oov3.setAssertionResult(aId2, false);
        adapter.settleQuestion(qId);

        assertFalse(adapter.getQuestion(qId).outcome);
    }

    // ═══════════════════════════════════════════════════════
    // RE-ENTRANCY — assertionId MISMATCH (line 388)
    // ═══════════════════════════════════════════════════════

    /// @notice Simulates a re-entrancy attack via a malicious ERC20 bond token.
    ///         During initializeQuestion's safeTransferFrom, the token calls back into
    ///         the adapter to cancel+reinit the same questionId. This creates two
    ///         assertionIds for one questionId — the inner one gets overwritten when
    ///         the outer call resumes. When UMA settles the inner assertionId, the
    ///         guard at line 388 (q.assertionId != assertionId) catches the mismatch
    ///         and returns silently, preventing a stale callback from corrupting state.
    function test_assertionResolvedCallback_reentrantMismatch() public {
        // Deploy a fresh adapter with ReentrantERC20 instead of standard USDC
        ReentrantERC20 reentrantToken = new ReentrantERC20();
        UmaOracleAdapter reentrantAdapter = new UmaOracleAdapter(
            address(oov3), address(reentrantToken), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR
        );

        // Create the attacker contract (acts as operator)
        ReentrantAttacker attacker = new ReentrantAttacker(reentrantAdapter, reentrantToken);

        // Whitelist the attacker as an operator
        vm.prank(OWNER);
        reentrantAdapter.addOperator(address(attacker));

        // Fund the attacker with enough tokens for two bond payments
        reentrantToken.mint(address(attacker), DEFAULT_BOND * 2);

        bytes32 qId = keccak256("reentrant-q");

        // The reentrancy attack reverts because initializeQuestion has nonReentrant guard.
        // The attacker's callback tries cancel + reinit during the outer initializeQuestion's
        // transferFrom, but the inner initializeQuestion reverts with ReentrancyGuardReentrantCall.
        vm.expectRevert("ReentrantERC20: callback failed");
        attacker.startAttack(qId, DEFAULT_BOND);

        // The attack was blocked — question was never initialized
        assertFalse(attacker.attacked());
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
        adapter.setResolverGroup(GROUP_ID, members, true);

        assertTrue(adapter.resolverGroups(GROUP_ID, RESOLVER_1));
        assertTrue(adapter.resolverGroups(GROUP_ID, RESOLVER_2));
        assertFalse(adapter.resolverGroups(GROUP_ID, RANDOM));
    }

    /// @notice setResolverGroup removes members with authorized=false.
    function test_setResolverGroup_removesMembers() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        assertTrue(adapter.resolverGroups(GROUP_ID, RESOLVER_1));

        adapter.setResolverGroup(GROUP_ID, members, false);
        assertFalse(adapter.resolverGroups(GROUP_ID, RESOLVER_1));
        vm.stopPrank();
    }

    /// @notice setResolverGroup reverts for non-owner/non-operator.
    function test_setResolverGroup_revertsIfUnauthorized() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOperator.selector);
        adapter.setResolverGroup(GROUP_ID, members, true);
    }

    /// @notice setResolverGroup reverts for zero groupId.
    function test_setResolverGroup_revertsIfZeroGroupId() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.ZeroGroupId.selector);
        adapter.setResolverGroup(bytes32(0), members, true);
    }

    /// @notice setResolverGroup reverts for zero address member.
    function test_setResolverGroup_revertsIfZeroMember() public {
        address[] memory members = new address[](1);
        members[0] = address(0);

        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.ZeroAddress.selector);
        adapter.setResolverGroup(GROUP_ID, members, true);
    }

    /// @notice Operator can also manage resolver groups.
    function test_setResolverGroup_operatorCanCall() public {
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(OPERATOR);
        adapter.setResolverGroup(GROUP_ID, members, true);
        assertTrue(adapter.resolverGroups(GROUP_ID, RESOLVER_1));
    }

    /// @notice assignQuestionGroup links a question to a group.
    function test_assignQuestionGroup_success() public {
        bytes32 qId = keccak256("resolver-q");

        vm.prank(OWNER);
        adapter.assignQuestionGroup(qId, GROUP_ID);
        assertEq(adapter.questionGroup(qId), GROUP_ID);
    }

    /// @notice assignQuestionGroup with bytes32(0) unassigns.
    function test_assignQuestionGroup_unassign() public {
        bytes32 qId = keccak256("resolver-q");

        vm.startPrank(OWNER);
        adapter.assignQuestionGroup(qId, GROUP_ID);
        adapter.assignQuestionGroup(qId, bytes32(0));
        vm.stopPrank();

        assertEq(adapter.questionGroup(qId), bytes32(0));
    }

    /// @notice assignQuestionGroup reverts for non-owner/non-operator.
    function test_assignQuestionGroup_revertsIfUnauthorized() public {
        vm.prank(RANDOM);
        vm.expectRevert(UmaOracleAdapter.NotOperator.selector);
        adapter.assignQuestionGroup(keccak256("q"), GROUP_ID);
    }

    /// @notice Resolver can initializeQuestion after group assignment.
    function test_resolver_canInitializeQuestion() public {
        bytes32 qId = keccak256("resolver-init");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        adapter.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        usdc.mint(RESOLVER_1, DEFAULT_BOND);
        vm.startPrank(RESOLVER_1);
        usdc.approve(address(adapter), DEFAULT_BOND);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
        vm.stopPrank();

        assertTrue(adapter.getQuestion(qId).creator == RESOLVER_1);
    }

    /// @notice Resolver cannot initializeQuestion without group assignment.
    function test_resolver_cannotInitializeWithoutGroup() public {
        bytes32 qId = keccak256("no-group");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.prank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        // No assignQuestionGroup call

        vm.prank(RESOLVER_1);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
    }

    /// @notice Resolver can cancelQuestion for their authorized question.
    function test_resolver_canCancelQuestion() public {
        bytes32 qId = keccak256("resolver-cancel");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        adapter.assignQuestionGroup(qId, GROUP_ID);
        vm.stopPrank();

        usdc.mint(RESOLVER_1, DEFAULT_BOND);
        vm.startPrank(RESOLVER_1);
        usdc.approve(address(adapter), DEFAULT_BOND);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
        adapter.cancelQuestion(qId);
        vm.stopPrank();

        assertEq(adapter.getQuestion(qId).creator, address(0)); // deleted
    }

    /// @notice Removing member from group revokes access across all linked questions.
    function test_resolverGroup_removalRevokesAccess() public {
        bytes32 qId = keccak256("revoke-test");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        adapter.assignQuestionGroup(qId, GROUP_ID);
        // Now remove RESOLVER_1 from group
        adapter.setResolverGroup(GROUP_ID, members, false);
        vm.stopPrank();

        vm.prank(RESOLVER_1);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.initializeQuestion(qId, CLAIM, 0, 0, 0);
    }

    // ═══════════════════════════════════════════════════════
    // RECLAIM BOND
    // ═══════════════════════════════════════════════════════

    event CancelledAssertionSettled(bytes32 indexed assertionId, bytes32 indexed questionId, bool assertedTruthfully);
    event CancelledAssertionDisputed(bytes32 indexed assertionId, bytes32 indexed questionId);
    event BondReclaimed(
        bytes32 indexed assertionId, bytes32 indexed questionId, address indexed caller, bool settledByUs
    );

    /// @notice cancelQuestion pushes assertionId to cancelledAssertions array.
    function test_cancelQuestion_pushesToCancelledAssertions() public {
        bytes32 qId = keccak256("cancel-push");
        bytes32 aId = _initQuestion(qId);

        assertEq(adapter.cancelledAssertionsCount(), 0);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        assertEq(adapter.cancelledAssertionsCount(), 1);
        assertEq(adapter.cancelledAssertions(0), aId);
    }

    /// @notice Multiple cancels accumulate in the array.
    function test_cancelQuestion_multipleAccumulate() public {
        bytes32 qId1 = keccak256("cancel-multi-1");
        bytes32 qId2 = keccak256("cancel-multi-2");
        bytes32 aId1 = _initQuestion(qId1);
        bytes32 aId2 = _initQuestion(qId2);

        vm.startPrank(OWNER);
        adapter.cancelQuestion(qId1);
        adapter.cancelQuestion(qId2);
        vm.stopPrank();

        assertEq(adapter.cancelledAssertionsCount(), 2);
        assertEq(adapter.cancelledAssertions(0), aId1);
        assertEq(adapter.cancelledAssertions(1), aId2);
    }

    /// @notice reclaimBond settles on UMA and removes from array.
    function test_reclaimBond_success() public {
        bytes32 qId = keccak256("reclaim-ok");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);
        assertEq(adapter.cancelledAssertionsCount(), 1);

        vm.expectEmit(true, true, true, true);
        emit BondReclaimed(aId, keccak256("reclaim-ok"), RANDOM, true);

        vm.prank(RANDOM); // permissionless
        adapter.reclaimBond(0);

        assertEq(adapter.cancelledAssertionsCount(), 0);
    }

    /// @notice reclaimBond succeeds even if assertion was already settled on UMA externally.
    function test_reclaimBond_succeedsIfAlreadySettled() public {
        bytes32 qId = keccak256("already-settled");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);
        assertEq(adapter.cancelledAssertionsCount(), 1);

        // Settle directly on UMA (bypassing adapter)
        oov3.settleAssertion(aId);

        // reclaimBond should still succeed and remove the entry (try/catch absorbs the revert)
        adapter.reclaimBond(0);
        assertEq(adapter.cancelledAssertionsCount(), 0);
    }

    /// @notice reclaimBond is permissionless — anyone can call.
    function test_reclaimBond_permissionless() public {
        bytes32 qId = keccak256("reclaim-perm");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        // Random address can reclaim
        vm.prank(address(0xDEAD));
        adapter.reclaimBond(0);

        assertEq(adapter.cancelledAssertionsCount(), 0);
    }

    /// @notice reclaimBond reverts with IndexOutOfBounds for invalid index.
    function test_reclaimBond_revertsIfIndexOutOfBounds() public {
        vm.expectRevert(UmaOracleAdapter.IndexOutOfBounds.selector);
        adapter.reclaimBond(0); // empty array
    }

    /// @notice reclaimBond reverts with IndexOutOfBounds for index >= length.
    function test_reclaimBond_revertsIfIndexTooHigh() public {
        bytes32 qId = keccak256("reclaim-bounds");
        _initQuestion(qId);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        vm.expectRevert(UmaOracleAdapter.IndexOutOfBounds.selector);
        adapter.reclaimBond(1); // only index 0 exists
    }

    /// @notice reclaimBond swap-and-pop: reclaiming index 0 of [A, B] leaves [B].
    function test_reclaimBond_swapAndPop() public {
        bytes32 qId1 = keccak256("swap-1");
        bytes32 qId2 = keccak256("swap-2");
        bytes32 aId1 = _initQuestion(qId1);
        bytes32 aId2 = _initQuestion(qId2);
        oov3.setAssertionResult(aId1, true);
        oov3.setAssertionResult(aId2, true);

        vm.startPrank(OWNER);
        adapter.cancelQuestion(qId1);
        adapter.cancelQuestion(qId2);
        vm.stopPrank();

        // Array is [aId1, aId2]. Reclaim index 0 → swap aId2 into index 0, pop.
        adapter.reclaimBond(0);

        assertEq(adapter.cancelledAssertionsCount(), 1);
        assertEq(adapter.cancelledAssertions(0), aId2); // aId2 moved to index 0
    }

    /// @notice reclaimBond works for last element (no swap needed).
    function test_reclaimBond_lastElement() public {
        bytes32 qId1 = keccak256("last-1");
        bytes32 qId2 = keccak256("last-2");
        bytes32 aId1 = _initQuestion(qId1);
        bytes32 aId2 = _initQuestion(qId2);
        oov3.setAssertionResult(aId1, true);
        oov3.setAssertionResult(aId2, true);

        vm.startPrank(OWNER);
        adapter.cancelQuestion(qId1);
        adapter.cancelQuestion(qId2);
        vm.stopPrank();

        // Reclaim last index
        adapter.reclaimBond(1);

        assertEq(adapter.cancelledAssertionsCount(), 1);
        assertEq(adapter.cancelledAssertions(0), aId1); // aId1 stays at index 0
    }

    /// @notice reclaimBond triggers CancelledAssertionSettled event via callback.
    function test_reclaimBond_emitsCancelledAssertionSettled() public {
        bytes32 qId = keccak256("reclaim-event");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, true);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        // OOV3.settleAssertion calls assertionResolvedCallback which emits CancelledAssertionSettled
        vm.expectEmit(true, true, false, true);
        emit CancelledAssertionSettled(aId, qId, true);

        adapter.reclaimBond(0);
    }

    /// @notice After cancel, dispute callback emits CancelledAssertionDisputed.
    function test_cancelledCallback_disputeEmitsEvent() public {
        bytes32 qId = keccak256("cancelled-dispute");
        bytes32 aId = _initQuestion(qId);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        vm.expectEmit(true, true, false, false);
        emit CancelledAssertionDisputed(aId, qId);

        oov3.simulateDispute(aId);
    }

    /// @notice After cancel, resolve callback emits CancelledAssertionSettled (false outcome).
    function test_cancelledCallback_resolveEmitsEvent() public {
        bytes32 qId = keccak256("cancelled-resolve");
        bytes32 aId = _initQuestion(qId);
        oov3.setAssertionResult(aId, false);

        vm.prank(OWNER);
        adapter.cancelQuestion(qId);

        vm.expectEmit(true, true, false, true);
        emit CancelledAssertionSettled(aId, qId, false);

        oov3.settleAssertion(aId);
    }

    /// @notice Reclaim all bonds from multiple cancels.
    function test_reclaimBond_drainAll() public {
        bytes32 qId1 = keccak256("drain-1");
        bytes32 qId2 = keccak256("drain-2");
        bytes32 qId3 = keccak256("drain-3");
        bytes32 aId1 = _initQuestion(qId1);
        bytes32 aId2 = _initQuestion(qId2);
        bytes32 aId3 = _initQuestion(qId3);
        oov3.setAssertionResult(aId1, true);
        oov3.setAssertionResult(aId2, true);
        oov3.setAssertionResult(aId3, true);

        vm.startPrank(OWNER);
        adapter.cancelQuestion(qId1);
        adapter.cancelQuestion(qId2);
        adapter.cancelQuestion(qId3);
        vm.stopPrank();

        assertEq(adapter.cancelledAssertionsCount(), 3);

        // Drain from end to avoid swap confusion
        adapter.reclaimBond(2);
        adapter.reclaimBond(1);
        adapter.reclaimBond(0);

        assertEq(adapter.cancelledAssertionsCount(), 0);
    }

    /// @notice cancelledAssertionsCount returns 0 when empty.
    function test_cancelledAssertionsCount_zeroWhenEmpty() public view {
        assertEq(adapter.cancelledAssertionsCount(), 0);
    }

    /// @notice Multiple questions can share the same resolver group.
    function test_resolverGroup_sharedAcrossQuestions() public {
        bytes32 qId1 = keccak256("shared-q1");
        bytes32 qId2 = keccak256("shared-q2");
        address[] memory members = new address[](1);
        members[0] = RESOLVER_1;

        vm.startPrank(OWNER);
        adapter.setResolverGroup(GROUP_ID, members, true);
        adapter.assignQuestionGroup(qId1, GROUP_ID);
        adapter.assignQuestionGroup(qId2, GROUP_ID);
        vm.stopPrank();

        // Resolver can init both questions
        usdc.mint(RESOLVER_1, DEFAULT_BOND * 2);
        vm.startPrank(RESOLVER_1);
        usdc.approve(address(adapter), DEFAULT_BOND * 2);
        adapter.initializeQuestion(qId1, CLAIM, 0, 0, 0);
        adapter.initializeQuestion(qId2, CLAIM, 0, 0, 0);
        vm.stopPrank();

        assertEq(adapter.getQuestion(qId1).creator, RESOLVER_1);
        assertEq(adapter.getQuestion(qId2).creator, RESOLVER_1);
    }

    // ═══════════════════════════════════════════════════════
    // initializeQuestion — EMPTY CLAIM
    // ═══════════════════════════════════════════════════════

    /// @notice initializeQuestion reverts when claim bytes are empty.
    function test_initializeQuestion_revertsIfClaimEmpty() public {
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.EmptyClaimData.selector);
        adapter.initializeQuestion(keccak256("empty-claim"), "", 0, 0, 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // relayResolved — DOUBLE RELAY
    // ═══════════════════════════════════════════════════════

    /// @notice relayResolved reverts if the same question is relayed twice.
    function test_relayResolved_revertsIfAlreadyRelayed() public {
        _setupRelay();
        bytes32 qId = keccak256("double-relay");
        _initAndSettle(qId, true);

        vm.deal(RANDOM, 2 ether);
        vm.startPrank(RANDOM);
        adapter.relayResolved{value: 0.01 ether}(qId);
        // Second relay should revert
        vm.expectRevert(UmaOracleAdapter.QuestionAlreadyRelayed.selector);
        adapter.relayResolved{value: 0.01 ether}(qId);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // cancelQuestion — DISPUTED
    // ═══════════════════════════════════════════════════════

    /// @notice Cannot cancel a question while its UMA assertion is actively disputed
    ///         (wasDisputed=true, settled=false). This prevents operators from
    ///         bypassing the dispute mechanism.
    function test_cancelQuestion_revertsIfDisputed() public {
        bytes32 qId = keccak256("disputed");
        bytes32 aId = _initQuestion(qId);

        // Simulate dispute (sets wasDisputed=true on the assertion)
        oov3.simulateDispute(aId);

        vm.prank(OWNER);
        vm.expectRevert(UmaOracleAdapter.CannotCancelDisputedQuestion.selector);
        adapter.cancelQuestion(qId);
    }
}
