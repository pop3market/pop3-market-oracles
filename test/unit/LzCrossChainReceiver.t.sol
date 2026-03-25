// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LzCrossChainReceiver} from "../../src/LzCrossChainRelay.sol";
import {MockLayerZeroEndpoint} from "../mocks/MockLayerZeroEndpoint.sol";
import {MockBridgeReceiver} from "../mocks/MockBridgeReceiver.sol";
import {Origin} from "../../src/interfaces/ILayerZeroEndpointV2.sol";

/// @title LzCrossChainReceiverTest
/// @notice Unit + integration tests for LzCrossChainReceiver covering all branches.
contract LzCrossChainReceiverTest is Test {
    // ── Constants ──────────────────────────────────────────
    address constant OWNER = address(0xABCD);
    address constant NEW_OWNER = address(0x9999);
    address constant RANDOM = address(0xBEEF);
    uint32 constant SRC_EID = 30109; // Polygon
    bytes32 constant TRUSTED_PEER = bytes32(uint256(uint160(address(0xDEAD))));
    bytes32 constant GUID = keccak256("test-guid");

    // ── State ──────────────────────────────────────────────
    LzCrossChainReceiver receiver;
    MockLayerZeroEndpoint endpoint;
    MockBridgeReceiver bridge;

    // ── Events ─────────────────────────────────────────────
    event AnswerReceived(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint32 indexed srcEid,
        bytes32 sender,
        bytes32 guid,
        bool relayed
    );
    event RelayFailed(bytes32 indexed questionId, bytes32 indexed requestId, bool outcome, uint256 index, bytes reason);
    event RelayRecovered(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint256 index,
        uint256 newLength,
        bool manual
    );
    event FailedRelayRemoved(
        address indexed caller,
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint256 index,
        uint256 newLength
    );
    event PeerSet(address indexed caller, uint32 indexed srcEid, bytes32 oldPeer, bytes32 newPeer);
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Helpers ────────────────────────────────────────────

    function _makeOrigin(uint32 srcEid, bytes32 senderAddr) internal pure returns (Origin memory) {
        return Origin({srcEid: srcEid, sender: senderAddr, nonce: 1});
    }

    function _encodePayload(bytes32 qId, bytes32 rId, bool outcome) internal pure returns (bytes memory) {
        return abi.encode(qId, rId, outcome);
    }

    /// @dev Simulate an lzReceive call from the endpoint with a trusted peer.
    function _simulateLzReceive(bytes32 qId, bytes32 rId, bool outcome) internal {
        Origin memory origin = _makeOrigin(SRC_EID, TRUSTED_PEER);
        bytes memory message = _encodePayload(qId, rId, outcome);
        vm.prank(address(endpoint));
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        bridge = new MockBridgeReceiver();
        receiver = new LzCrossChainReceiver(address(endpoint), address(bridge), OWNER);

        // Set trusted peer
        vm.prank(OWNER);
        receiver.setPeer(SRC_EID, TRUSTED_PEER);
    }

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @notice Constructor sets all state correctly.
    function test_constructor_setsState() public view {
        assertEq(address(receiver.ENDPOINT()), address(endpoint));
        assertEq(address(receiver.BRIDGE_RECEIVER()), address(bridge));
        assertEq(receiver.owner(), OWNER);
    }

    /// @notice Constructor emits PeerSet and OwnershipTransferred.
    function test_constructor_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PeerSet(OWNER, 0, bytes32(0), bytes32(0));
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), OWNER);
        new LzCrossChainReceiver(address(endpoint), address(bridge), OWNER);
    }

    /// @notice Constructor reverts if endpoint is zero.
    function test_constructor_revertsIfEndpointZero() public {
        vm.expectRevert(LzCrossChainReceiver.ZeroAddress.selector);
        new LzCrossChainReceiver(address(0), address(bridge), OWNER);
    }

    /// @notice Constructor reverts if bridgeReceiver is zero.
    function test_constructor_revertsIfBridgeZero() public {
        vm.expectRevert(LzCrossChainReceiver.ZeroAddress.selector);
        new LzCrossChainReceiver(address(endpoint), address(0), OWNER);
    }

    /// @notice Constructor reverts if owner is zero.
    function test_constructor_revertsIfOwnerZero() public {
        vm.expectRevert(LzCrossChainReceiver.ZeroAddress.selector);
        new LzCrossChainReceiver(address(endpoint), address(bridge), address(0));
    }

    // ═══════════════════════════════════════════════════════
    // lzReceive — HAPPY PATHS
    // ═══════════════════════════════════════════════════════

    /// @notice lzReceive with requestId != 0 calls relayOracleAnswer on BridgeReceiver.
    function test_lzReceive_relayOracleAnswerPath() public {
        bytes32 qId = keccak256("q1");
        bytes32 rId = keccak256("r1");

        vm.expectEmit(true, true, true, true);
        emit AnswerReceived(qId, rId, true, SRC_EID, TRUSTED_PEER, GUID, true);

        _simulateLzReceive(qId, rId, true);

        assertEq(bridge.relayOracleAnswerCallCount(), 1);
        (bytes32 bQ, bytes32 bR, bool bO) = bridge.relayOracleAnswerCalls(0);
        assertEq(bQ, qId);
        assertEq(bR, rId);
        assertTrue(bO);
    }

    /// @notice lzReceive with requestId == 0 calls relayOutcome on BridgeReceiver.
    function test_lzReceive_relayOutcomePath() public {
        bytes32 qId = keccak256("direct");

        _simulateLzReceive(qId, bytes32(0), false);

        assertEq(bridge.relayOutcomeCallCount(), 1);
        (bytes32 bQ, bool bO) = bridge.relayOutcomeCalls(0);
        assertEq(bQ, qId);
        assertFalse(bO);
    }

    // ═══════════════════════════════════════════════════════
    // lzReceive — REVERTS / GUARDS
    // ═══════════════════════════════════════════════════════

    /// @notice lzReceive reverts with UnexpectedETH if msg.value > 0.
    function test_lzReceive_revertsIfETHSent() public {
        Origin memory origin = _makeOrigin(SRC_EID, TRUSTED_PEER);
        bytes memory message = _encodePayload(keccak256("q"), keccak256("r"), true);

        vm.deal(address(endpoint), 1 ether);
        vm.prank(address(endpoint));
        vm.expectRevert(LzCrossChainReceiver.UnexpectedETH.selector);
        receiver.lzReceive{value: 1}(origin, GUID, message, address(0), "");
    }

    /// @notice lzReceive reverts with NotEndpoint if caller is not the endpoint.
    function test_lzReceive_revertsIfNotEndpoint() public {
        Origin memory origin = _makeOrigin(SRC_EID, TRUSTED_PEER);
        bytes memory message = _encodePayload(keccak256("q"), keccak256("r"), true);

        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotEndpoint.selector);
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    /// @notice lzReceive reverts with NotTrustedPeer if peer not set for srcEid.
    function test_lzReceive_revertsIfPeerNotSet() public {
        Origin memory origin = _makeOrigin(99999, TRUSTED_PEER); // Unknown srcEid
        bytes memory message = _encodePayload(keccak256("q"), keccak256("r"), true);

        vm.prank(address(endpoint));
        vm.expectRevert(LzCrossChainReceiver.NotTrustedPeer.selector);
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    /// @notice lzReceive reverts with NotTrustedPeer if sender doesn't match peer.
    function test_lzReceive_revertsIfWrongSender() public {
        bytes32 wrongSender = bytes32(uint256(0x9999));
        Origin memory origin = _makeOrigin(SRC_EID, wrongSender);
        bytes memory message = _encodePayload(keccak256("q"), keccak256("r"), true);

        vm.prank(address(endpoint));
        vm.expectRevert(LzCrossChainReceiver.NotTrustedPeer.selector);
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    // ═══════════════════════════════════════════════════════
    // lzReceive — FAILED RELAY / SELF-HEALING
    // ═══════════════════════════════════════════════════════

    /// @notice When BridgeReceiver reverts, the relay is stored in _failedRelays.
    function test_lzReceive_storesFailedRelay() public {
        bridge.setShouldRevert(true);

        bytes32 qId = keccak256("fail");
        bytes32 rId = keccak256("r-fail");

        vm.expectEmit(true, true, false, false);
        emit RelayFailed(qId, rId, true, 0, "");

        _simulateLzReceive(qId, rId, true);

        // Check stored
        assertEq(receiver.failedRelayCount(), 1);
        (bytes32 sQ, bytes32 sR, bool sO) = receiver.getFailedRelay(0);
        assertEq(sQ, qId);
        assertEq(sR, rId);
        assertTrue(sO);
    }

    /// @notice AnswerReceived event is emitted even when relay fails.
    function test_lzReceive_emitsAnswerReceivedEvenOnFailure() public {
        bridge.setShouldRevert(true);

        bytes32 qId = keccak256("fail-event");
        bytes32 rId = keccak256("r-fail-event");

        vm.expectEmit(true, true, true, true);
        emit AnswerReceived(qId, rId, true, SRC_EID, TRUSTED_PEER, GUID, false);

        _simulateLzReceive(qId, rId, true);
    }

    /// @notice Self-healing: next lzReceive retries the last failed relay (LIFO).
    function test_lzReceive_selfHealsFailedRelay() public {
        // First message fails
        bridge.setShouldRevert(true);
        bytes32 qFail = keccak256("q-fail");
        bytes32 rFail = keccak256("r-fail");
        _simulateLzReceive(qFail, rFail, true);
        assertEq(receiver.failedRelayCount(), 1);

        // Second message: bridge is now working
        bridge.setShouldRevert(false);
        bytes32 qNew = keccak256("q-new");
        bytes32 rNew = keccak256("r-new");

        vm.expectEmit(true, true, false, true);
        emit RelayRecovered(qFail, rFail, true, 0, 0, false);

        _simulateLzReceive(qNew, rNew, false);

        // Failed relay was drained
        assertEq(receiver.failedRelayCount(), 0);

        // Both messages were relayed (recovered + new)
        assertEq(bridge.relayOracleAnswerCallCount(), 2);
    }

    /// @notice Self-healing only retries ONE failed relay per incoming message.
    function test_lzReceive_selfHealsOnlyOne() public {
        // Store 2 failed relays
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("f1"), keccak256("r1"), true);
        _simulateLzReceive(keccak256("f2"), keccak256("r2"), false);
        assertEq(receiver.failedRelayCount(), 2);

        // Now bridge works
        bridge.setShouldRevert(false);
        _simulateLzReceive(keccak256("new"), keccak256("rnew"), true);

        // Only ONE retry happened (LIFO: f2 retried), plus the new message
        assertEq(receiver.failedRelayCount(), 1);
    }

    /// @notice Self-healing: if retry also fails, the old entry stays.
    function test_lzReceive_selfHealFailsKeepsEntry() public {
        // First message fails
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("stuck"), keccak256("r-stuck"), true);
        assertEq(receiver.failedRelayCount(), 1);

        // Second message also fails (bridge still reverts)
        _simulateLzReceive(keccak256("also-stuck"), keccak256("r-also"), false);

        // Both are stored (retry of first failed, new also stored)
        assertEq(receiver.failedRelayCount(), 2);
    }

    /// @notice relayOutcome path (requestId=0) also stores failures and self-heals.
    function test_lzReceive_directOutcomePathFailsAndHeals() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("direct-fail"), bytes32(0), true);
        assertEq(receiver.failedRelayCount(), 1);

        bridge.setShouldRevert(false);
        _simulateLzReceive(keccak256("direct-new"), bytes32(0), false);

        // Self-healed + new relayed
        assertEq(receiver.failedRelayCount(), 0);
        assertEq(bridge.relayOutcomeCallCount(), 2);
    }

    // ═══════════════════════════════════════════════════════
    // allowInitializePath
    // ═══════════════════════════════════════════════════════

    /// @notice Returns true for trusted peer.
    function test_allowInitializePath_trustedPeer() public view {
        Origin memory origin = _makeOrigin(SRC_EID, TRUSTED_PEER);
        assertTrue(receiver.allowInitializePath(origin));
    }

    /// @notice Returns false for unknown srcEid (peer not set).
    function test_allowInitializePath_unknownSrcEid() public view {
        Origin memory origin = _makeOrigin(99999, TRUSTED_PEER);
        assertFalse(receiver.allowInitializePath(origin));
    }

    /// @notice Returns false for wrong sender.
    function test_allowInitializePath_wrongSender() public view {
        Origin memory origin = _makeOrigin(SRC_EID, bytes32(uint256(0x9999)));
        assertFalse(receiver.allowInitializePath(origin));
    }

    /// @notice Returns false when peer is disabled (bytes32(0)).
    function test_allowInitializePath_disabledPeer() public {
        vm.prank(OWNER);
        receiver.setPeer(SRC_EID, bytes32(0));

        Origin memory origin = _makeOrigin(SRC_EID, TRUSTED_PEER);
        assertFalse(receiver.allowInitializePath(origin));
    }

    // ═══════════════════════════════════════════════════════
    // retryFailedRelay
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can retry a failed relay. Entry is removed on success.
    function test_retryFailedRelay_success() public {
        // Store a failed relay
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("retry"), keccak256("r-retry"), true);
        assertEq(receiver.failedRelayCount(), 1);

        // Fix bridge, then retry
        bridge.setShouldRevert(false);

        vm.expectEmit(true, true, false, true);
        emit RelayRecovered(keccak256("retry"), keccak256("r-retry"), true, 0, 0, true);

        vm.prank(OWNER);
        receiver.retryFailedRelay(0);

        assertEq(receiver.failedRelayCount(), 0);
        assertEq(bridge.relayOracleAnswerCallCount(), 1);
    }

    /// @notice retryFailedRelay with requestId=0 calls relayOutcome.
    function test_retryFailedRelay_directOutcomePath() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("retry-direct"), bytes32(0), false);

        bridge.setShouldRevert(false);
        vm.prank(OWNER);
        receiver.retryFailedRelay(0);

        assertEq(bridge.relayOutcomeCallCount(), 1);
    }

    /// @notice retryFailedRelay reverts if bridge still reverts (swap+pop rolled back).
    function test_retryFailedRelay_revertsIfBridgeStillReverts() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("stuck"), keccak256("r"), true);

        // Bridge still reverts → retryFailedRelay reverts, array unchanged
        vm.prank(OWNER);
        vm.expectRevert("MockBridgeReceiver: reverted");
        receiver.retryFailedRelay(0);

        // Entry still in array
        assertEq(receiver.failedRelayCount(), 1);
    }

    /// @notice retryFailedRelay reverts with NoFailedRelay for out-of-bounds index.
    function test_retryFailedRelay_revertsIfOutOfBounds() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainReceiver.NoFailedRelay.selector);
        receiver.retryFailedRelay(0);
    }

    /// @notice retryFailedRelay reverts if not owner.
    function test_retryFailedRelay_revertsIfNotOwner() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("q"), keccak256("r"), true);
        bridge.setShouldRevert(false);

        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.retryFailedRelay(0);
    }

    /// @notice retryFailedRelay uses swap-and-pop: middle index swaps with last.
    function test_retryFailedRelay_swapAndPop() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("a"), keccak256("ra"), true);
        _simulateLzReceive(keccak256("b"), keccak256("rb"), false);
        _simulateLzReceive(keccak256("c"), keccak256("rc"), true);
        assertEq(receiver.failedRelayCount(), 3);

        bridge.setShouldRevert(false);

        // Retry index 0 → "a" is retried, "c" swapped to index 0
        vm.prank(OWNER);
        receiver.retryFailedRelay(0);

        assertEq(receiver.failedRelayCount(), 2);
        (bytes32 q0,,) = receiver.getFailedRelay(0);
        assertEq(q0, keccak256("c"));
        (bytes32 q1,,) = receiver.getFailedRelay(1);
        assertEq(q1, keccak256("b"));
    }

    // ═══════════════════════════════════════════════════════
    // removeFailedRelay
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can remove a failed relay without retrying.
    function test_removeFailedRelay_success() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("remove"), keccak256("r-remove"), true);

        vm.expectEmit(true, true, true, true);
        emit FailedRelayRemoved(OWNER, keccak256("remove"), keccak256("r-remove"), true, 0, 0);

        vm.prank(OWNER);
        receiver.removeFailedRelay(0);

        assertEq(receiver.failedRelayCount(), 0);
        // BridgeReceiver should NOT have been called (no retry)
        assertEq(bridge.relayOracleAnswerCallCount(), 0);
    }

    /// @notice removeFailedRelay reverts if out of bounds.
    function test_removeFailedRelay_revertsIfOutOfBounds() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainReceiver.NoFailedRelay.selector);
        receiver.removeFailedRelay(0);
    }

    /// @notice removeFailedRelay reverts if not owner.
    function test_removeFailedRelay_revertsIfNotOwner() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("q"), keccak256("r"), true);

        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.removeFailedRelay(0);
    }

    /// @notice removeFailedRelay swap-and-pop: correct element removed.
    function test_removeFailedRelay_swapAndPop() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("x"), keccak256("rx"), true);
        _simulateLzReceive(keccak256("y"), keccak256("ry"), false);

        vm.prank(OWNER);
        receiver.removeFailedRelay(0);

        assertEq(receiver.failedRelayCount(), 1);
        (bytes32 q0,,) = receiver.getFailedRelay(0);
        assertEq(q0, keccak256("y"));
    }

    // ═══════════════════════════════════════════════════════
    // getFailedRelay / failedRelayCount
    // ═══════════════════════════════════════════════════════

    /// @notice getFailedRelay returns correct data.
    function test_getFailedRelay_success() public {
        bridge.setShouldRevert(true);
        _simulateLzReceive(keccak256("view"), keccak256("r-view"), false);

        (bytes32 q, bytes32 r, bool o) = receiver.getFailedRelay(0);
        assertEq(q, keccak256("view"));
        assertEq(r, keccak256("r-view"));
        assertFalse(o);
    }

    /// @notice getFailedRelay reverts for out-of-bounds index.
    function test_getFailedRelay_revertsIfOutOfBounds() public {
        vm.expectRevert(LzCrossChainReceiver.NoFailedRelay.selector);
        receiver.getFailedRelay(0);
    }

    /// @notice failedRelayCount returns zero initially.
    function test_failedRelayCount_initiallyZero() public view {
        assertEq(receiver.failedRelayCount(), 0);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — setPeer
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can set peer.
    function test_setPeer_success() public {
        bytes32 newPeer = bytes32(uint256(0x1234));
        vm.expectEmit(true, true, false, true);
        emit PeerSet(OWNER, 42, bytes32(0), newPeer);

        vm.prank(OWNER);
        receiver.setPeer(42, newPeer);

        assertEq(receiver.peers(42), newPeer);
    }

    /// @notice setPeer can disable a chain by setting bytes32(0).
    function test_setPeer_disable() public {
        vm.prank(OWNER);
        receiver.setPeer(SRC_EID, bytes32(0));
        assertEq(receiver.peers(SRC_EID), bytes32(0));
    }

    /// @notice setPeer reverts if not owner.
    function test_setPeer_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.setPeer(SRC_EID, TRUSTED_PEER);
    }

    // ═══════════════════════════════════════════════════════
    // OWNERSHIP
    // ═══════════════════════════════════════════════════════

    /// @notice Propose + accept ownership.
    function test_ownership_transfer() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);
        assertEq(receiver.proposedOwner(), NEW_OWNER);

        vm.prank(NEW_OWNER);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), NEW_OWNER);
        assertEq(receiver.proposedOwner(), address(0));
    }

    /// @notice proposeOwner reverts if zero.
    function test_proposeOwner_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainReceiver.ZeroAddress.selector);
        receiver.proposeOwner(address(0));
    }

    /// @notice proposeOwner reverts if not owner.
    function test_proposeOwner_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.proposeOwner(NEW_OWNER);
    }

    /// @notice acceptOwnership reverts if not proposed owner.
    function test_acceptOwnership_revertsIfNotProposed() public {
        vm.prank(OWNER);
        receiver.proposeOwner(NEW_OWNER);

        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // INTEGRATION
    // ═══════════════════════════════════════════════════════

    /// @notice Full lifecycle: receive → fail → self-heal on next receive → retry remaining.
    function test_integration_fullFailureRecovery() public {
        // Message 1: fails
        bridge.setShouldRevert(true);
        bytes32 q1 = keccak256("msg1");
        bytes32 r1 = keccak256("req1");
        _simulateLzReceive(q1, r1, true);

        // Message 2: also fails
        bytes32 q2 = keccak256("msg2");
        bytes32 r2 = keccak256("req2");
        _simulateLzReceive(q2, r2, false);

        assertEq(receiver.failedRelayCount(), 2);

        // Message 3: bridge works now. Self-heals ONE (LIFO: q2).
        bridge.setShouldRevert(false);
        bytes32 q3 = keccak256("msg3");
        bytes32 r3 = keccak256("req3");
        _simulateLzReceive(q3, r3, true);

        assertEq(receiver.failedRelayCount(), 1);

        // Owner retries the remaining one (q1)
        vm.prank(OWNER);
        receiver.retryFailedRelay(0);

        assertEq(receiver.failedRelayCount(), 0);
        // Total: q2 (self-healed) + q3 (new) + q1 (retried) = 3 relayOracleAnswer calls
        assertEq(bridge.relayOracleAnswerCallCount(), 3);
    }

    /// @notice setPeer then receive from new chain.
    function test_integration_multiChainPeers() public {
        uint32 newSrcEid = 30101; // Ethereum
        bytes32 newPeer = bytes32(uint256(0x1111));

        vm.prank(OWNER);
        receiver.setPeer(newSrcEid, newPeer);

        Origin memory origin = Origin({srcEid: newSrcEid, sender: newPeer, nonce: 1});
        bytes memory message = _encodePayload(keccak256("eth-q"), keccak256("eth-r"), true);

        vm.prank(address(endpoint));
        receiver.lzReceive(origin, GUID, message, address(0), "");

        assertEq(bridge.relayOracleAnswerCallCount(), 1);
    }
}
