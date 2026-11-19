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

        uint256 index = currentMilestone[id];
        if (index >= milestones[id].length) revert NoMilestonesRemaining(id);
        if (votingDeadline[id] != 0) revert VoteAlreadyOpened(id);
        if (block.timestamp >= milestones[id][index].dueDate) {
            revert MilestoneOverdue(id, index);
        }

        uint256 deadline = block.timestamp + VOTING_PERIOD;
        votingDeadline[id] = deadline;

        emit MilestoneSubmitted(id, index, deadline);
    }

}

