// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LzCrossChainSender, LzCrossChainReceiver} from "../../src/LzCrossChainRelay.sol";
import {MockLayerZeroEndpoint} from "../mocks/MockLayerZeroEndpoint.sol";
import {MockBridgeReceiver} from "../mocks/MockBridgeReceiver.sol";
import {Origin} from "../../src/interfaces/ILayerZeroEndpointV2.sol";

/// @title LzCrossChainSenderFuzzTest
/// @notice Fuzz tests for LzCrossChainSender.
contract LzCrossChainSenderFuzzTest is Test {
    address constant OWNER = address(0xABCD);
    address constant ADAPTER = address(0x7777);
    uint32 constant DST_EID = 30145;
    bytes32 constant PEER = bytes32(uint256(uint160(address(0xDEAD))));

    LzCrossChainSender sender;
    MockLayerZeroEndpoint endpoint;

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        sender = new LzCrossChainSender(address(endpoint), DST_EID, OWNER, hex"0001");
        vm.startPrank(OWNER);
        sender.setPeer(PEER);
        sender.addAdapter(ADAPTER);
        vm.stopPrank();
    }

    /// @notice sendAnswer correctly encodes any (questionId, requestId, outcome) payload.
    function testFuzz_sendAnswer_payloadEncoding(bytes32 qId, bytes32 rId, bool outcome) public {
        vm.deal(ADAPTER, 1 ether);
        vm.prank(ADAPTER);
        sender.sendAnswer{value: 0.01 ether}(qId, rId, outcome, address(0));

        bytes memory payload = endpoint.getSendCallMessage(0);
        (bytes32 decQ, bytes32 decR, bool decO) = abi.decode(payload, (bytes32, bytes32, bool));
        assertEq(decQ, qId);
        assertEq(decR, rId);
        assertEq(decO, outcome);
    }

    /// @notice Non-adapter callers always revert.
    function testFuzz_sendAnswer_nonAdapterReverts(address caller) public {
        vm.assume(caller != ADAPTER);
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(LzCrossChainSender.NotAdapter.selector);
        sender.sendAnswer{value: 0.01 ether}(keccak256("q"), keccak256("r"), true, address(0));
    }

    /// @notice Non-owner callers always revert on admin functions.
    function testFuzz_admin_nonOwnerReverts(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.setPeer(bytes32(0));

        vm.prank(caller);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.setOptions(hex"00");

        vm.prank(caller);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.addAdapter(address(0x1234));

        vm.prank(caller);
        vm.expectRevert(LzCrossChainSender.NotOwner.selector);
        sender.proposeOwner(address(0x1234));
    }

    /// @notice Any non-zero address can be added as adapter by owner.
    function testFuzz_addAdapter_success(address adapter) public {
        vm.assume(adapter != address(0) && adapter != ADAPTER);
        vm.prank(OWNER);
        sender.addAdapter(adapter);
        assertTrue(sender.isAdapter(adapter));
    }
}

/// @title LzCrossChainReceiverFuzzTest
/// @notice Fuzz tests for LzCrossChainReceiver.
contract LzCrossChainReceiverFuzzTest is Test {
    address constant OWNER = address(0xABCD);
    uint32 constant SRC_EID = 30109;
    bytes32 constant TRUSTED_PEER = bytes32(uint256(uint160(address(0xDEAD))));
    bytes32 constant GUID = keccak256("fuzz-guid");

    LzCrossChainReceiver receiver;
    MockLayerZeroEndpoint endpoint;
    MockBridgeReceiver bridge;

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        bridge = new MockBridgeReceiver();
        receiver = new LzCrossChainReceiver(address(endpoint), address(bridge), OWNER);
        vm.prank(OWNER);
        receiver.setPeer(SRC_EID, TRUSTED_PEER);
    }

    /// @notice lzReceive correctly routes based on requestId: != 0 → relayOracleAnswer, == 0 → relayOutcome.
    function testFuzz_lzReceive_routingByRequestId(bytes32 qId, bytes32 rId, bool outcome) public {
        Origin memory origin = Origin({srcEid: SRC_EID, sender: TRUSTED_PEER, nonce: 1});
        bytes memory message = abi.encode(qId, rId, outcome);

        vm.prank(address(endpoint));
        receiver.lzReceive(origin, GUID, message, address(0), "");

        if (rId != bytes32(0)) {
            assertEq(bridge.relayOracleAnswerCallCount(), 1);
            (bytes32 bQ, bytes32 bR, bool bO) = bridge.relayOracleAnswerCalls(0);
            assertEq(bQ, qId);
            assertEq(bR, rId);
            assertEq(bO, outcome);
        } else {
            assertEq(bridge.relayOutcomeCallCount(), 1);
            (bytes32 bQ, bool bO) = bridge.relayOutcomeCalls(0);
            assertEq(bQ, qId);
            assertEq(bO, outcome);
        }
    }

    /// @notice Non-endpoint callers always revert.
    function testFuzz_lzReceive_nonEndpointReverts(address caller) public {
        vm.assume(caller != address(endpoint));

        Origin memory origin = Origin({srcEid: SRC_EID, sender: TRUSTED_PEER, nonce: 1});
        bytes memory message = abi.encode(keccak256("q"), keccak256("r"), true);

        vm.prank(caller);
        vm.expectRevert(LzCrossChainReceiver.NotEndpoint.selector);
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    /// @notice Untrusted senders always revert.
    function testFuzz_lzReceive_untrustedSenderReverts(bytes32 senderAddr) public {
        vm.assume(senderAddr != TRUSTED_PEER && senderAddr != bytes32(0));

        Origin memory origin = Origin({srcEid: SRC_EID, sender: senderAddr, nonce: 1});
        bytes memory message = abi.encode(keccak256("q"), keccak256("r"), true);

        vm.prank(address(endpoint));
        vm.expectRevert(LzCrossChainReceiver.NotTrustedPeer.selector);
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    /// @notice allowInitializePath: only trusted peer returns true.
    function testFuzz_allowInitializePath(uint32 srcEid, bytes32 senderAddr) public view {
        Origin memory origin = Origin({srcEid: srcEid, sender: senderAddr, nonce: 1});
        bool expected = (srcEid == SRC_EID && senderAddr == TRUSTED_PEER);
        assertEq(receiver.allowInitializePath(origin), expected);
    }

    /// @notice Any ETH value > 0 causes UnexpectedETH revert.
    function testFuzz_lzReceive_revertsOnAnyETH(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        Origin memory origin = Origin({srcEid: SRC_EID, sender: TRUSTED_PEER, nonce: 1});
        bytes memory message = abi.encode(keccak256("q"), keccak256("r"), true);

        vm.deal(address(endpoint), amount);
        vm.prank(address(endpoint));
        vm.expectRevert(LzCrossChainReceiver.UnexpectedETH.selector);
        receiver.lzReceive{value: amount}(origin, GUID, message, address(0), "");
    }

    /// @notice Non-owner always reverts on admin functions.
    function testFuzz_admin_nonOwnerReverts(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.setPeer(1, bytes32(0));

        vm.prank(caller);
        vm.expectRevert(LzCrossChainReceiver.NotOwner.selector);
        receiver.proposeOwner(address(0x1234));
    }
}
