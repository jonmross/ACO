// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TestAgentCouncilOracleNative.sol";

contract TestAgentCouncilOracleNative_EdgeCases is Test {
    TestAgentCouncilOracleNative oracle;

    address requester = address(0xA11CE);

    address agentA    = address(0xB0B);
    address agentB    = address(0xCA11);
    address agentC    = address(0xD00D);
    address agentD    = address(0xABCD); // extra

    // ✅ avoid Solidity 0.8.30 address-literal checksum rules
    address judge1    = address(uint160(0xBEEF));
    address judge2    = address(uint160(0xFEED));

    function setUp() public {
        oracle = new TestAgentCouncilOracleNative();

        // make balance asserts exact
        vm.txGasPrice(0);

        vm.deal(requester, 100 ether);
        vm.deal(agentA,    100 ether);
        vm.deal(agentB,    100 ether);
        vm.deal(agentC,    100 ether);
        vm.deal(agentD,    100 ether);
        vm.deal(judge1,    100 ether);
        vm.deal(judge2,    100 ether);
    }

    // -------- helpers --------

    function _emptyCaps() internal pure returns (IAgentCouncilOracle.AgentCapabilities memory caps) {
        string[] memory empty;
        caps = IAgentCouncilOracle.AgentCapabilities({capabilities: empty, domains: empty});
    }

    function _commitHash(bytes memory answer, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(answer, nonce));
    }

    function _createReq(
        uint256 numAgents,
        uint256 reward,
        uint256 bond,
        uint256 commitDeadline
    ) internal returns (uint256 id) {
        vm.prank(requester);
        id = oracle.createRequest{value: reward}(
            "Q",
            numAgents,
            reward,
            bond,
            commitDeadline,
            address(0),
            address(0),
            "SPEC",
            _emptyCaps()
        );
    }

    function _reachReveal_2Agents(uint256 reward, uint256 bond) internal returns (uint256 id, uint256 deadline) {
        deadline = block.timestamp + 1 hours;
        id = _createReq(2, reward, bond, deadline);

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(bytes("a"), 1));

        vm.prank(agentB);
        oracle.commit{value: bond}(id, _commitHash(bytes("b"), 2));

        // after 2nd commit, phase becomes Reveal
    }

    function _reachAwaitingJudge_1Agent(uint256 reward, uint256 bond) internal returns (uint256 id, uint256 deadline) {
        deadline = block.timestamp + 1 hours;
        id = _createReq(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 123;

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(ans, nonce));

        vm.prank(agentA);
        oracle.reveal(id, ans, nonce); // 1 agent => AwaitingJudge now
    }

    function _reachAwaitingJudge_2Agents_AllReveal(uint256 reward, uint256 bond)
        internal
        returns (uint256 id, uint256 deadline)
    {
        (id, deadline) = _reachReveal_2Agents(reward, bond);

        vm.prank(agentA);
        oracle.reveal(id, bytes("a"), 1);

        vm.prank(agentB);
        oracle.reveal(id, bytes("b"), 2);
        // all revealed => AwaitingJudge
    }

    function _reachJudging_SelectSingleJudge_1Agent(uint256 reward, uint256 bond)
        internal
        returns (uint256 id, uint256 deadline)
    {
        (id, deadline) = _reachAwaitingJudge_1Agent(reward, bond);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(id);

        oracle.selectJudge(id); // only judge1 registered => judge1 will be selected
    }

// small array helpers
function _asArray(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
}

