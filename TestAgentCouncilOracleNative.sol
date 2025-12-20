// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentCouncilOracle {
    struct AgentCapabilities {
        string[] capabilities;
        string[] domains;
    }

    struct Request {
        address requester;
        uint256 rewardAmount;
        address rewardToken;
        uint256 bondAmount;
        address bondToken;
        uint256 numInfoAgents;
        uint256 deadline;
        string query;
        string specifications;
        AgentCapabilities requiredCapabilities;
    }

    event RequestCreated(
        uint256 indexed requestId,
        address requester,
        string query,
        uint256 rewardAmount,
        uint256 numInfoAgents,
        uint256 bondAmount
    );
    event AgentCommitted(uint256 indexed requestId, address agent, bytes32 commitment);
    event AgentRevealed(uint256 indexed requestId, address agent, bytes answer);
    event JudgeSelected(uint256 indexed requestId, address judge);
    event ResolutionFinalized(uint256 indexed requestId, bytes finalAnswer);
    event RewardsDistributed(uint256 indexed requestId, address[] winners, uint256[] amounts);
    event ResolutionFailed(uint256 indexed requestId, string reason);

    event DisputeInitiated(uint256 indexed requestId, address disputer, string reason);
    event DisputeWindowOpened(uint256 indexed requestId, uint256 endTimestamp);
    event DisputeResolved(uint256 indexed requestId, bool overturned, bytes finalAnswer);

    function createRequest(
        string calldata query,
        uint256 numInfoAgents,
        uint256 rewardAmount,
        uint256 bondAmount,
        uint256 deadline,
        address rewardToken,
        address bondToken,
        string calldata specifications,
        AgentCapabilities calldata requiredCapabilities
    ) external payable returns (uint256 requestId);

    function commit(uint256 requestId, bytes32 commitment) external payable;
    function reveal(uint256 requestId, bytes calldata answer, uint256 nonce) external;

    function aggregate(
        uint256 requestId,
        bytes calldata finalAnswer,
        address[] calldata winners,
        bytes calldata reasoning
    ) external;

    function distributeRewards(uint256 requestId) external;

    function getResolution(uint256 requestId) external view returns (bytes memory finalAnswer, bool finalized);

    function initiateDispute(uint256 requestId, string calldata reason) external payable;

    function resolveDispute(
        uint256 requestId,
        bool overturn,
        bytes calldata newAnswer,
        address[] calldata newWinners
    ) external;

    function getRequest(uint256 requestId) external view returns (Request memory);

    function getCommits(uint256 requestId) external view returns (address[] memory agents, bytes32[] memory commitments);

    function getReveals(uint256 requestId) external view returns (address[] memory agents, bytes[] memory answers);
}

