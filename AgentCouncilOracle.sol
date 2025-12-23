// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAgentCouncilOracle {
    struct AgentCapabilities {
        string[] capabilities;
        string[] domains;
    }

    struct CreateRequestParams {
        string query;
        uint256 numInfoAgents;
        uint256 rewardAmount;
        uint256 bondAmount;
        uint256 deadline;            // commit deadline
        uint256 judgeSignupDeadline; // must be >= revealDeadline
        uint256 revealWindow;        // duration after commit deadline for reveals
        uint256 judgeBondAmount;     // bond amount required from judge
        uint256 judgeAggWindow;      // time window for judge to aggregate after selection
        uint16 judgeRewardBps;       // judge reward as basis points of rewardAmount (e.g., 1000 = 10%)
        address rewardToken;         // address(0) for native ETH, or ERC20 token address
        address bondToken;           // address(0) for native ETH, or ERC20 token address
        string specifications;
        AgentCapabilities requiredCapabilities;
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

    function createRequest(CreateRequestParams calldata params) external payable returns (uint256 requestId);

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

    function getRequest(uint256 requestId) external view returns (Request memory);

    function getCommits(uint256 requestId) external view returns (address[] memory agents, bytes32[] memory commitments);

    function getReveals(uint256 requestId) external view returns (address[] memory agents, bytes[] memory answers);
}

