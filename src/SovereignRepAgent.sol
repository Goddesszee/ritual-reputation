// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  SovereignRepAgent v2 — Real AI Scoring on Ritual Chain
//
//  Precompiles:
//    0x0801 — HTTP  (fetch wallet data from Etherscan API in TEE)
//    0x0802 — LLM   (GLM-4.7-FP8 runs in TEE, no API key needed)
//    Scheduler      (self-waking every 500 blocks)
//
//  Flow:
//    1. requestScore() called by user
//    2. HTTP precompile fetches real tx data for wallet (TEE-attested)
//    3. LLM precompile scores wallet based on real data (TEE-attested)
//    4. Score stored on-chain — verifiable, tamper-proof
//    5. Agent wakes every 500 blocks, auto-refreshes expiring scores
// ================================================================

interface IHTTPPrecompile {
    struct HTTPRequest {
        string  url;
        string  method;
        string  headers;
        string  body;
    }
    // Sync: returns response inline
    function request(HTTPRequest calldata req)
        external returns (bytes memory response);
}

interface ILLMPrecompile {
    struct Message {
        string role;    // "system" | "user" | "assistant"
        string content;
    }
    struct LLMRequest {
        Message[] messages;
        uint32    maxTokens;
        bool      stream;
    }
    // Sync: returns completion inline (same tx)
    function complete(LLMRequest calldata req)
        external returns (string memory text);
}

interface IScheduler {
    function schedule(address target, bytes calldata data, uint32 delayBlocks)
        external returns (uint256 callId);
    function cancel(uint256 callId) external;
}