contract TestAgentCouncilOracleNative is IAgentCouncilOracle {
    uint256 public constant REVEAL_WINDOW = 1 days;

    // -------------------------
    // NEW: judge reward percent
    // -------------------------
    uint16 public constant BPS_DENOM = 10_000;
    uint16 public constant JUDGE_REWARD_BPS = 1_000; // 10% of rewardAmount

    enum Phase {
        None,
        Commit,
        Reveal,
        AwaitingJudge,
        Judging,
        Finalized,
        Distributed,
        Failed
    }

    struct StoredRequest {
        address requester;
        uint256 rewardAmount;
        address rewardToken; // must be address(0)
        uint256 bondAmount;
        address bondToken;   // must be address(0)
        uint256 numInfoAgents;

        uint256 deadline;            // commit deadline (absolute timestamp)
        uint256 judgeSignupDeadline; // judge signup cutoff (absolute timestamp)

        string query;
        string specifications;
    }

    struct RequestState {
        StoredRequest req;
        Phase phase;

        address[] commitAgents;
        bytes32[] commitHashes;
        mapping(address => bytes32) commitmentOf;
        mapping(address => bool) hasCommitted;

        address[] revealAgents;
        mapping(address => bytes) revealedAnswer;
        mapping(address => bool) hasRevealed;

        address judge;
        bytes finalAnswer;
        bytes reasoning;
        bool finalized;
        bool distributed;

        address[] winners;
        mapping(address => bool) isWinner;

        mapping(address => uint256) bondHeld;
        uint256 revealDeadline;
    }

    uint256 private _nextRequestId = 1;
    mapping(uint256 => RequestState) private _st;

    mapping(uint256 => bytes) private _requiredCapsEncoded;

    // ---- Per-request judge pools ----
    event JudgeRegisteredForRequest(uint256 indexed requestId, address judge);
    event JudgeUnregisteredForRequest(uint256 indexed requestId, address judge);
    event RevealsClosed(uint256 indexed requestId);

    struct JudgePool {
        address[] judges;
        mapping(address => bool) isJudge;
        mapping(address => uint256) indexPlusOne; // 1-based index for swap-remove
    }
    mapping(uint256 => JudgePool) private _judgePool;

    struct CreateRequestV2Params {
        string query;
        uint256 numInfoAgents;
        uint256 rewardAmount;
        uint256 bondAmount;
        uint256 deadline;            // commit deadline
        uint256 judgeSignupDeadline; // must be >= revealDeadline
        address rewardToken;
        address bondToken;
        string specifications;
        AgentCapabilities requiredCapabilities;
    }

    // ---- Errors ----
    error NotFound();
    error BadPhase();
    error DeadlinePassed();
    error NotEnoughValue();
    error TooManyAgents();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error NotJudge();
    error AlreadyFinalized();
    error AlreadyDistributed();
    error TokenNotSupported();
    error NoJudgesRegistered();
    error JudgeCannotCommit();

    error JudgePoolClosed();
    error JudgeAlreadyRegistered();
    error BadJudgeDeadline();
    error RevealsStillOpen();
    error TooEarly();

    // NEW: no revert strings on transfers
    error RewardRefundFail();
    error BondRefundFail();
    error RewardPayFail();
    error RemainderFail();

    function _get(uint256 requestId) internal view returns (RequestState storage s) {
        s = _st[requestId];
        if (s.req.requester == address(0)) revert NotFound();
    }

    function _emitRequestCreated(uint256 requestId) internal {
        StoredRequest storage r = _st[requestId].req;
        emit RequestCreated(
            requestId,
            r.requester,
            r.query,
            r.rewardAmount,
            r.numInfoAgents,
            r.bondAmount
        );
    }

    function registerJudgeForRequest(uint256 requestId) external {
        RequestState storage s = _get(requestId);

        if (s.judge != address(0)) revert JudgePoolClosed();
        if (s.phase != Phase.AwaitingJudge) revert BadPhase();
        if (block.timestamp >= s.req.judgeSignupDeadline) revert JudgePoolClosed();

        JudgePool storage p = _judgePool[requestId];
        if (p.isJudge[msg.sender]) revert JudgeAlreadyRegistered();

        p.isJudge[msg.sender] = true;
        p.judges.push(msg.sender);
        p.indexPlusOne[msg.sender] = p.judges.length;

        emit JudgeRegisteredForRequest(requestId, msg.sender);
    }

    function unregisterJudgeForRequest(uint256 requestId) external {
        RequestState storage s = _get(requestId);

        if (s.judge != address(0)) revert JudgePoolClosed();
        if (s.phase != Phase.AwaitingJudge) revert BadPhase();
        if (block.timestamp >= s.req.judgeSignupDeadline) revert JudgePoolClosed();

        JudgePool storage p = _judgePool[requestId];
        if (!p.isJudge[msg.sender]) return;

        uint256 idx = p.indexPlusOne[msg.sender] - 1;
        uint256 last = p.judges.length - 1;

        if (idx != last) {
            address moved = p.judges[last];
            p.judges[idx] = moved;
            p.indexPlusOne[moved] = idx + 1;
        }
        p.judges.pop();

        p.isJudge[msg.sender] = false;
        p.indexPlusOne[msg.sender] = 0;

        emit JudgeUnregisteredForRequest(requestId, msg.sender);
    }

    function judgeCount(uint256 requestId) external view returns (uint256) {
        return _judgePool[requestId].judges.length;
    }

    function getJudgeAt(uint256 requestId, uint256 index) external view returns (address) {
        return _judgePool[requestId].judges[index];
    }

    function isJudgeForRequest(uint256 requestId, address who) external view returns (bool) {
        return _judgePool[requestId].isJudge[who];
    }

    function getJudgeSignupDeadline(uint256 requestId) external view returns (uint256) {
        RequestState storage s = _get(requestId);
        return s.req.judgeSignupDeadline;
    }

    function _pickJudge(uint256 requestId, RequestState storage s) internal view returns (address) {
        JudgePool storage p = _judgePool[requestId];
        uint256 n = p.judges.length;
        if (n == 0) return address(0);

        bytes32 h = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                address(this),
                requestId,
                s.req.requester,
                s.req.deadline,
                s.commitAgents.length,
                n
            )
        );

        return p.judges[uint256(h) % n];
    }

    // Default: judgeSignupDeadline = revealDeadline (deadline + REVEAL_WINDOW)
    function createRequest(
        string calldata query,
        uint256 numInfoAgents,
        uint256 rewardAmount,
        uint256 bondAmount,
        uint256 deadline,
        address rewardToken,
        address bondToken,
        string calldata specifications,
        AgentCapabilities calldata requiredCapabilities
    ) external payable override returns (uint256 requestId) {
        if (rewardToken != address(0) || bondToken != address(0)) revert TokenNotSupported();
        if (numInfoAgents == 0) revert TooManyAgents();
        if (deadline <= block.timestamp) revert DeadlinePassed();
        if (msg.value != rewardAmount) revert NotEnoughValue();

        requestId = _nextRequestId++;
        RequestState storage s = _st[requestId];

        s.phase = Phase.Commit;
        s.revealDeadline = deadline + REVEAL_WINDOW;

        StoredRequest storage r = s.req;
        r.requester = msg.sender;
        r.rewardAmount = rewardAmount;
        r.rewardToken = address(0);
        r.bondAmount = bondAmount;
        r.bondToken = address(0);
        r.numInfoAgents = numInfoAgents;

        r.deadline = deadline;
        r.judgeSignupDeadline = s.revealDeadline;

        r.query = query;
        r.specifications = specifications;

        _requiredCapsEncoded[requestId] = abi.encode(requiredCapabilities);

        _emitRequestCreated(requestId);
    }

    // judgeSignupDeadline must be >= revealDeadline
    function createRequestV2(CreateRequestV2Params calldata p)
        external
        payable
        returns (uint256 requestId)
    {
        if (p.rewardToken != address(0) || p.bondToken != address(0)) revert TokenNotSupported();
        if (p.numInfoAgents == 0) revert TooManyAgents();
        if (p.deadline <= block.timestamp) revert DeadlinePassed();
        if (msg.value != p.rewardAmount) revert NotEnoughValue();

        uint256 revealDeadline = p.deadline + REVEAL_WINDOW;
        if (p.judgeSignupDeadline <= block.timestamp) revert BadJudgeDeadline();
        if (p.judgeSignupDeadline < revealDeadline) revert BadJudgeDeadline();

        requestId = _nextRequestId++;
        RequestState storage s = _st[requestId];

        s.phase = Phase.Commit;
        s.revealDeadline = revealDeadline;

        StoredRequest storage r = s.req;
        r.requester = msg.sender;
        r.rewardAmount = p.rewardAmount;
        r.rewardToken = address(0);
        r.bondAmount = p.bondAmount;
        r.bondToken = address(0);
        r.numInfoAgents = p.numInfoAgents;

        r.deadline = p.deadline;
        r.judgeSignupDeadline = p.judgeSignupDeadline;

        r.query = p.query;
        r.specifications = p.specifications;

        _requiredCapsEncoded[requestId] = abi.encode(p.requiredCapabilities);

        _emitRequestCreated(requestId);
    }

    function commit(uint256 requestId, bytes32 commitment) external payable override {
        if (_judgePool[requestId].isJudge[msg.sender]) revert JudgeCannotCommit();

        RequestState storage s = _get(requestId);
        if (s.phase != Phase.Commit) revert BadPhase();
        if (block.timestamp >= s.req.deadline) revert DeadlinePassed();
        if (s.commitAgents.length >= s.req.numInfoAgents) revert TooManyAgents();
        if (s.hasCommitted[msg.sender]) revert AlreadyCommitted();
        if (msg.value != s.req.bondAmount) revert NotEnoughValue();

        s.hasCommitted[msg.sender] = true;
        s.commitmentOf[msg.sender] = commitment;
        s.commitAgents.push(msg.sender);
        s.commitHashes.push(commitment);
        s.bondHeld[msg.sender] = msg.value;

        emit AgentCommitted(requestId, msg.sender, commitment);

        if (s.commitAgents.length == s.req.numInfoAgents) {
            s.phase = Phase.Reveal;
        }
    }

    function reveal(uint256 requestId, bytes calldata answer, uint256 nonce) external override {
        RequestState storage s = _get(requestId);

        if (s.phase == Phase.Commit && block.timestamp >= s.req.deadline) {
            s.phase = Phase.Reveal;
        }

        if (s.phase != Phase.Reveal) revert BadPhase();
        if (!s.hasCommitted[msg.sender]) revert NotCommitted();
        if (s.hasRevealed[msg.sender]) revert AlreadyRevealed();
        if (block.timestamp > s.revealDeadline) revert DeadlinePassed();

        bytes32 expected = s.commitmentOf[msg.sender];
        bytes32 got = keccak256(abi.encode(answer, nonce));
        if (got != expected) revert CommitmentMismatch();

        s.hasRevealed[msg.sender] = true;
        s.revealedAnswer[msg.sender] = answer;
        s.revealAgents.push(msg.sender);

        emit AgentRevealed(requestId, msg.sender, answer);

        if (s.revealAgents.length == s.commitAgents.length) {
            s.phase = Phase.AwaitingJudge;
            emit RevealsClosed(requestId);
        }
    }

    function closeReveals(uint256 requestId) external {
        RequestState storage s = _get(requestId);
        if (s.phase != Phase.Reveal) revert BadPhase();

        bool allRevealed = (s.revealAgents.length == s.commitAgents.length);
        bool windowEnded = (block.timestamp > s.revealDeadline);

        if (!allRevealed && !windowEnded) revert RevealsStillOpen();

        s.phase = Phase.AwaitingJudge;
        emit RevealsClosed(requestId);
    }

    function selectJudge(uint256 requestId) external {
        RequestState storage s = _get(requestId);
        if (s.phase != Phase.AwaitingJudge) revert BadPhase();
        if (s.judge != address(0)) revert JudgePoolClosed();
        if (block.timestamp >= s.req.judgeSignupDeadline) revert JudgePoolClosed();

        address j = _pickJudge(requestId, s);
        if (j == address(0)) revert NoJudgesRegistered();

        s.judge = j;
        s.phase = Phase.Judging;
        emit JudgeSelected(requestId, j);
    }

    /// @notice If judgeSignupDeadline has passed and no judge was selected,
    ///         fail the request and refund reward + all bonds. Callable by anyone.
    function refundIfNoJudge(uint256 requestId) external {
        RequestState storage s = _get(requestId);

        if (s.phase != Phase.AwaitingJudge) revert BadPhase();
        if (s.judge != address(0)) revert JudgePoolClosed();
        if (block.timestamp < s.req.judgeSignupDeadline) revert TooEarly();

        s.phase = Phase.Failed;
        emit ResolutionFailed(requestId, "NO_JUDGE_REFUND");

        uint256 reward = s.req.rewardAmount;
        s.req.rewardAmount = 0;

        if (reward > 0) {
            (bool ok,) = s.req.requester.call{value: reward}("");
            if (!ok) revert RewardRefundFail();
        }

        for (uint256 i = 0; i < s.commitAgents.length; i++) {
            address a = s.commitAgents[i];
            uint256 b = s.bondHeld[a];
            if (b == 0) continue;

            s.bondHeld[a] = 0;
            (bool ok,) = a.call{value: b}("");
            if (!ok) revert BondRefundFail();
        }
    }

    function aggregate(
        uint256 requestId,
        bytes calldata finalAnswer,
        address[] calldata winners,
        bytes calldata reasoning
    ) external override {
        RequestState storage s = _get(requestId);
        if (s.phase != Phase.Judging) revert BadPhase();
        if (s.finalized) revert AlreadyFinalized();
        if (msg.sender != s.judge) revert NotJudge();

        uint256 commits = s.commitAgents.length;
        uint256 revealsCount = s.revealAgents.length;
        if (commits == 0 || revealsCount * 2 <= commits) {
            s.phase = Phase.Failed;
            emit ResolutionFailed(requestId, "NO_QUORUM");
            return;
        }

        for (uint256 i = 0; i < s.winners.length; i++) {
            s.isWinner[s.winners[i]] = false;
        }
        delete s.winners;

        for (uint256 i = 0; i < winners.length; i++) {
            s.winners.push(winners[i]);
            s.isWinner[winners[i]] = true;
        }

        s.finalAnswer = finalAnswer;
        s.reasoning = reasoning;
        s.finalized = true;
        s.phase = Phase.Finalized;

        emit ResolutionFinalized(requestId, finalAnswer);
    }

    function distributeRewards(uint256 requestId) external override {
        RequestState storage s = _get(requestId);
if (s.distributed) revert AlreadyDistributed();
if (!s.finalized || s.phase != Phase.Finalized) revert BadPhase();


        uint256 winnersLen = s.winners.length;
        if (winnersLen == 0) {
            s.phase = Phase.Failed;
            emit ResolutionFailed(requestId, "NO_WINNERS");
            return;
        }

        uint256 loserBondSum;
        for (uint256 i = 0; i < s.commitAgents.length; i++) {
            address a = s.commitAgents[i];
            uint256 b = s.bondHeld[a];
            if (b == 0) continue;

            s.bondHeld[a] = 0;

            if (s.isWinner[a]) {
                (bool ok,) = a.call{value: b}("");
                if (!ok) revert BondRefundFail();
            } else {
                loserBondSum += b;
            }
        }

        // -------------------------
        // NEW: judge gets % of reward
        // -------------------------
        uint256 reward = s.req.rewardAmount;
        uint256 judgeCut = (reward * uint256(JUDGE_REWARD_BPS)) / uint256(BPS_DENOM);

        if (judgeCut > 0) {
            (bool ok,) = s.judge.call{value: judgeCut}("");
            if (!ok) revert RewardPayFail();
        }

        uint256 remainingReward = reward - judgeCut;

        // Winners split remainingReward + loserBondSum
        uint256 pool = remainingReward + loserBondSum;
        uint256 perWinner = pool / winnersLen;
        uint256 remainder = pool - (perWinner * winnersLen);

        uint256[] memory amounts = new uint256[](winnersLen);
        for (uint256 i = 0; i < winnersLen; i++) {
            address w = s.winners[i];
            amounts[i] = perWinner;

            (bool ok,) = w.call{value: perWinner}("");
            if (!ok) revert RewardPayFail();
        }

        if (remainder > 0) {
            (bool ok,) = s.req.requester.call{value: remainder}("");
            if (!ok) revert RemainderFail();
        }

        s.distributed = true;
        s.phase = Phase.Distributed;

        emit RewardsDistributed(requestId, s.winners, amounts);
    }

    function getResolution(uint256 requestId)
        external
        view
        override
        returns (bytes memory finalAnswer, bool finalized)
    {
        RequestState storage s = _get(requestId);
        return (s.finalAnswer, s.finalized);
    }

    function initiateDispute(uint256 requestId, string calldata reason) external payable override {
        _get(requestId);
        emit DisputeInitiated(requestId, msg.sender, reason);
    }

    function resolveDispute(
        uint256 requestId,
        bool overturn,
        bytes calldata newAnswer,
        address[] calldata /*newWinners*/
    ) external override {
        RequestState storage s = _get(requestId);
        if (msg.sender != s.req.requester) revert NotJudge();
        if (overturn) s.finalAnswer = newAnswer;
        emit DisputeResolved(requestId, overturn, s.finalAnswer);
    }

    function getRequest(uint256 requestId) external view override returns (Request memory out) {
        RequestState storage s = _get(requestId);

        AgentCapabilities memory caps;
        bytes storage blob = _requiredCapsEncoded[requestId];
        if (blob.length == 0) {
            string[] memory empty;
            caps = AgentCapabilities({capabilities: empty, domains: empty});
        } else {
            caps = abi.decode(blob, (AgentCapabilities));
        }

        out.requester = s.req.requester;
        out.rewardAmount = s.req.rewardAmount;
        out.rewardToken = s.req.rewardToken;
        out.bondAmount = s.req.bondAmount;
        out.bondToken = s.req.bondToken;
        out.numInfoAgents = s.req.numInfoAgents;
        out.deadline = s.req.deadline;
        out.query = s.req.query;
        out.specifications = s.req.specifications;
        out.requiredCapabilities = caps;
    }

    function getCommits(uint256 requestId)
        external
        view
        override
        returns (address[] memory agents, bytes32[] memory commitments)
    {
        RequestState storage s = _get(requestId);
        return (s.commitAgents, s.commitHashes);
    }

    function getReveals(uint256 requestId)
        external
        view
        override
        returns (address[] memory agents, bytes[] memory answers)
    {
        RequestState storage s = _get(requestId);
        uint256 n = s.revealAgents.length;
        agents = new address[](n);
        answers = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = s.revealAgents[i];
            agents[i] = a;
            answers[i] = s.revealedAnswer[a];
        }
    }

    receive() external payable {}
}
