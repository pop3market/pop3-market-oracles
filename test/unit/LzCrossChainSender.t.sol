// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LzCrossChainSender} from "../../src/LzCrossChainRelay.sol";
import {MockLayerZeroEndpoint} from "../mocks/MockLayerZeroEndpoint.sol";
import {MessagingFee} from "../../src/interfaces/ILayerZeroEndpointV2.sol";

/// @title LzCrossChainSenderTest
/// @notice Unit + integration tests for LzCrossChainSender.
contract LzCrossChainSenderTest is Test {
    // ── Constants ──────────────────────────────────────────
    address constant OWNER = address(0xABCD);
    address constant NEW_OWNER = address(0x9999);
    address constant ADAPTER = address(0x7777);
    address constant ADAPTER_2 = address(0x8888);
    address constant RANDOM = address(0xBEEF);
    address constant REFUND = address(0xFEED);
    uint32 constant DST_EID = 30145; // Unichain
    bytes32 constant PEER = bytes32(uint256(uint160(address(0xDEAD))));
    bytes constant DEFAULT_OPTIONS = hex"0003010011010000000000000000000000000000c350";

    // ── State ──────────────────────────────────────────────
    LzCrossChainSender sender;
    MockLayerZeroEndpoint endpoint;

    // ── Events ─────────────────────────────────────────────
    event AnswerSent(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint32 dstEid,
        bytes32 guid,
        address indexed adapter,
        uint256 feePaid,
        address refundAddress
    );
    event AdapterUpdated(address indexed caller, address indexed adapter, bool authorized);
    event PeerSet(address indexed caller, uint32 indexed dstEid, bytes32 oldPeer, bytes32 newPeer);
    event OptionsUpdated(address indexed caller, bytes oldOptions, bytes newOptions);
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        sender = new LzCrossChainSender(address(endpoint), DST_EID, OWNER, DEFAULT_OPTIONS);

        // Setup: set peer and add adapter
        vm.startPrank(OWNER);
        sender.setPeer(PEER);
        sender.addAdapter(ADAPTER);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @notice Constructor sets all state correctly.
    function test_constructor_setsState() public view {
        assertEq(address(sender.ENDPOINT()), address(endpoint));
        assertEq(sender.dstEid(), DST_EID);
        assertEq(sender.owner(), OWNER);
        assertEq(sender.defaultOptions(), DEFAULT_OPTIONS);
    }

    /// @notice Constructor emits OwnershipTransferred.
    function test_constructor_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), OWNER);
        new LzCrossChainSender(address(endpoint), DST_EID, OWNER, DEFAULT_OPTIONS);
    }

    /// @notice Constructor reverts if endpoint is zero.
    function test_constructor_revertsIfEndpointZero() public {
        vm.expectRevert(LzCrossChainSender.ZeroAddress.selector);
        new LzCrossChainSender(address(0), DST_EID, OWNER, DEFAULT_OPTIONS);
    }

    /// @notice Constructor reverts if owner is zero.
    function test_constructor_revertsIfOwnerZero() public {
        vm.expectRevert(LzCrossChainSender.ZeroAddress.selector);
        new LzCrossChainSender(address(endpoint), DST_EID, address(0), DEFAULT_OPTIONS);
    }

    // ═══════════════════════════════════════════════════════
    // sendAnswer
    // ═══════════════════════════════════════════════════════

    /// @notice Happy path: adapter sends an answer, verifying endpoint call and event.
    function test_sendAnswer_success() public {
        bytes32 qId = keccak256("q1");
        bytes32 rId = keccak256("r1");
        uint256 fee = 0.01 ether;

        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        sender.sendAnswer{value: fee}(qId, rId, true, REFUND);

        // Verify endpoint.send was called
        assertEq(endpoint.sendCallCount(), 1);
        (uint32 dstEid, bytes32 receiver,,,, address refund, uint256 val) = endpoint.sendCalls(0);
        assertEq(dstEid, DST_EID);
        assertEq(receiver, PEER);
        assertEq(refund, REFUND);
        assertEq(val, fee);

        // Verify payload encoding
        bytes memory payload = endpoint.getSendCallMessage(0);
        (bytes32 decQ, bytes32 decR, bool decO) = abi.decode(payload, (bytes32, bytes32, bool));
        assertEq(decQ, qId);
        assertEq(decR, rId);
        assertTrue(decO);

        // Verify options passed through
        bytes memory opts = endpoint.getSendCallOptions(0);
        assertEq(opts, DEFAULT_OPTIONS);
    }

    /// @notice sendAnswer emits AnswerSent with correct params.
    function test_sendAnswer_emitsEvent() public {
        bytes32 qId = keccak256("q-event");
        bytes32 rId = keccak256("r-event");

        vm.deal(ADAPTER, 1 ether);
        vm.expectEmit(true, true, true, false);
        emit AnswerSent(qId, rId, true, DST_EID, bytes32(0), ADAPTER, 0.01 ether, REFUND);

        vm.prank(ADAPTER);
        sender.sendAnswer{value: 0.01 ether}(qId, rId, true, REFUND);
    }

    /// @notice sendAnswer reverts if caller is not an adapter.
    function test_sendAnswer_revertsIfNotAdapter() public {
        vm.deal(RANDOM, 1 ether);
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotAdapter.selector);
        sender.sendAnswer{value: 0.01 ether}(keccak256("q"), keccak256("r"), true, REFUND);
    }

    /// @notice sendAnswer reverts if peer is not set (bytes32(0)).
    function test_sendAnswer_revertsIfPeerNotSet() public {
        // Deploy fresh sender without peer
        LzCrossChainSender freshSender = new LzCrossChainSender(address(endpoint), DST_EID, OWNER, DEFAULT_OPTIONS);
        vm.prank(OWNER);
        freshSender.addAdapter(ADAPTER);

        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        vm.expectRevert(LzCrossChainSender.PeerNotSet.selector);
        freshSender.sendAnswer{value: 0.01 ether}(keccak256("q"), keccak256("r"), true, REFUND);
    }

    /// @notice sendAnswer sends with requestId = bytes32(0) (direct outcome path).
    function test_sendAnswer_zeroRequestId() public {
        bytes32 qId = keccak256("direct");

        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        sender.sendAnswer{value: 0.01 ether}(qId, bytes32(0), false, REFUND);

        bytes memory payload = endpoint.getSendCallMessage(0);
        (bytes32 decQ, bytes32 decR, bool decO) = abi.decode(payload, (bytes32, bytes32, bool));
        assertEq(decQ, qId);
        assertEq(decR, bytes32(0));
        assertFalse(decO);
    }

    // ═══════════════════════════════════════════════════════
    // quoteFee
    // ═══════════════════════════════════════════════════════

    /// @notice quoteFee returns the endpoint's quoted fee.
    function test_quoteFee_success() public {
        endpoint.setQuotedNativeFee(0.005 ether);

        MessagingFee memory fee = sender.quoteFee(keccak256("q"), keccak256("r"), true);
        assertEq(fee.nativeFee, 0.005 ether);
        assertEq(fee.lzTokenFee, 0);
    }

    /// @notice quoteFee reverts if peer not set.
    function test_quoteFee_revertsIfPeerNotSet() public {
        LzCrossChainSender freshSender = new LzCrossChainSender(address(endpoint), DST_EID, OWNER, DEFAULT_OPTIONS);

        vm.expectRevert(LzCrossChainSender.PeerNotSet.selector);
        freshSender.quoteFee(keccak256("q"), keccak256("r"), true);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — setPeer
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can set peer. Verifies state + event. dstEid is immutable.
    function test_setPeer_success() public {
        bytes32 newPeer = bytes32(uint256(0x1234));
        vm.expectEmit(true, true, false, true);
        emit PeerSet(OWNER, DST_EID, PEER, newPeer);

        vm.prank(OWNER);
        sender.setPeer(newPeer);

        assertEq(sender.dstEid(), DST_EID); // dstEid unchanged (immutable)
        assertEq(sender.peer(), newPeer);
    }

    /// @notice setPeer can disable by setting bytes32(0).
    function test_setPeer_disable() public {
        vm.prank(OWNER);
        sender.setPeer(bytes32(0));
        assertEq(sender.peer(), bytes32(0));
    }

    /// @notice setPeer reverts if not owner.
    function test_setPeer_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.setPeer(PEER);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — setOptions
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can update options. Verifies state + event.
    function test_setOptions_success() public {
        bytes memory newOpts = hex"deadbeef";
        vm.expectEmit(true, false, false, true);
        emit OptionsUpdated(OWNER, DEFAULT_OPTIONS, newOpts);

        vm.prank(OWNER);
        sender.setOptions(newOpts);

        assertEq(sender.defaultOptions(), newOpts);
    }

    /// @notice setOptions reverts if not owner.
    function test_setOptions_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.setOptions(hex"00");
    }

    /// @notice setOptions reverts if empty bytes are provided.
    function test_setOptions_revertsIfEmptyOptions() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainSender.EmptyOptions.selector);
        sender.setOptions(bytes(""));
    }

    /// @notice Constructor reverts if empty options are provided.
    function test_constructor_revertsIfEmptyOptions() public {
        vm.expectRevert(LzCrossChainSender.EmptyOptions.selector);
        new LzCrossChainSender(address(endpoint), DST_EID, OWNER, bytes(""));
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — addAdapter / removeAdapter
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can add adapter. Verifies state + event.
    function test_addAdapter_success() public {
        vm.expectEmit(true, true, false, true);
        emit AdapterUpdated(OWNER, ADAPTER_2, true);

        vm.prank(OWNER);
        sender.addAdapter(ADAPTER_2);

        assertTrue(sender.isAdapter(ADAPTER_2));
    }

    /// @notice addAdapter reverts if zero address.
    function test_addAdapter_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainSender.ZeroAddress.selector);
        sender.addAdapter(address(0));
    }

    /// @notice addAdapter reverts if already adapter.
    function test_addAdapter_revertsIfAlready() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainSender.AlreadyAdapter.selector);
        sender.addAdapter(ADAPTER);
    }

    /// @notice addAdapter reverts if not owner.
    function test_addAdapter_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.addAdapter(ADAPTER_2);
    }

    /// @notice Owner can remove adapter. Verifies state + event.
    function test_removeAdapter_success() public {
        vm.expectEmit(true, true, false, true);
        emit AdapterUpdated(OWNER, ADAPTER, false);

        vm.prank(OWNER);
        sender.removeAdapter(ADAPTER);

        assertFalse(sender.isAdapter(ADAPTER));
    }

    /// @notice removeAdapter reverts if not authorized.
    function test_removeAdapter_revertsIfNotAdapter() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainSender.NotAuthorizedAdapter.selector);
        sender.removeAdapter(RANDOM);
    }

    /// @notice removeAdapter reverts if not owner.
    function test_removeAdapter_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.removeAdapter(ADAPTER);
    }

    /// @notice Removed adapter cannot send.
    function test_removeAdapter_blocksSubsequentSend() public {
        vm.prank(OWNER);
        sender.removeAdapter(ADAPTER);

        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        vm.expectRevert(LzCrossChainSender.NotAdapter.selector);
        sender.sendAnswer{value: 0.01 ether}(keccak256("q"), keccak256("r"), true, REFUND);
    }

    // ═══════════════════════════════════════════════════════
    // OWNERSHIP
    // ═══════════════════════════════════════════════════════

    /// @notice Owner can propose new owner.
    function test_proposeOwner_success() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipProposed(OWNER, NEW_OWNER);

        vm.prank(OWNER);
        sender.proposeOwner(NEW_OWNER);
        assertEq(sender.proposedOwner(), NEW_OWNER);
    }

    /// @notice proposeOwner reverts if zero.
    function test_proposeOwner_revertsIfZero() public {
        vm.prank(OWNER);
        vm.expectRevert(LzCrossChainSender.ZeroAddress.selector);
        sender.proposeOwner(address(0));
    }

    /// @notice proposeOwner reverts if not owner.
    function test_proposeOwner_revertsIfNotOwner() public {
        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.proposeOwner(NEW_OWNER);
    }

    /// @notice Proposed owner can accept.
    function test_acceptOwnership_success() public {
        vm.prank(OWNER);
        sender.proposeOwner(NEW_OWNER);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(OWNER, NEW_OWNER);

        vm.prank(NEW_OWNER);
        sender.acceptOwnership();

        assertEq(sender.owner(), NEW_OWNER);
        assertEq(sender.proposedOwner(), address(0));
    }

    /// @notice acceptOwnership reverts if not proposed.
    function test_acceptOwnership_revertsIfNotProposed() public {
        vm.prank(OWNER);
        sender.proposeOwner(NEW_OWNER);

        vm.prank(RANDOM);
        vm.expectRevert(LzCrossChainSender.NotProposedOwner.selector);
        sender.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // INTEGRATION
    // ═══════════════════════════════════════════════════════

    /// @notice Full flow: add adapter → set peer → set options → send → verify payload.
    function test_integration_fullSendFlow() public {
        // Fresh deployment
        LzCrossChainSender s = new LzCrossChainSender(address(endpoint), DST_EID, OWNER, DEFAULT_OPTIONS);

        vm.startPrank(OWNER);
        s.addAdapter(ADAPTER);
        s.setPeer(PEER);
        s.setOptions(hex"cafe");
        vm.stopPrank();

        bytes32 qId = keccak256("integration");
        bytes32 rId = keccak256("req");

        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        s.sendAnswer{value: 0.05 ether}(qId, rId, false, REFUND);

        // Options should be the new ones
        bytes memory opts = endpoint.getSendCallOptions(0);
        assertEq(opts, hex"cafe");
    }
}
