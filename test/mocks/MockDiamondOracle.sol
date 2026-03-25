// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDiamondOracle} from "../../src/interfaces/IDiamondOracle.sol";

/// @title MockDiamondOracle
/// @notice Mock implementation of IDiamondOracle for testing BridgeReceiver.
///         Records all calls for assertion in tests.
contract MockDiamondOracle is IDiamondOracle {
    // ── Call tracking ──────────────────────────────────────

    struct RegisterCall {
        bytes32 questionId;
        bytes32 requestId;
    }

    struct ReportPayoutsCall {
        bytes32 requestId;
        uint256[] payouts;
    }

    struct ReportOutcomeCall {
        bytes32 questionId;
        bool outcome;
    }

    RegisterCall[] public registerCalls;
    ReportPayoutsCall[] public reportPayoutsCalls;
    ReportOutcomeCall[] public reportOutcomeCalls;

    // ── Revert controls ────────────────────────────────────

    bool public shouldRevertRegister;
    bool public shouldRevertReportPayouts;
    bool public shouldRevertReportOutcome;

    function setRevertRegister(bool _revert) external {
        shouldRevertRegister = _revert;
    }

    function setRevertReportPayouts(bool _revert) external {
        shouldRevertReportPayouts = _revert;
    }

    function setRevertReportOutcome(bool _revert) external {
        shouldRevertReportOutcome = _revert;
    }

    // ── IDiamondOracle implementation ──────────────────────

    function registerOracleRequest(bytes32 questionId, bytes32 requestId) external override {
        if (shouldRevertRegister) revert("MockDiamondOracle: register reverted");
        registerCalls.push(RegisterCall(questionId, requestId));
    }

    function reportPayouts(bytes32 requestId, uint256[] calldata payouts) external override {
        if (shouldRevertReportPayouts) revert("MockDiamondOracle: reportPayouts reverted");
        ReportPayoutsCall storage c = reportPayoutsCalls.push();
        c.requestId = requestId;
        for (uint256 i = 0; i < payouts.length; i++) {
            c.payouts.push(payouts[i]);
        }
    }

    function reportOutcome(bytes32 questionId, bool outcome) external override {
        if (shouldRevertReportOutcome) revert("MockDiamondOracle: reportOutcome reverted");
        reportOutcomeCalls.push(ReportOutcomeCall(questionId, outcome));
    }

    // ── View helpers ───────────────────────────────────────

    function registerCallCount() external view returns (uint256) {
        return registerCalls.length;
    }

    function reportPayoutsCallCount() external view returns (uint256) {
        return reportPayoutsCalls.length;
    }

    function reportOutcomeCallCount() external view returns (uint256) {
        return reportOutcomeCalls.length;
    }

    function getReportPayoutsPayouts(uint256 index) external view returns (uint256[] memory) {
        return reportPayoutsCalls[index].payouts;
    }
}
