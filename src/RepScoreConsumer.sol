// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  RepScoreConsumer — Ritual Chain (correct architecture)
//
//  Architecture based on official Ritual dApp skills docs:
//  - LLM/HTTP calls happen from FRONTEND (30-field / 13-field ABI)
//  - This contract STORES the TEE-attested results on-chain
//  - Scheduler uses correct 4-param overload
//  - No precompile calls inside contract (they're frontend-side)
//
//  Flow:
//    1. Frontend fetches executor from TEEServiceRegistry
//    2. Frontend sends LLM tx directly to 0x0802 (30 fields)
//    3. Frontend reads score from receipt spcCalls
//    4. Frontend calls submitScore() on this contract
//    5. Score stored on-chain permanently
// ================================================================

interface IScheduler {
    // 4-param overload (correct per docs)
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency
    ) external returns (uint256 callId);

    function cancel(uint256 callId) external;
}

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract RepScoreConsumer {

    address constant SCHEDULER     = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;

    uint256 constant SCORE_VALIDITY = 30 days;
    uint256 constant FEE            = 0.001 ether;

    struct Score {
        uint16  points;
        uint8   tier;
        uint64  updatedAt;
        uint64  expiresAt;
        bool    exists;
        string  reason;
        string  model;      // which LLM model scored this
        bytes32 txProof;    // tx hash where TEE inference happened
    }

    mapping(address => Score) public scores;
    address[] public wallets;
    mapping(address => bool) public registered;

    // Authorized submitters (frontends that can submit TEE results)
    mapping(address => bool) public authorizedSubmitters;

    address public owner;
    uint256 public totalScored;
    uint256 public earnings;
    uint256 public scheduleId;
    bool    public agentRunning;
    uint256 public totalWakeups;

    event ScoreSubmitted(address indexed wallet, uint16 points, uint8 tier, bytes32 txProof);
    event AgentWoke(uint256 indexed wakeup, uint256 blockNumber);
    event SubmitterAuthorized(address submitter, bool status);

    error OnlyOwner();
    error OnlyScheduler();
    error OnlySubmitter();
    error LowFee();
    error AlreadyRunning();

    constructor() {
        owner = msg.sender;
        authorizedSubmitters[msg.sender] = true;
    }

    // ── Score Submission (called by frontend after LLM tx) ────
    /// @notice Submit a TEE-attested score from a Ritual LLM call
    /// @param wallet   The wallet that was scored
    /// @param points   Score 0-1000
    /// @param tier     1=Bronze 2=Silver 3=Gold 4=Platinum
    /// @param reason   AI reasoning (max 80 chars)
    /// @param model    Model used (e.g. "zai-org/GLM-4.7-FP8")
    /// @param txProof  Hash of the LLM precompile tx for verification
    function submitScore(
        address wallet,
        uint16  points,
        uint8   tier,
        string  calldata reason,
        string  calldata model,
        bytes32 txProof
    ) external {
        if (!authorizedSubmitters[msg.sender]) revert OnlySubmitter();
        if (points > 1000) points = 1000;
        if (tier < 1 || tier > 4) tier = _scoreToTier(points);

        bool isNew = !scores[wallet].exists;
        scores[wallet] = Score({
            points:    points,
            tier:      tier,
            updatedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + SCORE_VALIDITY),
            exists:    true,
            reason:    reason,
            model:     model,
            txProof:   txProof
        });

        if (isNew) {
            wallets.push(wallet);
            registered[wallet] = true;
            totalScored++;
        }

        emit ScoreSubmitted(wallet, points, tier, txProof);
    }

    /// @notice Pay fee to request a score — emits event for frontend to pick up
    function requestScore() external payable {
        if (msg.value < FEE) revert LowFee();
        earnings += msg.value;
        if (!registered[msg.sender]) {
            wallets.push(msg.sender);
            registered[msg.sender] = true;
        }
        // Frontend listens for this event and triggers LLM call
        emit ScoreRequested(msg.sender, block.number);
    }

    event ScoreRequested(address indexed wallet, uint256 blockNumber);

    // ── Scheduler Wakeup (auto-refresh expiring scores) ───────
    function startAgent() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (agentRunning) revert AlreadyRunning();
        agentRunning = true;

        // Fund RitualWallet for scheduler fees
        IRitualWallet(RITUAL_WALLET).deposit{value: address(this).balance / 2}(5000);

        // Schedule wakeup every 500 blocks
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, 0);
        scheduleId = IScheduler(SCHEDULER).schedule(
            data,
            200000,  // gas
            0,       // numCalls: 0 = infinite
            500      // frequency: every 500 blocks
        );
    }

    function wakeUp(uint256 executionIndex) external {
        if (msg.sender != SCHEDULER) revert OnlyScheduler();
        totalWakeups++;
        emit AgentWoke(executionIndex, block.number);
        // Frontend monitors AgentWoke events and scores expiring wallets
    }

    // ── View Functions ─────────────────────────────────────────
    function getScore(address wallet) external view returns (
        uint16 points, string memory tierName, bool valid,
        string memory reason, string memory model, bytes32 txProof
    ) {
        Score memory s = scores[wallet];
        return (
            s.points,
            _tierName(s.tier),
            s.exists && block.timestamp < s.expiresAt,
            s.reason,
            s.model,
            s.txProof
        );
    }

    function isEligible(address wallet, uint16 minScore) external view returns (bool) {
        Score memory s = scores[wallet];
        return s.exists && block.timestamp < s.expiresAt && s.points >= minScore;
    }

    function getStatus() external view returns (
        bool running, uint256 wakeups, uint256 scored,
        uint256 earn, uint256 tracked
    ) {
        return (agentRunning, totalWakeups, totalScored, earnings, wallets.length);
    }

    function getExpiringWallets(uint256 bufferDays) external view returns (address[] memory) {
        uint256 count;
        uint256 cutoff = block.timestamp + (bufferDays * 1 days);
        for (uint256 i = 0; i < wallets.length; i++) {
            if (scores[wallets[i]].exists && scores[wallets[i]].expiresAt < cutoff) count++;
        }
        address[] memory result = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < wallets.length; i++) {
            if (scores[wallets[i]].exists && scores[wallets[i]].expiresAt < cutoff) {
                result[j++] = wallets[i];
            }
        }
        return result;
    }

    // ── Admin ──────────────────────────────────────────────────
    function authorizeSubmitter(address submitter, bool status) external {
        if (msg.sender != owner) revert OnlyOwner();
        authorizedSubmitters[submitter] = status;
        emit SubmitterAuthorized(submitter, status);
    }

    function stopAgent() external {
        if (msg.sender != owner) revert OnlyOwner();
        agentRunning = false;
        if (scheduleId != 0) IScheduler(SCHEDULER).cancel(scheduleId);
    }

    function withdraw() external {
        if (msg.sender != owner) revert OnlyOwner();
        payable(owner).transfer(address(this).balance);
    }

    // ── Utils ──────────────────────────────────────────────────
    function _scoreToTier(uint16 score) internal pure returns (uint8) {
        if (score >= 750) return 4;
        if (score >= 500) return 3;
        if (score >= 250) return 2;
        return 1;
    }

    function _tierName(uint8 t) internal pure returns (string memory) {
        if (t == 4) return "Platinum";
        if (t == 3) return "Gold";
        if (t == 2) return "Silver";
        if (t == 1) return "Bronze";
        return "Unrated";
    }

    receive() external payable {}
}
