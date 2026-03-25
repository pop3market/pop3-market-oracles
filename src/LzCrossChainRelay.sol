// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

import {
    ILayerZeroEndpointV2,
    ILayerZeroReceiver,
    MessagingFee,
    MessagingReceipt,
    MessagingParams,
    Origin
} from "./interfaces/ILayerZeroEndpointV2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//  LzCrossChainSender — Deployed on Polygon
// ═══════════════════════════════════════════════════════════════════════════════

/// @title  LzCrossChainSender
/// @notice Deployed on **Polygon**. Sends oracle answers cross-chain to Unichain via LayerZero V2.
///         Called by UmaOracleAdapter after question settlement.
///
/// @dev Architecture:
///
///      UmaOracleAdapter.settleQuestion() ──▶ LzCrossChainSender.sendAnswer() ═══LZ═══▶ LzCrossChainReceiver
///                                                                                      on Unichain
///
///      The sender encodes (questionId, requestId, outcome) as bytes and sends via
///      LayerZero to the trusted receiver on Unichain. The caller pays the LayerZero
///      fee in native MATIC (msg.value).
///
///      Only whitelisted adapters can call sendAnswer() to prevent unauthorized messages.
///
/// @author Pop3 Market
contract LzCrossChainSender {
    // ═══════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════

    /// @dev Caller is not the contract owner.
    error NotOwner();
    /// @dev Caller is not the pending proposed owner.
    error NotProposedOwner();
    /// @dev Caller is not an authorized adapter contract.
    error NotAdapter();
    /// @dev A required address parameter is the zero address.
    error ZeroAddress();
    /// @dev The address is already an authorized adapter.
    error AlreadyAdapter();
    /// @dev The address is not currently an authorized adapter.
    error NotAuthorizedAdapter();
    /// @dev The trusted receiver (peer) has not been configured yet.
    error PeerNotSet();
    /// @dev The provided options bytes are empty.
    error EmptyOptions();

    // ═══════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when an answer is sent cross-chain via LayerZero.
    event AnswerSent(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint32 dstEid,
        bytes32 guid,
        address indexed adapter,
        uint256 feePaid,
        address refundAddress
    );

    /// @notice Emitted when an adapter is added or removed.
    event AdapterUpdated(address indexed caller, address indexed adapter, bool authorized);

    /// @notice Emitted when the peer (receiver) is updated.
    event PeerSet(address indexed caller, uint32 indexed dstEid, bytes32 oldPeer, bytes32 newPeer);

    /// @notice Emitted when default LayerZero options are updated.
    event OptionsUpdated(address indexed caller, bytes oldOptions, bytes newOptions);

    /// @notice Emitted when a new owner is proposed.
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════

    /// @notice LayerZero Endpoint V2 on Polygon.
    ILayerZeroEndpointV2 public immutable ENDPOINT;

    /// @notice Contract owner.
    address public owner;

    /// @notice Proposed new owner (two-step transfer).
    address public proposedOwner;

    /// @notice Destination endpoint ID (Unichain). Immutable — deploy a new sender to target a different chain.
    uint32 public immutable dstEid;

    /// @notice Trusted receiver on Unichain (LzCrossChainReceiver address as bytes32).
    bytes32 public peer;

    /// @notice Default execution options for LayerZero (gas limit for destination execution).
    /// @dev Encoded as LayerZero executor options. Set via setOptions().
    bytes public defaultOptions;

    /// @notice Authorized adapter contracts that can call sendAnswer().
    mapping(address => bool) public isAdapter;

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _endpoint LayerZero Endpoint V2 address on Polygon.
    /// @param _dstEid LayerZero endpoint ID for Unichain.
    /// @param _owner Contract owner.
    /// @param _defaultOptions Default LayerZero executor options (gas for destination).
    constructor(address _endpoint, uint32 _dstEid, address _owner, bytes memory _defaultOptions) {
        if (_endpoint == address(0) || _owner == address(0)) revert ZeroAddress();
        if (_defaultOptions.length == 0) revert EmptyOptions();
        ENDPOINT = ILayerZeroEndpointV2(_endpoint);
        dstEid = _dstEid;
        owner = _owner;
        defaultOptions = _defaultOptions;

        emit PeerSet(_owner, _dstEid, bytes32(0), bytes32(0));
        emit OptionsUpdated(_owner, bytes(""), _defaultOptions);
        emit OwnershipTransferred(address(0), _owner);
    }

    // ═══════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAdapter() {
        if (!isAdapter[msg.sender]) revert NotAdapter();
        _;
    }

    // ═══════════════════════════════════════════════════════
    // SEND
    // ═══════════════════════════════════════════════════════

    /// @notice Send an oracle answer cross-chain to Unichain via LayerZero.
    /// @dev Called by UmaOracleAdapter after settlement.
    ///      The caller must send enough native gas token (e.g., MATIC) as msg.value
    ///      to cover the LayerZero messaging fee. Use quoteFee() to estimate.
    ///
    ///      Payload encoding: abi.encode(questionId, requestId, outcome)
    ///      - questionId: Diamond's internal question ID
    ///      - requestId: external oracle ID (bytes32(0) for direct outcome path)
    ///      - outcome: true = YES wins, false = NO wins
    ///
    ///      The receiver (LzCrossChainReceiver) decodes this and forwards to BridgeReceiver.
    /// @param questionId The Diamond's internal question ID.
    /// @param requestId The external oracle request ID (e.g., UMA assertionId). Use bytes32(0) for direct outcome.
    /// @param outcome true = YES wins, false = NO wins.
    /// @param refundAddress Address to refund excess LayerZero fees.
    function sendAnswer(bytes32 questionId, bytes32 requestId, bool outcome, address refundAddress)
        external
        payable
        onlyAdapter
    {
        if (peer == bytes32(0)) revert PeerNotSet();

        bytes memory payload = abi.encode(questionId, requestId, outcome);

        MessagingParams memory params = MessagingParams({
            dstEid: dstEid, receiver: peer, message: payload, options: defaultOptions, payInLzToken: false
        });

        MessagingReceipt memory receipt = ENDPOINT.send{value: msg.value}(params, refundAddress);

        emit AnswerSent(
            questionId, requestId, outcome, dstEid, receipt.guid, msg.sender, receipt.fee.nativeFee, refundAddress
        );
    }

    /// @notice Quote the LayerZero fee for sending an answer.
    /// @dev Builds the same payload as sendAnswer() for accurate fee estimation.
    ///      The fee depends on payload size and destination gas settings (defaultOptions).
    ///      Returns the fee struct — use .nativeFee for the required msg.value.
    /// @param questionId The question ID (used to build the payload for accurate quoting).
    /// @param requestId The request ID.
    /// @param outcome The outcome.
    /// @return fee The estimated fee in native MATIC.
    function quoteFee(bytes32 questionId, bytes32 requestId, bool outcome)
        external
        view
        returns (MessagingFee memory fee)
    {
        if (peer == bytes32(0)) revert PeerNotSet();
        bytes memory payload = abi.encode(questionId, requestId, outcome);

        MessagingParams memory params = MessagingParams({
            dstEid: dstEid, receiver: peer, message: payload, options: defaultOptions, payInLzToken: false
        });

        fee = ENDPOINT.quote(params, address(this));
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    /// @notice Set the trusted receiver on Unichain. Pass bytes32(0) to disable.
    /// @param _peer Receiver contract address as bytes32. Use bytes32(0) to disable sending.
    function setPeer(bytes32 _peer) external onlyOwner {
        bytes32 oldPeer = peer;
        peer = _peer;
        emit PeerSet(msg.sender, dstEid, oldPeer, _peer);
    }

    /// @notice Update default LayerZero execution options.
    /// @param _options New options bytes (encoded gas limit for destination execution).
    function setOptions(bytes memory _options) external onlyOwner {
        if (_options.length == 0) revert EmptyOptions();
        bytes memory old = defaultOptions;
        defaultOptions = _options;
        emit OptionsUpdated(msg.sender, old, _options);
    }

    /// @notice Authorize an adapter contract to send answers.
    /// @param adapter The adapter address (e.g., UmaOracleAdapter).
    function addAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        if (isAdapter[adapter]) revert AlreadyAdapter();
        isAdapter[adapter] = true;
        emit AdapterUpdated(msg.sender, adapter, true);
    }

    /// @notice Revoke an adapter's authorization.
    /// @param adapter The adapter address to revoke.
    function removeAdapter(address adapter) external onlyOwner {
        if (!isAdapter[adapter]) revert NotAuthorizedAdapter();
        isAdapter[adapter] = false;
        emit AdapterUpdated(msg.sender, adapter, false);
    }

    /// @notice Propose a new owner (two-step transfer).
    /// @param newOwner The proposed new owner address.
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        proposedOwner = newOwner;
        emit OwnershipProposed(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by the proposed owner).
    function acceptOwnership() external {
        if (msg.sender != proposedOwner) revert NotProposedOwner();
        address previousOwner = owner;
        owner = proposedOwner;
        proposedOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  LzCrossChainReceiver — Deployed on Unichain
// ═══════════════════════════════════════════════════════════════════════════════

/// @title  LzCrossChainReceiver
/// @notice Deployed on **Unichain**. Receives oracle answers from Polygon via LayerZero V2
///         and forwards them to the Diamond proxy through the BridgeReceiver.
///
/// @dev Security model:
///      - Only accepts messages from the LayerZero Endpoint (msg.sender check)
///      - Only accepts messages from the trusted peer (sender check)
///      - The receiver is added as a relayer on BridgeReceiver
///      - BridgeReceiver handles double-relay prevention and Diamond interaction
///
/// @notice Minimal interface for calling BridgeReceiver's relay functions.
interface ILzBridgeReceiver {
    function relayOracleAnswer(bytes32 questionId, bytes32 requestId, bool outcome) external;
    function relayOutcome(bytes32 questionId, bool outcome) external;
}

/// @author Pop3 Market
contract LzCrossChainReceiver is ILayerZeroReceiver, ReentrancyGuard {
    // ═══════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════

    /// @dev Caller is not the contract owner.
    error NotOwner();
    /// @dev Caller is not the pending proposed owner.
    error NotProposedOwner();
    /// @dev Caller is not the LayerZero Endpoint contract.
    error NotEndpoint();
    /// @dev Message sender is not the trusted peer for the source chain.
    error NotTrustedPeer();
    /// @dev A required address parameter is the zero address.
    error ZeroAddress();
    /// @dev ETH was sent with the call but this function does not accept value.
    error UnexpectedETH();
    /// @dev No failed relay exists at the given index (or array is empty).
    error NoFailedRelay();

    // ═══════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════

    /// @notice Stored data for a relay that failed to forward to BridgeReceiver.
    /// @dev When lzReceive() cannot forward to BridgeReceiver (e.g., BridgeReceiver
    ///      reverts due to paused state or already-relayed question), the message is
    ///      stored here instead of blocking the LayerZero nonce channel. Stored relays
    ///      are automatically retried on the next lzReceive() call (self-healing),
    ///      manually retried via retryFailedRelay(), or discarded via removeFailedRelay().
    struct FailedRelay {
        bytes32 questionId;
        bytes32 requestId;
        bool outcome;
    }

    // ═══════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when an answer is received from Polygon and forwarded to BridgeReceiver.
    event AnswerReceived(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint32 indexed srcEid,
        bytes32 sender,
        bytes32 guid,
        bool relayed
    );

    /// @notice Emitted when forwarding to BridgeReceiver fails. Message is stored for retry.
    event RelayFailed(bytes32 indexed questionId, bytes32 indexed requestId, bool outcome, uint256 index, bytes reason);

    /// @notice Emitted when a previously failed relay is successfully retried.
    /// @param newLength Array length after removal (if index < newLength, a swap-and-pop occurred).
    /// @param manual True if triggered via retryFailedRelay(), false if self-healed in lzReceive().
    event RelayRecovered(
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint256 index,
        uint256 newLength,
        bool manual
    );

    /// @notice Emitted when a stored failed relay is removed by the owner without retrying.
    /// @param newLength Array length after removal (if index < newLength, a swap-and-pop occurred).
    event FailedRelayRemoved(
        address indexed caller,
        bytes32 indexed questionId,
        bytes32 indexed requestId,
        bool outcome,
        uint256 index,
        uint256 newLength
    );

    /// @notice Emitted when the peer (sender) is updated.
    event PeerSet(address indexed caller, uint32 indexed srcEid, bytes32 oldPeer, bytes32 newPeer);

    /// @notice Emitted when a new owner is proposed.
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════

    /// @notice LayerZero Endpoint V2 on Unichain.
    ILayerZeroEndpointV2 public immutable ENDPOINT;

    /// @notice BridgeReceiver contract on Unichain.
    ILzBridgeReceiver public immutable BRIDGE_RECEIVER;

    /// @notice Contract owner.
    address public owner;

    /// @notice Proposed new owner (two-step transfer).
    address public proposedOwner;

    /// @notice Trusted peers per source chain (srcEid → sender address as bytes32).
    mapping(uint32 => bytes32) public peers;

    /// @notice Stored failed relays awaiting retry. Drained automatically by lzReceive.
    FailedRelay[] internal _failedRelays;

    /// @dev Cycling index for self-heal retries. Incremented each lzReceive to ensure
    ///      every failed relay gets a turn — prevents a single stuck entry from blocking others.
    uint256 internal _nextRetryIndex;

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _endpoint LayerZero Endpoint V2 address on Unichain.
    /// @param _bridgeReceiver BridgeReceiver contract address on Unichain.
    /// @param _owner Contract owner.
    constructor(address _endpoint, address _bridgeReceiver, address _owner) {
        if (_endpoint == address(0) || _bridgeReceiver == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        ENDPOINT = ILayerZeroEndpointV2(_endpoint);
        BRIDGE_RECEIVER = ILzBridgeReceiver(_bridgeReceiver);
        owner = _owner;

        emit PeerSet(_owner, 0, bytes32(0), bytes32(0));
        emit OwnershipTransferred(address(0), _owner);
    }

    // ═══════════════════════════════════════════════════════
    // LAYERZERO RECEIVE
    // ═══════════════════════════════════════════════════════

    /// @notice Called by the LayerZero Endpoint when a message arrives from Polygon.
    /// @dev Validates the sender is the trusted peer, then decodes the payload and
    ///      forwards to BridgeReceiver. If forwarding fails, the message is stored
    ///      in _failedRelays for automatic retry on the next lzReceive call.
    ///      Uses try/catch to prevent blocking the LayerZero nonce channel.
    function lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        external
        payable
        override
        nonReentrant
    {
        // Reject any ETH sent — prevents locked ether (interface requires payable but LZ sends 0)
        if (msg.value > 0) revert UnexpectedETH();

        // Only the LayerZero Endpoint can call this
        if (msg.sender != address(ENDPOINT)) revert NotEndpoint();

        // Verify the sender is our trusted peer on the source chain
        if (peers[_origin.srcEid] == bytes32(0) || peers[_origin.srcEid] != _origin.sender) {
            revert NotTrustedPeer();
        }

        // Decode and process the current message FIRST — prioritize new messages
        // over self-heal retries to prevent cascading failures when gas is tight.
        (bytes32 questionId, bytes32 requestId, bool outcome) = abi.decode(_message, (bytes32, bytes32, bool));

        // Cache pre-existing failed relay count BEFORE processing current message.
        // This ensures the self-heal block below retries a previously failed relay,
        // not the one we might push in the next block (which would be a guaranteed
        // wasted retry since it just failed under the same state).
        uint256 lenBefore = _failedRelays.length;

        (bool success, bytes memory reason) = _tryRelay(questionId, requestId, outcome);
        if (!success) {
            _failedRelays.push(FailedRelay({questionId: questionId, requestId: requestId, outcome: outcome}));
            emit RelayFailed(questionId, requestId, outcome, _failedRelays.length - 1, reason);
        }

        emit AnswerReceived(questionId, requestId, outcome, _origin.srcEid, _origin.sender, _guid, success);

        // ── Self-heal: retry ONE pre-existing failure after processing new message ──
        // Piggybacks on incoming LZ messages to drain the failed queue
        // without requiring separate keeper transactions. Runs AFTER the current
        // message to ensure the new message always gets priority for gas budget.
        // Uses a cycling index to rotate through all entries fairly — prevents
        // a single stuck entry from blocking retries of recoverable ones.
        // Uses lenBefore to avoid retrying the just-failed current message.
        if (lenBefore > 0) {
            uint256 idx = _nextRetryIndex % lenBefore;
            FailedRelay memory f = _failedRelays[idx];
            (bool recovered,) = _tryRelay(f.questionId, f.requestId, f.outcome);
            if (recovered) {
                // Swap with last element and pop for O(1) removal
                _failedRelays[idx] = _failedRelays[_failedRelays.length - 1];
                _failedRelays.pop();
                emit RelayRecovered(f.questionId, f.requestId, f.outcome, idx, _failedRelays.length, false);
            }
            unchecked {
                _nextRetryIndex = idx + 1;
            }
        }
    }

    /// @dev Attempts to forward a decoded message to BridgeReceiver. Uses try/catch
    ///      to absorb reverts (e.g., QuestionAlreadyRelayed, BridgeReceiver paused).
    ///      Choosing relayOracleAnswer vs relayOutcome based on whether requestId is set:
    ///        - requestId != 0 → full path (registerOracleRequest + reportPayouts)
    ///        - requestId == 0 → direct path (reportOutcome only)
    /// @return success True if BridgeReceiver accepted the relay without reverting.
    function _tryRelay(bytes32 questionId, bytes32 requestId, bool outcome) internal returns (bool, bytes memory) {
        if (requestId != bytes32(0)) {
            try BRIDGE_RECEIVER.relayOracleAnswer(questionId, requestId, outcome) {
                return (true, "");
            } catch (bytes memory reason) {
                return (false, reason);
            }
        } else {
            try BRIDGE_RECEIVER.relayOutcome(questionId, outcome) {
                return (true, "");
            } catch (bytes memory reason) {
                return (false, reason);
            }
        }
    }

    /// @notice Called by LayerZero Endpoint to check if a message path should be initialized.
    /// @dev Returns true only for trusted peers. Required by LZ V2 for nonce channel setup.
    /// @param _origin Source chain info (srcEid, sender).
    /// @return True if the sender is a trusted peer on the source chain.
    function allowInitializePath(Origin calldata _origin) external view override returns (bool) {
        return peers[_origin.srcEid] != bytes32(0) && peers[_origin.srcEid] == _origin.sender;
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Set the trusted sender on a source chain. Pass bytes32(0) to disable.
    /// @param _srcEid Source endpoint ID (e.g., Polygon's LayerZero eid).
    /// @param _peer Sender contract address as bytes32. Use bytes32(0) to disable reception from this chain.
    function setPeer(uint32 _srcEid, bytes32 _peer) external onlyOwner {
        bytes32 oldPeer = peers[_srcEid];
        peers[_srcEid] = _peer;
        emit PeerSet(msg.sender, _srcEid, oldPeer, _peer);
    }

    // ═══════════════════════════════════════════════════════
    // FAILED RELAY MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Manually retry a failed relay by index. Owner only.
    /// @dev Uses swap-and-pop for O(1) removal. If BridgeReceiver reverts, the entire
    ///      tx reverts and the swap+pop is rolled back — the array remains unchanged.
    ///      This is intentional: if the relay still fails, the entry stays in the array
    ///      for future retry. Use removeFailedRelay() to discard permanently stuck entries.
    /// @param index The index in the _failedRelays array to retry.
    function retryFailedRelay(uint256 index) external nonReentrant onlyOwner {
        uint256 len = _failedRelays.length;
        if (index >= len) revert NoFailedRelay();
        FailedRelay memory f = _failedRelays[index];

        // Swap with last and pop (reverted if relay fails below)
        _failedRelays[index] = _failedRelays[len - 1];
        _failedRelays.pop();

        // Direct call — no try/catch. Revert rolls back the swap+pop.
        if (f.requestId != bytes32(0)) {
            BRIDGE_RECEIVER.relayOracleAnswer(f.questionId, f.requestId, f.outcome);
        } else {
            BRIDGE_RECEIVER.relayOutcome(f.questionId, f.outcome);
        }

        emit RelayRecovered(f.questionId, f.requestId, f.outcome, index, _failedRelays.length, true);
    }

    /// @notice Remove a single failed relay by index without retrying. Owner only.
    /// @dev Swap-and-pop for O(1) removal. Use for entries that are permanently stuck
    ///      (e.g., already relayed via another path) and should not be retried.
    /// @param index The index in the _failedRelays array to remove.
    function removeFailedRelay(uint256 index) external onlyOwner {
        uint256 len = _failedRelays.length;
        if (index >= len) revert NoFailedRelay();
        FailedRelay memory f = _failedRelays[index];
        _failedRelays[index] = _failedRelays[len - 1];
        _failedRelays.pop();
        emit FailedRelayRemoved(msg.sender, f.questionId, f.requestId, f.outcome, index, _failedRelays.length);
    }

    /// @notice Number of stored failed relays.
    function failedRelayCount() external view returns (uint256) {
        return _failedRelays.length;
    }

    /// @notice Get a stored failed relay by index.
    function getFailedRelay(uint256 index) external view returns (bytes32 questionId, bytes32 requestId, bool outcome) {
        if (index >= _failedRelays.length) revert NoFailedRelay();
        FailedRelay memory f = _failedRelays[index];
        return (f.questionId, f.requestId, f.outcome);
    }

    /// @notice Propose a new owner (two-step transfer).
    /// @param newOwner The proposed new owner address.
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        proposedOwner = newOwner;
        emit OwnershipProposed(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by the proposed owner).
    function acceptOwnership() external {
        if (msg.sender != proposedOwner) revert NotProposedOwner();
        address previousOwner = owner;
        owner = proposedOwner;
        proposedOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }
}
