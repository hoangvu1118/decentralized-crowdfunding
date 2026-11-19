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
