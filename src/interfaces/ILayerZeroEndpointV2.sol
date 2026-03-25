// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

/// @title ILayerZeroEndpointV2
/// @notice Minimal interface for LayerZero Endpoint V2.
///         Only includes functions used by LzCrossChainRelay.
/// @dev Full interface: https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol

/// @notice Fee structure for LayerZero cross-chain messages.
/// @dev Returned by quote() and included in MessagingReceipt. The caller must send
///      at least nativeFee as msg.value when calling send(). lzTokenFee is typically 0
///      unless the sender opts to pay in ZRO token (payInLzToken=true).
struct MessagingFee {
    uint256 nativeFee; // Fee in native gas token (e.g., MATIC, ETH)
    uint256 lzTokenFee; // Fee in ZRO token (usually 0)
}

/// @notice Receipt returned after sending a message.
struct MessagingReceipt {
    bytes32 guid; // Global unique identifier for the message
    uint64 nonce; // Message sequence number
    MessagingFee fee; // Actual fee charged
}

/// @notice Parameters for sending a LayerZero cross-chain message.
/// @dev The options field encodes executor-level settings (e.g., gas limit for the
///      destination lzReceive() call). Built using LayerZero's OptionsBuilder library.
struct MessagingParams {
    uint32 dstEid; // Destination endpoint ID
    bytes32 receiver; // Receiver address as bytes32
    bytes message; // Payload
    bytes options; // Execution options (gas settings)
    bool payInLzToken; // Pay fee in ZRO token
}

/// @notice Origin metadata for received LayerZero messages.
/// @dev Passed to lzReceive() and allowInitializePath(). The receiver uses srcEid + sender
///      to verify the message comes from a trusted peer on the expected source chain.
struct Origin {
    uint32 srcEid; // Source endpoint ID
    bytes32 sender; // Sender address as bytes32
    uint64 nonce; // Message nonce
}

interface ILayerZeroEndpointV2 {
    /// @notice Send a cross-chain message.
    /// @param _params Messaging parameters (destination, receiver, payload, options).
    /// @param _refundAddress Address to refund excess fees.
    /// @return receipt The messaging receipt with guid, nonce, and fee.
    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt);

    /// @notice Quote the fee for sending a message.
    /// @param _params Messaging parameters.
    /// @param _sender The sender address (used for fee calculation).
    /// @return fee The estimated fee.
    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory fee);
}

/// @title ILayerZeroReceiver
/// @notice Interface that receiver contracts must implement.
interface ILayerZeroReceiver {
    /// @notice Called by the LayerZero Endpoint when a message arrives.
    /// @param _origin Source chain info (srcEid, sender, nonce).
    /// @param _guid Global unique message identifier.
    /// @param _message The payload.
    /// @param _executor Who executed the delivery.
    /// @param _extraData Optional extra data.
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;

    /// @notice Called by the LayerZero Endpoint to check if a message path should be initialized.
    /// @dev Must return true for trusted peers to allow nonce channel setup.
    /// @param _origin Source chain info (srcEid, sender, nonce).
    /// @return True if the path should be initialized.
    function allowInitializePath(Origin calldata _origin) external view returns (bool);
}
