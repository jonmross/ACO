// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TestAgentCouncilOracleNative.sol";

contract TestAgentCouncilOracleNative_Unit is Test {
    TestAgentCouncilOracleNative oracle;

    address requester = address(0xA11CE);
    address agentA    = address(0xB0B);
    address agentB    = address(0xCA11);
    address agentC    = address(0xD00D);

    // ✅ avoid Solidity 0.8.30 address-literal checksum rules
    address judge1    = address(uint160(0xBEEF));

    function setUp() public {
        oracle = new TestAgentCouncilOracleNative();

        vm.deal(requester, 100 ether);
        vm.deal(agentA,    100 ether);
        vm.deal(agentB,    100 ether);
        vm.deal(agentC,    100 ether);
        vm.deal(judge1,    100 ether);
    }

    // -------- helpers --------

    function _emptyCaps() internal pure returns (IAgentCouncilOracle.AgentCapabilities memory caps) {
        string[] memory empty;
        caps = IAgentCouncilOracle.AgentCapabilities({capabilities: empty, domains: empty});
    }

    function _createReq(
        uint256 numAgents,
        uint256 reward,
        uint256 bond,
        uint256 commitDeadline
    ) internal returns (uint256 id) {
        vm.prank(requester);
        id = oracle.createRequest{value: reward}(
            "What is 2+2?",
            numAgents,
            reward,
            bond,
            commitDeadline,
            address(0),
            address(0),
            "spec",
            _emptyCaps()
        );
    }

    function _commitHash(bytes memory answer, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(answer, nonce));
    }

    function _reachAwaitingJudge_1Agent(uint256 reward, uint256 bond) internal returns (uint256 id) {
        uint256 deadline = block.timestamp + 1 hours;
        id = _createReq(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 123;
        bytes32 h = _commitHash(ans, nonce);

        vm.prank(agentA);
        oracle.commit{value: bond}(id, h);

        vm.prank(agentA);
        oracle.reveal(id, ans, nonce);
    }

    // -------- createRequest guards --------

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
            address(0x1234), // non-zero rewardToken not supported
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
        oracle.createRequest{value: 0.5 ether}( // msg.value != rewardAmount
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

    // -------- commit guards --------

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

    function test_RevertCommit_JudgeCannotCommit() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;

        uint256 id = _reachAwaitingJudge_1Agent(reward, bond);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(id);

        vm.prank(judge1);
        vm.expectRevert(TestAgentCouncilOracleNative.JudgeCannotCommit.selector);
        oracle.commit{value: bond}(id, bytes32(uint256(1)));
    }

    // -------- reveal guards --------

    function test_RevertReveal_NotCommitted() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 deadline = block.timestamp + 10;

        uint256 id = _createReq(1, reward, bond, deadline);

        vm.warp(deadline);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.NotCommitted.selector);
        oracle.reveal(id, bytes("a"), 1);
    }

function test_RevertReveal_AlreadyRevealed_OneAgent_BecomesBadPhase() public {
    uint256 reward = 1 ether;
    uint256 bond   = 0.25 ether;
    uint256 deadline = block.timestamp + 1 hours;

    // 1 agent => after first reveal, phase becomes AwaitingJudge
    uint256 id = _createReq(1, reward, bond, deadline);

    bytes memory ans = bytes("four");
    uint256 nonce = 7;
    bytes32 h = _commitHash(ans, nonce);

    vm.prank(agentA);
    oracle.commit{value: bond}(id, h);

    vm.prank(agentA);
    oracle.reveal(id, ans, nonce);

    // second reveal attempt hits BadPhase() first
    vm.prank(agentA);
    vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
    oracle.reveal(id, ans, nonce);
}

function test_RevertReveal_AlreadyRevealed_TwoAgents_HitsAlreadyRevealed() public {
    uint256 reward = 1 ether;
    uint256 bond   = 0.25 ether;
    uint256 deadline = block.timestamp + 1 hours;

    // 2 agents => after A reveals, phase stays Reveal until B reveals (or window closes)
    uint256 id = _createReq(2, reward, bond, deadline);

    bytes memory ansA = bytes("four");
    uint256 nonceA = 7;
    bytes32 hA = _commitHash(ansA, nonceA);

    bytes memory ansB = bytes("also four");
    uint256 nonceB = 8;
    bytes32 hB = _commitHash(ansB, nonceB);

    vm.prank(agentA);
    oracle.commit{value: bond}(id, hA);

    vm.prank(agentB);
    oracle.commit{value: bond}(id, hB);

    vm.prank(agentA);
    oracle.reveal(id, ansA, nonceA);

    // second reveal attempt now reaches AlreadyRevealed()
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
        bytes32 h = _commitHash(ans, nonce);

        vm.prank(agentA);
        oracle.commit{value: bond}(id, h);

        vm.prank(agentA);
        vm.expectRevert(TestAgentCouncilOracleNative.CommitmentMismatch.selector);
        oracle.reveal(id, ans, nonce + 1);
    }

    // -------- judge selection / aggregation / distribution guards --------

    function test_RevertSelectJudge_NoJudgesRegistered() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 id = _reachAwaitingJudge_1Agent(reward, bond);

        vm.expectRevert(TestAgentCouncilOracleNative.NoJudgesRegistered.selector);
        oracle.selectJudge(id);
    }

    function test_RevertAggregate_NotJudge() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 id = _reachAwaitingJudge_1Agent(reward, bond);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(id);

        oracle.selectJudge(id);

        vm.prank(agentB);
        vm.expectRevert(TestAgentCouncilOracleNative.NotJudge.selector);
        oracle.aggregate(id, bytes("final"), _asArray(agentA), bytes("reasoning"));
    }

    function test_RevertDistributeRewards_BadPhase_WhenNotFinalized() public {
        uint256 reward = 1 ether;
        uint256 bond   = 0.25 ether;
        uint256 id = _reachAwaitingJudge_1Agent(reward, bond);

        vm.expectRevert(TestAgentCouncilOracleNative.BadPhase.selector);
        oracle.distributeRewards(id);
    }

// -------- small array helper --------
function _asArray(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
}


}
