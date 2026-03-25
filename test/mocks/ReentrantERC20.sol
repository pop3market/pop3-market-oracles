// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ReentrantERC20
/// @notice ERC20 that executes an arbitrary callback during transferFrom.
///         Used to simulate ERC777-style re-entrancy in UmaOracleAdapter tests.
contract ReentrantERC20 is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackEnabled;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm the re-entrancy: next transferFrom will call target with data.
    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callbackData = data;
        callbackEnabled = true;
    }

    function disableCallback() external {
        callbackEnabled = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Execute callback BEFORE the transfer (simulating ERC777 sender hook)
        if (callbackEnabled && callbackTarget != address(0)) {
            callbackEnabled = false; // prevent infinite recursion
            (bool success,) = callbackTarget.call(callbackData);
            require(success, "ReentrantERC20: callback failed");
        }
        return super.transferFrom(from, to, amount);
    }
}
