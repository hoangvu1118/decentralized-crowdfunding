import assert from "node:assert/strict";
import { it } from "node:test";
import { network } from "hardhat";
import { zeroHash } from "viem";

it("refunds a failed campaign once without touching another campaign's funds", async () => {
  const { viem, networkHelpers } = await network.create();
  const [creator, alice, bob] = await viem.getWalletClients();
  const publicClient = await viem.getPublicClient();
  const contract = await viem.deployContract("Crowdfunding");

  const deadline = BigInt(await networkHelpers.time.latest()) + 3_600n;
  const dueDates = [deadline + 86_400n];

  // Both campaigns have a 100 wei goal and one milestone.
  for (let i = 0; i < 2; i++) {
    await contract.write.createCampaign(
      [100n, deadline, [10_000n], dueDates, zeroHash],
      { account: creator.account },
    );
  }

  await contract.write.pledge([1n], { account: alice.account, value: 60n });
  await contract.write.pledge([2n], { account: bob.account, value: 150n });

  await networkHelpers.time.increaseTo(deadline);
  await contract.write.settleFunding([1n]);

  await viem.assertions.emitWithArgs(
    contract.write.claimRefund([1n], { account: alice.account }),
    contract,
    "Refunded",
    [1n, alice.account.address, 60n],
  );

  await viem.assertions.revertWithCustomError(
    contract.write.claimRefund([1n], { account: alice.account }),
    contract,
    "NothingToRefund",
  );

  assert.equal(await contract.read.totalRaised([2n]), 150n);
  assert.equal(await contract.read.contributions([2n, bob.account.address]), 150n);
  assert.equal(await publicClient.getBalance({ address: contract.address }), 150n);
});

it("splits the remaining funds after a milestone payout and cancellation", async () => {
  const { viem, networkHelpers } = await network.create();
  const [creator, alice, bob] = await viem.getWalletClients();
  const publicClient = await viem.getPublicClient();
  const contract = await viem.deployContract("Crowdfunding");

  const day = 86_400n;
  const deadline = BigInt(await networkHelpers.time.latest()) + day;
  const firstDue = deadline + 7n * day;
  const secondDue = deadline + 14n * day;

  await contract.write.createCampaign(
    [100n, deadline, [4_000n, 6_000n], [firstDue, secondDue], zeroHash],
    { account: creator.account },
  );
  await contract.write.pledge([1n], { account: alice.account, value: 60n });
  await contract.write.pledge([1n], { account: bob.account, value: 40n });

  await networkHelpers.time.increaseTo(deadline);
  await contract.write.settleFunding([1n]);
  await contract.write.submitMilestone([1n], { account: creator.account });
  await contract.write.vote([1n, true], { account: alice.account });

  await networkHelpers.time.increaseTo(await contract.read.votingDeadline([1n]));
  await contract.write.finalizeVote([1n]);
  await contract.write.withdrawMilestone([1n], { account: creator.account });

  assert.equal(await contract.read.totalReleased([1n]), 40n);
  assert.equal(await contract.read.currentMilestone([1n]), 1n);

  await networkHelpers.time.increaseTo(secondDue);
  await contract.write.cancelOverdue([1n], { account: bob.account });

  // Bob claims first and gets 40% of the original 60-wei refund pool.
  await viem.assertions.balancesHaveChanged(
    contract.write.claimRemaining([1n], { account: bob.account }),
    [{ address: bob.account.address, amount: 24n }],
  );

  // Alice still gets 60% of that same pool, even after Bob's claim.
  await viem.assertions.balancesHaveChanged(
    contract.write.claimRemaining([1n], { account: alice.account }),
    [{ address: alice.account.address, amount: 36n }],
  );

  assert.equal(await publicClient.getBalance({ address: contract.address }), 0n);
});
