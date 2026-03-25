// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3Callback} from "../../src/interfaces/IOptimisticOracleV3.sol";

/// @title MockOOv3
/// @notice Mock UMA Optimistic Oracle V3 for testing UmaOracleAdapter.
contract MockOOv3 is IOptimisticOracleV3 {
    uint256 internal _nextAssertionNonce;
    uint256 public minimumBond;
    mapping(bytes32 => Assertion) internal _assertions;

    // Settlement control
    mapping(bytes32 => bool) public settledAssertions;
    mapping(bytes32 => bool) public assertionResults; // true = assertedTruthfully

    function setMinimumBond(uint256 _min) external {
        minimumBond = _min;
    }

    /// @notice Pre-configure what result settleAssertion will produce.
    function setAssertionResult(bytes32 assertionId, bool result) external {
        assertionResults[assertionId] = result;
    }

    function assertTruth(
        bytes memory,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32
    ) external override returns (bytes32 assertionId) {
        _nextAssertionNonce++;
        assertionId = keccak256(abi.encode(_nextAssertionNonce, msg.sender, block.timestamp));

        // Pull bond from the adapter (it already approved us)
        require(currency.transferFrom(msg.sender, address(this), bond), "transfer failed");

        _assertions[assertionId] = Assertion({
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            escalationManager: escalationManager,
            currency: address(currency),
            assertionTime: uint64(block.timestamp),
            expirationTime: uint64(block.timestamp) + liveness,
            settled: false,
            wasDisputed: false,
            settlementResolution: false,
            bond: bond,
            identifier: identifier
        });
    }

    function settleAssertion(bytes32 assertionId) external override {
        Assertion storage a = _assertions[assertionId];
        require(!a.settled, "already settled");
        a.settled = true;
        bool result = assertionResults[assertionId];
        a.settlementResolution = result;

        // Call the callback on the adapter
        IOptimisticOracleV3Callback(a.callbackRecipient).assertionResolvedCallback(assertionId, result);
    }

    /// @notice Simulate a dispute callback.
    function simulateDispute(bytes32 assertionId) external {
        Assertion storage a = _assertions[assertionId];
        a.wasDisputed = true;
        IOptimisticOracleV3Callback(a.callbackRecipient).assertionDisputedCallback(assertionId);
    }

    function getAssertion(bytes32 assertionId) external view override returns (Assertion memory) {
        return _assertions[assertionId];
    }

    function getMinimumBond(address) external view override returns (uint256) {
        return minimumBond;
    }
}
