// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {UmaOracleAdapter} from "../../src/UmaOracleAdapter.sol";
import {MockOOv3} from "../mocks/MockOOv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title UmaOracleAdapterHandler
contract UmaOracleAdapterHandler is Test {
    UmaOracleAdapter public adapter;
    MockOOv3 public oov3;
    MockERC20 public usdc;
    address public owner;
    address public operator;

    uint256 constant DEFAULT_BOND = 250e6;

    uint256 public ghost_initialized;
    uint256 public ghost_settled;
    uint256 public ghost_cancelled;
    mapping(bytes32 => bool) public ghost_isInitialized;
    mapping(bytes32 => bool) public ghost_isDone;
    bytes32[] public ghost_allQuestions;

    constructor(UmaOracleAdapter _adapter, MockOOv3 _oov3, MockERC20 _usdc, address _owner, address _operator) {
        adapter = _adapter;
        oov3 = _oov3;
        usdc = _usdc;
        owner = _owner;
        operator = _operator;
    }

    function initializeQuestion(uint256 seed) external {
        bytes32 qId = keccak256(abi.encode("inv", seed));
        if (ghost_isInitialized[qId]) return;

        usdc.mint(operator, DEFAULT_BOND);
        vm.startPrank(operator);
        usdc.approve(address(adapter), DEFAULT_BOND);
        bytes32 aId = adapter.initializeQuestion(qId, "test", 0, 0, 0);
        vm.stopPrank();

        oov3.setAssertionResult(aId, true);

        ghost_isInitialized[qId] = true;
        ghost_initialized++;
        ghost_allQuestions.push(qId);
    }

    function settleQuestion(uint256 index) external {
        if (ghost_allQuestions.length == 0) return;
        index = bound(index, 0, ghost_allQuestions.length - 1);
        bytes32 qId = ghost_allQuestions[index];
        if (ghost_isDone[qId]) return;

        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        if (q.creator == address(0) || q.resolved) return;

        adapter.settleQuestion(qId);
        ghost_isDone[qId] = true;
        ghost_settled++;
    }

    function cancelQuestion(uint256 index) external {
        if (ghost_allQuestions.length == 0) return;
        index = bound(index, 0, ghost_allQuestions.length - 1);
        bytes32 qId = ghost_allQuestions[index];
        if (ghost_isDone[qId]) return;

        UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
        if (q.creator == address(0) || q.resolved) return;

        vm.prank(owner);
        adapter.cancelQuestion(qId);
        ghost_isDone[qId] = true;
        ghost_cancelled++;
    }

    function ghost_allQuestionsLength() external view returns (uint256) {
        return ghost_allQuestions.length;
    }
}

/// @title UmaOracleAdapterInvariantTest
contract UmaOracleAdapterInvariantTest is Test {
    address constant OWNER = address(0xABCD);
    address constant OPERATOR = address(0x7777);

    UmaOracleAdapter adapter;
    MockOOv3 oov3;
    MockERC20 usdc;
    UmaOracleAdapterHandler handler;

    function setUp() public {
        oov3 = new MockOOv3();
        usdc = new MockERC20("USDC", "USDC", 6);
        adapter = new UmaOracleAdapter(address(oov3), address(usdc), 250e6, 7200, 1800, OWNER, OPERATOR);
        vm.warp(1000);

        handler = new UmaOracleAdapterHandler(adapter, oov3, usdc, OWNER, OPERATOR);
        targetContract(address(handler));
    }

    /// @notice Owner never changes.
    function invariant_ownerUnchanged() public view {
        assertEq(adapter.owner(), OWNER);
    }

    /// @notice Resolved questions always have a non-zero creator.
    function invariant_resolvedQuestionsHaveCreator() public view {
        uint256 len = handler.ghost_allQuestionsLength();
        for (uint256 i = 0; i < len && i < 50; i++) {
            bytes32 qId = handler.ghost_allQuestions(i);
            UmaOracleAdapter.QuestionData memory q = adapter.getQuestion(qId);
            if (q.resolved) {
                assertTrue(q.creator != address(0));
            }
        }
    }

    /// @notice Bond currency balance on OOv3 >= initialized * DEFAULT_BOND (bonds deposited).
    function invariant_bondsSentToOov3() public view {
        assertGe(usdc.balanceOf(address(oov3)), handler.ghost_initialized() * 250e6);
    }
}
