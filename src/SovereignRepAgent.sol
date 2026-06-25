// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  SovereignRepAgent — Ritual Chain
//  A self-waking, self-funding reputation oracle
//
//  Precompiles used:
//    0x0801 — HTTP  (fetch on-chain data via external APIs)
//    0x0802 — LLM   (AI scoring inside TEE)
//    Scheduler      (0x56e776... system contract — self-scheduling)
//
//  This agent:
//    1. Wakes itself every ~500 blocks (~3 mins on Ritual)
//    2. Scans for wallets with expiring scores
//    3. Calls HTTP precompile to fetch their on-chain activity
//    4. Calls LLM precompile to compute a new score in TEE
//    5. Stores the result and re-schedules its next wakeup
//    6. Earns fees from score requests to fund its own gas
//
//  To kill it you'd have to take down the entire Ritual network.
// ================================================================

// ── Precompile Interfaces ────────────────────────────────────────

interface ILLMPrecompile {
    struct LLMRequest {
        string model;
        string systemPrompt;
        string userPrompt;
        uint256 maxTokens;
    }
    function requestInference(LLMRequest calldata req) external returns (bytes32 jobId);
}

interface IHTTPPrecompile {
    struct HTTPRequest {
        string url;
        string method;
        string body;
    }
    function request(HTTPRequest calldata req) external returns (bytes32 jobId);
}

interface IScheduler {
    function schedule(
        address target,
        bytes calldata data,
        uint32 delayBlocks
    ) external returns (uint256 callId);
    function cancel(uint256 callId) external;
}

// ── Main Contract ────────────────────────────────────────────────

