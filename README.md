# SovereignRepAgent — Ritual Chain

A self-waking autonomous reputation scoring agent on Ritual Chain.
Built for the Ritual Builders Program.

## What Makes This a Sovereign Agent

- **Never sleeps** — Scheduler precompile wakes it every ~500 blocks (~3 mins)
- **Never needs a human** — auto-refreshes expiring wallet scores
- **Funds itself** — earns fees from score requests to pay its own gas
- **Can't be taken down** — lives on Ritual Chain, no server, no keeper
- **TEE-verified** — LLM scores computed inside Intel SGX enclave, cryptographically attested

## Precompiles Used

| Precompile | Address | Purpose |
|---|---|---|
| LLM Inference | `0x0802` | AI scoring inside TEE |
| HTTP | `0x0801` | Fetch on-chain activity data |
| Scheduler | `0x56e776...` | Self-scheduling wakeups |
| AsyncDelivery | `0x5A162...` | Receive TEE-attested results |

## Chain Info

```
Network:  Ritual Chain Testnet
Chain ID: 1979
RPC:      https://rpc.ritualfoundation.org
Explorer: https://explorer.ritualfoundation.org
Faucet:   https://faucet.ritualfoundation.org
```

## Deploy

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Set your key
export PRIVATE_KEY=your_private_key

# Deploy + auto-start the agent
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.ritualfoundation.org \
  --broadcast \
  --legacy
```

Then paste the deployed address into `index.html` → `CONTRACT_ADDRESS`.

## Test

```bash
forge test -v
```

## How the Agent Loop Works

```
Deploy → startAgent() → Scheduler queues first wakeup
         ↓
Block +500 → wakeUp() fires
         ↓
Scan registered wallets → find expiring scores
         ↓
Call LLM precompile (0x0802) → TEE runs inference
         ↓
AsyncDelivery calls receiveScore() → score stored on-chain
         ↓
_scheduleNextWakeup() → loop repeats forever
```

## Protocol Integration

```solidity
interface ISovereignRepAgent {
    function isEligible(address wallet, uint16 minScore)
        external view returns (bool);
}

modifier requireReputation(uint16 minScore) {
    require(
        ISovereignRepAgent(REP_AGENT).isEligible(msg.sender, minScore),
        "Insufficient reputation"
    );
    _;
}
```

## File Structure

```
ritual-reputation/
├── src/SovereignRepAgent.sol   ← Core sovereign agent
├── script/Deploy.s.sol         ← Foundry deploy + auto-start
├── test/SovereignRepAgent.t.sol← Unit tests (13 tests)
├── index.html                  ← dApp frontend
├── foundry.toml                ← Ritual Chain config
└── README.md
```

## Apply for Ritual Realm
https://ritualfoundation.com — grants + support for Ritual builders
