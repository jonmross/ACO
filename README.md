# Agent Council Oracle

A decentralized oracle system that uses multi-agent councils to resolve information queries through commit-reveal mechanisms with economic incentives.

## Overview

The Agent Council Oracle enables trustless information resolution by:

1. **Requesters** post queries with ETH or ERC20  rewards
2. **Information Agents** stake bonds and submit answers via commit-reveal
3. **Judge Agents** evaluate submissions and determine winners
4. **Economic incentives** ensure honest participation - winners are rewarded, losers are slashed

## Key Features

- **Commit-Reveal Scheme**: Agents commit hashed answers first, then reveal - preventing copying
- **Economic Security**: Bonds are slashed for incorrect answers and distributed to winners
- **Decentralized Judging**: Judges register for requests and are randomly selected
- **Configurable Parameters**: Reward amounts, bond sizes, time windows, and judge compensation are all customizable per-request
- **Timeout Protection**: Automatic refunds if judges fail to act within deadlines
- **Flexible Token Support**: Supports native ETH or any ERC20 token for rewards and bonds (can be different tokens)

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Requester  │────▶│   Oracle    │◀────│   Agents    │
│             │     │  Contract   │     │  (Info +    │
│  Posts query│     │             │     │   Judge)    │
│  + reward   │     │  Manages    │     │             │
└─────────────┘     │  lifecycle  │     │  Commit,    │
                    │  + payouts  │     │  Reveal,    │
                    └─────────────┘     │  Judge      │
                                        └─────────────┘
```

## Request Lifecycle

```
Phase 1: COMMIT
├── Requester creates request with reward
├── Info agents submit hashed answers + bond
└── Transitions when: all slots filled OR deadline passed

Phase 2: REVEAL  
├── Agents reveal their answers + nonces
├── Contract verifies commitments match
└── Transitions when: all revealed OR window ends

Phase 3: AWAITING_JUDGE
├── Judge agents register for the request
├── Anyone can trigger random judge selection
└── Transitions when: judge selected

Phase 4: JUDGING
├── Selected judge posts bond
├── Judge reviews answers and picks winners
└── Transitions when: judge aggregates OR timeout

Phase 5: FINALIZED
├── Resolution is locked
└── Anyone can trigger reward distribution

Phase 6: DISTRIBUTED
└── All funds distributed, request complete
```

## Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/agent-council-oracle.git
cd agent-council-oracle

# Install Foundry if you haven't already
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install
```

## Usage

### Run Tests

```bash
# Run all tests
forge test

# Run with verbosity (see test names)
forge test -vv

# Run with full traces (see all logs)
forge test -vvvv
```

### Run Interactive Demo

The demo script walks through a complete request lifecycle with detailed logging:

```bash
forge script script/OracleDemo.s.sol -vvvv
```

This shows:
- Request creation with parameters
- 3 agents committing answers (2 correct, 1 wrong)
- Answer reveals
- Judge registration and random selection
- Winner determination and reward distribution
- Final balance changes for all participants

### Deploy

```bash
# Deploy to local network
forge script script/Deploy.s.sol --broadcast

# Deploy to testnet (e.g., Sepolia)
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

## Contract Interface

### Creating a Request

```solidity
IAgentCouncilOracle.CreateRequestParams memory params;
params.query = "What is the price of ETH?";
params.numInfoAgents = 3;           // Number of agent slots
params.rewardAmount = 1 ether;      // Total reward pool
params.bondAmount = 0.1 ether;      // Bond required from each agent
params.deadline = block.timestamp + 1 hours;  // Commit deadline
params.judgeSignupDeadline = block.timestamp + 3 hours;
params.revealWindow = 1 hours;      // Time for reveals after commit deadline
params.judgeBondAmount = 0.1 ether; // Bond required from judge
params.judgeAggWindow = 1 hours;    // Time for judge to aggregate
params.judgeRewardBps = 1000;       // 10% of reward to judge (basis points)
params.rewardToken = address(0);    // address(0) for native ETH, or ERC20 token address
params.bondToken = address(0);      // address(0) for native ETH, or ERC20 token address
params.specifications = "Return price in USD";
params.requiredCapabilities = capabilities;

// For native ETH rewards:
uint256 requestId = oracle.createRequest{value: 1 ether}(params);

// For ERC20 rewards (must approve first):
// IERC20(rewardToken).approve(address(oracle), rewardAmount);
// uint256 requestId = oracle.createRequest(params);  // no ETH sent
```

### Participating as an Agent

```solidity
// 1. Commit (hashed answer)
bytes memory answer = bytes("4500");
uint256 nonce = 12345; // Keep this secret!
bytes32 commitment = keccak256(abi.encode(answer, nonce));

// For native ETH bonds:
oracle.commit{value: 0.1 ether}(requestId, commitment);

// For ERC20 bonds (must approve first):
// IERC20(bondToken).approve(address(oracle), bondAmount);
// oracle.commit(requestId, commitment);  // no ETH sent

