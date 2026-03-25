// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IChainlinkAggregatorV3} from "../../src/interfaces/IChainlinkAggregatorV3.sol";

/// @title MockChainlinkAggregator
/// @notice Configurable mock of a Chainlink AggregatorV3 price feed for testing.
///         Supports phase-aware round IDs, configurable round data, and revert simulation.
contract MockChainlinkAggregator is IChainlinkAggregatorV3 {
    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        bool exists;
    }

    mapping(uint80 => RoundData) internal rounds;
    uint80 internal _latestRoundId;
    uint8 internal _decimals;

    bool public shouldRevertGetRoundData;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    // ── Configuration ──────────────────────────────────────

    /// @notice Set data for a specific round. The round ID should be phase-encoded:
    ///         roundId = (uint80(phaseId) << 64) | uint80(aggregatorRoundId)
    function setRoundData(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) external {
        rounds[roundId] = RoundData({answer: answer, startedAt: startedAt, updatedAt: updatedAt, exists: true});
    }

    /// @notice Set the latest round ID returned by latestRoundData().
    function setLatestRoundId(uint80 roundId) external {
        _latestRoundId = roundId;
    }

    /// @notice Convenience: set round data AND mark it as the latest.
    function setLatestRound(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) external {
        rounds[roundId] = RoundData({answer: answer, startedAt: startedAt, updatedAt: updatedAt, exists: true});
        _latestRoundId = roundId;
    }

    function setShouldRevertGetRoundData(bool _revert) external {
        shouldRevertGetRoundData = _revert;
    }

    // ── IChainlinkAggregatorV3 ─────────────────────────────

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        RoundData memory r = rounds[_latestRoundId];
        return (_latestRoundId, r.answer, r.startedAt, r.updatedAt, _latestRoundId);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (shouldRevertGetRoundData) revert("MockChainlinkAggregator: reverted");
        RoundData memory r = rounds[_roundId];
        if (!r.exists) revert("MockChainlinkAggregator: round not found");
        return (_roundId, r.answer, r.startedAt, r.updatedAt, _roundId);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MOCK / USD";
    }

    // ── Helpers ────────────────────────────────────────────

    /// @notice Build a phase-encoded round ID from phaseId and aggregator round number.
    function encodeRoundId(uint16 phaseId, uint64 aggRound) external pure returns (uint80) {
        return (uint80(phaseId) << 64) | uint80(aggRound);
    }

    /// @notice Convenience: set up N sequential rounds in a phase with linearly spaced timestamps.
    ///         Rounds 1..count in the given phase, each `interval` seconds apart starting at `startTimestamp`.
    function setupSequentialRounds(
        uint16 phaseId,
        uint64 count,
        int256 basePrice,
        uint256 startTimestamp,
        uint256 interval
    ) external {
        for (uint64 i = 1; i <= count; i++) {
            uint80 roundId = (uint80(phaseId) << 64) | uint80(i);
            uint256 ts = startTimestamp + (uint256(i) - 1) * interval;
            rounds[roundId] = RoundData({answer: basePrice, startedAt: ts, updatedAt: ts, exists: true});
        }
        // Set latest to the last round
        uint80 lastRoundId = (uint80(phaseId) << 64) | uint80(count);
        _latestRoundId = lastRoundId;
    }
}