contract SovereignRepAgent {

    // ── Precompile Addresses ───────────────────────────────────
    address constant HTTP      = 0x0000000000000000000000000000000000000801;
    address constant LLM       = 0x0000000000000000000000000000000000000802;
    address constant DELIVERY  = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;

    // ── Config ─────────────────────────────────────────────────
    uint32  constant WAKE_INTERVAL = 500;    // ~3 mins on Ritual
    uint256 constant SCORE_VALIDITY = 30 days;
    uint256 constant EXPIRY_BUFFER  = 3 days;
    uint256 constant FEE            = 0.001 ether;

    // ── Data Structures ────────────────────────────────────────
    struct Score {
        uint16  points;      // 0–1000
        uint8   tier;        // 1=Bronze 2=Silver 3=Gold 4=Platinum
        uint64  updatedAt;
        uint64  expiresAt;
        bool    exists;
        string  reason;
        string  walletData; // cached HTTP response summary
    }

    // ── State ──────────────────────────────────────────────────
    mapping(address => Score) public scores;
    address[] public wallets;
    mapping(address => bool) public registered;

    address public owner;
    bool    public agentRunning;
    uint256 public scheduleId;
    uint256 public totalWakeups;
    uint256 public totalScored;
    uint256 public earnings;
    uint256 public lastWakeBlock;
    string  public etherscanApiKey; // set by owner for HTTP calls

    // ── Events ─────────────────────────────────────────────────
    event AgentStarted(uint256 block_);
    event AgentWoke(uint256 wakeup, uint256 block_, uint256 refreshed);
    event ScoreRequested(address wallet);
    event ScoreUpdated(address wallet, uint16 points, uint8 tier, string reason);
    event HTTPDataFetched(address wallet, string summary);

    // ── Errors ─────────────────────────────────────────────────
    error OnlyOwner();
    error OnlyScheduler();
    error AlreadyRunning();
    error LowFee();

    constructor() {
        owner = msg.sender;
        // Default public Etherscan API key (rate limited but works)
        etherscanApiKey = "YourApiKeyToken";
    }

    // ══════════════════════════════════════════════════════════
    //  AGENT LIFECYCLE
    // ══════════════════════════════════════════════════════════

    function startAgent() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (agentRunning) revert AlreadyRunning();
        agentRunning  = true;
        scheduleId    = _scheduleWakeup(WAKE_INTERVAL);
        emit AgentStarted(block.number);
    }

    function wakeUp(uint256) external {
        if (msg.sender != SCHEDULER) revert OnlyScheduler();
        if (!agentRunning) return;
        totalWakeups++;
        lastWakeBlock = block.number;

        // Auto-refresh expiring scores
        uint256 refreshed = _refreshExpiring();

        // Schedule next wakeup — this is what makes it sovereign
        scheduleId = _scheduleWakeup(WAKE_INTERVAL);
        emit AgentWoke(totalWakeups, block.number, refreshed);
    }

    function _scheduleWakeup(uint32 delay) internal returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, totalWakeups + 1);
        return IScheduler(SCHEDULER).schedule(address(this), data, delay);
    }

    function _refreshExpiring() internal returns (uint256 count) {
        for (uint256 i = 0; i < wallets.length && count < 5; i++) {
            Score storage s = scores[wallets[i]];
            if (!s.exists) continue;
            if (s.expiresAt > block.timestamp + EXPIRY_BUFFER) continue;
            _computeScore(wallets[i]);
            count++;
        }
    }

    // ══════════════════════════════════════════════════════════
    //  USER-FACING: REQUEST SCORE
    // ══════════════════════════════════════════════════════════

    function requestScore() external payable {
        if (msg.value < FEE) revert LowFee();
        earnings += msg.value;

        if (!registered[msg.sender]) {
            wallets.push(msg.sender);
            registered[msg.sender] = true;
        }

        emit ScoreRequested(msg.sender);
        _computeScore(msg.sender);
    }

    // ══════════════════════════════════════════════════════════
    //  CORE: FETCH DATA + SCORE WITH LLM (both TEE-attested)
    // ══════════════════════════════════════════════════════════

    function _computeScore(address wallet) internal {
        // ── Step 1: HTTP precompile fetches real wallet data ──
        string memory walletAddr = _toHexString(wallet);
        string memory walletData = _fetchWalletData(walletAddr);

        // ── Step 2: LLM precompile scores based on real data ──
        (uint16 points, uint8 tier, string memory reason) = _scoreLLM(walletAddr, walletData);

        // ── Step 3: Store verified result on-chain ────────────
        bool isNew = !scores[wallet].exists;
        scores[wallet] = Score({
            points:     points,
            tier:       tier,
            updatedAt:  uint64(block.timestamp),
            expiresAt:  uint64(block.timestamp + SCORE_VALIDITY),
            exists:     true,
            reason:     reason,
            walletData: walletData
        });

        if (isNew) totalScored++;
        emit ScoreUpdated(wallet, points, tier, reason);
    }

    // ── HTTP Precompile: fetch tx data from Etherscan ─────────
    function _fetchWalletData(string memory walletAddr)
        internal returns (string memory summary)
    {
        // Build Etherscan API URL to get transaction list
        string memory url = string(abi.encodePacked(
            "https://api.etherscan.io/api?module=account&action=txlist",
            "&address=", walletAddr,
            "&startblock=0&endblock=99999999",
            "&page=1&offset=20&sort=desc",
            "&apikey=", etherscanApiKey
        ));

        IHTTPPrecompile.HTTPRequest memory req = IHTTPPrecompile.HTTPRequest({
            url:     url,
            method:  "GET",
            headers: "Accept: application/json",
            body:    ""
        });

        try IHTTPPrecompile(HTTP).request(req) returns (bytes memory resp) {
            // Parse response to extract key metrics
            string memory respStr = string(resp);
            summary = _summarizeResponse(walletAddr, respStr);
            emit HTTPDataFetched(msg.sender, summary);
        } catch {
            // Fallback if HTTP fails — use on-chain data only
            summary = string(abi.encodePacked(
                "wallet:", walletAddr,
                " block:", _uint2str(block.number),
                " timestamp:", _uint2str(block.timestamp)
            ));
        }
    }

    // ── LLM Precompile: score with GLM-4.7-FP8 in TEE ────────
    function _scoreLLM(string memory walletAddr, string memory walletData)
        internal returns (uint16 points, uint8 tier, string memory reason)
    {
        ILLMPrecompile.Message[] memory msgs = new ILLMPrecompile.Message[](2);

        msgs[0] = ILLMPrecompile.Message({
            role: "system",
            content: "You are a blockchain wallet reputation scorer. Analyze wallet data and return ONLY valid JSON: {\"score\":<0-1000>,\"tier\":<1-4>,\"reasoning\":\"<max 80 chars>\"}. Scoring: wallet age 200pts, tx activity 300pts, DeFi usage 300pts, risk factors -200pts. Tiers: 1=Bronze(0-249) 2=Silver(250-499) 3=Gold(500-749) 4=Platinum(750-1000). No text outside JSON."
        });

        msgs[1] = ILLMPrecompile.Message({
            role: "user",
            content: string(abi.encodePacked(
                "Score this wallet: ", walletAddr,
                "\nOn-chain data: ", walletData,
                "\nChain: Ritual Testnet | Block: ", _uint2str(block.number),
                "\nReturn JSON only."
            ))
        });

        ILLMPrecompile.LLMRequest memory req = ILLMPrecompile.LLMRequest({
            messages:  msgs,
            maxTokens: 150,
            stream:    false
        });

        try ILLMPrecompile(LLM).complete(req) returns (string memory result) {
            (points, tier, reason) = _parseJSON(result);
        } catch {
            // Fallback scoring if LLM fails
            points = 300;
            tier   = 2;
            reason = "Scored via fallback (LLM unavailable)";
        }
    }

    // ── Parse HTTP response to extract key metrics ────────────
    function _summarizeResponse(string memory addr, string memory resp)
        internal pure returns (string memory)
    {
        // Extract tx count from JSON response
        // Etherscan returns: {"status":"1","message":"OK","result":[{...},...]}
        uint16 txCount = _countOccurrences(resp, '"hash"');
        bool hasDefi   = _contains(resp, "swap") || _contains(resp, "approve");

        return string(abi.encodePacked(
            "addr:", addr,
            " txs:", _uint2str(txCount),
            " defi:", hasDefi ? "yes" : "no"
        ));
    }

    // ══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════

    function getScore(address wallet) external view returns (
        uint16 points, string memory tierName, bool valid, string memory reason
    ) {
        Score memory s = scores[wallet];
        return (
            s.points,
            _tierName(s.tier),
            s.exists && block.timestamp < s.expiresAt,
            s.reason
        );
    }

    function getScoreFull(address wallet) external view returns (
        uint16 points, uint8 tier, string memory tierName,
        uint64 updatedAt, uint64 expiresAt, bool valid,
        string memory reason, string memory walletData
    ) {
        Score memory s = scores[wallet];
        return (
            s.points, s.tier, _tierName(s.tier),
            s.updatedAt, s.expiresAt,
            s.exists && block.timestamp < s.expiresAt,
            s.reason, s.walletData
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




    // ══════════════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════════════

    function setApiKey(string calldata key) external {
        if (msg.sender != owner) revert OnlyOwner();
        etherscanApiKey = key;
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

    // ══════════════════════════════════════════════════════════
    //  PARSE + STRING UTILS
    // ══════════════════════════════════════════════════════════

    function _parseJSON(string memory json) internal pure returns (
        uint16 score, uint8 tier, string memory reason
    ) {
        score  = _extractNum(json, '"score":');
        if (score > 1000) score = 1000;
        tier   = uint8(_extractNum(json, '"tier":'));
        if (tier < 1 || tier > 4) tier = score >= 750 ? 4 : score >= 500 ? 3 : score >= 250 ? 2 : 1;
        reason = _extractStr(json, '"reasoning":"');
    }

    function _extractNum(string memory json, string memory key) internal pure returns (uint16) {
        bytes memory j = bytes(json);
        bytes memory k = bytes(key);
        uint256 i = _indexOf(j, k);
        if (i == type(uint256).max) return 0;
        i += k.length;
        while (i < j.length && (j[i] == 0x20 || j[i] == 0x09)) i++;
        uint16 n;
        while (i < j.length && j[i] >= 0x30 && j[i] <= 0x39) {
            n = n * 10 + uint16(uint8(j[i]) - 48); i++;
        }
        return n;
    }

    function _extractStr(string memory json, string memory key) internal pure returns (string memory) {
        bytes memory j = bytes(json);
        bytes memory k = bytes(key);
        uint256 i = _indexOf(j, k);
        if (i == type(uint256).max) return "";
        i += k.length;
        uint256 start = i;
        while (i < j.length && j[i] != '"') i++;
        bytes memory out = new bytes(i - start);
        for (uint256 x = 0; x < i - start; x++) out[x] = j[start + x];
        return string(out);
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length > h.length) return type(uint256).max;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i+j] != n[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _contains(string memory s, string memory sub) internal pure returns (bool) {
        return _indexOf(bytes(s), bytes(sub)) != type(uint256).max;
    }

    function _countOccurrences(string memory s, string memory sub) internal pure returns (uint16) {
        bytes memory b = bytes(s);
        bytes memory k = bytes(sub);
        uint16 count;
        for (uint256 i = 0; i <= b.length - k.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < k.length; j++) {
                if (b[i+j] != k[j]) { ok = false; break; }
            }
            if (ok) { count++; i += k.length - 1; }
        }
        return count;
    }

    function _tierName(uint8 t) internal pure returns (string memory) {
        if (t == 4) return "Platinum";
        if (t == 3) return "Gold";
        if (t == 2) return "Silver";
        if (t == 1) return "Bronze";
        return "Unrated";
    }

    function _toHexString(address a) internal pure returns (string memory) {
        bytes memory b = new bytes(42);
        b[0] = "0"; b[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 v = uint8(uint160(a) >> (8 * (19 - i)));
            b[2+i*2]   = v >> 4 < 10 ? bytes1(v >> 4 + 48) : bytes1(v >> 4 + 87);
            b[2+i*2+1] = v & 15 < 10 ? bytes1(v & 15 + 48) : bytes1(v & 15 + 87);
        }
        return string(b);
    }

    function _uint2str(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 t = n; uint256 d;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (n != 0) { d--; b[d] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(b);
    }

    receive() external payable {}
}
