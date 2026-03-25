// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILzBridgeReceiver} from "../../src/LzCrossChainRelay.sol";

/// @title MockBridgeReceiver
/// @notice Mock for testing LzCrossChainReceiver's forwarding to BridgeReceiver.
contract MockBridgeReceiver is ILzBridgeReceiver {
    struct RelayOracleAnswerCall {
        bytes32 questionId;
        bytes32 requestId;
        bool outcome;
    }

    struct RelayOutcomeCall {
        bytes32 questionId;
        bool outcome;
    }

    RelayOracleAnswerCall[] public relayOracleAnswerCalls;
    RelayOutcomeCall[] public relayOutcomeCalls;

    bool public shouldRevert;

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function relayOracleAnswer(bytes32 questionId, bytes32 requestId, bool outcome) external override {
        if (shouldRevert) revert("MockBridgeReceiver: reverted");
        relayOracleAnswerCalls.push(RelayOracleAnswerCall(questionId, requestId, outcome));
    }

    function relayOutcome(bytes32 questionId, bool outcome) external override {
        if (shouldRevert) revert("MockBridgeReceiver: reverted");
        relayOutcomeCalls.push(RelayOutcomeCall(questionId, outcome));
    }

    function relayOracleAnswerCallCount() external view returns (uint256) {
        return relayOracleAnswerCalls.length;
    }

    function relayOutcomeCallCount() external view returns (uint256) {
        return relayOutcomeCalls.length;
    }
}
