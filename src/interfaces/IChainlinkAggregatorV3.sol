// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

/// @title IChainlinkAggregatorV3
/// @notice Minimal interface for Chainlink AggregatorV3 price feeds.
/// @dev Full interface: https://docs.chain.link/data-feeds/api-reference
interface IChainlinkAggregatorV3 {
    /// @notice Get data from the latest round.
    /// @return roundId The round ID.
    /// @return answer The price (scaled by decimals()).
    /// @return startedAt Timestamp when the round started.
    /// @return updatedAt Timestamp when the round was last updated.
    /// @return answeredInRound Deprecated — for backwards compatibility.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Get data from a specific historical round.
    /// @param _roundId The round to query. Reverts if round doesn't exist.
    /// @return roundId The round ID.
    /// @return answer The price (scaled by decimals()).
    /// @return startedAt Timestamp when the round started.
    /// @return updatedAt Timestamp when the round was last updated.
    /// @return answeredInRound Deprecated — for backwards compatibility.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Get the number of decimals in the price answer.
    /// @return The decimal count (e.g., 8 for BTC/USD = 1e8).
    function decimals() external view returns (uint8);

    /// @notice Get a human-readable description of the feed (e.g., "BTC / USD").
    /// @return The feed description.
    function description() external view returns (string memory);
}
