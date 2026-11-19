// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Crowdfunding is ReentrancyGuard {
    uint256 private constant TOTAL_SHARE_BPS = 10_000;

    struct Campaign {
        address creator;
        uint256 goal;
        uint256 fundingDeadline;
        bytes32 descriptionHash;
    }

    struct Milestone {
        uint256 shareBps;
        uint256 dueDate;
    }

    error InvalidGoal();
    error InvalidFundingDeadline();
    error InvalidMilestoneArrays();
    error InvalidMilestoneShare(uint256 index);
    error InvalidMilestoneDueDate(uint256 index);
    error InvalidTotalShare(uint256 total);

    event CampaignCreated(uint256 indexed id, address indexed creator, uint256 goal);

    uint256 public nextCampaignId = 1;
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => Milestone[]) public milestones;

    function createCampaign(
        uint256 goal,
        uint256 deadline,
        uint256[] calldata shares,
        uint256[] calldata dueDates,
        bytes32 descHash
    ) external returns (uint256 id) {
        if (goal == 0) revert InvalidGoal();
        if (deadline <= block.timestamp) revert InvalidFundingDeadline();
        if (shares.length == 0 || shares.length != dueDates.length) {
            revert InvalidMilestoneArrays();
        }

        id = nextCampaignId;
        uint256 totalShare;
        uint256 previousDueDate = deadline;
        for (uint256 i = 0; i < shares.length; i++) {
            uint256 share = shares[i];
            uint256 dueDate = dueDates[i];
            if (share == 0 || share > TOTAL_SHARE_BPS) revert InvalidMilestoneShare(i);
            if (dueDate <= previousDueDate) revert InvalidMilestoneDueDate(i);

            totalShare += share;
            previousDueDate = dueDate;
            milestones[id].push(Milestone(share, dueDate));
        }
        if (totalShare != TOTAL_SHARE_BPS) revert InvalidTotalShare(totalShare);

        campaigns[id] = Campaign(msg.sender, goal, deadline, descHash);
        nextCampaignId = id + 1;
        emit CampaignCreated(id, msg.sender, goal);
    }

    mapping(uint256 => uint256) public totalRaised;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    
    error CampaignNotFound(uint256 id);
    error FundingClosed(uint256 id);
    error EmptyPledge();

    event Pledged(uint256 indexed id, address indexed backer, uint256 amount);

    function pledge(uint256 id) external payable {
        Campaign storage campaign = campaigns[id];

        if (campaign.creator == address(0)) revert CampaignNotFound(id);
        if (block.timestamp >= campaign.fundingDeadline) revert FundingClosed(id);
        if (msg.value == 0) revert EmptyPledge();

        contributions[id][msg.sender] += msg.value;
        totalRaised[id] += msg.value;

        emit Pledged(id, msg.sender, msg.value);
    }

    enum FundingStatus {
        Pending,
        Funded,
        Failed
    }

    mapping(uint256 => FundingStatus) public fundingStatus;

    error FundingStillOpen(uint256 id);
    error FundingAlreadySettled(uint256 id);

    event FundingSettled(
        uint256 indexed id,
        FundingStatus status,
        uint256 raised
    );

    function settleFunding(uint256 id) external {
        Campaign storage campaign = campaigns[id];

        if (campaign.creator == address(0)) revert CampaignNotFound(id);
        if (block.timestamp < campaign.fundingDeadline) revert FundingStillOpen(id);
        if (fundingStatus[id] != FundingStatus.Pending) {
            revert FundingAlreadySettled(id);
        }

        uint256 raised = totalRaised[id];
        FundingStatus result = raised >= campaign.goal
            ? FundingStatus.Funded
            : FundingStatus.Failed;

        fundingStatus[id] = result;
        emit FundingSettled(id, result, raised);
    }

    error CampaignNotFailed(uint256 id);
    error NothingToRefund(uint256 id);
    error RefundTransferFailed();

    event Refunded(uint256 indexed id, address indexed backer, uint256 amount);

    function claimRefund(uint256 id) external nonReentrant {
        if (campaigns[id].creator == address(0)) revert CampaignNotFound(id);
        if (fundingStatus[id] != FundingStatus.Failed) revert CampaignNotFailed(id);

        uint256 amount = contributions[id][msg.sender];
        if (amount == 0) revert NothingToRefund(id);

        contributions[id][msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert RefundTransferFailed();

        emit Refunded(id, msg.sender, amount);
    }

    uint256 public constant VOTING_PERIOD = 3 days;

    mapping(uint256 => uint256) public currentMilestone;
    mapping(uint256 => uint256) public votingDeadline;

    error NotCampaignCreator(uint256 id);
    error CampaignNotFunded(uint256 id);
    error NoMilestonesRemaining(uint256 id);
    error MilestoneOverdue(uint256 id, uint256 milestoneIndex);
    error VoteAlreadyOpened(uint256 id);

    event MilestoneSubmitted(
        uint256 indexed id,
        uint256 indexed milestoneIndex,
        uint256 votingDeadline
    );

    function submitMilestone(uint256 id) external {
        Campaign storage campaign = campaigns[id];

        if (campaign.creator == address(0)) revert CampaignNotFound(id);
        if (msg.sender != campaign.creator) revert NotCampaignCreator(id);
        if (fundingStatus[id] != FundingStatus.Funded) {
            revert CampaignNotFunded(id);
        }

        if (campaignCancelled[id]) revert CampaignAlreadyCancelled(id);
        if (milestoneApproved[id]) revert MilestoneAlreadyApproved(id);

        uint256 index = currentMilestone[id];
        if (index >= milestones[id].length) revert NoMilestonesRemaining(id);
        if (votingDeadline[id] != 0) revert VoteAlreadyOpened(id);
        if (block.timestamp >= milestones[id][index].dueDate) {
            revert MilestoneOverdue(id, index);
        }

        uint256 deadline = block.timestamp + VOTING_PERIOD;
        votingDeadline[id] = deadline;
        votingRound[id] += 1;

        emit MilestoneSubmitted(id, index, deadline);
        }

        struct VoteTally {
        uint256 yesWeight;
        uint256 noWeight;
        }

        mapping(uint256 => uint256) public votingRound;
        mapping(uint256 => mapping(uint256 => VoteTally)) public voteTallies;
        mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasVoted;

        error VotingNotOpen(uint256 id);
        error NotABacker(uint256 id);
        error AlreadyVoted(uint256 id);

        event Voted(
            uint256 indexed id,
            uint256 indexed round,
            address indexed backer,
            bool approve,
            uint256 weight
        );

        function vote(uint256 id, bool approve) external {
        uint256 deadline = votingDeadline[id];
        if (deadline == 0 || block.timestamp >= deadline) {
            revert VotingNotOpen(id);
        }

        uint256 weight = contributions[id][msg.sender];
        if (weight == 0) revert NotABacker(id);

        uint256 round = votingRound[id];
        if (hasVoted[id][round][msg.sender]) revert AlreadyVoted(id);

        hasVoted[id][round][msg.sender] = true;

        VoteTally storage tally = voteTallies[id][round];
        if (approve) {
            tally.yesWeight += weight;
        } else {
            tally.noWeight += weight;
        }

        emit Voted(id, round, msg.sender, approve, weight);
    }

    mapping(uint256 => bool) public milestoneApproved;
    mapping(uint256 => uint256) public milestoneRejections;
    mapping(uint256 => bool) public campaignCancelled;

    error VoteStillOpen(uint256 id);
    error MilestoneAlreadyApproved(uint256 id);
    error CampaignAlreadyCancelled(uint256 id);

    event MilestoneApproved(uint256 indexed id, uint256 indexed milestoneIndex);
    event MilestoneRejected(uint256 indexed id, uint256 indexed milestoneIndex);
    event CampaignCancelled(uint256 indexed id);

    function finalizeVote(uint256 id) external {
        uint256 deadline = votingDeadline[id];
        if (deadline == 0) revert VotingNotOpen(id);
        if (block.timestamp < deadline) revert VoteStillOpen(id);

        uint256 index = currentMilestone[id];
        VoteTally storage tally = voteTallies[id][votingRound[id]];

        uint256 turnout = tally.yesWeight + tally.noWeight;
        uint256 raised = totalRaised[id];

        // Calculate 30% of the total, rounded up to a whole wei.
        uint256 quorum = (raised / 10) * 3 + ((raised % 10) * 3 + 9) / 10;

        votingDeadline[id] = 0;

        if (turnout >= quorum && tally.yesWeight > tally.noWeight) {
            milestoneApproved[id] = true;
            emit MilestoneApproved(id, index);
            return;
        }

        milestoneRejections[id] += 1;
        emit MilestoneRejected(id, index);

        if (milestoneRejections[id] == 2) {
            campaignCancelled[id] = true;
            emit CampaignCancelled(id);
        }
    }

    mapping(uint256 => uint256) public totalReleased;

    error MilestoneNotApproved(uint256 id);
    error PayoutTransferFailed();

    event FundsReleased(
        uint256 indexed id,
        uint256 indexed milestoneIndex,
        uint256 amount
    );

    function withdrawMilestone(uint256 id) external nonReentrant {
        Campaign storage campaign = campaigns[id];

        if (campaign.creator == address(0)) revert CampaignNotFound(id);
        if (msg.sender != campaign.creator) revert NotCampaignCreator(id);
        if (campaignCancelled[id]) revert CampaignAlreadyCancelled(id);
        if (!milestoneApproved[id]) revert MilestoneNotApproved(id);

        uint256 index = currentMilestone[id];
        uint256 raised = totalRaised[id];
        uint256 amount;

        if (index + 1 == milestones[id].length) {
            // Give the final milestone any wei left over from rounding.
            amount = raised - totalReleased[id];
        } else {
            amount = raised * milestones[id][index].shareBps / TOTAL_SHARE_BPS;
        }

        milestoneApproved[id] = false;
        milestoneRejections[id] = 0;
        currentMilestone[id] = index + 1;
        totalReleased[id] += amount;

        if (amount != 0) {
            (bool success, ) = payable(campaign.creator).call{value: amount}("");
            if (!success) revert PayoutTransferFailed();
        }

        emit FundsReleased(id, index, amount);
    }

    error MilestoneNotOverdue(uint256 id, uint256 milestoneIndex);
    error VoteAwaitingFinalization(uint256 id);

    function cancelOverdue(uint256 id) external {
        if (campaigns[id].creator == address(0)) revert CampaignNotFound(id);
        if (fundingStatus[id] != FundingStatus.Funded) revert CampaignNotFunded(id);
        if (campaignCancelled[id]) revert CampaignAlreadyCancelled(id);

        uint256 index = currentMilestone[id];
        if (index >= milestones[id].length) revert NoMilestonesRemaining(id);
        if (milestoneApproved[id]) revert MilestoneAlreadyApproved(id);
        if (votingDeadline[id] != 0) revert VoteAwaitingFinalization(id);
        if (block.timestamp < milestones[id][index].dueDate) {
            revert MilestoneNotOverdue(id, index);
        }

        campaignCancelled[id] = true;
        emit CampaignCancelled(id);
    }
}