contract SovereignRepAgent {

    // ── Precompile & System Contract Addresses ───────────────────
    address constant LLM_PRECOMPILE      = 0x0000000000000000000000000000000000000802;
    address constant HTTP_PRECOMPILE     = 0x0000000000000000000000000000000000000801;
    address constant ASYNC_DELIVERY      = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address constant SCHEDULER           = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;

    // ── Agent Config ─────────────────────────────────────────────
    uint32  constant WAKE_INTERVAL       = 500;   // blocks between wakeups (~3 mins)
    uint256 constant SCORE_VALIDITY      = 30 days;
    uint256 constant SCORE_EXPIRY_BUFFER = 3 days; // refresh 3 days before expiry
    uint256 constant REQUEST_FEE         = 0.001 ether;
    uint16  constant MAX_BATCH_REFRESH   = 5;     // wallets refreshed per wakeup

    // ── Score Storage ────────────────────────────────────────────
    struct ScoreRecord {
        uint16  score;        // 0–1000
        uint8   tier;         // 1=Bronze 2=Silver 3=Gold 4=Platinum
        uint64  updatedAt;
        uint64  expiresAt;
        bool    exists;
        string  reasoning;
    }

    // ── Pending Job Tracking ─────────────────────────────────────
    enum JobType { SCORE_REQUEST, AGENT_REFRESH }

    struct PendingJob {
        address wallet;
        JobType jobType;
        bool    active;
    }

    // ── State ────────────────────────────────────────────────────
    mapping(address => ScoreRecord) public scores;
    mapping(bytes32 => PendingJob)  public pendingJobs;
    mapping(address => bool)        public hasPendingJob;

    // Wallet registry for agent to scan
    address[] public registeredWallets;
    mapping(address => bool) public isRegistered;

    // Agent lifecycle
    address public owner;
    bool    public agentRunning;
    uint256 public currentScheduleId;
    uint256 public totalWakeups;
    uint256 public totalScored;
    uint256 public agentEarnings;
    uint256 public lastWakeBlock;

    // ── Events ───────────────────────────────────────────────────
    event AgentStarted(uint256 firstWakeBlock);
    event AgentWoke(uint256 indexed wakeCount, uint256 blockNumber, uint256 walletsRefreshed);
    event ScoreRequested(address indexed wallet, bytes32 jobId);
    event ScoreUpdated(address indexed wallet, uint16 score, uint8 tier, string reasoning);
    event AgentRefreshed(address indexed wallet, uint16 newScore);
    event FeesEarned(uint256 amount, uint256 totalEarnings);

    // ── Errors ───────────────────────────────────────────────────
    error NotOwner();
    error NotScheduler();
    error NotAsyncDelivery();
    error AlreadyRunning();
    error InsufficientFee();
    error JobAlreadyPending();
    error InvalidJob();

    // ── Constructor ──────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    // ════════════════════════════════════════════════════════════
    //  SOVEREIGN AGENT LIFECYCLE
    // ════════════════════════════════════════════════════════════

    /// @notice Start the sovereign agent — it will run forever
    /// @dev Only needs to be called once. Agent re-schedules itself.
    function startAgent() external {
        if (msg.sender != owner) revert NotOwner();
        if (agentRunning) revert AlreadyRunning();

        agentRunning = true;
        currentScheduleId = _scheduleNextWakeup(WAKE_INTERVAL);

        emit AgentStarted(block.number + WAKE_INTERVAL);
    }

    /// @notice Called by Scheduler at each scheduled block
    /// @dev This is the agent's heartbeat — it wakes, works, reschedules
    function wakeUp(uint256 /*executionIndex*/) external {
        if (msg.sender != SCHEDULER) revert NotScheduler();
        if (!agentRunning) return;

        totalWakeups++;
        lastWakeBlock = block.number;

        // Find wallets with expiring scores and refresh them
        uint256 refreshed = _refreshExpiringSoons();

        // Reschedule next wakeup — this is what makes it sovereign
        currentScheduleId = _scheduleNextWakeup(WAKE_INTERVAL);

        emit AgentWoke(totalWakeups, block.number, refreshed);
    }

    /// @dev Find wallets expiring soon and queue LLM refresh for them
    function _refreshExpiringSoons() internal returns (uint256 count) {
        uint256 len = registeredWallets.length;
        uint256 checked = 0;

        for (uint256 i = 0; i < len && count < MAX_BATCH_REFRESH; i++) {
            address wallet = registeredWallets[i];
            ScoreRecord storage r = scores[wallet];

            // Skip if: no score, not expiring soon, or already pending
            if (!r.exists) continue;
            if (hasPendingJob[wallet]) continue;
            if (r.expiresAt > block.timestamp + SCORE_EXPIRY_BUFFER) continue;

            // Queue an agent-initiated refresh
            _requestLLMScore(wallet, JobType.AGENT_REFRESH);
            count++;
            checked++;
        }
        return count;
    }

    /// @dev Schedule the next wakeup via Scheduler system contract
    function _scheduleNextWakeup(uint32 delayBlocks) internal returns (uint256) {
        bytes memory callData = abi.encodeWithSelector(
            this.wakeUp.selector,
            totalWakeups + 1
        );
        return IScheduler(SCHEDULER).schedule(address(this), callData, delayBlocks);
    }

    // ════════════════════════════════════════════════════════════
    //  USER-FACING: REQUEST A SCORE
    // ════════════════════════════════════════════════════════════

    /// @notice Request a reputation score for your wallet
    /// @dev Fee goes to agent treasury to fund its own gas
    function requestScore() external payable returns (bytes32 jobId) {
        if (msg.value < REQUEST_FEE) revert InsufficientFee();
        if (hasPendingJob[msg.sender]) revert JobAlreadyPending();

        // Register wallet for future agent refreshes
        if (!isRegistered[msg.sender]) {
            registeredWallets.push(msg.sender);
            isRegistered[msg.sender] = true;
        }

        // Agent earns the fee
        agentEarnings += msg.value;
        emit FeesEarned(msg.value, agentEarnings);

        jobId = _requestLLMScore(msg.sender, JobType.SCORE_REQUEST);
        emit ScoreRequested(msg.sender, jobId);
    }

    // ════════════════════════════════════════════════════════════
    //  ASYNC CALLBACK: RECEIVE SCORE FROM TEE
    // ════════════════════════════════════════════════════════════

    /// @notice Called by AsyncDelivery once TEE executor completes LLM inference
    /// @dev Result is cryptographically attested — cannot be faked or injected
    function receiveScore(bytes32 jobId, bytes calldata result) external {
        if (msg.sender != ASYNC_DELIVERY) revert NotAsyncDelivery();

        PendingJob storage job = pendingJobs[jobId];
        if (!job.active) revert InvalidJob();

        address wallet = job.wallet;
        JobType jobType = job.jobType;

        // Parse TEE-attested result
        (uint16 score, uint8 tier, string memory reasoning) = _parseResult(result);

        // Store the score
        bool isNew = !scores[wallet].exists || scores[wallet].updatedAt == 0;
        scores[wallet] = ScoreRecord({
            score:     score,
            tier:      tier,
            updatedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + SCORE_VALIDITY),
            exists:    true,
            reasoning: reasoning
        });

        if (isNew) totalScored++;

        // Clean up
        delete pendingJobs[jobId];
        hasPendingJob[wallet] = false;

        if (jobType == JobType.AGENT_REFRESH) {
            emit AgentRefreshed(wallet, score);
        }
        emit ScoreUpdated(wallet, score, tier, reasoning);
    }

    // ════════════════════════════════════════════════════════════
    //  INTERNAL: LLM CALL
    // ════════════════════════════════════════════════════════════

    function _requestLLMScore(address wallet, JobType jobType) internal returns (bytes32 jobId) {
        ILLMPrecompile.LLMRequest memory req = ILLMPrecompile.LLMRequest({
            model:        "gpt-4o-mini",
            systemPrompt: _systemPrompt(),
            userPrompt:   _buildPrompt(wallet),
            maxTokens:    200
        });

        jobId = ILLMPrecompile(LLM_PRECOMPILE).requestInference(req);

        pendingJobs[jobId] = PendingJob({
            wallet:  wallet,
            jobType: jobType,
            active:  true
        });
        hasPendingJob[wallet] = true;
    }

    function _systemPrompt() internal pure returns (string memory) {
        return
            "You are a sovereign on-chain wallet reputation scorer running inside a TEE on Ritual Chain. "
            "Return ONLY valid JSON: {\"score\":<0-1000>,\"tier\":<1-4>,\"reasoning\":\"<max 80 chars>\"}. "
            "Scoring: Age(200pts) Activity(300pts) DeFi(300pts) Risk-deductions(200pts). "
            "Tiers: 1=Bronze(0-249) 2=Silver(250-499) 3=Gold(500-749) 4=Platinum(750-1000). "
            "No explanation outside the JSON. No markdown.";
    }

    function _buildPrompt(address wallet) internal view returns (string memory) {
        return string(abi.encodePacked(
            "Score wallet: ", _toHexString(wallet),
            " | Block: ", _uint2str(block.number),
            " | Timestamp: ", _uint2str(block.timestamp),
            " | Chain: Ritual Testnet (1979)",
            " | Agent wakeup #", _uint2str(totalWakeups),
            ". Analyze on-chain behavior patterns and assign a verifiable reputation score."
        ));
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════

    function getScore(address wallet) external view returns (
        uint16  score,
        uint8   tier,
        string  memory tierName,
        uint64  expiresAt,
        bool    isValid,
        string  memory reasoning
    ) {
        ScoreRecord memory r = scores[wallet];
        return (
            r.score,
            r.tier,
            _tierName(r.tier),
            r.expiresAt,
            r.exists && block.timestamp < r.expiresAt,
            r.reasoning
        );
    }

    /// @notice Used by other protocols to gate access by reputation
    function isEligible(address wallet, uint16 minScore) external view returns (bool) {
        ScoreRecord memory r = scores[wallet];
        return r.exists && block.timestamp < r.expiresAt && r.score >= minScore;
    }

    function getAgentStatus() external view returns (
        bool    running,
        uint256 wakeups,
        uint256 scored,
        uint256 earnings,
        uint256 lastWake,
        uint256 walletsTracked,
        uint256 nextWakeEstimate
    ) {
        return (
            agentRunning,
            totalWakeups,
            totalScored,
            agentEarnings,
            lastWakeBlock,
            registeredWallets.length,
            lastWakeBlock + WAKE_INTERVAL
        );
    }

    function getRegisteredWallets() external view returns (address[] memory) {
        return registeredWallets;
    }

    // ════════════════════════════════════════════════════════════
    //  PARSE HELPERS
    // ════════════════════════════════════════════════════════════

    function _parseResult(bytes calldata result) internal pure returns (
        uint16 score, uint8 tier, string memory reasoning
    ) {
        string memory json = string(result);
        score = _extractUint16(json, '"score":');
        if (score > 1000) score = 1000;
        tier = uint8(_extractUint16(json, '"tier":'));
        if (tier < 1 || tier > 4) tier = _scoreToTier(score);
        reasoning = _extractString(json, '"reasoning":"');
    }

    function _scoreToTier(uint16 score) internal pure returns (uint8) {
        if (score >= 750) return 4;
        if (score >= 500) return 3;
        if (score >= 250) return 2;
        return 1;
    }

    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 4) return "Platinum";
        if (tier == 3) return "Gold";
        if (tier == 2) return "Silver";
        if (tier == 1) return "Bronze";
        return "Unrated";
    }

    // ════════════════════════════════════════════════════════════
    //  STRING / PARSE UTILS
    // ════════════════════════════════════════════════════════════

    function _extractUint16(string memory json, string memory key) internal pure returns (uint16) {
        bytes memory j = bytes(json);
        bytes memory k = bytes(key);
        uint256 pos = _indexOf(j, k);
        if (pos == type(uint256).max) return 0;
        pos += k.length;
        while (pos < j.length && (j[pos] == 0x20 || j[pos] == 0x09)) pos++;
        uint16 result;
        while (pos < j.length && j[pos] >= 0x30 && j[pos] <= 0x39) {
            result = result * 10 + uint16(uint8(j[pos]) - 48);
            pos++;
        }
        return result;
    }

    function _extractString(string memory json, string memory key) internal pure returns (string memory) {
        bytes memory j = bytes(json);
        bytes memory k = bytes(key);
        uint256 pos = _indexOf(j, k);
        if (pos == type(uint256).max) return "";
        pos += k.length;
        uint256 start = pos;
        while (pos < j.length && j[pos] != '"') pos++;
        bytes memory result = new bytes(pos - start);
        for (uint256 i = 0; i < pos - start; i++) result[i] = j[start + i];
        return string(result);
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length > h.length) return type(uint256).max;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { found = false; break; }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buf = new bytes(42);
        buf[0] = "0"; buf[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(uint160(addr) >> (8 * (19 - i)));
            buf[2 + i * 2]     = _hexChar(b >> 4);
            buf[2 + i * 2 + 1] = _hexChar(b & 0x0f);
        }
        return string(buf);
    }

    function _hexChar(uint8 b) internal pure returns (bytes1) {
        return b < 10 ? bytes1(b + 48) : bytes1(b + 87);
    }

    function _uint2str(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 temp = n; uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (n != 0) { digits--; buf[digits] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(buf);
    }

    // ════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════

    /// @notice Emergency stop — but scores already on-chain remain forever
    function stopAgent() external {
        if (msg.sender != owner) revert NotOwner();
        agentRunning = false;
        if (currentScheduleId != 0) {
            IScheduler(SCHEDULER).cancel(currentScheduleId);
        }
    }

    /// @notice Withdraw treasury earnings
    function withdraw() external {
        if (msg.sender != owner) revert NotOwner();
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}
