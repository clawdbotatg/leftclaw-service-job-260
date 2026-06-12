//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ContentRanking
 * @author leftclaw
 * @notice A sandbox where creators submit content by IPFS CID, "Larva" users vote using
 *         CLAWD token burns, with dispute windows, sybil resistance via token burning,
 *         and onchain randomness for tiebreaking.
 * @dev Designed for Base (chainid 8453). Owner is the client wallet, set in constructor.
 */
contract ContentRanking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    enum ContentType {
        Film,
        Music,
        Art,
        Writing
    }

    enum ContentStatus {
        Active,
        Disputed,
        Finalized,
        Removed
    }

    struct Content {
        uint256 id;
        address creator;
        string title;
        string description;
        ContentType contentType;
        string ipfsCID; // IPFS hash of actual content
        uint256 submittedAt;
        ContentStatus status;
        int256 score; // sum of weighted votes (upvote +weight, downvote -weight)
        uint256 totalVoteWeight; // sum of all |weight| for ranking tiebreaks
        uint256 disputeStake; // ETH staked in active dispute
        address disputer; // who filed current dispute
        uint256 disputeDeadline; // when dispute window closes
    }

    struct Vote {
        bool voted;
        bool isUpvote;
        uint256 burnAmount; // CLAWD burned = vote weight
        bool slashed; // if owner flagged this vote as manipulative
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn sink. The dead address has no private key, so tokens sent here are effectively burned.
    address public constant BURN_ADDRESS = address(0xdEaD);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The CLAWD token used for voting. May be the zero address if CLAWD is not yet deployed.
    IERC20 public clawdToken;

    /// @notice Minimum CLAWD to burn per vote (default 1e18 = 1 CLAWD).
    uint256 public burnPerVote;

    /// @notice Duration of the voting window after submission.
    uint256 public votingDuration;

    /// @notice Duration of the dispute window after a dispute is filed.
    uint256 public disputeDuration;

    /// @notice ETH required to file a dispute.
    uint256 public disputeStakeRequired;

    /// @notice Total number of content items submitted (also the next id).
    uint256 public contentCount;

    /// @notice contentId => Content.
    mapping(uint256 => Content) public contents;

    /// @notice contentId => voter => Vote.
    mapping(uint256 => mapping(address => Vote)) public votes;

    /// @notice CLAWD staked for sybil resistance bonus.
    mapping(address => uint256) public stakedBalance;

    /// @notice Anti-spam fee (ETH) required to submit content.
    uint256 public submissionFee = 0.00001 ether;

    /// @notice contentId => timestamp of the last dispute filed (used for re-dispute cooldown).
    mapping(uint256 => uint256) public lastDisputedAt;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ContentSubmitted(
        uint256 indexed contentId, address indexed creator, string ipfsCID, ContentType contentType
    );
    event Voted(uint256 indexed contentId, address indexed voter, bool isUpvote, uint256 burnAmount);
    event DisputeFiled(uint256 indexed contentId, address indexed disputer, uint256 stake);
    event DisputeResolved(uint256 indexed contentId, bool upheld);
    event VoteSlashed(uint256 indexed contentId, address indexed voter, uint256 burntAmount);
    event ClawdTokenUpdated(address oldToken, address newToken);
    event BurnPerVoteUpdated(uint256 oldAmount, uint256 newAmount);
    event VotingDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event DisputeDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event DisputeStakeRequiredUpdated(uint256 oldAmount, uint256 newAmount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event SubmissionFeeUpdated(uint256 oldFee, uint256 newFee);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ClawdTokenNotSet();
    error EmptyTitle();
    error EmptyCID();
    error InvalidContentId();
    error ContentNotActive();
    error VotingClosed();
    error AlreadyVoted();
    error BurnAmountTooLow();
    error InsufficientDisputeStake();
    error DisputeAlreadyActive();
    error ContentNotDisputable();
    error ContentNotDisputed();
    error VoteNotFound();
    error VoteAlreadySlashed();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error NothingToWithdraw();
    error ETHTransferFailed();
    error BurnAmountTooLarge();
    error DisputeNotExpired();
    error RedisputeCooldown();
    error InsufficientSubmissionFee();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _clawdToken Address of the CLAWD token (may be address(0) if not yet deployed).
     * @param _owner Address that will own the contract (the client wallet, not the deployer).
     */
    constructor(address _clawdToken, address _owner) Ownable(_owner) {
        clawdToken = IERC20(_clawdToken);
        burnPerVote = 1e18;
        votingDuration = 7 days;
        disputeDuration = 24 hours;
        disputeStakeRequired = 0.001 ether;
    }

    /*//////////////////////////////////////////////////////////////
                            CONTENT LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submit a new piece of content for ranking.
     * @param title Human readable title (must be non-empty).
     * @param description Free-form description.
     * @param contentType The category of content.
     * @param ipfsCID IPFS hash of the actual content (must be non-empty).
     * @return contentId The id assigned to the new content.
     */
    function submitContent(
        string calldata title,
        string calldata description,
        ContentType contentType,
        string calldata ipfsCID
    ) external payable returns (uint256 contentId) {
        if (msg.value < submissionFee) revert InsufficientSubmissionFee();
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(ipfsCID).length == 0) revert EmptyCID();

        contentId = contentCount;
        unchecked {
            contentCount = contentId + 1;
        }

        Content storage c = contents[contentId];
        c.id = contentId;
        c.creator = msg.sender;
        c.title = title;
        c.description = description;
        c.contentType = contentType;
        c.ipfsCID = ipfsCID;
        c.submittedAt = block.timestamp;
        c.status = ContentStatus.Active;
        // score, totalVoteWeight, disputeStake, disputer, disputeDeadline default to 0/zero-address.

        emit ContentSubmitted(contentId, msg.sender, ipfsCID, contentType);
    }

    /**
     * @notice Vote on a piece of content by burning CLAWD. The burn amount is the vote weight.
     * @dev Burns by transferring to the dead address (CLAWD may not expose burn()).
     *      Follows CEI: state is written before the external token transfer.
     * @param contentId The content to vote on.
     * @param isUpvote True for an upvote (+weight), false for a downvote (-weight).
     * @param burnAmount Amount of CLAWD to burn; must be >= burnPerVote.
     */
    function vote(uint256 contentId, bool isUpvote, uint256 burnAmount) external nonReentrant {
        if (address(clawdToken) == address(0)) revert ClawdTokenNotSet();
        if (contentId >= contentCount) revert InvalidContentId();
        if (burnAmount < burnPerVote) revert BurnAmountTooLow();
        if (burnAmount > uint256(type(int256).max)) revert BurnAmountTooLarge();

        Content storage c = contents[contentId];
        if (c.status != ContentStatus.Active) revert ContentNotActive();
        if (block.timestamp > c.submittedAt + votingDuration) revert VotingClosed();

        Vote storage v = votes[contentId][msg.sender];
        if (v.voted) revert AlreadyVoted();

        // Effects.
        v.voted = true;
        v.isUpvote = isUpvote;
        v.burnAmount = burnAmount;

        if (isUpvote) {
            c.score += int256(burnAmount);
        } else {
            c.score -= int256(burnAmount);
        }
        c.totalVoteWeight += burnAmount;

        emit Voted(contentId, msg.sender, isUpvote, burnAmount);

        // Interactions: pull tokens from the voter and burn them.
        clawdToken.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
    }

    /**
     * @notice File a dispute against a piece of content, staking ETH.
     * @dev Disputable when Active or Finalized, with no dispute already active.
     * @param contentId The content to dispute.
     */
    function dispute(uint256 contentId) external payable nonReentrant {
        if (contentId >= contentCount) revert InvalidContentId();
        if (msg.value < disputeStakeRequired) revert InsufficientDisputeStake();

        Content storage c = contents[contentId];
        if (c.status != ContentStatus.Active && c.status != ContentStatus.Finalized) {
            revert ContentNotDisputable();
        }
        if (c.disputer != address(0)) revert DisputeAlreadyActive();
        if (c.status == ContentStatus.Finalized) {
            if (block.timestamp <= lastDisputedAt[contentId] + 7 days) revert RedisputeCooldown();
        }

        c.status = ContentStatus.Disputed;
        c.disputer = msg.sender;
        c.disputeStake = msg.value;
        c.disputeDeadline = block.timestamp + disputeDuration;
        lastDisputedAt[contentId] = block.timestamp;

        emit DisputeFiled(contentId, msg.sender, msg.value);
    }

    /**
     * @notice Permissionlessly resolve a dispute whose deadline has passed without owner action.
     * @dev Refunds the full stake to the disputer and restores the content's prior status. This
     *      prevents stakes from being locked forever if the owner never resolves a dispute.
     *      Follows CEI; guarded against reentrancy.
     * @param contentId The disputed content.
     */
    function resolveExpiredDispute(uint256 contentId) external nonReentrant {
        if (contentId >= contentCount) revert InvalidContentId();

        Content storage c = contents[contentId];
        if (c.status != ContentStatus.Disputed || block.timestamp <= c.disputeDeadline) {
            revert DisputeNotExpired();
        }

        uint256 stake = c.disputeStake;
        address disputer = c.disputer;

        // Effects: clear dispute bookkeeping and restore prior status.
        c.disputeStake = 0;
        c.disputer = address(0);
        c.disputeDeadline = 0;
        if (block.timestamp <= c.submittedAt + votingDuration) {
            c.status = ContentStatus.Active;
        } else {
            c.status = ContentStatus.Finalized;
        }

        emit DisputeResolved(contentId, false);

        // Interactions: refund the disputer their full stake.
        if (stake > 0) {
            (bool ok,) = payable(disputer).call{ value: stake }("");
            if (!ok) revert ETHTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Resolve an active dispute.
     * @dev If upheld, the content is removed and the disputer's ETH is returned.
     *      If not upheld, the content returns to Active (or Finalized if voting closed) and the
     *      ETH stake is retained by the contract as a treasury fee (withdrawable by owner).
     *      Follows CEI: state cleared before the ETH refund.
     * @param contentId The disputed content.
     * @param upheld Whether the dispute is upheld (content was indeed violating).
     */
    function resolveDispute(uint256 contentId, bool upheld) external onlyOwner nonReentrant {
        if (contentId >= contentCount) revert InvalidContentId();

        Content storage c = contents[contentId];
        if (c.status != ContentStatus.Disputed) revert ContentNotDisputed();

        uint256 stake = c.disputeStake;
        address disputer = c.disputer;

        // Effects: clear dispute bookkeeping regardless of outcome.
        c.disputeStake = 0;
        c.disputer = address(0);
        c.disputeDeadline = 0;

        if (upheld) {
            c.status = ContentStatus.Removed;
        } else {
            // Return to Active if still within the voting window, otherwise Finalized.
            if (block.timestamp <= c.submittedAt + votingDuration) {
                c.status = ContentStatus.Active;
            } else {
                c.status = ContentStatus.Finalized;
            }
        }

        emit DisputeResolved(contentId, upheld);

        // Interactions: refund the disputer.
        if (stake > 0) {
            if (upheld) {
                // Dispute upheld: full stake returned to the disputer.
                (bool success,) = payable(disputer).call{ value: stake }("");
                if (!success) revert ETHTransferFailed();
            } else {
                // Dispute not upheld: refund half, keep half as a treasury fee.
                uint256 refund = stake / 2;
                if (refund > 0) {
                    (bool success,) = payable(disputer).call{ value: refund }("");
                    if (!success) revert ETHTransferFailed();
                }
            }
        }
    }

    /**
     * @notice Flag a vote as manipulative and reverse its score contribution.
     * @dev The burned CLAWD is not refunded (it is already burned); only the score is corrected.
     * @param contentId The content the vote was cast on.
     * @param voter The voter whose vote is being slashed.
     */
    function slashVote(uint256 contentId, address voter) external onlyOwner {
        if (contentId >= contentCount) revert InvalidContentId();
        if (voter == address(0)) revert ZeroAddress();

        Vote storage v = votes[contentId][voter];
        if (!v.voted) revert VoteNotFound();
        if (v.slashed) revert VoteAlreadySlashed();

        if (v.burnAmount > uint256(type(int256).max)) revert BurnAmountTooLarge();

        v.slashed = true;

        Content storage c = contents[contentId];
        // Reverse the score contribution.
        if (v.isUpvote) {
            c.score -= int256(v.burnAmount);
        } else {
            c.score += int256(v.burnAmount);
        }
        // Reverse the weight contribution so tiebreak ranking stays accurate.
        if (c.totalVoteWeight >= v.burnAmount) {
            c.totalVoteWeight -= v.burnAmount;
        } else {
            c.totalVoteWeight = 0;
        }

        emit VoteSlashed(contentId, voter, v.burnAmount);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the CLAWD token address.
    function setClawdToken(address token) external onlyOwner {
        address old = address(clawdToken);
        clawdToken = IERC20(token);
        emit ClawdTokenUpdated(old, token);
    }

    /// @notice Update the minimum CLAWD burn required per vote.
    function setBurnPerVote(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 old = burnPerVote;
        burnPerVote = amount;
        emit BurnPerVoteUpdated(old, amount);
    }

    /// @notice Update the voting window duration.
    function setVotingDuration(uint256 duration) external onlyOwner {
        if (duration == 0) revert ZeroDuration();
        uint256 old = votingDuration;
        votingDuration = duration;
        emit VotingDurationUpdated(old, duration);
    }

    /// @notice Update the dispute window duration.
    function setDisputeDuration(uint256 duration) external onlyOwner {
        if (duration == 0) revert ZeroDuration();
        uint256 old = disputeDuration;
        disputeDuration = duration;
        emit DisputeDurationUpdated(old, duration);
    }

    /// @notice Update the ETH stake required to file a dispute.
    function setDisputeStakeRequired(uint256 amount) external onlyOwner {
        uint256 old = disputeStakeRequired;
        disputeStakeRequired = amount;
        emit DisputeStakeRequiredUpdated(old, amount);
    }

    /// @notice Update the anti-spam content submission fee.
    function setSubmissionFee(uint256 amount) external onlyOwner {
        uint256 old = submissionFee;
        submissionFee = amount;
        emit SubmissionFeeUpdated(old, amount);
    }

    /**
     * @notice Withdraw accumulated dispute fees (ETH) to a destination address.
     * @dev Follows CEI; guarded against reentrancy.
     * @param to Recipient of the ETH.
     */
    function withdrawETH(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();

        (bool success,) = payable(to).call{ value: amount }("");
        if (!success) revert ETHTransferFailed();

        emit ETHWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the full Content struct for an id.
    function getContent(uint256 id) external view returns (Content memory) {
        if (id >= contentCount) revert InvalidContentId();
        return contents[id];
    }

    /// @notice Return the Vote struct for a (contentId, voter) pair.
    function getVote(uint256 contentId, address voter) external view returns (Vote memory) {
        return votes[contentId][voter];
    }

    /// @notice Whether the voting window for a content is currently open.
    function isVotingOpen(uint256 contentId) external view returns (bool) {
        if (contentId >= contentCount) return false;
        Content storage c = contents[contentId];
        return c.status == ContentStatus.Active && block.timestamp <= c.submittedAt + votingDuration;
    }

    /**
     * @notice Return the top `count` content ids ranked by score (descending).
     * @dev Ties on score are broken first by totalVoteWeight, and remaining exact ties are
     *      broken pseudo-randomly using blockhash(block.number - 1) as entropy. This is a view
     *      helper for off-chain consumers; it is O(n^2) and intended for modest content counts.
     *      Removed content is excluded from the ranking.
     * @param count Maximum number of ids to return.
     * @return ranked Array of content ids, highest ranked first.
     */
    function getRankedContent(uint256 count) external view returns (uint256[] memory ranked) {
        // Cap the working set to bound gas (O(n^2) selection sort).
        uint256 total = contentCount > 200 ? 200 : contentCount;

        // Collect eligible (non-removed) ids.
        uint256[] memory eligible = new uint256[](total);
        uint256 eligibleCount;
        for (uint256 i = 0; i < total; i++) {
            if (contents[i].status != ContentStatus.Removed) {
                eligible[eligibleCount] = i;
                eligibleCount++;
            }
        }

        uint256 resultLen = count < eligibleCount ? count : eligibleCount;
        ranked = new uint256[](resultLen);
        if (resultLen == 0) {
            return ranked;
        }

        // Entropy for tiebreaking. blockhash of a recent block; falls back to 0 if unavailable.
        uint256 entropy = uint256(blockhash(block.number - 1));

        // Selection sort over the eligible set, picking the best remaining each pass.
        for (uint256 pos = 0; pos < resultLen; pos++) {
            uint256 bestIdx = pos;
            for (uint256 j = pos + 1; j < eligibleCount; j++) {
                if (_ranksHigher(eligible[j], eligible[bestIdx], entropy)) {
                    bestIdx = j;
                }
            }
            // Swap best into position.
            if (bestIdx != pos) {
                (eligible[pos], eligible[bestIdx]) = (eligible[bestIdx], eligible[pos]);
            }
            ranked[pos] = eligible[pos];
        }
    }

    /**
     * @dev Returns true if content `a` should rank higher than content `b`.
     *      Ordering: score desc, then totalVoteWeight desc, then a pseudo-random coin flip
     *      seeded with the provided entropy and the two ids.
     */
    function _ranksHigher(uint256 a, uint256 b, uint256 entropy) private view returns (bool) {
        Content storage ca = contents[a];
        Content storage cb = contents[b];

        if (ca.score != cb.score) {
            return ca.score > cb.score;
        }
        if (ca.totalVoteWeight != cb.totalVoteWeight) {
            return ca.totalVoteWeight > cb.totalVoteWeight;
        }
        // Exact tie: deterministic-but-unpredictable tiebreak using onchain entropy.
        uint256 coin = uint256(keccak256(abi.encodePacked(entropy, a, b)));
        return (coin & 1) == 0;
    }

    /// @notice Accept ETH (e.g. stray transfers); dispute stakes arrive via dispute().
    receive() external payable { }
}
