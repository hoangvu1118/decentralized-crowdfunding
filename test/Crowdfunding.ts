import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { getAddress, parseEther, zeroHash } from "viem";

describe("Crowdfunding campaign creation", async function () {
  const { viem, networkHelpers } = await network.create();

  async function deployCampaignFixture() {
    const contract = await viem.deployContract("Crowdfunding");
    const [creator] = await viem.getWalletClients();
    const goal = parseEther("1");
    const deadline = BigInt(await networkHelpers.time.latest()) + 3_600n;
    const shares = [4_000n, 6_000n];
    const dueDates = [deadline + 86_400n, deadline + 172_800n];
    return { contract, creator, goal, deadline, shares, dueDates };
  }

  it("stores the creator, terms, and both ordered milestones", async function () {
    const { contract, creator, goal, deadline, shares, dueDates } =
      await networkHelpers.loadFixture(deployCampaignFixture);

    await viem.assertions.emitWithArgs(
      contract.write.createCampaign([goal, deadline, shares, dueDates, zeroHash]),
      contract,
      "CampaignCreated",
      [1n, getAddress(creator.account.address), goal],
    );

    assert.deepEqual(await contract.read.campaigns([1n]), [
      getAddress(creator.account.address), goal, deadline, zeroHash,
    ]);
    assert.deepEqual(await contract.read.milestones([1n, 0n]), [shares[0], dueDates[0]]);
    assert.deepEqual(await contract.read.milestones([1n, 1n]), [shares[1], dueDates[1]]);
    assert.equal(await contract.read.nextCampaignId(), 2n);
  });

  it("rejects a zero goal and an expired deadline", async function () {
    const { contract, goal, deadline, shares, dueDates } =
      await networkHelpers.loadFixture(deployCampaignFixture);

    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([0n, deadline, shares, dueDates, zeroHash]),
      contract,
      "InvalidGoal",
    );
    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([goal, 1n, shares, dueDates, zeroHash]),
      contract,
      "InvalidFundingDeadline",
    );
  });

  it("rejects mismatched arrays, invalid shares, and unordered dates", async function () {
    const { contract, goal, deadline, shares, dueDates } =
      await networkHelpers.loadFixture(deployCampaignFixture);

    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([goal, deadline, shares, [dueDates[0]], zeroHash]),
      contract,
      "InvalidMilestoneArrays",
    );
    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([goal, deadline, [0n, 10_000n], dueDates, zeroHash]),
      contract,
      "InvalidMilestoneShare",
    );
    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([goal, deadline, shares, [...dueDates].reverse(), zeroHash]),
      contract,
      "InvalidMilestoneDueDate",
    );
    await viem.assertions.revertWithCustomError(
      contract.write.createCampaign([goal, deadline, [4_000n, 5_000n], dueDates, zeroHash]),
      contract,
      "InvalidTotalShare",
    );
    assert.equal(await contract.read.nextCampaignId(), 1n);
  });
});
