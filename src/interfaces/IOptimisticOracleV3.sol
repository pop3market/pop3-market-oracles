// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOptimisticOracleV3
/// @notice Minimal interface for UMA's Optimistic Oracle V3 (OOv3).
///         Only includes functions used by the UmaOracleAdapter.
/// @dev Full interface: https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol
interface IOptimisticOracleV3 {
    // ═══════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════

    /// @notice On-chain state of a UMA assertion.
    /// @dev This is a simplified view struct. The actual OOv3 storage layout is packed
    ///      differently, but getAssertion() returns data ABI-decoded into this layout.
    ///      Key fields for our integration:
    ///        - asserter: receives bond back if assertion is correct
    ///        - callbackRecipient: our UmaOracleAdapter (receives settlement callbacks)
    ///        - settled + settlementResolution: final outcome after liveness or DVM vote
    struct Assertion {
        address asserter; // Who made the assertion and receives bond back if correct
        address callbackRecipient; // Contract receiving settlement callbacks
        address escalationManager; // Custom dispute resolver (address(0) = DVM)
        address currency; // Bond token address
        uint64 assertionTime; // Timestamp when assertion was made
        uint64 expirationTime; // Liveness expiration timestamp
        bool settled; // True if the assertion has been settled
        bool wasDisputed; // True if assertion was disputed
        bool settlementResolution; // Resolution after settlement (true = asserted truthfully)
        uint256 bond; // Bond amount
        bytes32 identifier; // DVM price identifier
    }

    // ═══════════════════════════════════════════════════════
    // ASSERTION
    // ═══════════════════════════════════════════════════════

    /// @notice Assert a truth about the world. The assertion will be verified by the oracle.
    /// @param claim The claim being asserted (UTF-8 encoded, human-readable).
    /// @param asserter The address posting the bond and making the claim.
    /// @param callbackRecipient The contract that will receive resolution/dispute callbacks.
    /// @param escalationManager Optional alternative dispute resolution. address(0) = use DVM.
    /// @param liveness Challenge window in seconds (e.g., 7200 = 2 hours).
    /// @param currency ERC20 token for bonding (e.g., USDC).
    /// @param bond The bond amount in `currency` tokens.
    /// @param identifier The DVM identifier for dispute resolution (e.g., "ASSERT_TRUTH2").
    /// @param domainId Optional grouping identifier. bytes32(0) if not used.
    /// @return assertionId Unique identifier for this assertion.
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    /// @notice Settle an assertion after liveness expires. Permissionless.
    /// @param assertionId The assertion to settle.
    function settleAssertion(bytes32 assertionId) external;

    /// @notice Read assertion data.
    /// @param assertionId The assertion to query.
    /// @return The assertion struct.
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);

    /// @notice Get the minimum bond amount required for a given currency.
    /// @param currency The bond token.
    /// @return The minimum bond in `currency` units.
    function getMinimumBond(address currency) external view returns (uint256);
}

/// @title IOptimisticOracleV3Callback
/// @notice Callback interface that the adapter must implement to receive UMA resolution.
/// @dev UMA calls these functions after assertion settlement or dispute.
interface IOptimisticOracleV3Callback {
    /// @notice Called by OOv3 when an assertion is settled.
    /// @param assertionId The unique identifier of the settled assertion.
    /// @param assertedTruthfully True if the assertion was confirmed (no dispute or won dispute).
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    /// @notice Called by OOv3 when an assertion is disputed before liveness expires.
    /// @param assertionId The unique identifier of the disputed assertion.
    function assertionDisputedCallback(bytes32 assertionId) external;
}
