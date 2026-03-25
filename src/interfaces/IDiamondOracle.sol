// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

/// @title IDiamondOracle
/// @notice Minimal interface for the Diamond's oracle-facing functions on Unichain.
///         Used by BridgeReceiver and ChainlinkPriceResolver to deliver oracle results.
/// @dev These functions are exposed by the Diamond's ResolutionFacet. The caller must
///      be the whitelisted oracle address for the market that owns the questionId.
///      Two resolution paths exist:
///        1. requestId path: registerOracleRequest() → reportPayouts() (used by UMA via BridgeReceiver)
///        2. direct path: reportOutcome(questionId, bool) (used by ChainlinkPriceResolver)
interface IDiamondOracle {
    /// @notice Register an external oracle requestId → questionId mapping.
    /// @dev Only callable by the market's whitelisted oracle address.
    /// @param questionId The internal question ID on the Diamond.
    /// @param requestId The external oracle request ID (e.g., UMA assertionId).
    function registerOracleRequest(bytes32 questionId, bytes32 requestId) external;

    /// @notice Report payouts via requestId (UMA-style).
    /// @dev Only callable by the market's whitelisted oracle address.
    ///      Looks up questionId via requestIdToQuestionId mapping.
    /// @param requestId The external oracle request ID.
    /// @param payouts [1,0] = YES wins, [0,1] = NO wins.
    function reportPayouts(bytes32 requestId, uint256[] calldata payouts) external;

    /// @notice Report outcome directly via questionId.
    /// @dev Only callable by the market's whitelisted oracle address.
    /// @param questionId The question to report on.
    /// @param outcome true = YES wins, false = NO wins.
    function reportOutcome(bytes32 questionId, bool outcome) external;
}
