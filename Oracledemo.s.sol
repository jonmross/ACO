// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/TestAgentCouncilOracleNative.sol";

/**
 * @title OracleDemo
 * @notice Interactive demonstration of the Agent Council Oracle
 * 
 * Run with: forge script script/OracleDemo.s.sol -vvvv
 * 
 * This script walks through a complete oracle request lifecycle:
 * 1. Create a request with reward and bond requirements
 * 2. Agents commit their answers (hashed)
 * 3. Agents reveal their answers
 * 4. Judges register for the request
 * 5. A judge is randomly selected
 * 6. Judge posts bond and aggregates the final answer
 * 7. Rewards are distributed to winners
 */
contract OracleDemo is Script {
    TestAgentCouncilOracleNative oracle;

    // Participants
    address requester;
    address agentA;
    address agentB;
    address agentC;
    address judge1;
    address judge2;
    address judge3;

    // Request parameters
    uint256 reward = 1 ether;
    uint256 agentBond = 0.1 ether;
    uint256 judgeBondAmt = 0.1 ether;
    uint256 numAgents = 3;

    // Track initial balances for change calculation
    uint256 requesterInitial;
    uint256 agentAInitial;
    uint256 agentBInitial;
    uint256 agentCInitial;
    uint256 judge1Initial;
    uint256 judge2Initial;
    uint256 judge3Initial;

    function run() public {
        // Setup accounts
        requester = makeAddr("requester");
        agentA = makeAddr("agentA");
        agentB = makeAddr("agentB");
        agentC = makeAddr("agentC");
        judge1 = makeAddr("judge1");
        judge2 = makeAddr("judge2");
        judge3 = makeAddr("judge3");

        // Fund accounts
        vm.deal(requester, 10 ether);
        vm.deal(agentA, 10 ether);
        vm.deal(agentB, 10 ether);
        vm.deal(agentC, 10 ether);
        vm.deal(judge1, 10 ether);
        vm.deal(judge2, 10 ether);
        vm.deal(judge3, 10 ether);

        // Store initial balances
        requesterInitial = requester.balance;
        agentAInitial = agentA.balance;
        agentBInitial = agentB.balance;
        agentCInitial = agentC.balance;
        judge1Initial = judge1.balance;
        judge2Initial = judge2.balance;
        judge3Initial = judge3.balance;

        console.log("");
        console.log("==============================================");
        console.log("   AGENT COUNCIL ORACLE - FULL DEMO");
        console.log("==============================================");
        console.log("");

        // Deploy oracle
        oracle = new TestAgentCouncilOracleNative();
        console.log("Oracle deployed at:", address(oracle));
        console.log("");

        // Print participant addresses
        console.log("PARTICIPANTS:");
        console.log("  Requester:", requester);
        console.log("  Agent A:  ", agentA);
        console.log("  Agent B:  ", agentB);
        console.log("  Agent C:  ", agentC);
        console.log("  Judge 1:  ", judge1);
        console.log("  Judge 2:  ", judge2);
        console.log("  Judge 3:  ", judge3);
        console.log("");

        // Print initial balances
        _printBalances("INITIAL BALANCES");

        // Step 1: Create request
        uint256 requestId = _step1_createRequest();

        // Step 2: Agents commit
        _step2_agentsCommit(requestId);

        // Step 3: Agents reveal
        _step3_agentsReveal(requestId);

        // Step 4: Judges register
        _step4_judgesRegister(requestId);

        // Step 5: Select judge
        address selectedJudge = _step5_selectJudge(requestId);

        // Step 6: Judge posts bond and aggregates
        _step6_judgeAggregates(requestId, selectedJudge);

        // Step 7: Distribute rewards
        _step7_distributeRewards(requestId);

        // Final state
        _printFinalState(requestId);
        _printBalances("FINAL BALANCES");
        _printBalanceChanges();

        console.log("");
        console.log("==============================================");
        console.log("   DEMO COMPLETE!");
        console.log("==============================================");
    }

    function _step1_createRequest() internal returns (uint256 requestId) {
        console.log("----------------------------------------------");
        console.log("STEP 1: CREATE REQUEST");
        console.log("----------------------------------------------");
        console.log("");

        uint256 deadline = block.timestamp + 1 hours;
        uint256 revealWindow = 1 hours;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 hours;
        uint256 judgeAggWindow = 1 hours;
        uint16 judgeRewardBps = 1000; // 10%

        console.log("Request parameters:");
        console.log("  Query: 'What is 2 + 2?'");
        _logEther("  Reward: ", reward);
        _logEther("  Agent bond: ", agentBond);
        _logEther("  Judge bond: ", judgeBondAmt);
        console.log("  Num agents:", numAgents);
        console.log("  Judge reward: 10% of reward pool");
        console.log("");

        IAgentCouncilOracle.CreateRequestParams memory p;
        p.query = "What is 2 + 2?";
        p.numInfoAgents = numAgents;
        p.rewardAmount = reward;
        p.bondAmount = agentBond;
        p.deadline = deadline;
        p.judgeSignupDeadline = judgeSignupDeadline;
        p.revealWindow = revealWindow;
        p.judgeBondAmount = judgeBondAmt;
        p.judgeAggWindow = judgeAggWindow;
        p.judgeRewardBps = judgeRewardBps;
        p.rewardToken = address(0);
        p.bondToken = address(0);
        p.specifications = "Return a single integer";
        
        string[] memory empty = new string[](0);
        p.requiredCapabilities = IAgentCouncilOracle.AgentCapabilities({
            capabilities: empty,
            domains: empty
        });

        vm.prank(requester);
        requestId = oracle.createRequest{value: reward}(p);

        console.log(">>> Request created! ID:", requestId);
        _logEther(">>> Requester deposited ", reward);
        console.log("");
    }

    function _step2_agentsCommit(uint256 requestId) internal {
        console.log("----------------------------------------------");
        console.log("STEP 2: AGENTS COMMIT (HASHED ANSWERS)");
        console.log("----------------------------------------------");
        console.log("");

        // Agent A commits "4" (correct)
        bytes memory answerA = bytes("4");
        uint256 nonceA = 111;
        bytes32 commitA = keccak256(abi.encode(answerA, nonceA));
        
        console.log("Agent A committing...");
        console.log("  Address:", agentA);
        console.log("  Answer: '4' (hidden)");
        console.log("  Nonce:", nonceA);
        console.log("  Commitment hash:", vm.toString(commitA));
        
        vm.prank(agentA);
        oracle.commit{value: agentBond}(requestId, commitA);
        _logEther("  >>> Committed! Bond deposited: ", agentBond);
        console.log("");

        // Agent B commits "4" (correct)
        bytes memory answerB = bytes("4");
        uint256 nonceB = 222;
        bytes32 commitB = keccak256(abi.encode(answerB, nonceB));
        
        console.log("Agent B committing...");
        console.log("  Address:", agentB);
        console.log("  Answer: '4' (hidden)");
        console.log("  Nonce:", nonceB);
        console.log("  Commitment hash:", vm.toString(commitB));
        
        vm.prank(agentB);
        oracle.commit{value: agentBond}(requestId, commitB);
        _logEther("  >>> Committed! Bond deposited: ", agentBond);
        console.log("");

        // Agent C commits "5" (WRONG!)
        bytes memory answerC = bytes("5");
        uint256 nonceC = 333;
        bytes32 commitC = keccak256(abi.encode(answerC, nonceC));
        
        console.log("Agent C committing...");
        console.log("  Address:", agentC);
        console.log("  Answer: '5' (hidden) <-- WRONG ANSWER!");
        console.log("  Nonce:", nonceC);
        console.log("  Commitment hash:", vm.toString(commitC));
        
        vm.prank(agentC);
        oracle.commit{value: agentBond}(requestId, commitC);
        _logEther("  >>> Committed! Bond deposited: ", agentBond);
        console.log("");

        // Check commits
        (address[] memory agents, bytes32[] memory hashes) = oracle.getCommits(requestId);
        console.log("Total commits:", agents.length);
        console.log("Committed agents:");
        for (uint256 i = 0; i < agents.length; i++) {
            console.log("  ", agents[i]);
        }
        console.log("");
        console.log(">>> Phase automatically transitioned to REVEAL (all slots filled)");
        console.log("");
    }

    function _step3_agentsReveal(uint256 requestId) internal {
        console.log("----------------------------------------------");
        console.log("STEP 3: AGENTS REVEAL ANSWERS");
        console.log("----------------------------------------------");
        console.log("");

        console.log("Agent A revealing...");
        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);
        console.log("  >>> Revealed: '4'");
        console.log("");

        console.log("Agent B revealing...");
        vm.prank(agentB);
        oracle.reveal(requestId, bytes("4"), 222);
        console.log("  >>> Revealed: '4'");
        console.log("");

        console.log("Agent C revealing...");
        vm.prank(agentC);
        oracle.reveal(requestId, bytes("5"), 333);
        console.log("  >>> Revealed: '5'");
        console.log("");

        // Show reveals
        (address[] memory agents, bytes[] memory answers) = oracle.getReveals(requestId);
        console.log("All reveals complete! Answers:");
        for (uint256 i = 0; i < agents.length; i++) {
            console.log("  ", agents[i], "->", string(answers[i]));
        }
        console.log("");
        console.log(">>> Phase transitioned to AWAITING_JUDGE");
        console.log("");
    }

    function _step4_judgesRegister(uint256 requestId) internal {
        console.log("----------------------------------------------");
        console.log("STEP 4: JUDGES REGISTER");
        console.log("----------------------------------------------");
        console.log("");

        console.log("Judge 1 registering...");
        console.log("  Address:", judge1);
        vm.prank(judge1);
        oracle.registerJudgeForRequest(requestId);
        console.log("  >>> Registered!");
        console.log("");

        console.log("Judge 2 registering...");
        console.log("  Address:", judge2);
        vm.prank(judge2);
        oracle.registerJudgeForRequest(requestId);
        console.log("  >>> Registered!");
        console.log("");

        console.log("Judge 3 registering...");
        console.log("  Address:", judge3);
        vm.prank(judge3);
        oracle.registerJudgeForRequest(requestId);
        console.log("  >>> Registered!");
        console.log("");

        uint256 count = oracle.judgeCount(requestId);
        console.log("Total judges registered:", count);
        console.log("");

        console.log("Judge pool:");
        for (uint256 i = 0; i < count; i++) {
            address j = oracle.getJudgeAt(requestId, i);
            console.log("  [", i, "]", j);
        }
        console.log("");
    }

    function _step5_selectJudge(uint256 requestId) internal returns (address selectedJudge) {
        console.log("----------------------------------------------");
        console.log("STEP 5: SELECT JUDGE (RANDOM)");
        console.log("----------------------------------------------");
        console.log("");

        console.log("Selecting judge using on-chain randomness...");
        console.log("  Block number:", block.number);
        console.log("");

        // Advance block to get fresh randomness
        vm.roll(block.number + 1);

        oracle.selectJudge(requestId);

        console.log(">>> Judge selection complete!");
        console.log("");
        
        // Try to identify selected judge by attempting postJudgeBond
        // (only the selected judge can do this)
        
        vm.prank(judge1);
        try oracle.postJudgeBond{value: judgeBondAmt}(requestId) {
            selectedJudge = judge1;
            console.log(">>> SELECTED: Judge 1");
            console.log("    Address:", judge1);
        } catch {
            vm.prank(judge2);
            try oracle.postJudgeBond{value: judgeBondAmt}(requestId) {
                selectedJudge = judge2;
                console.log(">>> SELECTED: Judge 2");
                console.log("    Address:", judge2);
            } catch {
                vm.prank(judge3);
                oracle.postJudgeBond{value: judgeBondAmt}(requestId);
                selectedJudge = judge3;
                console.log(">>> SELECTED: Judge 3");
                console.log("    Address:", judge3);
            }
        }
        
        _logEther(">>> Judge bond posted: ", judgeBondAmt);
        console.log("");
        console.log(">>> Phase transitioned to JUDGING");
        console.log("");
    }

    function _step6_judgeAggregates(uint256 requestId, address selectedJudge) internal {
        console.log("----------------------------------------------");
        console.log("STEP 6: JUDGE AGGREGATES ANSWERS");
        console.log("----------------------------------------------");
        console.log("");

        console.log("Judge reviewing answers:");
        console.log("  Agent A:", agentA, "-> '4'");
        console.log("  Agent B:", agentB, "-> '4'");
        console.log("  Agent C:", agentC, "-> '5'");
        console.log("");
        console.log("Judge decision:");
        console.log("  Final answer: '4' (majority)");
        console.log("  Winners: Agent A, Agent B");
        console.log("  Losers: Agent C (bond will be slashed)");
        console.log("");

        address[] memory winners = new address[](2);
        winners[0] = agentA;
        winners[1] = agentB;

        console.log("Winners array being submitted:");
        console.log("  [0]:", winners[0]);
        console.log("  [1]:", winners[1]);
        console.log("");

        vm.prank(selectedJudge);
        oracle.aggregate(
            requestId,
            bytes("4"),
            winners,
            bytes("Majority answered '4'. Agent C's answer '5' is incorrect.")
        );

        console.log(">>> Aggregation complete!");
        console.log(">>> Phase transitioned to FINALIZED");
        console.log("");
    }

    function _step7_distributeRewards(uint256 requestId) internal {
        console.log("----------------------------------------------");
        console.log("STEP 7: DISTRIBUTE REWARDS");
        console.log("----------------------------------------------");
        console.log("");

        uint256 judgeCut = reward * 10 / 100; // 10%
        uint256 remainingReward = reward - judgeCut;
        uint256 loserBonds = agentBond; // Just Agent C
        uint256 totalPool = remainingReward + loserBonds;
        uint256 perWinner = totalPool / 2;

        console.log("Calculating distribution:");
        _logEther("  Total reward pool: ", reward);
        _logEther("  Judge cut (10%): ", judgeCut);
        _logEther("  Remaining for winners: ", remainingReward);
        _logEther("  Loser bond (Agent C): ", loserBonds);
        _logEther("  Total to distribute to winners: ", totalPool);
        _logEther("  Per winner (2 winners): ", perWinner);
        console.log("");
        
        console.log("Expected payouts:");
        _logEther("  Agent A: bond back + ", perWinner);
        _logEther("  Agent B: bond back + ", perWinner);
        console.log("  Agent C: loses bond (0)");
        _logEther("  Judge: ", judgeCut);
        console.log("");

        // Capture balances before distribution
        uint256 agentABefore = agentA.balance;
        uint256 agentBBefore = agentB.balance;
        uint256 agentCBefore = agentC.balance;
        uint256 judgeBefore;
        
        // Find which judge was selected
        if (judge1.balance < judge1Initial) {
            judgeBefore = judge1.balance;
        } else if (judge2.balance < judge2Initial) {
            judgeBefore = judge2.balance;
        } else {
            judgeBefore = judge3.balance;
        }

        oracle.distributeRewards(requestId);

        console.log(">>> Rewards distributed!");
        console.log("");
        
        // Show actual changes
        console.log("Actual payouts received:");
        _logEther("  Agent A received: ", agentA.balance - agentABefore);
        _logEther("  Agent B received: ", agentB.balance - agentBBefore);
        _logEther("  Agent C received: ", agentC.balance - agentCBefore);
        console.log("");
        
        console.log(">>> Phase transitioned to DISTRIBUTED");
        console.log("");
    }

    function _printFinalState(uint256 requestId) internal view {
        console.log("----------------------------------------------");
        console.log("FINAL RESOLUTION STATE");
        console.log("----------------------------------------------");
        console.log("");

        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        console.log("Finalized:", finalized);
        console.log("Final Answer:", string(finalAnswer));
        console.log("");
    }

    function _printBalances(string memory header) internal view {
        console.log("----------------------------------------------");
        console.log(header);
        console.log("----------------------------------------------");
        _logEther("  Requester: ", requester.balance);
        _logEther("  Agent A:   ", agentA.balance);
        _logEther("  Agent B:   ", agentB.balance);
        _logEther("  Agent C:   ", agentC.balance);
        _logEther("  Judge 1:   ", judge1.balance);
        _logEther("  Judge 2:   ", judge2.balance);
        _logEther("  Judge 3:   ", judge3.balance);
        _logEther("  Oracle:    ", address(oracle).balance);
        console.log("");
    }

    function _printBalanceChanges() internal view {
        console.log("----------------------------------------------");
        console.log("BALANCE CHANGES SUMMARY");
        console.log("----------------------------------------------");
        
        _logChange("  Requester: ", requester.balance, requesterInitial, "(paid reward)");
        _logChange("  Agent A:   ", agentA.balance, agentAInitial, "(WINNER!)");
        _logChange("  Agent B:   ", agentB.balance, agentBInitial, "(WINNER!)");
        _logChange("  Agent C:   ", agentC.balance, agentCInitial, "(LOSER - bond slashed)");
        _logChange("  Judge 1:   ", judge1.balance, judge1Initial, "");
        _logChange("  Judge 2:   ", judge2.balance, judge2Initial, "");
        _logChange("  Judge 3:   ", judge3.balance, judge3Initial, "");
        console.log("");
    }

    // Helper to log ether values with decimals
    function _logEther(string memory prefix, uint256 value) internal pure {
        uint256 whole = value / 1 ether;
        uint256 decimal = (value % 1 ether) / 1e16; // 2 decimal places
        
        if (decimal == 0) {
            console.log(string(abi.encodePacked(prefix, _uint2str(whole), " ETH")));
        } else if (decimal < 10) {
            console.log(string(abi.encodePacked(prefix, _uint2str(whole), ".0", _uint2str(decimal), " ETH")));
        } else {
            console.log(string(abi.encodePacked(prefix, _uint2str(whole), ".", _uint2str(decimal), " ETH")));
        }
    }

    function _logChange(string memory prefix, uint256 current, uint256 initial, string memory suffix) internal pure {
        if (current >= initial) {
            uint256 gain = current - initial;
            uint256 whole = gain / 1 ether;
            uint256 decimal = (gain % 1 ether) / 1e16;
            
            if (decimal == 0) {
                console.log(string(abi.encodePacked(prefix, "+", _uint2str(whole), " ETH ", suffix)));
            } else if (decimal < 10) {
                console.log(string(abi.encodePacked(prefix, "+", _uint2str(whole), ".0", _uint2str(decimal), " ETH ", suffix)));
            } else {
                console.log(string(abi.encodePacked(prefix, "+", _uint2str(whole), ".", _uint2str(decimal), " ETH ", suffix)));
            }
        } else {
            uint256 loss = initial - current;
            uint256 whole = loss / 1 ether;
            uint256 decimal = (loss % 1 ether) / 1e16;
            
            if (decimal == 0) {
                console.log(string(abi.encodePacked(prefix, "-", _uint2str(whole), " ETH ", suffix)));
            } else if (decimal < 10) {
                console.log(string(abi.encodePacked(prefix, "-", _uint2str(whole), ".0", _uint2str(decimal), " ETH ", suffix)));
            } else {
                console.log(string(abi.encodePacked(prefix, "-", _uint2str(whole), ".", _uint2str(decimal), " ETH ", suffix)));
            }
        }
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
