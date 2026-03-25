// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {BridgeReceiver} from "../../src/BridgeReceiver.sol";
import {MockDiamondOracle} from "../mocks/MockDiamondOracle.sol";

/// @title BridgeReceiverFuzzTest
/// @notice Stateless fuzz tests for BridgeReceiver relay functions and admin operations.
contract BridgeReceiverFuzzTest is Test {
    address constant OWNER = address(0xABCD);
    address constant RELAYER = address(0x7777);

    BridgeReceiver receiver;
    MockDiamondOracle diamond;

    function setUp() public {
        diamond = new MockDiamondOracle();
        receiver = new BridgeReceiver(address(diamond), OWNER, RELAYER);
    }

    // ═══════════════════════════════════════════════════════
    // relayOracleAnswer fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice For any (questionId, requestId, outcome), relay succeeds exactly once
    ///         and produces correct payouts: [1,0] for YES, [0,1] for NO.
    function testFuzz_relayOracleAnswer_correctPayouts(bytes32 questionId, bytes32 requestId, bool outcome) public {
        vm.prank(RELAYER);
        receiver.relayOracleAnswer(questionId, requestId, outcome);

        // Verify relayed flag set
        assertTrue(receiver.relayed(questionId));

        // Verify payouts
        uint256[] memory payouts = diamond.getReportPayoutsPayouts(0);
        assertEq(payouts.length, 2);
        if (outcome) {
            assertEq(payouts[0], 1);
            assertEq(payouts[1], 0);
        } else {
            assertEq(payouts[0], 0);
            assertEq(payouts[1], 1);
        }

        // Verify registerOracleRequest args
        (bytes32 regQ, bytes32 regR) = diamond.registerCalls(0);
        assertEq(regQ, questionId);
        assertEq(regR, requestId);
    }

    /// @notice Double-relay always reverts regardless of the questionId value.
    function testFuzz_relayOracleAnswer_doubleRelayReverts(bytes32 questionId, bytes32 r1, bytes32 r2, bool o1, bool o2)
        public
    {
        vm.prank(RELAYER);
        receiver.relayOracleAnswer(questionId, r1, o1);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOracleAnswer(questionId, r2, o2);
    }

    /// @notice Non-relayer callers always revert.
    function testFuzz_relayOracleAnswer_nonRelayerReverts(address caller, bytes32 qId, bytes32 rId, bool outcome)
        public
    {
        vm.assume(caller != RELAYER);
        vm.prank(caller);
        vm.expectRevert(BridgeReceiver.NotRelayer.selector);
        receiver.relayOracleAnswer(qId, rId, outcome);
    }

    // ═══════════════════════════════════════════════════════
    // relayOutcome fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice relayOutcome forwards the correct questionId and outcome to the Diamond.
    function testFuzz_relayOutcome_correctArgs(bytes32 questionId, bool outcome) public {
        vm.prank(RELAYER);
        receiver.relayOutcome(questionId, outcome);

        assertTrue(receiver.relayed(questionId));
        (bytes32 outQ, bool outO) = diamond.reportOutcomeCalls(0);
        assertEq(outQ, questionId);
        assertEq(outO == outcome, true);
    }

    /// @notice Double relayOutcome always reverts.
    function testFuzz_relayOutcome_doubleRelayReverts(bytes32 questionId, bool o1, bool o2) public {
        vm.prank(RELAYER);
        receiver.relayOutcome(questionId, o1);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOutcome(questionId, o2);
    }

    /// @notice Cross-path double-relay: relayOracleAnswer then relayOutcome for same questionId.
    function testFuzz_crossPathDoubleRelay(bytes32 questionId, bytes32 requestId, bool o1, bool o2) public {
        vm.prank(RELAYER);
        receiver.relayOracleAnswer(questionId, requestId, o1);

        vm.prank(RELAYER);
        vm.expectRevert(BridgeReceiver.QuestionAlreadyRelayed.selector);
        receiver.relayOutcome(questionId, o2);
    }

    // ═══════════════════════════════════════════════════════
    // addRelayer fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice Any non-zero, non-existing relayer address can be added by owner.
    function testFuzz_addRelayer_success(address newRelayer) public {
        vm.assume(newRelayer != address(0));
        vm.assume(newRelayer != RELAYER);

        vm.prank(OWNER);
        receiver.addRelayer(newRelayer);

        assertTrue(receiver.isRelayer(newRelayer));
    }

    /// @notice Non-owner callers always revert when trying to add relayer.
    function testFuzz_addRelayer_nonOwnerReverts(address caller, address relayer) public {
        vm.assume(caller != OWNER);
        vm.prank(caller);
        vm.expectRevert(BridgeReceiver.NotOwner.selector);
        receiver.addRelayer(relayer);
    }

    // ═══════════════════════════════════════════════════════
    // removeRelayer fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice Removing a non-relayer address always reverts.
    function testFuzz_removeRelayer_nonRelayerReverts(address nonRelayer) public {
        vm.assume(!receiver.isRelayer(nonRelayer));
        vm.prank(OWNER);
        vm.expectRevert(BridgeReceiver.NotAuthorizedRelayer.selector);
        receiver.removeRelayer(nonRelayer);
    }

    // ═══════════════════════════════════════════════════════
    // setDiamond fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice Any non-zero address can be set as diamond by owner.
    function testFuzz_setDiamond_success(address newDiamond) public {
        vm.assume(newDiamond != address(0));
        vm.prank(OWNER);
        receiver.setDiamond(newDiamond);
        assertEq(address(receiver.diamond()), newDiamond);
    }

    // ═══════════════════════════════════════════════════════
    // Ownership fuzz
    // ═══════════════════════════════════════════════════════

    /// @notice Any non-zero address can be proposed as owner.
    function testFuzz_proposeOwner_success(address proposed) public {
        vm.assume(proposed != address(0));
        vm.prank(OWNER);
        receiver.proposeOwner(proposed);
        assertEq(receiver.proposedOwner(), proposed);
    }

    /// @notice Only the exact proposed address can accept. All others revert.
    function testFuzz_acceptOwnership_onlyProposedCanAccept(address proposed, address impersonator) public {
        vm.assume(proposed != address(0));
        vm.assume(impersonator != proposed);

        vm.prank(OWNER);
        receiver.proposeOwner(proposed);

        vm.prank(impersonator);
        vm.expectRevert(BridgeReceiver.NotProposedOwner.selector);
        receiver.acceptOwnership();
    }

    /// @notice Constructor rejects any combination with a zero address parameter.
    function testFuzz_constructor_rejectsZeroAddresses(address d, address o, address r) public {
        bool anyZero = d == address(0) || o == address(0) || r == address(0);
        if (anyZero) {
            vm.expectRevert(BridgeReceiver.ZeroAddress.selector);
            new BridgeReceiver(d, o, r);
        } else {
            BridgeReceiver br = new BridgeReceiver(d, o, r);
            assertEq(address(br.diamond()), d);
            assertEq(br.owner(), o);
            assertTrue(br.isRelayer(r));
        }
    }
}