// 2. Reveal (after commit phase ends)
oracle.reveal(requestId, answer, nonce);
```

### Participating as a Judge

```solidity
// 1. Register for the request
oracle.registerJudgeForRequest(requestId);

// 2. Wait to be selected (anyone can call this)
oracle.selectJudge(requestId);

// 3. If selected, post bond
// For native ETH:
oracle.postJudgeBond{value: 0.1 ether}(requestId);
// For ERC20 (must approve first):
// oracle.postJudgeBond(requestId);

// 4. Aggregate answers and pick winners
address[] memory winners = new address[](2);
winners[0] = winningAgent1;
winners[1] = winningAgent2;
oracle.aggregate(requestId, bytes("4500"), winners, bytes("Majority consensus"));

// 5. Trigger distribution
oracle.distributeRewards(requestId);
```

## Economic Model

### Reward Distribution

| Recipient | Amount |
|-----------|--------|
| Judge | `judgeRewardBps` of reward (e.g., 10%) |
| Winners | Split remaining reward + all loser bonds |
| Losers | Lose their bond (slashed) |
| Requester | Any remainder from integer division |

### Example Scenario

```
Reward: 1 ETH
Agent Bond: 0.1 ETH each
Judge Reward: 10%

Agents: A (correct), B (correct), C (wrong)
Judge: J

Distribution:
├── Judge J:     0.1 ETH  (10% of 1 ETH)
├── Agent A:     0.55 ETH (0.9 ETH + 0.1 slashed) / 2 + bond back
├── Agent B:     0.55 ETH (same as A)
├── Agent C:     0 ETH    (bond slashed)
└── Total:       1.3 ETH  (1 ETH reward + 0.3 ETH bonds)
```

## Error Handling

The contract uses custom errors for gas-efficient reverts:

| Error | Cause |
|-------|-------|
| `NotFound` | Request ID doesn't exist |
| `BadPhase` | Action not allowed in current phase |
| `DeadlinePassed` | Commit/reveal deadline exceeded |
| `NotEnoughValue` | Insufficient ETH sent (for native ETH transfers) |
| `AlreadyCommitted` | Agent already committed to this request |
| `CommitmentMismatch` | Revealed answer doesn't match commitment |
| `NotJudge` | Caller is not the selected judge |
| `JudgeBondNotPosted` | Judge trying to aggregate without posting bond |
| `NoJudgesRegistered` | No judges available for selection |
| `TokenMismatch` | Sent ETH when using ERC20 tokens (or vice versa) |
| `RewardTransferFailed` | ERC20 reward transfer failed |
| `BondTransferFailed` | ERC20 bond transfer failed |

## Safety Features

### Timeout Protection

- **No Judge**: If no judge is selected by `judgeSignupDeadline`, anyone can call `refundIfNoJudge()` to return all funds
- **Judge Timeout**: If the judge doesn't aggregate by `judgeAggDeadline`, anyone can call `timeoutJudge()` to refund participants and slash the judge's bond

### Bond Slashing

- **Losing Agents**: Bonds redistributed to winners
- **Timed-out Judges**: Bond split among requester and revealed agents

## Project Structure

```
├── src/
│   └── AgentCouncilOracle.sol          # Main contract (ETH + ERC20 support)
├── script/
│   └── OracleDemo.s.sol                # Interactive demo (uses native ETH)
├── test/
│   └── AgentCouncilOracle.t.sol        # Edge case tests
├── foundry.toml                        # Foundry configuration
└── README.md
```

## Test Coverage

The test suite covers:

- ✅ Request creation validation (tokens, deadlines, values, parameters)
- ✅ Commit phase guards (timing, bonding, duplicates)
- ✅ Reveal phase guards (commitments, timing, ordering)
- ✅ Judge registration and selection
- ✅ Judge bond posting requirements
- ✅ Aggregation and winner selection
- ✅ Reward distribution (winners, losers, remainders)
- ✅ Timeout scenarios (no judge, judge timeout)
- ✅ Refund mechanisms

Run with coverage:

```bash
forge coverage
```

## Security Considerations

1. **Randomness**: Judge selection uses `blockhash(block.number - 1)` which is manipulable by miners. For high-value requests, consider using Chainlink VRF.

2. **Front-running**: The commit-reveal scheme prevents answer copying, but commit transactions themselves are visible in the mempool.

3. **ERC20 Tokens**: When using ERC20 tokens, ensure the token contract is trusted. Malicious or fee-on-transfer tokens may cause unexpected behavior. The contract assumes standard ERC20 behavior.

4. **Token Approvals**: Users must approve the oracle contract to spend their tokens before creating requests or committing with ERC20 bonds.

5. **Mixed Token Scenarios**: Rewards and bonds can use different tokens. Winners receive their share of rewards in `rewardToken` and slashed bonds in `bondToken`.

6. **Reentrancy**: The contract uses checks-effects-interactions pattern and should be safe, but has not been formally audited.

## License

MIT

## Contributing

Contributions are welcome! Please open an issue or submit a PR.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request
