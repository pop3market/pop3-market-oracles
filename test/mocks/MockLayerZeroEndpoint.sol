// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt,
    MessagingParams
} from "../../src/interfaces/ILayerZeroEndpointV2.sol";

/// @title MockLayerZeroEndpoint
/// @notice Mock LayerZero Endpoint V2 for testing LzCrossChainSender/Receiver.
contract MockLayerZeroEndpoint is ILayerZeroEndpointV2 {
    struct SendCall {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
        address refundAddress;
        uint256 valueSent;
    }

    SendCall[] public sendCalls;
    uint64 public nonceCounter;
    uint256 public quotedNativeFee;
    bool public shouldRevert;

    function setQuotedNativeFee(uint256 _fee) external {
        quotedNativeFee = _fee;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        override
        returns (MessagingReceipt memory receipt)
    {
        if (shouldRevert) revert("MockLzEndpoint: reverted");

        nonceCounter++;
        bytes32 guid = keccak256(abi.encode(nonceCounter, _params.dstEid, _params.receiver, _params.message));

        sendCalls.push(
            SendCall({
                dstEid: _params.dstEid,
                receiver: _params.receiver,
                message: _params.message,
                options: _params.options,
                payInLzToken: _params.payInLzToken,
                refundAddress: _refundAddress,
                valueSent: msg.value
            })
        );

        receipt = MessagingReceipt({
            guid: guid, nonce: nonceCounter, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    function quote(MessagingParams calldata, address) external view override returns (MessagingFee memory fee) {
        fee = MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    function sendCallCount() external view returns (uint256) {
        return sendCalls.length;
    }

    function getSendCallMessage(uint256 index) external view returns (bytes memory) {
        return sendCalls[index].message;
    }

    function getSendCallOptions(uint256 index) external view returns (bytes memory) {
        return sendCalls[index].options;
    }
}
