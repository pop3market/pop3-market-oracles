// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {BridgeReceiver} from "../../src/BridgeReceiver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";

/// @title BridgeReceiverTest
/// @notice Unit tests for BridgeReceiver — covers every branch, revert, event, and state mutation.
contract BridgeReceiverTest is Test {
    // ── Constants ──────────────────────────────────────────
    address constant OWNER = address(0xABCD);
    address constant RELAYER = address(0x7777);
    address constant RELAYER_2 = address(0x8888);
    address constant NEW_OWNER = address(0x9999);
    address constant RANDOM = address(0xBEEF);

    // ── State ──────────────────────────────────────────────
    BridgeReceiver receiver;
    MockDiamondOracle diamond;

    // ── Events (redeclared for vm.expectEmit) ──────────────
    event AnswerRelayed(bytes32 indexed questionId, bytes32 indexed requestId, bool outcome, address indexed relayer);
    event OutcomeRelayed(bytes32 indexed questionId, bool outcome, address indexed relayer);
    event RelayerUpdated(address indexed relayer, bool authorized, address indexed actor);
    event DiamondUpdated(address indexed previousDiamond, address indexed newDiamond, address indexed actor);
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════

    function setUp() public {
        diamond = new MockDiamondOracle();
        receiver = new BridgeReceiver(address(diamond), OWNER, RELAYER);
    }

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @notice Constructor sets diamond, owner, and initial relayer correctly.
    function test_constructor_setsState() public view {
        assertEq(address(receiver.diamond()), address(diamond));
        assertEq(receiver.owner(), OWNER);
        assertTrue(receiver.isRelayer(RELAYER));
    }

    /// @notice Constructor emits OwnershipTransferred(address(0), owner).
    function test_constructor_emitsOwnershipTransferred() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), OWNER);
        new BridgeReceiver(address(diamond), OWNER, RELAYER);
    }

    /// @notice Constructor emits RelayerUpdated(relayer, true).
    function test_constructor_emitsRelayerUpdated() public {
        vm.expectEmit(true, false, true, true);
        emit RelayerUpdated(RELAYER, true, OWNER);
        new BridgeReceiver(address(diamond), OWNER, RELAYER);
    }

    /// @notice Constructor reverts with ZeroAddress if diamond is address(0).
    function test_constructor_revertsIfDiamondZero() public {
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        new BridgeReceiver(address(0), OWNER, RELAYER);
    }

    /// @notice Constructor reverts with ZeroAddress if owner is address(0).
    function test_constructor_revertsIfOwnerZero() public {
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        new BridgeReceiver(address(diamond), address(0), RELAYER);
    }

    /// @notice Constructor reverts with ZeroAddress if relayer is address(0).
    function test_constructor_revertsIfRelayerZero() public {
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        new BridgeReceiver(address(diamond), OWNER, address(0));
    }

    // ═══════════════════════════════════════════════════════
    // relayOracleAnswer
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: relayer relays a YES outcome. Verifies Diamond calls and event.
    function test_relayOracleAnswer_yesOutcome() public {
        bytes32 qId = keccak256("q1");
        bytes32 rId = keccak256("r1");

        vm.expectEmit(true, true, false, true);
        emit AnswerRelayed(qId, rId, true, RELAYER);

        vm.prank(RELAYER);
        receiver.relayOracleAnswer(qId, rId, true);

        // Verify registerOracleRequest was called
        assertEq(diamond.registerCallCount(), 1);
        (bytes32 regQ, bytes32 regR) = diamond.registerCalls(0);
        assertEq(regQ, qId);
        assertEq(regR, rId);

        // Verify reportPayouts was called with [1, 0]
        assertEq(diamond.reportPayoutsCallCount(), 1);
        uint256[] memory payouts = diamond.getReportPayoutsPayouts(0);
        assertEq(payouts.length, 2);
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 0);

        // Verify relayed flag
        assertTrue(receiver.relayed(qId));
    }

    /// @notice Happy path: relayer relays a NO outcome. Payouts should be [0, 1].
    function test_relayOracleAnswer_noOutcome() public {
        bytes32 qId = keccak256("q2");
        bytes32 rId = keccak256("r2");

        vm.expectEmit(true, true, false, true);
        emit AnswerRelayed(qId, rId, false, RELAYER);

        vm.prank(RELAYER);
        receiver.relayOracleAnswer(qId, rId, false);

        uint256[] memory payouts = diamond.getReportPayoutsPayouts(0);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    /// @notice relayOracleAnswer reverts with NotRelayer when called by non-relayer.
    function test_relayOracleAnswer_revertsIfNotRelayer() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOracleAnswer(keccak256("q"), keccak256("r"), true);
    }

    /// @notice relayOracleAnswer reverts with QuestionAlreadyRelayed on double-relay.
    function test_relayOracleAnswer_revertsIfAlreadyRelayed() public {
        bytes32 qId = keccak256("q-dup");
        bytes32 rId = keccak256("r-dup");

        vm.prank(RELAYER);
        receiver.relayOracleAnswer(qId, rId, true);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOracleAnswer(qId, keccak256("r-other"), false);
    }

    /// @notice Double-relay check is per-questionId regardless of requestId or outcome.
    function test_relayOracleAnswer_doubleRelayDifferentRequestId() public {
        bytes32 qId = keccak256("shared-q");

        vm.prank(RELAYER);
        receiver.relayOracleAnswer(qId, keccak256("r1"), true);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOracleAnswer(qId, keccak256("r2"), false);
    }

    /// @notice Owner cannot relay (owner is not automatically a relayer).
    function test_relayOracleAnswer_revertsIfOwnerNotRelayer() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOracleAnswer(keccak256("q"), keccak256("r"), true);
    }

    // ═══════════════════════════════════════════════════════
    // relayOutcome
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: relayOutcome with YES outcome calls diamond.reportOutcome.
    function test_relayOutcome_yesOutcome() public {
        bytes32 qId = keccak256("direct-q1");

        vm.expectEmit(true, false, true, true);
        emit OutcomeRelayed(qId, true, RELAYER);

        vm.prank(RELAYER);
        receiver.relayOutcome(qId, true);

        assertEq(diamond.reportOutcomeCallCount(), 1);
        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, qId);
        assertTrue(outO);
        assertTrue(receiver.relayed(qId));
    }

    /// @notice Happy path: relayOutcome with NO outcome.
    function test_relayOutcome_noOutcome() public {
        bytes32 qId = keccak256("direct-q2");

        vm.prank(RELAYER);
        receiver.relayOutcome(qId, false);

        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, qId);
        assertFalse(outO);
    }

    /// @notice relayOutcome emits AnswerRelayed with requestId = bytes32(0).
    function test_relayOutcome_emitsWithZeroRequestId() public {
        bytes32 qId = keccak256("direct-q-event");

        vm.expectEmit(true, false, true, true);
        emit OutcomeRelayed(qId, false, RELAYER);

        vm.prank(RELAYER);
        receiver.relayOutcome(qId, false);
    }

    /// @notice relayOutcome reverts with NotRelayer when called by non-relayer.
    function test_relayOutcome_revertsIfNotRelayer() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOutcome(keccak256("q"), true);
    }

    /// @notice relayOutcome reverts with QuestionAlreadyRelayed on double-relay.
    function test_relayOutcome_revertsIfAlreadyRelayed() public {
        bytes32 qId = keccak256("direct-dup");

        vm.prank(RELAYER);
        receiver.relayOutcome(qId, true);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOutcome(qId, false);
    }

    /// @notice A questionId relayed via relayOracleAnswer blocks relayOutcome (shared relayed map).
    function test_relayOutcome_blockedByPriorRelayOracleAnswer() public {
        bytes32 qId = keccak256("cross-block");

        vm.prank(RELAYER);
        receiver.relayOracleAnswer(qId, keccak256("r"), true);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOutcome(qId, false);
    }

    /// @notice A questionId relayed via relayOutcome blocks relayOracleAnswer (shared relayed map).
    function test_relayOracleAnswer_blockedByPriorRelayOutcome() public {
        bytes32 qId = keccak256("cross-block-2");

        vm.prank(RELAYER);
        receiver.relayOutcome(qId, true);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOracleAnswer(qId, keccak256("r"), false);
    }

    /// @notice relayOutcome does NOT call registerOracleRequest or reportPayouts.
    function test_relayOutcome_doesNotCallRegisterOrReportPayouts() public {
        vm.prank(RELAYER);
        receiver.relayOutcome(keccak256("only-outcome"), true);

        assertEq(diamond.registerCallCount(), 0);
        assertEq(diamond.reportPayoutsCallCount(), 0);
    }

    // ═══════════════════════════════════════════════════════
    // addRelayer
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can add a new relayer. Verifies state and event.
    function test_addRelayer_success() public {
        vm.expectEmit(true, false, true, true);
        emit RelayerUpdated(RELAYER_2, true, OWNER);

        vm.prank(OWNER);
        receiver.addRelayer(RELAYER_2);

        assertTrue(receiver.isRelayer(RELAYER_2));
    }

    /// @notice addRelayer reverts with NotOwner when called by non-owner.
    function test_addRelayer_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.addRelayer(RELAYER_2);
    }

    /// @notice addRelayer reverts with ZeroAddress for address(0).
    function test_addRelayer_revertsIfZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        receiver.addRelayer(address(0));
    }

    /// @notice addRelayer reverts with AlreadyRelayer if address is already a relayer.
    function test_addRelayer_revertsIfAlreadyRelayer() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.AlreadyRelayer.selector);
        receiver.addRelayer(RELAYER);
    }

    /// @notice Newly added relayer can successfully relay.
    function test_addRelayer_newRelayerCanRelay() public {
        vm.prank(OWNER);
        receiver.addRelayer(RELAYER_2);

        vm.prank(RELAYER_2);
        receiver.relayOutcome(keccak256("new-relayer-q"), true);

        assertEq(diamond.reportOutcomeCallCount(), 1);
    }

    // ═══════════════════════════════════════════════════════
    // removeRelayer
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can remove an existing relayer. Verifies state and event.
    function test_removeRelayer_success() public {
        vm.expectEmit(true, false, true, true);
        emit RelayerUpdated(RELAYER, false, OWNER);

        vm.prank(OWNER);
        receiver.removeRelayer(RELAYER);

        assertFalse(receiver.isRelayer(RELAYER));
    }

    /// @notice removeRelayer reverts with NotOwner when called by non-owner.
    function test_removeRelayer_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.removeRelayer(RELAYER);
    }

    /// @notice removeRelayer reverts with NotAuthorizedRelayer if address is not a relayer.
    function test_removeRelayer_revertsIfNotRelayer() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.NotAuthorizedRelayer.selector);
        receiver.removeRelayer(RANDOM);
    }

    /// @notice Removed relayer can no longer relay.
    function test_removeRelayer_removedRelayerCannotRelay() public {
        vm.prank(OWNER);
        receiver.removeRelayer(RELAYER);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOutcome(keccak256("blocked"), true);
    }

    /// @notice Re-adding a removed relayer works.
    function test_removeRelayer_reAddAfterRemove() public {
        vm.startPrank(OWNER);
        receiver.removeRelayer(RELAYER);
        receiver.addRelayer(RELAYER);
        vm.stopPrank();

        assertTrue(receiver.isRelayer(RELAYER));

        vm.prank(RELAYER);
        receiver.relayOutcome(keccak256("re-added"), true);
        assertEq(diamond.reportOutcomeCallCount(), 1);
    }

    // ═══════════════════════════════════════════════════════
    // setDiamond
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can update the diamond address. Verifies state and event.
    function test_setDiamond_success() public {
        MockDiamondOracle newDiamond = new MockDiamondOracle();

        vm.expectEmit(true, true, true, false);
        emit DiamondUpdated(address(diamond), address(newDiamond), OWNER);

        vm.prank(OWNER);
        receiver.setDiamond(address(newDiamond));

        assertEq(address(receiver.diamond()), address(newDiamond));
    }

    /// @notice setDiamond reverts with NotOwner when called by non-owner.
    function test_setDiamond_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.setDiamond(address(0x1234));
    }

    /// @notice setDiamond reverts with ZeroAddress for address(0).
    function test_setDiamond_revertsIfZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        receiver.setDiamond(address(0));
    }

    /// @notice After setDiamond, relays go to the new diamond.
    function test_setDiamond_relaysGoToNewDiamond() public {
        MockDiamondOracle newDiamond = new MockDiamondOracle();

        vm.prank(OWNER);
        receiver.setDiamond(address(newDiamond));

        vm.prank(RELAYER);
        receiver.relayOutcome(keccak256("new-diamond-q"), true);

        // Old diamond should have no calls
        assertEq(diamond.reportOutcomeCallCount(), 0);
        // New diamond should have the call
        assertEq(newDiamond.reportOutcomeCallCount(), 1);
    }

    // ═══════════════════════════════════════════════════════
    // proposeOwner
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can propose a new owner. Verifies state and event.
    function test_proposeOwner_success() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipProposed(OWNER, NEW_OWNER);

        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        assertEq(receiver.proposedOwner(), NEW_OWNER);
    }

    /// @notice proposeOwner reverts with NotOwner when called by non-owner.
    function test_proposeOwner_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.proposeOwner(NEW_OWNER);
    }

    /// @notice proposeOwner reverts with ZeroAddress for address(0).
    function test_proposeOwner_revertsIfZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
        receiver.proposeOwner(address(0));
    }

    /// @notice proposeOwner can be called multiple times, overwriting the previous proposal.
    function test_proposeOwner_overwritesPrevious() public {
        vm.startPrank(OWNER);
        receiver.proposeOwner(NEW_OWNER);
        receiver.proposeOwner(RELAYER_2);
        vm.stopPrank();

        assertEq(receiver.proposedOwner(), RELAYER_2);
    }

    // ═══════════════════════════════════════════════════════
    // acceptOwnership
    // ═══════════════════════════════════════════════════════

    /// @notice Proposed owner can accept ownership. Verifies state, event, and proposedOwner reset.
    function test_acceptOwnership_success() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(OWNER, NEW_OWNER);

        vm.prank(NEW_OWNER);
        receiver.acceptOwnership();

        assertEq(receiver.owner(), NEW_OWNER);
        assertEq(receiver.proposedOwner(), address(0));
    }

    /// @notice acceptOwnership reverts with NotProposedOwner if caller is not the proposed owner.
    function test_acceptOwnership_revertsIfNotProposedOwner() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();
    }

    /// @notice acceptOwnership reverts if no owner has been proposed (proposedOwner = address(0)).
    function test_acceptOwnership_revertsIfNoPendingProposal() public {
        vm.prank(RANDOM);
        vm.expectRevert(BridgeReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();
    }

    /// @notice Current owner cannot accept (they are not the proposed owner).
    function test_acceptOwnership_revertsIfCurrentOwnerCalls() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();
    }

    /// @notice After ownership transfer, old owner cannot perform admin actions.
    function test_acceptOwnership_oldOwnerLosesAccess() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.prank(NEW_OWNER);
        receiver.acceptOwnership();

        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.addRelayer(RELAYER_2);
    }

    /// @notice After ownership transfer, new owner can perform admin actions.
    function test_acceptOwnership_newOwnerHasAccess() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.prank(NEW_OWNER);
        receiver.acceptOwnership();

        vm.prank(NEW_OWNER);
        receiver.addRelayer(RELAYER_2);
        assertTrue(receiver.isRelayer(RELAYER_2));
    }

    /// @notice Overwritten proposal: only the latest proposed owner can accept.
    function test_acceptOwnership_overwrittenProposalCannotAccept() public {
        vm.startPrank(OWNER);
        receiver.proposeOwner(NEW_OWNER);
        receiver.proposeOwner(RELAYER_2);
        vm.stopPrank();

        // First proposed owner cannot accept
        vm.prank(NEW_OWNER);
        vm.expectRevert(BridgeReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();

        // Latest proposed owner can accept
        vm.prank(RELAYER_2);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), RELAYER_2);
    }

    // ═══════════════════════════════════════════════════════
    // INTEGRATION: Full lifecycle tests
    // ═══════════════════════════════════════════════════════

    /// @notice Full lifecycle: deploy → relay YES → relay different question NO.
    function test_integration_multipleRelays() public {
        bytes32 q1 = keccak256("market-1");
        bytes32 r1 = keccak256("req-1");
        bytes32 q2 = keccak256("market-2");
        bytes32 r2 = keccak256("req-2");

        vm.startPrank(RELAYER);
        receiver.relayOracleAnswer(q1, r1, true);
        receiver.relayOracleAnswer(q2, r2, false);
        vm.stopPrank();

        assertEq(diamond.registerCallCount(), 2);
        assertEq(diamond.reportPayoutsCallCount(), 2);

        // First relay: YES
        uint256[] memory p1 = diamond.getReportPayoutsPayouts(0);
        assertEq(p1[0], 1);
        assertEq(p1[1], 0);

        // Second relay: NO
        uint256[] memory p2 = diamond.getReportPayoutsPayouts(1);
        assertEq(p2[0], 0);
        assertEq(p2[1], 1);
    }

    /// @notice Full lifecycle: ownership transfer → new owner manages relayers → relay succeeds.
    function test_integration_ownershipTransferAndRelayerManagement() public {
        // Transfer ownership
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);
        vm.prank(NEW_OWNER);
        receiver.acceptOwnership();

        // New owner removes old relayer, adds new one
        vm.startPrank(NEW_OWNER);
        receiver.removeRelayer(RELAYER);
        receiver.addRelayer(RELAYER_2);
        vm.stopPrank();

        // Old relayer cannot relay
        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOutcome(keccak256("q"), true);

        // New relayer can relay
        vm.prank(RELAYER_2);
        receiver.relayOutcome(keccak256("q"), true);
        assertEq(diamond.reportOutcomeCallCount(), 1);
    }

    /// @notice Mixed relay paths: relayOracleAnswer for one question, relayOutcome for another.
    function test_integration_mixedRelayPaths() public {
        bytes32 q1 = keccak256("uma-q");
        bytes32 q2 = keccak256("chainlink-q");

        vm.startPrank(RELAYER);
        receiver.relayOracleAnswer(q1, keccak256("uma-r"), true);
        receiver.relayOutcome(q2, false);
        vm.stopPrank();

        // relayOracleAnswer path
        assertEq(diamond.registerCallCount(), 1);
        assertEq(diamond.reportPayoutsCallCount(), 1);

        // relayOutcome path
        assertEq(diamond.reportOutcomeCallCount(), 1);
        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, q2);
        assertFalse(outO);
    }
}
