// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {UmaOracleAdapter} from "../../src/UmaOracleAdapter.sol";
import {MockOOv3} from "../mocks/MockOOv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title UmaOracleAdapterFuzzTest
/// @notice Stateless fuzz tests for UmaOracleAdapter.
contract UmaOracleAdapterFuzzTest is Test {
    address constant OWNER = address(0xABCD);
    address constant OPERATOR = address(0x7777);
    uint256 constant DEFAULT_BOND = 250e6;
    uint64 constant DEFAULT_LIVENESS = 7200;
    uint64 constant MIN_LIVENESS = 1800;

    UmaOracleAdapter adapter;
    MockOOv3 oov3;
    MockERC20 usdc;

    function setUp() public {
        oov3 = new MockOOv3();
        usdc = new MockERC20("USDC", "USDC", 6);
        adapter = new UmaOracleAdapter(
            address(oov3), address(usdc), DEFAULT_BOND, DEFAULT_LIVENESS, MIN_LIVENESS, OWNER, OPERATOR
        );
        vm.warp(1000);
    }

    /// @notice Non-authorized callers always revert.
    function testFuzz_initializeQuestion_nonAuthorizedReverts(address caller) public {
        vm.assume(caller != OPERATOR && caller != OWNER);
        vm.prank(caller);
        vm.expectRevert(UmaOracleAdapter.NotQuestionAuthorized.selector);
        adapter.initializeQuestion(keccak256("q"), "claim", 0, 0, 0);
    }

    /// @notice Duplicate questionId always reverts.
    function testFuzz_initializeQuestion_duplicateReverts(bytes32 qId) public {
        vm.assume(qId != bytes32(0));
        usdc.mint(OPERATOR, DEFAULT_BOND * 2);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND * 2);
        adapter.initializeQuestion(qId, "claim", 0, 0, 0);

        vm.expectRevert(UmaOracleAdapter.QuestionAlreadyInitialized.selector);
        adapter.initializeQuestion(qId, "claim", 0, 0, 0);
        vm.stopPrank();
    }

    /// @notice Settlement outcome always matches assertedTruthfully.
    function testFuzz_settleQuestion_outcomeMatchesTruthfulness(bool truthful) public {
        bytes32 qId = keccak256(abi.encode("outcome", truthful));
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, "claim", 0, 0, 0);
        vm.stopPrank();

        oov3.setAssertionResult(aId, truthful);
        adapter.settleQuestion(qId);

        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        assertTrue(q.resolved);
        assertEq(q.outcome, truthful);
    }

    /// @notice Non-owner admin always reverts.
    function testFuzz_admin_nonOwnerReverts(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.setDefaultBond(1);

        vm.prank(caller);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.setDefaultLiveness(MIN_LIVENESS);

        vm.prank(caller);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.addOperator(address(0x1234));

        vm.prank(caller);
        vm.expectRevert(UmaOracleAdapter.NotOwner.selector);
        adapter.proposeOwner(address(0x1234));
    }

    /// @notice operatorDelay > actualLiveness always reverts.
    function testFuzz_initializeQuestion_delayTooLong(uint64 delay) public {
        delay = uint64(bound(uint256(delay), uint256(DEFAULT_LIVENESS) + 1, type(uint64).max));
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.DelayTooLong.selector);
        adapter.initializeQuestion(keccak256(abi.encode(delay)), "claim", 0, 0, delay);
        vm.stopPrank();
    }

    /// @notice Custom liveness below minLiveness always reverts.
    function testFuzz_initializeQuestion_livenessTooShort(uint64 liveness) public {
        liveness = uint64(bound(uint256(liveness), 1, MIN_LIVENESS - 1));
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        vm.expectRevert(UmaOracleAdapter.LivenessTooShort.selector);
        adapter.initializeQuestion(keccak256(abi.encode(liveness)), "claim", 0, liveness, 0);
        vm.stopPrank();
    }

    /// @notice Any non-zero bond can be set by owner.
    function testFuzz_setDefaultBond_success(uint256 bond) public {
        bond = bound(bond, 1, type(uint256).max);
        vm.prank(OWNER);
        adapter.setDefaultBond(bond);
        assertEq(adapter.defaultBond(), bond);
    }

    /// @notice During operator delay, non-operator/non-owner always reverts.
    function testFuzz_operatorDelay_blocksPublic(uint64 delay, uint64 timeAfterExpiry) public {
        delay = uint64(bound(uint256(delay), 1, DEFAULT_LIVENESS));
        timeAfterExpiry = uint64(bound(uint256(timeAfterExpiry), 0, uint256(delay) - 1));

        bytes32 qId = keccak256(abi.encode("delay-fuzz", delay, timeAfterExpiry));
        usdc.mint(OPERATOR, DEFAULT_BOND);
        vm.startPrank(OPERATOR);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, "claim", 0, 0, delay);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);

        // expirationTime = 1000 + DEFAULT_LIVENESS
        uint256 expiration = 1000 + uint256(DEFAULT_LIVENESS);
        vm.warp(expiration + uint256(timeAfterExpiry));
        vm.prank(address(0xDEAD));
        vm.expectRevert(UmaOracleAdapter.OperatorWindowActive.selector);
        adapter.settleQuestion(qId);
    }
}
