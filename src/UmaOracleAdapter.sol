// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Pop3 Market (pop3market.com). All rights reserved.
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3Callback} from "./interfaces/IOptimisticOracleV3.sol";
import {LzCrossChainSender} from "./LzCrossChainRelay.sol";

/// @title  UmaOracleAdapter
/// @notice Deployed on **Polygon**. Bridges prediction market questions to UMA's Optimistic
///         Oracle V3 for decentralized resolution, then emits an event for cross-chain relay
///         to the Diamond on Unichain.
///
/// @dev Architecture:
///
///      1. Operator calls `initializeQuestion()` → submits assertion to UMA OOv3
///      2. UMA challenge window passes (e.g., 2 hours)
///      3. Operator (or anyone after delay) calls `settleQuestion()` (or UMA auto-settles)
///      4. UMA calls `assertionResolvedCallback()` on this contract
///      5. This contract emits `QuestionResolved` event
///      6. Off-chain relayer (or LayerZero/CCIP) picks up the event and delivers
///         the answer to the BridgeReceiver on Unichain
///
///      The adapter does NOT directly call the Diamond. Cross-chain delivery supports
///      two modes:
///        a) Off-chain relayer — backend watches `QuestionResolved` events, sends tx on Unichain
///        b) LayerZero relay — call `relayResolved()` after settlement to send via LzCrossChainSender
///
///      Both modes use the same settlement flow. The owner configures the relay via
///      `setCrossChainRelay()` (set to `address(0)` to use event-only mode).
///
/// @author Pop3 Market
contract UmaOracleAdapter is IOptimisticOracleV3Callback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════

    /// @dev Caller is not the contract owner.
    error NotOwner();
    /// @dev Caller is not the pending proposed owner.
    error NotProposedOwner();
    /// @dev Caller is not an authorized operator.
    error NotOperator();
    /// @dev A required address parameter is the zero address.
    error ZeroAddress();
    /// @dev Caller is not the UMA Optimistic Oracle V3 contract (callback validation).
    error NotOOv3();
    /// @dev A question with this ID has already been submitted to UMA.
    error QuestionAlreadyInitialized();
    /// @dev No question has been submitted for this questionId.
    error QuestionNotInitialized();
    /// @dev The question has already been settled via UMA callback.
    error QuestionAlreadyResolved();
    /// @dev The bond amount is below UMA's minimum for the bond currency.
    error BondBelowMinimum();
    /// @dev The liveness (challenge window) is below the minimum allowed value.
    error LivenessTooShort();
    /// @dev The address is already an authorized operator.
    error AlreadyOperator();
    /// @dev The address is not currently an authorized operator.
    error NotAuthorizedOperator();
    /// @dev The question has not been settled yet via UMA callback.
    error QuestionNotResolved();
    /// @dev Cross-chain relay is not set.
    error RelayNotConfigured();
    /// @dev No native fee provided for the cross-chain relay.
    error InsufficientRelayFee();
    /// @dev This question has already been relayed cross-chain.
    error QuestionAlreadyRelayed();
    /// @dev The provided questionId is bytes32(0), which is invalid.
    error InvalidQuestionId();
    /// @dev The provided claim data is empty.
    error EmptyClaimData();
    /// @dev The provided groupId is bytes32(0), which is invalid.
    error ZeroGroupId();
    /// @dev The operator delay exceeds the actual liveness for this question.
    error DelayTooLong();
    /// @dev The operator review window is still active. Only operator/owner/resolver can settle during this period.
    error OperatorWindowActive();
    /// @dev Caller is not authorized to act on this question. Must be owner, operator, or a
    ///      member of the resolver group assigned to this questionId (see `questionGroup`).
    error NotQuestionAuthorized();
    /// @dev Index exceeds cancelledAssertions array length.
    error IndexOutOfBounds();
    /// @dev Cannot cancel a question while its UMA assertion is under active dispute.
    error CannotCancelDisputedQuestion();
    /// @dev Cannot cancel after UMA liveness expired — call settleQuestion() instead.
    error CannotCancelExpiredAssertion();

    // ═══════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when a question is submitted to UMA for resolution.
    event QuestionInitialized(
        bytes32 indexed questionId,
        bytes32 indexed assertionId,
        address indexed asserter,
        bytes claim,
        uint256 bond,
        uint64 liveness,
        uint64 operatorDelay
    );

    /// @notice Emitted when UMA resolves an assertion. This is the event the relayer watches.
    /// @dev The relayer reads this event and calls BridgeReceiver.relayOracleAnswer() on Unichain.
    event QuestionResolved(
        bytes32 indexed questionId, bytes32 indexed assertionId, bool outcome, address indexed resolver
    );

    /// @notice Emitted when an assertion is disputed before liveness expires.
    event QuestionDisputed(bytes32 indexed questionId, bytes32 indexed assertionId);

    /// @notice Emitted when the owner updates the default bond amount.
    event DefaultBondUpdated(uint256 oldBond, uint256 newBond, address indexed caller);

    /// @notice Emitted when the owner updates the default liveness.
    event DefaultLivenessUpdated(uint64 oldLiveness, uint64 newLiveness, address indexed caller);

    /// @notice Emitted when an operator is added or removed.
    event OperatorUpdated(address indexed operator, bool authorized, address indexed caller);

    /// @notice Emitted when the minimum liveness is updated.
    event MinLivenessUpdated(uint64 oldMinLiveness, uint64 newMinLiveness, address indexed caller);

    /// @notice Emitted when a question is cancelled by the owner or creator.
    event QuestionCancelled(
        bytes32 indexed questionId, bytes32 indexed assertionId, address indexed canceller, address creator
    );

    /// @notice Emitted when UMA settles an assertion whose question was already cancelled.
    /// @dev Allows off-chain systems to track bond recovery for cancelled assertions.
    event CancelledAssertionSettled(bytes32 indexed assertionId, bytes32 indexed questionId, bool assertedTruthfully);

    /// @notice Emitted when UMA disputes an assertion whose question was already cancelled.
    event CancelledAssertionDisputed(bytes32 indexed assertionId, bytes32 indexed questionId);

    /// @notice Emitted when a duplicate UMA callback is ignored (question already resolved).
    event DuplicateCallbackIgnored(bytes32 indexed assertionId, bytes32 indexed questionId);

    /// @notice Emitted when a cancelled assertion's bond is reclaimed via `reclaimBond()`.
    /// @param settledByUs True if OOV3.settleAssertion() succeeded (we triggered settlement), false if already settled externally.
    event BondReclaimed(
        bytes32 indexed assertionId, bytes32 indexed questionId, address indexed caller, bool settledByUs
    );

    /// @notice Emitted when the cross-chain relay is updated.
    event CrossChainRelayUpdated(address indexed previousRelay, address indexed newRelay, address indexed caller);

    /// @notice Emitted when a member is added/removed from a resolver group.
    event ResolverGroupUpdated(
        bytes32 indexed groupId, address indexed member, bool authorized, address indexed caller
    );

    /// @notice Emitted when a resolver group is assigned to a question.
    event QuestionGroupAssigned(
        bytes32 indexed questionId, bytes32 indexed groupId, address indexed caller, bytes32 previousGroupId
    );

    /// @notice Emitted when settleQuestion() is called, capturing the settler's address.
    /// @dev The assertionResolvedCallback's msg.sender is always OOV3, so we emit here to record who triggered settlement.
    event QuestionSettled(bytes32 indexed questionId, bytes32 indexed assertionId, address indexed settler);

    /// @notice Emitted when a resolved question is relayed cross-chain.
    event QuestionRelayed(
        bytes32 indexed questionId, bytes32 indexed assertionId, bool outcome, address indexed relayer
    );

    /// @notice Emitted when a new owner is proposed.
    event OwnershipProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════

    /// @notice Tracks the lifecycle of a question submitted to UMA's Optimistic Oracle V3.
    /// @dev The creator field doubles as an initialization guard: address(0) means
    ///      the question has not been initialized. This is checked before external calls
    ///      to prevent re-entry from re-initializing the same question.
    struct QuestionData {
        bytes32 assertionId; /// @dev UMA assertion ID returned by assertTruth(). bytes32(0) if not yet submitted.
        bool resolved; /// @dev True after assertionResolvedCallback() fires. Prevents double-settlement.
        bool outcome; /// @dev true = YES wins (assertion correct), false = NO wins (assertion wrong). Only valid when resolved == true.
        address creator; /// @dev Address that called initializeQuestion() and posted the bond. Used as init guard and cancel authorization.
        uint64 operatorDelay; /// @dev Seconds after liveness expiry during which only operator/owner can settle. 0 = permissionless immediately.
    }

    // ═══════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════

    /// @notice UMA Optimistic Oracle V3 contract on Polygon.
    IOptimisticOracleV3 public immutable OOV3;

    /// @notice ERC20 token used for bonds (e.g., USDC on Polygon).
    IERC20 public immutable BOND_CURRENCY;

    /// @notice Contract owner — manages operators, defaults, and min liveness.
    address public owner;

    /// @notice Proposed new owner (two-step transfer).
    address public proposedOwner;

    /// @notice Default bond amount in `bondCurrency` units (e.g., 250e6 = 250 USDC).
    uint256 public defaultBond;

    /// @notice Default challenge window in seconds (e.g., 7200 = 2 hours).
    uint64 public defaultLiveness;

    /// @notice DVM identifier used for UMA dispute resolution.
    /// @dev "ASSERT_TRUTH" was retired Dec 2025 (UMIP-192). "ASSERT_TRUTH2" is the
    ///      current standard identifier for yes/no assertions on UMA's DVM. If UMA
    ///      introduces a new identifier in the future, deploy a new adapter version.
    bytes32 public constant DEFAULT_IDENTIFIER = "ASSERT_TRUTH2";

    /// @notice Minimum challenge window in seconds. Prevents dangerously short liveness.
    uint64 public minLiveness;

    /// @notice LayerZero cross-chain sender (optional — address(0) disables auto-relay).
    LzCrossChainSender public crossChainRelay;

    /// @notice Tracks which questions have been relayed cross-chain (prevents duplicate LZ messages).
    mapping(bytes32 => bool) public relayed;

    /// @notice Authorized operators — only these addresses can call initializeQuestion.
    mapping(address => bool) public isOperator;

    /// @notice Question ID → question data.
    mapping(bytes32 => QuestionData) public questions;

    /// @notice UMA assertion ID → question ID (reverse lookup for callbacks).
    mapping(bytes32 => bytes32) public assertionToQuestion;

    /// @notice Named resolver groups — reusable sets of trusted addresses (e.g., a resolution team).
    /// @dev Groups are managed by owner/operators via `setResolverGroup()`. Multiple questions can
    ///      share the same group, and adding/removing members applies to all linked questions instantly.
    mapping(bytes32 => mapping(address => bool)) public resolverGroups;

    /// @notice Question → resolver group assignment.
    /// @dev Set via `assignQuestionGroup()`. Members of the assigned group can initialize,
    ///      settle (during operator delay), and cancel the question. bytes32(0) = no group assigned.
    ///      Resolvers are trusted parties (e.g., the market creator on Unichain who created the market
    ///      that this questionId belongs to). Cancel-then-recreate is allowed by design since resolvers
    ///      own their markets and the event trail provides full auditability.
    mapping(bytes32 => bytes32) public questionGroup;

    /// @notice Assertion IDs from cancelled questions awaiting bond reclaim via `reclaimBond()`.
    /// @dev Populated by `cancelQuestion()`, drained by `reclaimBond()`. Uses swap-and-pop for O(1) removal.
    bytes32[] public cancelledAssertions;

    /// @notice Cancelled assertion ID → original question ID (for callback event enrichment).
    /// @dev Populated by `cancelQuestion()`, cleaned up by `reclaimBond()`.
    mapping(bytes32 => bytes32) public cancelledAssertionQuestion;

    // ═══════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _oov3 UMA Optimistic Oracle V3 address on Polygon.
    /// @param _bondCurrency ERC20 token for bonds (e.g., USDC).
    /// @param _defaultBond Default bond amount (e.g., 250e6 for 250 USDC).
    /// @param _defaultLiveness Default challenge window in seconds (e.g., 7200 = 2 hours).
    /// @param _minLiveness Minimum allowed liveness in seconds (e.g., 1800 = 30 minutes).
    /// @param _owner Contract owner for admin functions.
    /// @param _operator Initial authorized operator (e.g., market creator or backend).
    constructor(
        address _oov3,
        address _bondCurrency,
        uint256 _defaultBond,
        uint64 _defaultLiveness,
        uint64 _minLiveness,
        address _owner,
        address _operator
    ) {
        if (_oov3 == address(0) || _bondCurrency == address(0) || _owner == address(0) || _operator == address(0)) {
            revert ZeroAddress();
        }
        if (_defaultLiveness < _minLiveness) revert LivenessTooShort();
        if (_defaultBond == 0) revert BondBelowMinimum();
        OOV3 = IOptimisticOracleV3(_oov3);
        BOND_CURRENCY = IERC20(_bondCurrency);
        defaultBond = _defaultBond;
        defaultLiveness = _defaultLiveness;
        minLiveness = _minLiveness;
        owner = _owner;
        isOperator[_operator] = true;

        emit DefaultBondUpdated(0, _defaultBond, _owner);
        emit DefaultLivenessUpdated(0, _defaultLiveness, _owner);
        emit MinLivenessUpdated(0, _minLiveness, _owner);
        emit OwnershipTransferred(address(0), _owner);
        emit OperatorUpdated(_operator, true, _owner);
    }

    // ═══════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ═══════════════════════════════════════════════════════
    // QUESTION LIFECYCLE
    // ═══════════════════════════════════════════════════════

    /// @notice Submit a question to UMA for resolution.
    /// @dev The caller must have approved `bondCurrency` for at least `bond` amount.
    ///      The claim should be a human-readable UTF-8 string that UMA voters can evaluate.
    ///
    ///      Example claim format (Polymarket standard):
    ///        "q: title: Will BTC hit $100k before April 2026?
    ///         description: Resolves YES if Bitcoin reaches $100,000 USD on any major
    ///         exchange (Binance, Coinbase, Kraken) before April 1, 2026 00:00 UTC.
    ///         res_data: p1: 0, p2: 1, p3: 0.5.
    ///         Where p1 corresponds to YES, p2 to NO, p3 to unknown/ambiguous."
    ///
    /// @param questionId The question ID from the Diamond (from prepareQuestion).
    /// @param claim Human-readable assertion text for UMA voters.
    /// @param bond Bond amount. Use 0 to use defaultBond.
    /// @param liveness Challenge window in seconds. Use 0 to use defaultLiveness.
    /// @param operatorDelay Seconds after liveness expiry during which only operator/owner can settle. 0 = permissionless immediately. Max = actualLiveness.
    /// @return assertionId The UMA assertion ID.
    function initializeQuestion(
        bytes32 questionId,
        bytes memory claim,
        uint256 bond,
        uint64 liveness,
        uint64 operatorDelay
    ) external nonReentrant returns (bytes32 assertionId) {
        if (!isOperator[msg.sender] && msg.sender != owner && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        // Zero questionId would be indistinguishable from "not found" in assertionToQuestion
        // reverse lookup, causing assertionResolvedCallback to revert permanently.
        if (questionId == bytes32(0)) revert InvalidQuestionId();
        if (claim.length == 0) revert EmptyClaimData();

        // Validate — check creator to block re-entry (CEI: state before external call)
        if (questions[questionId].creator != address(0)) {
            revert QuestionAlreadyInitialized();
        }

        // Apply defaults
        uint256 actualBond = bond > 0 ? bond : defaultBond;
        uint64 actualLiveness = liveness > 0 ? liveness : defaultLiveness;

        // Check minimum bond
        uint256 minBond = OOV3.getMinimumBond(address(BOND_CURRENCY));
        if (actualBond < minBond) revert BondBelowMinimum();

        // Check minimum liveness
        if (actualLiveness < minLiveness) revert LivenessTooShort();

        // Check operator delay doesn't exceed liveness
        if (operatorDelay > actualLiveness) revert DelayTooLong();

        // Set creator before external calls to prevent re-initialization during re-entry
        questions[questionId].creator = msg.sender;
        questions[questionId].operatorDelay = operatorDelay;

        // Transfer bond from caller to this contract
        BOND_CURRENCY.safeTransferFrom(msg.sender, address(this), actualBond);

        // Approve UMA to pull the bond
        BOND_CURRENCY.safeIncreaseAllowance(address(OOV3), actualBond);

        // Submit assertion to UMA OOv3
        assertionId = OOV3.assertTruth(
            claim,
            msg.sender, // asserter — bond is returned to them if not disputed
            address(this), // callbackRecipient — this contract receives the result
            address(0), // escalationManager — use UMA DVM for disputes
            actualLiveness, // challenge window
            BOND_CURRENCY, // bond token
            actualBond, // bond amount
            DEFAULT_IDENTIFIER, // "ASSERT_TRUTH2"
            bytes32(0) // domainId — not used
        );

        // Store remaining question data (after external call — assertionId needed)
        questions[questionId].assertionId = assertionId;
        assertionToQuestion[assertionId] = questionId;

        emit QuestionInitialized(questionId, assertionId, msg.sender, claim, actualBond, actualLiveness, operatorDelay);
    }

    /// @notice Settle an assertion after the challenge window expires. Permissionless after operator delay.
    /// @dev Anyone can call this after the delay. During the delay window, only the owner,
    ///      operators, or authorized resolvers for this question can settle.
    ///      UMA calls assertionResolvedCallback which stores the result.
    ///      To relay cross-chain after settlement, call relayResolved() separately.
    /// @param questionId The question to settle.
    function settleQuestion(bytes32 questionId) external nonReentrant {
        QuestionData storage q = questions[questionId];
        if (q.assertionId == bytes32(0)) revert QuestionNotInitialized();
        if (q.resolved) revert QuestionAlreadyResolved();

        // Enforce operator review window — only owner, operators, or resolvers can settle during the delay
        if (q.operatorDelay > 0) {
            uint64 expiration = OOV3.getAssertion(q.assertionId).expirationTime;
            if (block.timestamp < uint256(expiration) + uint256(q.operatorDelay)) {
                if (msg.sender != owner && !isOperator[msg.sender] && !_isResolver(questionId, msg.sender)) {
                    revert OperatorWindowActive();
                }
            }
        }

        // This triggers assertionResolvedCallback which sets q.resolved and q.outcome
        bytes32 aId = q.assertionId;
        OOV3.settleAssertion(aId);

        emit QuestionSettled(questionId, aId, msg.sender);
    }

    /// @notice Relay an already-resolved question cross-chain. Permissionless.
    /// @dev Decoupled from settleQuestion() by design. This prevents a front-runner from
    ///      calling settleQuestion() with 0 msg.value to permanently block auto-relay.
    ///      Anyone can call this later with the required LZ fee to complete the relay.
    ///      The relay sends (questionId, assertionId, outcome) to LzCrossChainSender,
    ///      which forwards it to LzCrossChainReceiver → BridgeReceiver → Diamond on Unichain.
    /// @param questionId The question to relay.
    function relayResolved(bytes32 questionId) external payable nonReentrant {
        QuestionData storage q = questions[questionId];
        if (q.assertionId == bytes32(0)) revert QuestionNotInitialized();
        if (!q.resolved) revert QuestionNotResolved();
        if (relayed[questionId]) revert QuestionAlreadyRelayed();
        if (address(crossChainRelay) == address(0)) revert RelayNotConfigured();
        if (msg.value == 0) revert InsufficientRelayFee();
        relayed[questionId] = true;
        crossChainRelay.sendAnswer{value: msg.value}(questionId, q.assertionId, q.outcome, msg.sender);
        emit QuestionRelayed(questionId, q.assertionId, q.outcome, msg.sender);
    }

    /// @notice Quote the LayerZero fee for cross-chain relay. Returns 0 if relay not configured.
    /// @dev The fee depends on payload size and LZ destination gas settings. The outcome
    ///      value doesn't affect the fee (same payload size for true/false).
    ///      Returns 0 if crossChainRelay is not configured or question not initialized.
    /// @param questionId The question to quote for.
    /// @return fee The estimated fee in native MATIC.
    function quoteCrossChainFee(bytes32 questionId) external view returns (uint256) {
        if (address(crossChainRelay) == address(0)) return 0;
        QuestionData storage q = questions[questionId];
        if (q.assertionId == bytes32(0)) return 0;
        return crossChainRelay.quoteFee(questionId, q.assertionId, q.outcome).nativeFee;
    }

    // ═══════════════════════════════════════════════════════
    // UMA CALLBACKS
    // ═══════════════════════════════════════════════════════

    /// @notice Called by UMA OOv3 when an assertion is settled (liveness expired or DVM voted).
    /// @dev CRITICAL: Only callable by the OOv3 contract (msg.sender check).
    ///      The assertedTruthfully flag maps directly to the market outcome:
    ///        - true  → the claim was correct → YES wins
    ///        - false → the claim was disputed and lost → NO wins
    ///      This means the claim text MUST be written so that "true = YES outcome".
    ///      Example: "BTC will hit $100k" → assertedTruthfully=true → YES wins.
    ///
    ///      State change: sets q.resolved=true and q.outcome=assertedTruthfully.
    ///      Emits QuestionResolved for the off-chain relayer to pick up.
    /// @param assertionId The UMA assertion that was settled.
    /// @param assertedTruthfully True if the assertion was confirmed (no dispute, or won dispute).
    ///                           False if the assertion was disputed and the disputer won.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        if (msg.sender != address(OOV3)) revert NotOOv3();

        bytes32 questionId = assertionToQuestion[assertionId];
        if (questionId == bytes32(0)) {
            emit CancelledAssertionSettled(assertionId, cancelledAssertionQuestion[assertionId], assertedTruthfully);
            return; // Cancelled or unknown — let UMA settle gracefully
        }

        QuestionData storage q = questions[questionId];
        if (q.resolved) {
            emit DuplicateCallbackIgnored(assertionId, questionId);
            return;
        }
        q.resolved = true;
        q.outcome = assertedTruthfully; // true = assertion was correct (YES), false = wrong (NO)

        emit QuestionResolved(questionId, assertionId, assertedTruthfully, msg.sender);
    }

    /// @notice Called by UMA OOv3 when an assertion is disputed before liveness expires.
    /// @dev Informational only — no state change. The dispute is handled by UMA's DVM.
    ///      The assertion will eventually settle via assertionResolvedCallback() with the
    ///      DVM's verdict. This event allows off-chain systems to track dispute status.
    /// @param assertionId The UMA assertion that was disputed.
    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(OOV3)) revert NotOOv3();

        bytes32 questionId = assertionToQuestion[assertionId];
        if (questionId == bytes32(0)) {
            emit CancelledAssertionDisputed(assertionId, cancelledAssertionQuestion[assertionId]);
            return; // Cancelled or unknown — let UMA proceed gracefully
        }

        emit QuestionDisputed(questionId, assertionId);
    }

    // ═══════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════

    /// @notice Get the full question data for a given questionId.
    /// @param questionId The question to query.
    /// @return data The question data struct.
    function getQuestion(bytes32 questionId) external view returns (QuestionData memory data) {
        return questions[questionId];
    }

    /// @notice Check if a question has been resolved.
    /// @param questionId The question to check.
    /// @return True if the question has been resolved by UMA.
    function isResolved(bytes32 questionId) external view returns (bool) {
        return questions[questionId].resolved;
    }

    /// @notice Get the question ID for a given UMA assertion ID.
    /// @param assertionId The UMA assertion ID.
    /// @return The corresponding question ID.
    function getQuestionByAssertion(bytes32 assertionId) external view returns (bytes32) {
        return assertionToQuestion[assertionId];
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    /// @notice Update the default bond amount for new questions.
    /// @param newBond New default bond in bondCurrency units.
    function setDefaultBond(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert BondBelowMinimum();
        uint256 old = defaultBond;
        defaultBond = newBond;
        emit DefaultBondUpdated(old, newBond, msg.sender);
    }

    /// @notice Update the default challenge window for new questions.
    /// @param newLiveness New default liveness in seconds. Must be >= minLiveness.
    function setDefaultLiveness(uint64 newLiveness) external onlyOwner {
        if (newLiveness < minLiveness) revert LivenessTooShort();
        uint64 old = defaultLiveness;
        defaultLiveness = newLiveness;
        emit DefaultLivenessUpdated(old, newLiveness, msg.sender);
    }

    /// @notice Update the minimum allowed liveness.
    /// @param newMinLiveness New minimum liveness in seconds. Must be <= defaultLiveness.
    function setMinLiveness(uint64 newMinLiveness) external onlyOwner {
        if (newMinLiveness > defaultLiveness) revert LivenessTooShort();
        uint64 old = minLiveness;
        minLiveness = newMinLiveness;
        emit MinLivenessUpdated(old, newMinLiveness, msg.sender);
    }

    /// @notice Set the LayerZero cross-chain relay.
    /// @param _relay The LzCrossChainSender contract address on Polygon.
    function setCrossChainRelay(address _relay) external onlyOwner {
        address previous = address(crossChainRelay);
        crossChainRelay = LzCrossChainSender(_relay);
        emit CrossChainRelayUpdated(previous, _relay, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // QUESTION MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Cancel a question and allow retry with the same questionId.
    /// @dev Resets all adapter state for this questionId. The UMA assertion
    ///      remains on-chain but is disconnected from this adapter. The bond
    ///      stays in UMA's lifecycle and returns to the asserter when UMA settles.
    ///      The callbacks (assertionResolvedCallback, assertionDisputedCallback)
    ///      gracefully return for cancelled assertions, allowing UMA to settle
    ///      and return bonds without reverting.
    ///      Only works before resolution (resolved == false).
    ///      Callable by owner, any active operator, or any member of the question's resolver group.
    /// @param questionId The question to cancel.
    function cancelQuestion(bytes32 questionId) external nonReentrant {
        QuestionData storage q = questions[questionId];
        if (q.creator == address(0)) revert QuestionNotInitialized();
        if (q.resolved) revert QuestionAlreadyResolved();
        if (msg.sender != owner && !isOperator[msg.sender] && !_isResolver(questionId, msg.sender)) {
            revert NotQuestionAuthorized();
        }
        // Prevent cancellation while UMA dispute is in progress — the dispute
        // mechanism is the core security guarantee and must not be bypassed.
        // Also prevent cancellation after liveness expired — a malicious operator
        // could suppress an unfavorable outcome by cancelling before settleAssertion
        // is called. Once liveness expires, the outcome is determined and must be settled.
        if (q.assertionId != bytes32(0)) {
            IOptimisticOracleV3.Assertion memory a = OOV3.getAssertion(q.assertionId);
            if (a.wasDisputed && !a.settled) revert CannotCancelDisputedQuestion();
            if (!a.wasDisputed && block.timestamp >= a.expirationTime) revert CannotCancelExpiredAssertion();
        }
        bytes32 aId = q.assertionId;
        address creator = q.creator;
        delete questions[questionId];
        if (aId != bytes32(0)) {
            delete assertionToQuestion[aId];
            cancelledAssertions.push(aId);
            cancelledAssertionQuestion[aId] = questionId;
        }
        emit QuestionCancelled(questionId, aId, msg.sender, creator);
    }

    /// @notice Settle a cancelled assertion on UMA to reclaim the bond.
    /// @dev Calls OOV3.settleAssertion() which returns the bond to the original asserter
    ///      (the operator/owner who called initializeQuestion). Removes the entry from
    ///      the cancelledAssertions array via swap-and-pop. Permissionless — anyone can
    ///      trigger bond reclaim for any cancelled assertion.
    ///      Uses try/catch so that already-settled assertions (e.g., settled directly
    ///      on UMA) are still removed from the array instead of being permanently stuck.
    /// @param index Position in the cancelledAssertions array.
    function reclaimBond(uint256 index) external nonReentrant {
        uint256 len = cancelledAssertions.length;
        if (index >= len) revert IndexOutOfBounds();
        bytes32 assertionId = cancelledAssertions[index];

        // Cache questionId before cleanup (delete would lose it)
        bytes32 questionId = cancelledAssertionQuestion[assertionId];

        // Swap-and-pop: remove entry from array
        cancelledAssertions[index] = cancelledAssertions[len - 1];
        cancelledAssertions.pop();

        // Try to settle on UMA — if already settled externally, still remove the entry.
        // The bond was already returned to the asserter when UMA settled it.
        // Note: cancelledAssertionQuestion is deleted AFTER this call so the
        // assertionResolvedCallback can still look up the questionId for its event.
        bool settledByUs;
        try OOV3.settleAssertion(assertionId) {
            settledByUs = true;
        } catch {}

        delete cancelledAssertionQuestion[assertionId];

        emit BondReclaimed(assertionId, questionId, msg.sender, settledByUs);
    }

    /// @notice Returns the number of cancelled assertions awaiting bond reclaim.
    function cancelledAssertionsCount() external view returns (uint256) {
        return cancelledAssertions.length;
    }

    // ═══════════════════════════════════════════════════════
    // RESOLVER GROUP MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Add or remove members from a resolver group. Only owner or operators can call.
    /// @dev Groups are reusable — multiple questions can share the same groupId.
    ///      Adding/removing members applies instantly to all questions linked to that group.
    /// @param groupId The group identifier (e.g., keccak256("resolution-team-alpha")).
    /// @param members Array of addresses to add or remove.
    /// @param authorized True to add, false to remove.
    function setResolverGroup(bytes32 groupId, address[] calldata members, bool authorized) external {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotOperator();
        if (groupId == bytes32(0)) revert ZeroGroupId();
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            resolverGroups[groupId][members[i]] = authorized;
            emit ResolverGroupUpdated(groupId, members[i], authorized, msg.sender);
        }
    }

    /// @notice Assign a resolver group to a question. Only owner or operators can call.
    /// @dev Members of the assigned group can initialize, settle (during delay), and cancel.
    ///      Pass bytes32(0) to unassign.
    /// @param questionId The question to assign a group to.
    /// @param groupId The resolver group to assign (bytes32(0) to unassign).
    function assignQuestionGroup(bytes32 questionId, bytes32 groupId) external {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotOperator();
        bytes32 previousGroupId = questionGroup[questionId];
        questionGroup[questionId] = groupId;
        emit QuestionGroupAssigned(questionId, groupId, msg.sender, previousGroupId);
    }

    /// @dev Check if an address is an authorized resolver for a question via its group.
    function _isResolver(bytes32 questionId, address account) internal view returns (bool) {
        bytes32 groupId = questionGroup[questionId];
        return groupId != bytes32(0) && resolverGroups[groupId][account];
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN — OPERATOR MANAGEMENT
    // ═══════════════════════════════════════════════════════

    /// @notice Authorize a new operator to submit questions.
    /// @param operator The address to authorize (e.g., market creator).
    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (isOperator[operator]) revert AlreadyOperator();
        isOperator[operator] = true;
        emit OperatorUpdated(operator, true, msg.sender);
    }

    /// @notice Revoke an operator's authorization.
    /// @param operator The address to revoke.
    function removeOperator(address operator) external onlyOwner {
        if (!isOperator[operator]) revert NotAuthorizedOperator();
        isOperator[operator] = false;
        emit OperatorUpdated(operator, false, msg.sender);
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
