// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UmaOracleAdapter} from "../../src/UmaOracleAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrantERC20} from "./ReentrantERC20.sol";

/// @title ReentrantAttacker
/// @notice Helper for the re-entrancy test. During the reentrant callback,
///         this contract cancels the question and re-initializes it, creating
///         a second assertionId that maps to the same questionId.
contract ReentrantAttacker {
    UmaOracleAdapter public adapter;
    ReentrantERC20 public token;
    bytes32 public questionId;
    bytes32 public innerAssertionId;
    bool public attacked;

    constructor(UmaOracleAdapter _adapter, ReentrantERC20 _token) {
        adapter = _adapter;
        token = _token;
    }

    /// @notice Called by the test to start the outer initializeQuestion.
    ///         The ReentrantERC20 will callback to `reentrantCallback` during transferFrom.
    function startAttack(bytes32 _questionId, uint256 bond) external {
        questionId = _questionId;

        // Approve adapter to pull bond for BOTH init calls
        token.approve(address(adapter), bond * 2);

        // Arm the callback — it will fire during safeTransferFrom in initializeQuestion
        token.setCallback(address(this), abi.encodeCall(this.reentrantCallback, ()));

        // This triggers: creator set → transferFrom → callback → cancel + reinit → resume
        adapter.initializeQuestion(questionId, "claim", bond, 0, 0);
    }

    /// @notice Called by ReentrantERC20 during the outer initializeQuestion's transferFrom.
    function reentrantCallback() external {
        // Cancel the question (we are the creator since we called initializeQuestion)
        adapter.cancelQuestion(questionId);

        // Re-initialize with the same questionId — gets a NEW assertionId
        innerAssertionId = adapter.initializeQuestion(questionId, "claim2", 0, 0, 0);
        attacked = true;
    }
}