function _asArray2(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
}


    // -------- createRequest edge cases --------

    function test_RevertCreateRequest_TokenNotSupported() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(requester);
        vm.expectRevert(TestAgentCouncilOracleNative.TokenNotSupported.selector);
        oracle.createRequest{value: 1 ether}(
            "q",
            1,
            1 ether,
            0.1 ether,
            deadline,
            address(0x1234),
            address(0),
            "spec",
            _emptyCaps()
        );
    }

    function test_RevertCreateRequest_NumInfoAgentsZero() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(requester);
        vm.expectRevert(TestAgentCouncilOracleNative.TooManyAgents.selector); // used for numInfoAgents==0 in this contract
        oracle.createRequest{value: 1 ether}(
            "q",
            0,
            1 ether,
            0.1 ether,
            deadline,
            address(0),
            address(0),
            "spec",
            _emptyCaps()
        );
    }

    function test_RevertCreateRequest_DeadlinePassed() public {
        uint256 deadline = block.timestamp; // <= now

        vm.prank(requester);
        vm.expectRevert(TestAgentCouncilOracleNative.DeadlinePassed.selector);
        oracle.createRequest{value: 1 ether}(
            "q",
            1,
            1 ether,
            0.1 ether,
            deadline,
            address(0),
            address(0),
            "spec",
            _emptyCaps()
        );
    }

    function test_RevertCreateRequest_NotEnoughValue() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(requester);
        vm.expectRevert(TestAgentCouncilOracleNative.NotEnoughValue.selector);
        oracle.createRequest{value: 0.5 ether}(
            "q",
            1,
            1 ether,
            0.1 ether,
            deadline,
            address(0),
            address(0),
            "spec",
            _emptyCaps()
        );
    }

    function test_CreateRequestV2_Revert_BadJudgeDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 revealDeadline = deadline + oracle.REVEAL_WINDOW();

        // judgeSignupDeadline <= now
        {
            TestAgentCouncilOracleNative.CreateRequestV2Params memory p;
            p.query = "q";
            p.numInfoAgents = 1;
            p.rewardAmount = 1 ether;
            p.bondAmount = 0.1 ether;
            p.deadline = deadline;
            p.judgeSignupDeadline = block.timestamp; // invalid
            p.rewardToken = address(0);
            p.bondToken = address(0);
            p.specifications = "spec";
            p.requiredCapabilities = _emptyCaps();

            vm.prank(requester);
            vm.expectRevert(TestAgentCouncilOracleNative.BadJudgeDeadline.selector);
            oracle.createRequestV2{value: 1 ether}(p);
        }

        // judgeSignupDeadline < revealDeadline
        {
            TestAgentCouncilOracleNative.CreateRequestV2Params memory p;
            p.query = "q";
            p.numInfoAgents = 1;
            p.rewardAmount = 1 ether;
            p.bondAmount = 0.1 ether;
            p.deadline = deadline;
            p.judgeSignupDeadline = revealDeadline - 1; // invalid
            p.rewardToken = address(0);
            p.bondToken = address(0);
            p.specifications = "spec";
            p.requiredCapabilities = _emptyCaps();

            vm.prank(requester);
            vm.expectRevert(TestAgentCouncilOracleNative.BadJudgeDeadline.selector);
            oracle.createRequestV2{value: 1 ether}(p);
        }
    }

    // -------- commit edge cases --------

    function test_RevertCommit_NotFound() public {
        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.NotFound.selector);
        oracle.commit{value: 0.1 ether}(999, bytes32(uint256(1)));
    }

    function test_RevertCommit_DeadlinePassed() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 10;

        uint256 id = _createReq(2, reward, bond, deadline);

        vm.warp(deadline);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.DeadlinePassed.selector);
        oracle.commit{value: bond}(id, bytes32(uint256(1)));
    }

    function test_RevertCommit_NotEnoughValue() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(2, reward, bond, deadline);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.NotEnoughValue.selector);
        oracle.commit{value: bond - 1}(id, bytes32(uint256(1)));
    }

    function test_RevertCommit_AlreadyCommitted() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(2, reward, bond, deadline);

        vm.prank(agentA);
        oracle.commit{value: bond}(id, bytes32(uint256(1)));

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.AlreadyCommitted.selector);
        oracle.commit{value: bond}(id, bytes32(uint256(2)));
    }

    function test_RevertCommit_BadPhase_AfterPhaseBecomesReveal() public {
        (uint256 id,) = _reachReveal_2Agents(1 ether, 0.25 ether);

        // now phase is Reveal; further commit hits BadPhase (not TooManyAgents)
        vm.prank(agentC);
        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.commit{value: 0.25 ether}(id, bytes32(uint256(3)));
    }

    function test_RevertCommit_JudgeCannotCommit() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;

        (uint256 id,) = _reachAwaitingJudge_1Agent(reward, bond);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(id);

        vm.prank(judge1);
        vm.expectRevert(TestAgentCouncilOracleNative.JudgeCannotCommit.selector);
        oracle.commit{value: bond}(id, bytes32(uint256(1)));
    }

    // -------- reveal edge cases --------

    function test_Reveal_AfterCommitDeadline_NoCommits_BecomesRevealThenNotCommitted() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 10;

        uint256 id = _createReq(1, reward, bond, deadline);

        // No commits, but warp >= deadline so reveal() will flip Commit->Reveal internally
        vm.warp(deadline);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.NotCommitted.selector);
        oracle.reveal(id, bytes("a"), 1);
    }

    function test_RevertReveal_NotCommitted_TwoAgents() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(2, reward, bond, deadline);

        // force phase to Reveal by having 2 commits from OTHER people
        vm.prank(agentB);
        oracle.commit{value: bond}(id, _commitHash(bytes("b"), 2));
        vm.prank(agentC);
        oracle.commit{value: bond}(id, _commitHash(bytes("c"), 3));

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.NotCommitted.selector);
        oracle.reveal(id, bytes("a"), 1);
    }

    function test_RevertReveal_AlreadyRevealed_OneAgent_BecomesBadPhase() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 7;

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(ans, nonce));

        vm.prank(agentA);
        oracle.reveal(id, ans, nonce);

        // now phase is AwaitingJudge => second reveal hits BadPhase
        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.reveal(id, ans, nonce);
    }

    function test_RevertReveal_AlreadyRevealed_TwoAgents_HitsAlreadyRevealed() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(2, reward, bond, deadline);

        bytes memory ansA = bytes("four");
        uint256 nonceA = 7;

        bytes memory ansB = bytes("also four");
        uint256 nonceB = 8;

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(ansA, nonceA));

        vm.prank(agentB);
        oracle.commit{value: bond}(id, _commitHash(ansB, nonceB));

        vm.prank(agentA);
        oracle.reveal(id, ansA, nonceA);

        // still in Reveal phase (because B hasn't revealed yet)
        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.AlreadyRevealed.selector);
        oracle.reveal(id, ansA, nonceA);
    }

    function test_RevertReveal_CommitmentMismatch() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 7;

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(ans, nonce));

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.CommitmentMismatch.selector);
        oracle.reveal(id, ans, nonce + 1);
    }

    function test_RevertReveal_DeadlinePassed_AfterRevealWindow() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 id = _createReq(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 7;

        vm.prank(agentA);
        oracle.commit{value: bond}(id, _commitHash(ans, nonce));

        uint256 revealDeadline = deadline + oracle.REVEAL_WINDOW();
        vm.warp(revealDeadline + 1);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.DeadlinePassed.selector);
        oracle.reveal(id, ans, nonce);
    }

    // -------- closeReveals edge cases --------

    function test_RevertCloseReveals_BadPhase_WhenCommit() public {
        uint256 id = _createReq(2, 1 ether, 0.25 ether, block.timestamp + 1 hours);

        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.closeReveals(id);
    }

    function test_RevertCloseReveals_RevealsStillOpen() public {
        (uint256 id, uint256 deadline) = _reachReveal_2Agents(1 ether, 0.25 ether);

        // only one reveal, and not past reveal deadline
        vm.prank(agentA);
        oracle.reveal(id, bytes("a"), 1);

        // not ended yet
        vm.warp(deadline + oracle.REVEAL_WINDOW() - 1);

        vm.expectRevert(TestAgentCouncilOracleNative.RevealsStillOpen.selector);
        oracle.closeReveals(id);
    }

    function test_CloseReveals_Succeeds_WhenWindowEnded() public {
        (uint256 id, uint256 deadline) = _reachReveal_2Agents(1 ether, 0.25 ether);

        // only one reveal
        vm.prank(agentA);
        oracle.reveal(id, bytes("a"), 1);

        // after reveal window ends
        vm.warp(deadline + oracle.REVEAL_WINDOW() + 1);

        oracle.closeReveals(id); // should succeed (moves to AwaitingJudge)
    }

    // -------- judge registration / selection edge cases --------

    function test_RevertRegisterJudge_BadPhase() public {
        uint256 id = _createReq(1, 1 ether, 0.25 ether, block.timestamp + 1 hours);

        vm.prank(judge1);
        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.registerJudgeForRequest(id);
    }

    function test_RevertRegisterJudge_JudgeAlreadyRegistered() public {
        (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(id);

        vm.prank(judge1);
        vm.expectRevert(TestAgentCouncilOracleNative.JudgeAlreadyRegistered.selector);
        oracle.registerJudgeForRequest(id);
    }

    function test_UnregisterJudge_NoOp_WhenNotRegistered() public {
        (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        vm.prank(judge1);
        oracle.unregisterJudgeForRequest(id);

        assertEq(oracle.judgeCount(id), 0);
    }

    function test_RevertSelectJudge_NoJudgesRegistered() public {
        (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        vm.expectRevert(TestAgentCouncilOracleNative.NoJudgesRegistered.selector);
        oracle.selectJudge(id);
    }

    function test_RevertSelectJudge_BadPhase() public {
        uint256 id = _createReq(1, 1 ether, 0.25 ether, block.timestamp + 1 hours);

        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.selectJudge(id);
    }

    // -------- aggregate edge cases --------

    function test_RevertAggregate_BadPhase() public {
        (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        // still AwaitingJudge (no selectJudge yet)
        vm.prank(judge1);
        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("reasoning"));
    }

function test_RevertAggregate_NotJudge() public {
    (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

    vm.prank(judge1);
    oracle.registerJudgeForRequest(id);

    oracle.selectJudge(id);

    vm.prank(agentB);
    vm.expectRevert(TestAgentCouncilOracleNative.NotJudge.selector);
    oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("reasoning"));
}

function test_RevertAggregate_AlreadyFinalized() public {
    (uint256 id,) = _reachJudging_SelectSingleJudge_1Agent(1 ether, 0.25 ether);

    vm.prank(judge1);
    oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("reasoning"));

    vm.prank(judge1);
    vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);  // Changed from AlreadyFinalized
    oracle.aggregate(id, bytes("final2"), _asArray(agentA), bytes("reasoning2"));
}

function test_Aggregate_NoQuorum_FailsAndCannotDistribute() public {
    uint256 reward = 1 ether;
    uint256 bond   = 0.25 ether;
    uint256 deadline = block.timestamp + 1 hours;
    uint256 revealDeadline = deadline + oracle.REVEAL_WINDOW();
    uint256 judgeSignupDeadline = revealDeadline + 1 hours; // Extra time for judge signup

    // Use createRequestV2 with custom judge signup deadline
    TestAgentCouncilOracleNative.CreateRequestV2Params memory p;
    p.query = "Q";
    p.numInfoAgents = 3;
    p.rewardAmount = reward;
    p.bondAmount = bond;
    p.deadline = deadline;
    p.judgeSignupDeadline = judgeSignupDeadline;
    p.rewardToken = address(0);
    p.bondToken = address(0);
    p.specifications = "SPEC";
    p.requiredCapabilities = _emptyCaps();

    vm.prank(requester);
    uint256 id = oracle.createRequestV2{value: reward}(p);

    // All 3 agents commit
    vm.prank(agentA);
    oracle.commit{value: bond}(id, _commitHash(bytes("a"), 1));
    vm.prank(agentB);
    oracle.commit{value: bond}(id, _commitHash(bytes("b"), 2));
    vm.prank(agentC);
    oracle.commit{value: bond}(id, _commitHash(bytes("c"), 3));

    // Only 1 reveal (no quorum)
    vm.prank(agentA);
    oracle.reveal(id, bytes("a"), 1);

    // Warp past reveal window but before judge signup deadline
    vm.warp(revealDeadline + 1);
    oracle.closeReveals(id);

    // Now we can register judge (still before judgeSignupDeadline)
    vm.prank(judge1);
    oracle.registerJudgeForRequest(id);

    oracle.selectJudge(id);

    vm.prank(judge1);
    oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("no quorum"));

    (, bool finalized) = oracle.getResolution(id);
    assertEq(finalized, false);

    vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
    oracle.distributeRewards(id);
}

    function test_Aggregate_AllowsWinnerNotInCommits_PaysThemAnyway() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;

        (uint256 id,) = _reachJudging_SelectSingleJudge_1Agent(reward, bond);

        // choose agentD who never committed as winner (current contract allows this)
        vm.prank(judge1);
        oracle.aggregate(id, bytes("final"), _asArray(agentD), bytes("weird winner"));

        uint256 dBefore = agentD.balance;
        oracle.distributeRewards(id);
        assertGt(agentD.balance, dBefore);
    }

    // -------- distributeRewards edge cases --------

    function test_RevertDistributeRewards_BadPhase_WhenNotFinalized() public {
        (uint256 id,) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.distributeRewards(id);
    }

    function test_DistributeRewards_Revert_AlreadyDistributed() public {
        (uint256 id,) = _reachJudging_SelectSingleJudge_1Agent(1 ether, 0.25 ether);

        vm.prank(judge1);
        oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("reasoning"));

        oracle.distributeRewards(id);

        vm.expectRevert(TestAgentCouncilOracleNative.AlreadyDistributed.selector);
        oracle.distributeRewards(id);
    }

    function test_DistributeRewards_NoWinners_LeavesFundsInContract_CurrentBehavior() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;

        (uint256 id,) = _reachJudging_SelectSingleJudge_1Agent(reward, bond);

        // finalize with empty winners list
        vm.prank(judge1);
        oracle.aggregate(id, bytes("final"), new address[](0), bytes("no winners"));

        uint256 heldBefore = address(oracle).balance;
        oracle.distributeRewards(id);

        // current implementation sets Failed and returns without refunding
        assertEq(address(oracle).balance, heldBefore);
    }

    // -------- refundIfNoJudge edge cases --------

    function test_RevertRefundIfNoJudge_BadPhase() public {
        uint256 id = _createReq(1, 1 ether, 0.25 ether, block.timestamp + 1 hours);

        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.refundIfNoJudge(id);
    }

    function test_RevertRefundIfNoJudge_TooEarly() public {
        (uint256 id, uint256 deadline) = _reachAwaitingJudge_1Agent(1 ether, 0.25 ether);

        uint256 signup = oracle.getJudgeSignupDeadline(id);
        assertEq(signup, deadline + oracle.REVEAL_WINDOW());

        vm.warp(signup - 1);
        vm.expectRevert(TestAgentCouncilOracleNative.TooEarly.selector);
        oracle.refundIfNoJudge(id);
    }

