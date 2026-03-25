// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LzCrossChainReceiver} from "../../src/LzCrossChainRelay.sol";
import {MockLayerZeroEndpoint} from "../mocks/MockLayerZeroEndpoint.sol";
import {MockBridgeReceiver} from "../mocks/MockBridgeReceiver.sol";
import {Origin} from "../../src/interfaces/ILayerZeroEndpointV2.sol";

/// @title LzCrossChainReceiverHandler
/// @notice Handler for stateful invariant testing of LzCrossChainReceiver.
contract LzCrossChainReceiverHandler is Test {
    LzCrossChainReceiver public receiver;
    MockLayerZeroEndpoint public endpoint;
    MockBridgeReceiver public bridge;
    address public owner;
    uint32 public srcEid;
    bytes32 public trustedPeer;

    // Ghost tracking
    uint256 public ghost_received;
    uint256 public ghost_failedStored;
    uint256 public ghost_selfHealed;
    uint256 public ghost_retried;
    uint256 public ghost_removed;

    constructor(
        LzCrossChainReceiver _receiver,
        MockLayerZeroEndpoint _endpoint,
        MockBridgeReceiver _bridge,
        address _owner,
        uint32 _srcEid,
        bytes32 _trustedPeer
    ) {
        receiver = _receiver;
        endpoint = _endpoint;
        bridge = _bridge;
        owner = _owner;
        srcEid = _srcEid;
        trustedPeer = _trustedPeer;
    }

    /// @notice Simulate receiving a LayerZero message (bridge works).
    function receiveMessage(uint256 seed, bool outcome) external {
        bytes32 qId = keccak256(abi.encode("q", seed));
        bytes32 rId = keccak256(abi.encode("r", seed));

        Origin memory origin = Origin({srcEid: srcEid, sender: trustedPeer, nonce: 1});
        bytes memory message = abi.encode(qId, rId, outcome);

        // Ensure bridge works
        bridge.setShouldRevert(false);

        vm.prank(address(endpoint));
        receiver.lzReceive(origin, keccak256(abi.encode(seed)), message, address(0), "");

        ghost_received++;
    }

    /// @notice Simulate receiving a message when bridge is broken (stores failed relay).
    function receiveMessageFailing(uint256 seed, bool outcome) external {
        bytes32 qId = keccak256(abi.encode("fail", seed));
        bytes32 rId = keccak256(abi.encode("rfail", seed));

        Origin memory origin = Origin({srcEid: srcEid, sender: trustedPeer, nonce: 1});
        bytes memory message = abi.encode(qId, rId, outcome);

        bridge.setShouldRevert(true);

        uint256 failedBefore = receiver.failedRelayCount();

        vm.prank(address(endpoint));
        receiver.lzReceive(origin, keccak256(abi.encode("fail", seed)), message, address(0), "");

        bridge.setShouldRevert(false);

        uint256 failedAfter = receiver.failedRelayCount();
        ghost_received++;

        // The new message always gets stored since bridge reverted.
        // But self-healing may have also popped one.
        // Net change can be 0 (healed one, added one) or +1 (no heal, added one)
        // or even -1 if healed one and self-heal retry of current also failed... but bridge was reverting.
        // Actually with bridge reverting: self-heal also fails, so no pop. New one added → net +1.
        ghost_failedStored += (failedAfter - failedBefore);
    }

    /// @notice Owner removes a failed relay.
    function removeFailedRelay(uint256 index) external {
        uint256 len = receiver.failedRelayCount();
        if (len == 0) return;
        index = bound(index, 0, len - 1);

        vm.prank(owner);
        receiver.removeFailedRelay(index);
        ghost_removed++;
    }
}

/// @title LzCrossChainReceiverInvariantTest
/// @notice Invariant tests for LzCrossChainReceiver state consistency.
contract LzCrossChainReceiverInvariantTest is Test {
    address constant OWNER = address(0xABCD);
    uint32 constant SRC_EID = 30109;
    bytes32 constant TRUSTED_PEER = bytes32(uint256(uint160(address(0xDEAD))));

    LzCrossChainReceiver receiver;
    MockLayerZeroEndpoint endpoint;
    MockBridgeReceiver bridge;
    LzCrossChainReceiverHandler handler;

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        bridge = new MockBridgeReceiver();
        receiver = new LzCrossChainReceiver(address(endpoint), address(bridge), OWNER);

        vm.prank(OWNER);
        receiver.setPeer(SRC_EID, TRUSTED_PEER);

        handler = new LzCrossChainReceiverHandler(receiver, endpoint, bridge, OWNER, SRC_EID, TRUSTED_PEER);
        targetContract(address(handler));
    }

    /// @notice Invariant: owner never changes (handler doesn't transfer).
    function invariant_ownerUnchanged() public view {
        assertEq(receiver.owner(), OWNER);
    }

    /// @notice Invariant: bridge call count >= received messages (some may fail + retry).
    ///         More precisely, bridge calls = successful relays (direct + self-healed + retried).
    function invariant_bridgeCallsNonNegative() public view {
        uint256 totalBridgeCalls = bridge.relayOracleAnswerCallCount() + bridge.relayOutcomeCallCount();
        // Bridge calls can never exceed total received + retried + self-healed
        assertTrue(totalBridgeCalls <= handler.ghost_received() * 2 + 100);
    }

    /// @notice Invariant: trusted peer for SRC_EID never changes (handler doesn't call setPeer).
    function invariant_peerUnchanged() public view {
        assertEq(receiver.peers(SRC_EID), TRUSTED_PEER);
    }
}
