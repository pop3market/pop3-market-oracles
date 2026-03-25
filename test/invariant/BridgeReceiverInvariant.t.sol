// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {BridgeReceiver} from "../../src/BridgeReceiver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";

/// @title BridgeReceiverHandler
/// @notice Handler for stateful invariant testing. Exposes bounded actions that the fuzzer
///         calls in random sequences to discover invariant violations.
contract BridgeReceiverHandler is Test {
    BridgeReceiver public receiver;
    MockDiamondOracle public diamond;

    address public owner;
    address public relayer;

    // Ghost variables for tracking
    uint256 public ghost_relayCount;
    uint256 public ghost_doubleRelayAttempts;
    mapping(bytes32 => bool) public ghost_relayed;
    bytes32[] public ghost_relayedQuestions;

    constructor(BridgeReceiver _receiver, MockDiamondOracle _diamond, address _owner, address _relayer) {
        receiver = _receiver;
        diamond = _diamond;
        owner = _owner;
        relayer = _relayer;
    }

    /// @notice Relay an oracle answer via relayOracleAnswer. Uses a bounded seed to generate IDs.
    function relayOracleAnswer(uint256 seed, bool outcome) external {
        bytes32 questionId = keccak256(abi.encode("q", seed));
        bytes32 requestId = keccak256(abi.encode("r", seed));

        if (ghost_relayed[questionId]) {
            ghost_doubleRelayAttempts++;
            vm.prank(relayer);
            vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
            receiver.relayOracleAnswer(questionId, requestId, outcome);
            return;
        }

        vm.prank(relayer);
        receiver.relayOracleAnswer(questionId, requestId, outcome);

        ghost_relayed[questionId] = true;
        ghost_relayedQuestions.push(questionId);
        ghost_relayCount++;
    }

    /// @notice Relay an outcome via relayOutcome. Uses a bounded seed to generate IDs.
    function relayOutcome(uint256 seed, bool outcome) external {
        bytes32 questionId = keccak256(abi.encode("direct", seed));

        if (ghost_relayed[questionId]) {
            ghost_doubleRelayAttempts++;
            vm.prank(relayer);
            vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
            receiver.relayOutcome(questionId, outcome);
            return;
        }

        vm.prank(relayer);
        receiver.relayOutcome(questionId, outcome);

        ghost_relayed[questionId] = true;
        ghost_relayedQuestions.push(questionId);
        ghost_relayCount++;
    }

    /// @notice Attempt relay from a non-relayer address (should always revert).
    function relayFromNonRelayer(address caller, uint256 seed, bool outcome) external {
        vm.assume(caller != relayer);
        bytes32 questionId = keccak256(abi.encode("non-relayer", seed));

        vm.prank(caller);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOutcome(questionId, outcome);
    }

    function ghost_relayedQuestionsLength() external view returns (uint256) {
        return ghost_relayedQuestions.length;
    }
}

/// @title BridgeReceiverInvariantTest
/// @notice Invariant tests verifying BridgeReceiver state consistency across random action sequences.
contract BridgeReceiverInvariantTest is Test {
    address constant OWNER = address(0xABCD);
    address constant RELAYER = address(0x7777);

    BridgeReceiver receiver;
    MockDiamondOracle diamond;
    BridgeReceiverHandler handler;

    function setUp() public {
        diamond = new MockDiamondOracle();
        receiver = new BridgeReceiver(address(diamond), OWNER, RELAYER);
        handler = new BridgeReceiverHandler(receiver, diamond, OWNER, RELAYER);

        targetContract(address(handler));
    }

    /// @notice Invariant: The number of successful relays tracked by the handler matches
    ///         the total Diamond calls (registerCalls + reportOutcomeCalls for the two paths).
    function invariant_relayCountMatchesDiamondCalls() public view {
        uint256 diamondRelays = diamond.registerCallCount() + diamond.reportOutcomeCallCount();
        assertEq(handler.ghost_relayCount(), diamondRelays);
    }

    /// @notice Invariant: Every question marked as relayed in the handler is also marked
    ///         as relayed in the contract.
    function invariant_relayedFlagsConsistent() public view {
        uint256 len = handler.ghost_relayedQuestionsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 qId = handler.ghost_relayedQuestions(i);
            assertTrue(receiver.relayed(qId));
        }
    }

    /// @notice Invariant: The owner never changes unless acceptOwnership is called
    ///         (handler doesn't call it, so owner should remain OWNER).
    function invariant_ownerUnchanged() public view {
        assertEq(receiver.owner(), OWNER);
    }

    /// @notice Invariant: The diamond address never changes (handler doesn't call setDiamond).
    function invariant_diamondUnchanged() public view {
        assertEq(address(receiver.diamond()), address(diamond));
    }

    /// @notice Invariant: reportPayouts call count equals registerOracleRequest call count
    ///         (they're always called in pairs by relayOracleAnswer).
    function invariant_registerAndReportPayoutsPaired() public view {
        assertEq(diamond.registerCallCount(), diamond.reportPayoutsCallCount());
    }
}