function test_RefundIfNoJudge_RefundsRewardAndBonds() public {
    uint256 reward = 1 ether;
    uint256 bond   = 0.25 ether;

    // Capture balances BEFORE creating the request
    uint256 reqInitial = requester.balance;
    uint256 aInitial = agentA.balance;
    uint256 bInitial = agentB.balance;

    (uint256 id, uint256 deadline) = _reachAwaitingJudge_2Agents_AllReveal(reward, bond);

    uint256 signup = oracle.getJudgeSignupDeadline(id);
    assertEq(signup, deadline + oracle.REVEAL_WINDOW());

    vm.warp(signup + 1);
    oracle.refundIfNoJudge(id);

    // After refund, everyone should be back to initial balances
    assertEq(requester.balance, reqInitial);
    assertEq(agentA.balance, aInitial);
    assertEq(agentB.balance, bInitial);
    assertEq(address(oracle).balance, 0);
}
    // -------- NotFound getter guards --------

    function test_Getters_Revert_NotFound() public {
        vm.expectRevert(TestAgentCouncilOracleNative.NotFound.selector);
        oracle.getRequest(999);

        vm.expectRevert(TestAgentCouncilOracleNative.NotFound.selector);
        oracle.getCommits(999);

        vm.expectRevert(TestAgentCouncilOracleNative.NotFound.selector);
        oracle.getReveals(999);

        vm.expectRevert(TestAgentCouncilOracleNative.NotFound.selector);
        oracle.getResolution(999);
    }
}
