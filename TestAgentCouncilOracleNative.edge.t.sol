// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentCouncilOracle.sol";

// Simple ERC20 mock for testing
contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AgentCouncilOracle_EdgeCases is Test {
    AgentCouncilOracle oracle;
    MockERC20 rewardToken;
    MockERC20 bondToken;

    address requester = address(0xA11CE);

    address agentA    = address(0xB0B);
    address agentB    = address(0xCA11);
    address agentC    = address(0xD00D);
    address agentD    = address(0xABCD); // extra

    address judge1    = address(uint160(0xBEEF));
    address judge2    = address(uint160(0xFEED));

    uint256 reward = 1 ether;
    uint256 bond   = 0.1 ether;
    uint256 judgeBond = 0.1 ether;
    uint256 numAgents = 3;
    
    // Default timing parameters
    uint256 revealWindow = 1 days;
    uint256 judgeAggWindow = 1 days;
    uint16 judgeRewardBps = 1000; // 10%

    function setUp() public {
        oracle = new AgentCouncilOracle();
        rewardToken = new MockERC20();
        bondToken = new MockERC20();

        vm.txGasPrice(0);
        vm.deal(requester, 100 ether);

        vm.deal(agentA, 100 ether);
        vm.deal(agentB, 100 ether);
        vm.deal(agentC, 100 ether);
        vm.deal(agentD, 100 ether);

        vm.deal(judge1, 100 ether);
        vm.deal(judge2, 100 ether);

        // Mint tokens for ERC20 tests
        rewardToken.mint(requester, 100 ether);
        bondToken.mint(agentA, 100 ether);
        bondToken.mint(agentB, 100 ether);
        bondToken.mint(agentC, 100 ether);
        bondToken.mint(agentD, 100 ether);
        bondToken.mint(judge1, 100 ether);
        bondToken.mint(judge2, 100 ether);

        vm.warp(1_000_000);
        vm.roll(100);
        vm.setBlockhash(99, bytes32(uint256(123456789)));
    }

    // ---------------- helpers ----------------

    function _emptyCaps() internal pure returns (IAgentCouncilOracle.AgentCapabilities memory caps) {
        string[] memory empty;
        caps = IAgentCouncilOracle.AgentCapabilities({capabilities: empty, domains: empty});
    }

    function _commitment(bytes memory answer, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(answer, nonce));
    }

    function _createRequestParams(
        uint256 _numAgents,
        uint256 _reward,
        uint256 _bond,
        uint256 _deadline,
        uint256 _judgeSignupDeadline
    ) internal view returns (IAgentCouncilOracle.CreateRequestParams memory p) {
        p.query = "Q";
        p.numInfoAgents = _numAgents;
        p.rewardAmount = _reward;
        p.bondAmount = _bond;
        p.deadline = _deadline;
        p.judgeSignupDeadline = _judgeSignupDeadline;
        p.revealWindow = revealWindow;
        p.judgeBondAmount = judgeBond;
        p.judgeAggWindow = judgeAggWindow;
        p.judgeRewardBps = judgeRewardBps;
        p.rewardToken = address(0); // native ETH by default
        p.bondToken = address(0);   // native ETH by default
        p.specifications = "SPEC";
        p.requiredCapabilities = _emptyCaps();
    }

    function _createRequestParamsERC20(
        uint256 _numAgents,
        uint256 _reward,
        uint256 _bond,
        uint256 _deadline,
        uint256 _judgeSignupDeadline
    ) internal view returns (IAgentCouncilOracle.CreateRequestParams memory p) {
        p = _createRequestParams(_numAgents, _reward, _bond, _deadline, _judgeSignupDeadline);
        p.rewardToken = address(rewardToken);
        p.bondToken = address(bondToken);
    }

    function _createRequest(
        uint256 _numAgents,
        uint256 _reward,
        uint256 _bond,
        uint256 _deadline
    ) internal returns (uint256 requestId) {
        uint256 revealDeadline = _deadline + revealWindow;
        uint256 judgeSignupDeadline = revealDeadline + 1 days; // give extra time for judge signup
        
        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            _numAgents, _reward, _bond, _deadline, judgeSignupDeadline
        );
        
        vm.prank(requester);
        requestId = oracle.createRequest{value: _reward}(p);
    }

    function _createRequestERC20(
        uint256 _numAgents,
        uint256 _reward,
        uint256 _bond,
        uint256 _deadline
    ) internal returns (uint256 requestId) {
        uint256 revealDeadline = _deadline + revealWindow;
        uint256 judgeSignupDeadline = revealDeadline + 1 days;
        
        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParamsERC20(
            _numAgents, _reward, _bond, _deadline, judgeSignupDeadline
        );
        
        vm.prank(requester);
        rewardToken.approve(address(oracle), _reward);
        vm.prank(requester);
        requestId = oracle.createRequest(p); // no ETH sent for ERC20
    }

    function _createBasicRequest() internal returns (uint256 requestId, uint256 deadline) {
        deadline = block.timestamp + 1 days;
        requestId = _createRequest(numAgents, reward, bond, deadline);
    }

    function _createBasicRequestERC20() internal returns (uint256 requestId, uint256 deadline) {
        deadline = block.timestamp + 1 days;
        requestId = _createRequestERC20(numAgents, reward, bond, deadline);
    }

    function _do3Commits(uint256 requestId) internal {
        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 111));

        vm.prank(agentB);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 222));

        vm.prank(agentC);
        oracle.commit{value: bond}(requestId, _commitment(bytes("5"), 333));
    }

    function _do3CommitsERC20(uint256 requestId) internal {
        vm.prank(agentA);
        bondToken.approve(address(oracle), bond);
        vm.prank(agentA);
        oracle.commit(requestId, _commitment(bytes("4"), 111));

        vm.prank(agentB);
        bondToken.approve(address(oracle), bond);
        vm.prank(agentB);
        oracle.commit(requestId, _commitment(bytes("4"), 222));

        vm.prank(agentC);
        bondToken.approve(address(oracle), bond);
        vm.prank(agentC);
        oracle.commit(requestId, _commitment(bytes("5"), 333));
    }

    function _do3Reveals(uint256 requestId) internal {
        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);

        vm.prank(agentB);
        oracle.reveal(requestId, bytes("4"), 222);

        vm.prank(agentC);
        oracle.reveal(requestId, bytes("5"), 333);
    }

    function _registerTwoJudges(uint256 requestId) internal {
        vm.prank(judge1);
        oracle.registerJudgeForRequest(requestId);
        vm.prank(judge2);
        oracle.registerJudgeForRequest(requestId);
    }

    function _expectedPickedJudge(uint256 requestId, address _requester, uint256 deadline, uint256 commitsLen)
        internal
        view
        returns (address)
    {
        // pick based on oracle logic and our deterministic blockhash setup
        bytes32 h = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                address(oracle),
                requestId,
                _requester,
                deadline,
                commitsLen,
                uint256(2)
            )
        );
        return (uint256(h) % 2 == 0) ? judge1 : judge2;
    }

    function _selectJudge(uint256 requestId, uint256 deadline) internal returns (address picked) {
        _registerTwoJudges(requestId);
        picked = _expectedPickedJudge(requestId, requester, deadline, 3);
        oracle.selectJudge(requestId);

        // Judge must post bond after being selected
        vm.prank(picked);
        oracle.postJudgeBond{value: judgeBond}(requestId);
    }

    function _selectJudgeERC20(uint256 requestId, uint256 deadline) internal returns (address picked) {
        _registerTwoJudges(requestId);
        picked = _expectedPickedJudge(requestId, requester, deadline, 3);
        oracle.selectJudge(requestId);

        // Judge must post bond after being selected (ERC20)
        vm.prank(picked);
        bondToken.approve(address(oracle), judgeBond);
        vm.prank(picked);
        oracle.postJudgeBond(requestId);
    }

    // Helper that selects judge WITHOUT posting bond (for testing pre-bond scenarios)
    function _selectJudgeNoBond(uint256 requestId, uint256 deadline) internal returns (address picked) {
        _registerTwoJudges(requestId);
        picked = _expectedPickedJudge(requestId, requester, deadline, 3);
        oracle.selectJudge(requestId);
    }

    // ============================================================
    // ================ NATIVE ETH TESTS ==========================
    // ============================================================

    // ---------------- createRequest edge cases ----------------

    function test_CreateRequest_Revert_NumInfoAgentsZero() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            0, reward, bond, deadline, judgeSignupDeadline
        );

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.TooManyAgents.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_DeadlinePassed() public {
        uint256 deadline = block.timestamp; // <= now
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.DeadlinePassed.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_NotEnoughValue() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.NotEnoughValue.selector);
        oracle.createRequest{value: reward - 1}(p);
    }

    function test_CreateRequest_Revert_InvalidRevealWindow() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + 2 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );
        p.revealWindow = 0; // invalid

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.InvalidWindow.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_InvalidJudgeAggWindow() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );
        p.judgeAggWindow = 0; // invalid

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.InvalidWindow.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_InvalidBps() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );
        p.judgeRewardBps = 10001; // > 10000

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.InvalidBps.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_BadJudgeDeadline_TooSoon() public {
        uint256 deadline = block.timestamp + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, block.timestamp // <= now
        );

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.BadJudgeDeadline.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_BadJudgeDeadline_BeforeRevealDeadline() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 revealDeadlineCalc = deadline + revealWindow;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParams(
            numAgents, reward, bond, deadline, revealDeadlineCalc - 1 // < revealDeadline
        );

        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.BadJudgeDeadline.selector);
        oracle.createRequest{value: reward}(p);
    }

    function test_CreateRequest_Revert_TokenMismatch_ETHSentWithERC20() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 judgeSignupDeadline = deadline + revealWindow + 1 days;

        IAgentCouncilOracle.CreateRequestParams memory p = _createRequestParamsERC20(
            numAgents, reward, bond, deadline, judgeSignupDeadline
        );

        // Approve tokens
        vm.prank(requester);
        rewardToken.approve(address(oracle), reward);

        // Try to send ETH with ERC20 request - should fail
        vm.prank(requester);
        vm.expectRevert(AgentCouncilOracle.TokenMismatch.selector);
        oracle.createRequest{value: reward}(p);
    }

    // ---------------- commit edge cases ----------------

    function test_Commit_Revert_NotFound() public {
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.commit{value: bond}(999, bytes32(uint256(123)));
    }

    function test_Commit_Revert_DeadlinePassed() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();

        vm.warp(deadline); // >= deadline triggers DeadlinePassed in commit()
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.DeadlinePassed.selector);
        oracle.commit{value: bond}(requestId, bytes32(uint256(123)));
    }

    function test_Commit_Revert_NotEnoughValue() public {
        (uint256 requestId,) = _createBasicRequest();

        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.NotEnoughValue.selector);
        oracle.commit{value: bond - 1}(requestId, bytes32(uint256(123)));
    }

    function test_Commit_Revert_AlreadyCommitted() public {
        (uint256 requestId,) = _createBasicRequest();

        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, bytes32(uint256(123)));

        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.AlreadyCommitted.selector);
        oracle.commit{value: bond}(requestId, bytes32(uint256(456)));
    }

    function test_Commit_Revert_BadPhase_AfterPhaseBecomesReveal() public {
        (uint256 requestId,) = _createBasicRequest();

        _do3Commits(requestId); // phase becomes Reveal

        vm.prank(agentD);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.commit{value: bond}(requestId, bytes32(uint256(777)));
    }

    function test_Commit_Revert_TokenMismatch_ETHSentWithERC20Bond() public {
        (uint256 requestId,) = _createBasicRequestERC20();

        // Approve tokens
        vm.prank(agentA);
        bondToken.approve(address(oracle), bond);

        // Try to send ETH with ERC20 bond request - should fail
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.TokenMismatch.selector);
        oracle.commit{value: bond}(requestId, bytes32(uint256(123)));
    }

    // NOTE: test_Commit_Revert_JudgeCannotCommit is not included because the 
    // JudgeCannotCommit check is defensive for a scenario that can't occur in the 
    // normal flow - judge registration requires AwaitingJudge phase which comes 
    // after Commit phase ends, so a registered judge can never attempt to commit 
    // on the same request they're registered for.

    // ---------------- reveal edge cases ----------------

    function test_Reveal_Revert_BadPhase_WhenStillCommitAndBeforeDeadline() public {
        (uint256 requestId,) = _createBasicRequest();

        // no commits yet, and before commit deadline -> reveal should revert BadPhase
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.reveal(requestId, bytes("4"), 111);
    }

    function test_Reveal_Revert_NotCommitted() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId); // phase Reveal

        vm.prank(agentD);
        vm.expectRevert(AgentCouncilOracle.NotCommitted.selector);
        oracle.reveal(requestId, bytes("4"), 444);
    }

    function test_Reveal_Revert_AlreadyRevealed() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);

        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);

        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.AlreadyRevealed.selector);
        oracle.reveal(requestId, bytes("4"), 111);
    }

    function test_Reveal_Revert_CommitmentMismatch() public {
        (uint256 requestId,) = _createBasicRequest();

        // commit expecting ("4",111)
        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 111));

        // fill remaining commits so phase becomes Reveal
        vm.prank(agentB);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 222));
        vm.prank(agentC);
        oracle.commit{value: bond}(requestId, _commitment(bytes("5"), 333));

        // reveal wrong nonce
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.CommitmentMismatch.selector);
        oracle.reveal(requestId, bytes("4"), 999);
    }

    function test_Reveal_Revert_AlreadyRevealed_OneAgent_BecomesBadPhase() public {
        uint256 deadline = block.timestamp + 1 hours;
        
        // 1 agent => after first reveal, phase becomes AwaitingJudge
        uint256 requestId = _createRequest(1, reward, bond, deadline);

        bytes memory ans = bytes("four");
        uint256 nonce = 7;
        bytes32 h = _commitment(ans, nonce);

        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, h);

        vm.prank(agentA);
        oracle.reveal(requestId, ans, nonce);

        // second reveal attempt hits BadPhase() first
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.reveal(requestId, ans, nonce);
    }

    function test_Reveal_Revert_AlreadyRevealed_TwoAgents_HitsAlreadyRevealed() public {
        uint256 deadline = block.timestamp + 1 hours;

        // 2 agents => after A reveals, phase stays Reveal until B reveals (or window closes)
        uint256 requestId = _createRequest(2, reward, bond, deadline);

        bytes memory ansA = bytes("four");
        uint256 nonceA = 7;
        bytes32 hA = _commitment(ansA, nonceA);

        bytes memory ansB = bytes("also four");
        uint256 nonceB = 8;
        bytes32 hB = _commitment(ansB, nonceB);

        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, hA);

        vm.prank(agentB);
        oracle.commit{value: bond}(requestId, hB);

        vm.prank(agentA);
        oracle.reveal(requestId, ansA, nonceA);

        // second reveal attempt now reaches AlreadyRevealed()
        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.AlreadyRevealed.selector);
        oracle.reveal(requestId, ansA, nonceA);
    }

    function test_Reveal_Revert_DeadlinePassed_AfterRevealWindow() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);

        // reveal window ends at deadline + revealWindow
        uint256 revealDeadline = deadline + revealWindow;
        vm.warp(revealDeadline + 1);

        vm.prank(agentA);
        vm.expectRevert(AgentCouncilOracle.DeadlinePassed.selector);
        oracle.reveal(requestId, bytes("4"), 111);
    }

    // ---------------- closeReveals edge cases ----------------

    function test_CloseReveals_Revert_BadPhase_WhenCommit() public {
        (uint256 requestId,) = _createBasicRequest();

        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.closeReveals(requestId);
    }

    function test_CloseReveals_Revert_RevealsStillOpen() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);

        // only one reveal and not past revealDeadline
        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);

        vm.expectRevert(AgentCouncilOracle.RevealsStillOpen.selector);
        oracle.closeReveals(requestId);
    }

    function test_CloseReveals_Succeeds_WhenAllRevealed() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        // phase should be AwaitingJudge now; closeReveals should revert BadPhase
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.closeReveals(requestId);
    }

    function test_CloseReveals_Succeeds_AfterRevealWindowEnds() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);

        // Only one reveal
        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);

        // Warp past reveal deadline
        uint256 revealDeadline = deadline + revealWindow;
        vm.warp(revealDeadline + 1);

        // Now closeReveals should succeed
        oracle.closeReveals(requestId);
    }

    // ---------------- judge registration edge cases ----------------

    function test_RegisterJudge_Revert_NotFound() public {
        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.registerJudgeForRequest(999);
    }

    function test_RegisterJudge_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest(); // phase Commit
        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.registerJudgeForRequest(requestId);
    }

    function test_RegisterJudge_Revert_JudgePoolClosed_AfterDeadline() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        uint256 signup = oracle.getJudgeSignupDeadline(requestId);

        vm.warp(signup); // >= signup deadline => closed
        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.JudgePoolClosed.selector);
        oracle.registerJudgeForRequest(requestId);
    }

    function test_RegisterJudge_Revert_JudgeAlreadyRegistered() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(requestId);

        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.JudgeAlreadyRegistered.selector);
        oracle.registerJudgeForRequest(requestId);
    }

    function test_UnregisterJudge_NoOp_WhenNotRegistered() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        // should not revert and judgeCount remains 0
        vm.prank(judge1);
        oracle.unregisterJudgeForRequest(requestId);

        assertEq(oracle.judgeCount(requestId), 0);
    }

    function test_UnregisterJudge_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest(); // Commit phase

        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.unregisterJudgeForRequest(requestId);
    }

    function test_UnregisterJudge_Success() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        vm.prank(judge1);
        oracle.registerJudgeForRequest(requestId);
        assertEq(oracle.judgeCount(requestId), 1);
        assertTrue(oracle.isJudgeForRequest(requestId, judge1));

        vm.prank(judge1);
        oracle.unregisterJudgeForRequest(requestId);
        assertEq(oracle.judgeCount(requestId), 0);
        assertFalse(oracle.isJudgeForRequest(requestId, judge1));
    }

    // ---------------- selectJudge edge cases ----------------

    function test_SelectJudge_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest(); // Commit phase
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.selectJudge(requestId);
    }

    function test_SelectJudge_Revert_NoJudgesRegistered() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        vm.expectRevert(AgentCouncilOracle.NoJudgesRegistered.selector);
        oracle.selectJudge(requestId);
    }

    function test_SelectJudge_Revert_JudgePoolClosed_AfterSignupDeadline() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        uint256 signup = oracle.getJudgeSignupDeadline(requestId);
        vm.warp(signup); // >= deadline => closed

        vm.expectRevert(AgentCouncilOracle.JudgePoolClosed.selector);
        oracle.selectJudge(requestId);
    }

    function test_SelectJudge_Revert_JudgePoolClosed_AlreadySelected() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        // Use the no-bond version since we just want to test selectJudge revert
        _selectJudgeNoBond(requestId, deadline);

        // After judge is selected, phase is Judging, so selectJudge reverts BadPhase
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.selectJudge(requestId);
    }

    // ---------------- postJudgeBond edge cases ----------------

    function test_PostJudgeBond_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest();
        
        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.postJudgeBond{value: judgeBond}(requestId);
    }

    function test_PostJudgeBond_Revert_NotJudge() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudgeNoBond(requestId, deadline);
        address notPicked = (picked == judge1) ? judge2 : judge1;

        vm.prank(notPicked);
        vm.expectRevert(AgentCouncilOracle.NotJudge.selector);
        oracle.postJudgeBond{value: judgeBond}(requestId);
    }

    function test_PostJudgeBond_Revert_NotEnoughValue() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudgeNoBond(requestId, deadline);

        vm.prank(picked);
        vm.expectRevert(AgentCouncilOracle.NotEnoughValue.selector);
        oracle.postJudgeBond{value: judgeBond - 1}(requestId);
    }

    function test_PostJudgeBond_Revert_JudgeBondAlreadyPosted() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudge(requestId, deadline); // This posts bond

        vm.prank(picked);
        vm.expectRevert(AgentCouncilOracle.JudgeBondAlreadyPosted.selector);
        oracle.postJudgeBond{value: judgeBond}(requestId);
    }

    // ---------------- aggregate edge cases ----------------

    function test_Aggregate_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);

        address[] memory winners = new address[](0);

        // still Reveal phase (no judge selected)
        vm.prank(judge1);
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("x"));
    }

    function test_Aggregate_Revert_NotJudge() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudge(requestId, deadline);

        address[] memory winners = new address[](0);

        // someone else tries
        address imposter = (picked == judge1) ? judge2 : judge1;
        vm.prank(imposter);
        vm.expectRevert(AgentCouncilOracle.NotJudge.selector);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("x"));
    }

    function test_Aggregate_Revert_JudgeBondNotPosted() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudgeNoBond(requestId, deadline); // No bond posted

        address[] memory winners = new address[](2);
        winners[0] = agentA;
        winners[1] = agentB;

        vm.prank(picked);
        vm.expectRevert(AgentCouncilOracle.JudgeBondNotPosted.selector);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("x"));
    }

    function test_Aggregate_Allows_WinnersNotInCommits_PaysThemAnyway() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudge(requestId, deadline);

        address[] memory winners = new address[](1);
        winners[0] = agentD; // agentD never committed/revealed

        uint256 dBefore = agentD.balance;

        vm.prank(picked);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("weird winner"));

        oracle.distributeRewards(requestId);

        assertGt(agentD.balance, dBefore, "agentD should have received payout even though not committed");
    }

    function test_Aggregate_NoQuorum_FailsGracefully() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 requestId = _createRequest(3, reward, bond, deadline);

        // Only 2 commits (need 3)
        vm.prank(agentA);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 111));
        vm.prank(agentB);
        oracle.commit{value: bond}(requestId, _commitment(bytes("4"), 222));

        // Warp past commit deadline to allow reveal phase
        vm.warp(deadline + 1);

        // Only 1 reveal (less than majority of 2 commits)
        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);

        // Close reveals after window
        uint256 revealDeadline = deadline + revealWindow;
        vm.warp(revealDeadline + 1);
        oracle.closeReveals(requestId);

        // Register and select judge
        vm.prank(judge1);
        oracle.registerJudgeForRequest(requestId);
        oracle.selectJudge(requestId);

        vm.prank(judge1);
        oracle.postJudgeBond{value: judgeBond}(requestId);

        address[] memory winners = new address[](1);
        winners[0] = agentA;

        // Should emit ResolutionFailed with NO_QUORUM
        vm.prank(judge1);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("no quorum"));
    }

    // ---------------- distributeRewards edge cases ----------------

    function test_DistributeRewards_Revert_BadPhase_IfNotFinalized() public {
        (uint256 requestId,) = _createBasicRequest();
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.distributeRewards(requestId);
    }

    function test_DistributeRewards_Revert_AlreadyDistributed() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudge(requestId, deadline);

        address[] memory winners = new address[](2);
        winners[0] = agentA;
        winners[1] = agentB;

        vm.prank(picked);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("ok"));

        oracle.distributeRewards(requestId);

        vm.expectRevert(AgentCouncilOracle.AlreadyDistributed.selector);
        oracle.distributeRewards(requestId);
    }

    function test_DistributeRewards_NoWinners_RefundsEveryone() public {
        // Capture balances BEFORE creating request
        uint256 reqInitial = requester.balance;
        uint256 aInitial = agentA.balance;
        uint256 bInitial = agentB.balance;
        uint256 cInitial = agentC.balance;

        (uint256 requestId, uint256 deadline) = _createBasicRequest();

        _do3Commits(requestId);
        _do3Reveals(requestId);

        address picked = _selectJudge(requestId, deadline);
        uint256 judgeInitial = picked.balance + judgeBond; // judge already spent bond in _selectJudge

        address[] memory winners = new address[](0);

        vm.prank(picked);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("no winners"));

        oracle.distributeRewards(requestId);

        // Everyone should be refunded to their initial balances
        assertEq(address(oracle).balance, 0, "contract should have no funds");
        assertEq(requester.balance, reqInitial, "requester got reward back");
        assertEq(agentA.balance, aInitial, "agentA got bond back");
        assertEq(agentB.balance, bInitial, "agentB got bond back");
        assertEq(agentC.balance, cInitial, "agentC got bond back");
        assertEq(picked.balance, judgeInitial, "judge got bond back");
    }

    function test_DistributeRewards_Remainder_ReturnedToRequester() public {
        uint256 localBond = 1 wei;

        uint256 deadline = block.timestamp + 1 days;
        uint256 requestId = _createRequest(3, reward, localBond, deadline);

        uint256 reqBefore = requester.balance;

        vm.prank(agentA);
        oracle.commit{value: localBond}(requestId, _commitment(bytes("4"), 111));
        vm.prank(agentB);
        oracle.commit{value: localBond}(requestId, _commitment(bytes("4"), 222));
        vm.prank(agentC);
        oracle.commit{value: localBond}(requestId, _commitment(bytes("5"), 333));

        vm.prank(agentA);
        oracle.reveal(requestId, bytes("4"), 111);
        vm.prank(agentB);
        oracle.reveal(requestId, bytes("4"), 222);
        vm.prank(agentC);
        oracle.reveal(requestId, bytes("5"), 333);

        _registerTwoJudges(requestId);
        address picked = _expectedPickedJudge(requestId, requester, deadline, 3);
        oracle.selectJudge(requestId);

        // Judge must post bond after being selected
        vm.prank(picked);
        oracle.postJudgeBond{value: judgeBond}(requestId);

        address[] memory winners = new address[](2);
        winners[0] = agentA;
        winners[1] = agentB;

        vm.prank(picked);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("remainder test"));

        oracle.distributeRewards(requestId);

        // Remainder from both reward and bond pools goes to requester
        assertGe(requester.balance, reqBefore, "requester got remainder");
    }

    // ---------------- timeoutJudge edge cases ----------------

    function test_TimeoutJudge_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest();
        
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.timeoutJudge(requestId);
    }

    function test_TimeoutJudge_Revert_TooEarly() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        _selectJudgeNoBond(requestId, deadline);

        // Try to timeout before judgeAggDeadline
        vm.expectRevert(AgentCouncilOracle.TooEarly.selector);
        oracle.timeoutJudge(requestId);
    }

    function test_TimeoutJudge_Success_SlashesJudgeBond() public {
        uint256 reqInitial = requester.balance;
        uint256 aInitial = agentA.balance;
        uint256 bInitial = agentB.balance;
        uint256 cInitial = agentC.balance;

        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        _selectJudge(requestId, deadline);
        
        // Warp past judge aggregation deadline
        vm.warp(block.timestamp + judgeAggWindow + 1);

        oracle.timeoutJudge(requestId);

        // Requester gets reward back + share of judge bond
        // Agents get their bonds back + share of judge bond
        assertEq(address(oracle).balance, 0, "contract should have no funds");
        assertGt(requester.balance, reqInitial, "requester got reward + judge bond share");
        assertGt(agentA.balance, aInitial, "agentA got bond back + judge bond share");
        assertGt(agentB.balance, bInitial, "agentB got bond back + judge bond share");
        assertGt(agentC.balance, cInitial, "agentC got bond back + judge bond share");
    }

    // ---------------- refundIfNoJudge edge cases ----------------

    function test_RefundIfNoJudge_Revert_BadPhase() public {
        (uint256 requestId,) = _createBasicRequest(); // Commit phase
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.refundIfNoJudge(requestId);
    }

    function test_RefundIfNoJudge_Revert_TooEarly() public {
        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        // awaiting judge, but before signup deadline
        vm.expectRevert(AgentCouncilOracle.TooEarly.selector);
        oracle.refundIfNoJudge(requestId);
    }

    function test_RefundIfNoJudge_Revert_JudgePoolClosed_AfterSelection() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        _selectJudgeNoBond(requestId, deadline);

        // Phase is now Judging, not AwaitingJudge
        vm.expectRevert(AgentCouncilOracle.BadPhase.selector);
        oracle.refundIfNoJudge(requestId);
    }

    function test_RefundIfNoJudge_Success() public {
        uint256 reqInitial = requester.balance;
        uint256 aInitial = agentA.balance;
        uint256 bInitial = agentB.balance;
        uint256 cInitial = agentC.balance;

        (uint256 requestId,) = _createBasicRequest();
        _do3Commits(requestId);
        _do3Reveals(requestId);

        // Don't register any judges, warp past signup deadline
        uint256 signup = oracle.getJudgeSignupDeadline(requestId);
        vm.warp(signup);

        oracle.refundIfNoJudge(requestId);

        // Everyone should be refunded
        assertEq(address(oracle).balance, 0, "contract should have no funds");
        assertEq(requester.balance, reqInitial, "requester got reward back");
        assertEq(agentA.balance, aInitial, "agentA got bond back");
        assertEq(agentB.balance, bInitial, "agentB got bond back");
        assertEq(agentC.balance, cInitial, "agentC got bond back");
    }

    // ---------------- misc getters / NotFound ----------------

    function test_Getters_Revert_NotFound() public {
        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.getRequest(999);

        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.getCommits(999);

        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.getReveals(999);

        vm.expectRevert(AgentCouncilOracle.NotFound.selector);
        oracle.getResolution(999);
    }

    function test_Getters_Success() public {
        (uint256 requestId,) = _createBasicRequest();

        IAgentCouncilOracle.Request memory req = oracle.getRequest(requestId);
        assertEq(req.requester, requester);
        assertEq(req.rewardAmount, reward);
        assertEq(req.bondAmount, bond);
        assertEq(req.numInfoAgents, numAgents);

        (address[] memory commitAgents, bytes32[] memory commitHashes) = oracle.getCommits(requestId);
        assertEq(commitAgents.length, 0);
        assertEq(commitHashes.length, 0);

        (address[] memory revealAgents, bytes[] memory answers) = oracle.getReveals(requestId);
        assertEq(revealAgents.length, 0);
        assertEq(answers.length, 0);

        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        assertEq(finalAnswer.length, 0);
        assertFalse(finalized);
    }

    function test_GetConfigurableParams() public {
        (uint256 requestId,) = _createBasicRequest();

        assertEq(oracle.getJudgeBondAmount(requestId), judgeBond);
        assertEq(oracle.getJudgeAggWindow(requestId), judgeAggWindow);
        assertEq(oracle.getJudgeRewardBps(requestId), judgeRewardBps);
    }

    // ============================================================
    // ================ ERC20 TOKEN TESTS =========================
    // ============================================================

    function test_ERC20_CreateRequest_Success() public {
        uint256 deadline = block.timestamp + 1 days;
        
        uint256 requesterBalanceBefore = rewardToken.balanceOf(requester);
        
        uint256 requestId = _createRequestERC20(numAgents, reward, bond, deadline);
        
        // Verify tokens transferred
        assertEq(rewardToken.balanceOf(address(oracle)), reward);
        assertEq(rewardToken.balanceOf(requester), requesterBalanceBefore - reward);
        
        // Verify request stored correctly
        IAgentCouncilOracle.Request memory req = oracle.getRequest(requestId);
        assertEq(req.rewardToken, address(rewardToken));
        assertEq(req.bondToken, address(bondToken));
    }

    function test_ERC20_Commit_Success() public {
        (uint256 requestId,) = _createBasicRequestERC20();
        
        uint256 agentBalanceBefore = bondToken.balanceOf(agentA);
        
        vm.prank(agentA);
        bondToken.approve(address(oracle), bond);
        vm.prank(agentA);
        oracle.commit(requestId, _commitment(bytes("4"), 111));
        
        // Verify tokens transferred
        assertEq(bondToken.balanceOf(address(oracle)), bond);
        assertEq(bondToken.balanceOf(agentA), agentBalanceBefore - bond);
    }

    function test_ERC20_FullFlow_Success() public {
        (uint256 requestId, uint256 deadline) = _createBasicRequestERC20();
        
        // Track initial balances
        uint256 agentABondBefore = bondToken.balanceOf(agentA);
        uint256 agentBBondBefore = bondToken.balanceOf(agentB);
        uint256 agentCBondBefore = bondToken.balanceOf(agentC);
        
        // Commits
        _do3CommitsERC20(requestId);
        
        // Reveals
        _do3Reveals(requestId);
        
        // Judge selection and bond
        address picked = _selectJudgeERC20(requestId, deadline);
        uint256 judgeBalanceBefore = bondToken.balanceOf(picked);
        
        // Aggregate - A and B win, C loses
        address[] memory winners = new address[](2);
        winners[0] = agentA;
        winners[1] = agentB;
        
        vm.prank(picked);
        oracle.aggregate(requestId, bytes("4"), winners, bytes("majority wins"));
        
        // Distribute
        oracle.distributeRewards(requestId);
        
        // Verify final state
        assertEq(rewardToken.balanceOf(address(oracle)), 0, "oracle should have no reward tokens");
        assertEq(bondToken.balanceOf(address(oracle)), 0, "oracle should have no bond tokens");
        
        // Winners should have more than before (bond back + winnings)
        assertGt(bondToken.balanceOf(agentA), agentABondBefore, "agentA should profit");
        assertGt(bondToken.balanceOf(agentB), agentBBondBefore, "agentB should profit");
        
        // Loser should have less (lost bond)
        assertLt(bondToken.balanceOf(agentC), agentCBondBefore, "agentC should lose bond");
        
        // Judge should have same bond tokens (refunded) plus some reward tokens
        assertEq(bondToken.balanceOf(picked), judgeBalanceBefore + judgeBond, "judge bond refunded");
        assertGt(rewardToken.balanceOf(picked), 0, "judge got reward cut");
    }

    function test_ERC20_RefundIfNoJudge_Success() public {
        uint256 requesterRewardBefore = rewardToken.balanceOf(requester);
        uint256 agentABondBefore = bondToken.balanceOf(agentA);
        uint256 agentBBondBefore = bondToken.balanceOf(agentB);
        uint256 agentCBondBefore = bondToken.balanceOf(agentC);

        (uint256 requestId,) = _createBasicRequestERC20();
        _do3CommitsERC20(requestId);
        _do3Reveals(requestId);

        // Don't register any judges, warp past signup deadline
        uint256 signup = oracle.getJudgeSignupDeadline(requestId);
        vm.warp(signup);

        oracle.refundIfNoJudge(requestId);

        // Everyone should be refunded
        assertEq(rewardToken.balanceOf(address(oracle)), 0, "oracle should have no reward tokens");
        assertEq(bondToken.balanceOf(address(oracle)), 0, "oracle should have no bond tokens");
        assertEq(rewardToken.balanceOf(requester), requesterRewardBefore, "requester got reward back");
        assertEq(bondToken.balanceOf(agentA), agentABondBefore, "agentA got bond back");
        assertEq(bondToken.balanceOf(agentB), agentBBondBefore, "agentB got bond back");
        assertEq(bondToken.balanceOf(agentC), agentCBondBefore, "agentC got bond back");
    }

    function test_ERC20_TimeoutJudge_SlashesBond() public {
        uint256 requesterRewardBefore = rewardToken.balanceOf(requester);
        uint256 agentABondBefore = bondToken.balanceOf(agentA);

        (uint256 requestId, uint256 deadline) = _createBasicRequestERC20();
        _do3CommitsERC20(requestId);
        _do3Reveals(requestId);

        _selectJudgeERC20(requestId, deadline);
        
        // Warp past judge aggregation deadline
        vm.warp(block.timestamp + judgeAggWindow + 1);

        oracle.timeoutJudge(requestId);

        // Requester gets reward back + share of judge bond
        assertEq(rewardToken.balanceOf(requester), requesterRewardBefore, "requester got reward back");
        assertGt(bondToken.balanceOf(requester), 0, "requester got judge bond share");
        
        // Agents get their bonds back + share of judge bond
        assertGt(bondToken.balanceOf(agentA), agentABondBefore, "agentA got bond back + judge bond share");
    }
}