contract AgentCouncilOracle is IAgentCouncilOracle {
    // -------------------------
    // basis points denominator
    // -------------------------
    uint16 public constant BPS_DENOM = 10_000;

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
        address rewardToken;         // address(0) = native ETH
        uint256 bondAmount;
        address bondToken;           // address(0) = native ETH
        uint256 numInfoAgents;

        uint256 deadline;            // commit deadline (absolute timestamp)
        uint256 judgeSignupDeadline; // judge signup cutoff (absolute timestamp)

        // Configurable parameters
        uint256 judgeBondAmount;     // bond amount required from judge
        uint256 judgeAggWindow;      // time window for judge to aggregate after selection
        uint16 judgeRewardBps;       // judge reward as basis points of rewardAmount

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

        // judge bond state (posted AFTER selection)
        bool judgeBondPosted;
        uint256 judgeBondHeld;
        uint256 judgeAggDeadline;
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
    error NoJudgesRegistered();
    error JudgeCannotCommit();

    error JudgePoolClosed();
    error JudgeAlreadyRegistered();
    error BadJudgeDeadline();
    error RevealsStillOpen();
    error TooEarly();
    error InvalidWindow();
    error InvalidBps();

    // Transfer errors
    error RewardTransferFailed();
    error BondTransferFailed();
    error JudgeBondTransferFailed();
    error TokenMismatch();

    // judge bond errors
    error JudgeBondNotPosted();
    error WrongJudgeBond();
    error JudgeBondAlreadyPosted();

    // ---- Internal transfer helpers ----

    /// @dev Transfer tokens or ETH to this contract (pull)
    function _pullTokens(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        
        if (token == address(0)) {
            // Native ETH - must be sent with msg.value
            if (msg.value != amount) revert NotEnoughValue();
        } else {
            // ERC20 token
            if (msg.value != 0) revert TokenMismatch(); // Don't send ETH when using tokens
            bool success = IERC20(token).transferFrom(from, address(this), amount);
            if (!success) revert BondTransferFailed();
        }
    }

    /// @dev Transfer tokens or ETH from this contract (push)
    function _pushTokens(address token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        
        if (token == address(0)) {
            // Native ETH
            (bool ok,) = to.call{value: amount}("");
            return ok;
        } else {
            // ERC20 token
            return IERC20(token).transfer(to, amount);
        }
    }

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

    function getJudgeBondAmount(uint256 requestId) external view returns (uint256) {
        RequestState storage s = _get(requestId);
        return s.req.judgeBondAmount;
    }

    function getJudgeAggWindow(uint256 requestId) external view returns (uint256) {
        RequestState storage s = _get(requestId);
        return s.req.judgeAggWindow;
    }

    function getJudgeRewardBps(uint256 requestId) external view returns (uint16) {
        RequestState storage s = _get(requestId);
        return s.req.judgeRewardBps;
    }

    function getRevealDeadline(uint256 requestId) external view returns (uint256) {
        RequestState storage s = _get(requestId);
        return s.revealDeadline;
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

    function createRequest(CreateRequestParams calldata p)
        external
        payable
        override
        returns (uint256 requestId)
    {
        if (p.numInfoAgents == 0) revert TooManyAgents();
        if (p.deadline <= block.timestamp) revert DeadlinePassed();
        if (p.revealWindow == 0) revert InvalidWindow();
        if (p.judgeAggWindow == 0) revert InvalidWindow();
        if (p.judgeRewardBps > BPS_DENOM) revert InvalidBps();

        uint256 revealDeadline = p.deadline + p.revealWindow;
        if (p.judgeSignupDeadline <= block.timestamp) revert BadJudgeDeadline();
        if (p.judgeSignupDeadline < revealDeadline) revert BadJudgeDeadline();

        // Pull reward tokens/ETH from requester
        if (p.rewardToken == address(0)) {
            if (msg.value != p.rewardAmount) revert NotEnoughValue();
        } else {
            if (msg.value != 0) revert TokenMismatch();
            bool success = IERC20(p.rewardToken).transferFrom(msg.sender, address(this), p.rewardAmount);
            if (!success) revert RewardTransferFailed();
        }

        requestId = _nextRequestId++;
        RequestState storage s = _st[requestId];

        s.phase = Phase.Commit;
        s.revealDeadline = revealDeadline;

        StoredRequest storage r = s.req;
        r.requester = msg.sender;
        r.rewardAmount = p.rewardAmount;
        r.rewardToken = p.rewardToken;
        r.bondAmount = p.bondAmount;
        r.bondToken = p.bondToken;
        r.numInfoAgents = p.numInfoAgents;

        r.deadline = p.deadline;
        r.judgeSignupDeadline = p.judgeSignupDeadline;

        r.judgeBondAmount = p.judgeBondAmount;
        r.judgeAggWindow = p.judgeAggWindow;
        r.judgeRewardBps = p.judgeRewardBps;

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

        // Pull bond tokens/ETH
        _pullTokens(s.req.bondToken, msg.sender, s.req.bondAmount);

        s.hasCommitted[msg.sender] = true;
        s.commitmentOf[msg.sender] = commitment;
        s.commitAgents.push(msg.sender);
        s.commitHashes.push(commitment);
        s.bondHeld[msg.sender] = s.req.bondAmount;

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

        // judge must post bond AFTER being chosen; aggregate deadline uses configured window
        s.judgeBondPosted = false;
        s.judgeBondHeld = 0;
        s.judgeAggDeadline = block.timestamp + s.req.judgeAggWindow;

        s.phase = Phase.Judging;
        emit JudgeSelected(requestId, j);
    }

    // Judge posts bond AFTER being chosen. Uses bondToken (same as agent bonds).
    function postJudgeBond(uint256 requestId) external payable {
        RequestState storage s = _get(requestId);
        if (s.phase != Phase.Judging) revert BadPhase();
        if (msg.sender != s.judge) revert NotJudge();
        if (s.judgeBondPosted) revert JudgeBondAlreadyPosted();

        // Pull judge bond tokens/ETH
        _pullTokens(s.req.bondToken, msg.sender, s.req.judgeBondAmount);

        s.judgeBondPosted = true;
        s.judgeBondHeld = s.req.judgeBondAmount;
    }

    // If judge doesn't aggregate within window, refund reward+bonds and slash judge bond to requester+revealers.
    function timeoutJudge(uint256 requestId) external {
        RequestState storage s = _get(requestId);
        if (s.phase != Phase.Judging) revert BadPhase();
        if (s.finalized) revert AlreadyFinalized();
        if (block.timestamp <= s.judgeAggDeadline) revert TooEarly();

        s.phase = Phase.Failed;
        emit ResolutionFailed(requestId, "JUDGE_TIMEOUT");

        // refund reward to requester
        uint256 reward = s.req.rewardAmount;
        s.req.rewardAmount = 0;
        if (reward > 0) {
            if (!_pushTokens(s.req.rewardToken, s.req.requester, reward)) {
                revert RewardTransferFailed();
            }
        }

        // refund all agent bonds
        for (uint256 i = 0; i < s.commitAgents.length; i++) {
            address a = s.commitAgents[i];
            uint256 b = s.bondHeld[a];
            if (b == 0) continue;
            s.bondHeld[a] = 0;
            if (!_pushTokens(s.req.bondToken, a, b)) {
                revert BondTransferFailed();
            }
        }

        // slash judge bond if posted: split among requester + revealAgents
        uint256 jb = s.judgeBondHeld;
        s.judgeBondHeld = 0;
        s.judgeBondPosted = false;

        if (jb > 0) {
            uint256 n = s.revealAgents.length;
            uint256 participants = 1 + n;
            uint256 per = jb / participants;
            uint256 rem = jb - (per * participants);

            if (!_pushTokens(s.req.bondToken, s.req.requester, per + rem)) {
                revert JudgeBondTransferFailed();
            }

            for (uint256 i = 0; i < n; i++) {
                if (!_pushTokens(s.req.bondToken, s.revealAgents[i], per)) {
                    revert JudgeBondTransferFailed();
                }
            }
        }
    }

    // If judgeSignupDeadline passes and no judge selected, refund reward + all bonds.
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
            if (!_pushTokens(s.req.rewardToken, s.req.requester, reward)) {
                revert RewardTransferFailed();
            }
        }

        for (uint256 i = 0; i < s.commitAgents.length; i++) {
            address a = s.commitAgents[i];
            uint256 b = s.bondHeld[a];
            if (b == 0) continue;

            s.bondHeld[a] = 0;
            if (!_pushTokens(s.req.bondToken, a, b)) {
                revert BondTransferFailed();
            }
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

        // judge must have posted bond
        if (!s.judgeBondPosted) revert JudgeBondNotPosted();

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
            // No winners: refund reward to requester, refund bonds to agents, refund judge bond to judge
            s.phase = Phase.Failed;
            s.distributed = true;
            emit ResolutionFailed(requestId, "NO_WINNERS");

            // Refund reward to requester
            uint256 rewardRefund = s.req.rewardAmount;
            s.req.rewardAmount = 0;
            if (rewardRefund > 0) {
                if (!_pushTokens(s.req.rewardToken, s.req.requester, rewardRefund)) {
                    revert RewardTransferFailed();
                }
            }

            // Refund all agent bonds
            for (uint256 i = 0; i < s.commitAgents.length; i++) {
                address a = s.commitAgents[i];
                uint256 b = s.bondHeld[a];
                if (b == 0) continue;
                s.bondHeld[a] = 0;
                if (!_pushTokens(s.req.bondToken, a, b)) {
                    revert BondTransferFailed();
                }
            }

            // Refund judge bond to judge
            uint256 judgeBondRefund = s.judgeBondHeld;
            if (judgeBondRefund > 0) {
                s.judgeBondHeld = 0;
                s.judgeBondPosted = false;
                if (!_pushTokens(s.req.bondToken, s.judge, judgeBondRefund)) {
                    revert JudgeBondTransferFailed();
                }
            }

            return;
        }

        // Process agent bonds: refund to winners, collect from losers
        uint256 loserBondSum;
        for (uint256 i = 0; i < s.commitAgents.length; i++) {
            address a = s.commitAgents[i];
            uint256 b = s.bondHeld[a];
            if (b == 0) continue;

            s.bondHeld[a] = 0;

            if (s.isWinner[a]) {
                if (!_pushTokens(s.req.bondToken, a, b)) {
                    revert BondTransferFailed();
                }
            } else {
                loserBondSum += b;
            }
        }

        // Calculate judge cut from reward
        uint256 reward = s.req.rewardAmount;
        uint256 judgeCut = (reward * uint256(s.req.judgeRewardBps)) / uint256(BPS_DENOM);

        // Pay judge cut (from reward token)
        if (judgeCut > 0) {
            if (!_pushTokens(s.req.rewardToken, s.judge, judgeCut)) {
                revert RewardTransferFailed();
            }
        }

        // Refund judge bond on success (bond token)
        uint256 jb = s.judgeBondHeld;
        if (jb > 0) {
            s.judgeBondHeld = 0;
            s.judgeBondPosted = false;
            if (!_pushTokens(s.req.bondToken, s.judge, jb)) {
                revert JudgeBondTransferFailed();
            }
        }

        uint256 remainingReward = reward - judgeCut;

        // Winners split: remaining reward (in rewardToken) + loser bonds (in bondToken)
        // Note: If rewardToken != bondToken, these are separate distributions
        
        uint256 perWinnerReward = remainingReward / winnersLen;
        uint256 rewardRemainder = remainingReward - (perWinnerReward * winnersLen);
        
        uint256 perWinnerBond = loserBondSum / winnersLen;
        uint256 bondRemainder = loserBondSum - (perWinnerBond * winnersLen);

        uint256[] memory amounts = new uint256[](winnersLen);
        for (uint256 i = 0; i < winnersLen; i++) {
            address w = s.winners[i];
            
            // Pay reward portion
            if (perWinnerReward > 0) {
                if (!_pushTokens(s.req.rewardToken, w, perWinnerReward)) {
                    revert RewardTransferFailed();
                }
            }
            
            // Pay bond portion (slashed loser bonds)
            if (perWinnerBond > 0) {
                if (!_pushTokens(s.req.bondToken, w, perWinnerBond)) {
                    revert BondTransferFailed();
                }
            }
            
            // Track total for event (note: may be in different tokens)
            amounts[i] = perWinnerReward + perWinnerBond;
        }

        // Return remainders to requester
        if (rewardRemainder > 0) {
            if (!_pushTokens(s.req.rewardToken, s.req.requester, rewardRemainder)) {
                revert RewardTransferFailed();
            }
        }
        if (bondRemainder > 0) {
            if (!_pushTokens(s.req.bondToken, s.req.requester, bondRemainder)) {
                revert BondTransferFailed();
            }
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
