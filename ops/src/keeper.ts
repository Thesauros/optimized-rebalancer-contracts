/**
 * Epoch keeper: drives the permissionless lifecycle on the hub vault.
 *
 *   KEEPER_PRIVATE_KEY        any funded key (the calls are permissionless)
 *   KEEPER_POLL_SECONDS       loop period (default 60)
 *   KEEPER_CLAIM_FOR_USERS    "true" to also deliver claims to receivers (pays gas)
 *   KEEPER_AUTOFUND           "true" to recall hub-local liquidity for unfunded
 *                             redemptions (needs EXECUTOR_PRIVATE_KEY)
 *   PORT_KEEPER               status port (default 8082)
 *
 * Each step is simulated first and sent only if it would succeed, so the
 * keeper never burns gas on calls the contracts would reject.
 */
import { Contract } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, STRATEGY } from './abi';
import { envNumber, hubOf, loadChains, signerFor } from './config';
import { drainCursor } from './keeper-cursor';
import { log, loop, scanMany, sendWithGasMargin, serveStatus } from './util';

const SERVICE = 'keeper';

async function main() {
  const chains = loadChains();
  const hub = hubOf(chains);
  const signer = signerFor(hub, 'KEEPER_PRIVATE_KEY');
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, signer);
  const claimForUsers = process.env.KEEPER_CLAIM_FOR_USERS === 'true';
  const autofund = process.env.KEEPER_AUTOFUND === 'true';
  const executor = autofund ? signerFor(hub, 'EXECUTOR_PRIVATE_KEY') : undefined;

  const openRequests = new Set<string>();
  let scannedTo = hub.manifest.startBlock - 1;
  let lastError = '';
  let lastPass = 0;
  const actions: string[] = [];

  serveStatus(SERVICE, envNumber('PORT_KEEPER', 8082), {
    healthy: () => lastError === '' && Date.now() - lastPass < 10 * 60_000,
    status: () => ({ lastPass: new Date(lastPass).toISOString(), lastError, recentActions: actions.slice(-20), openRequests: openRequests.size }),
  });

  async function attempt(label: string, fn: string, ...args: unknown[]): Promise<boolean> {
    try {
      await vault[fn].staticCall(...args);
    } catch {
      return false;
    }
    const tx = await sendWithGasMargin(vault, fn, args);
    await tx.wait();
    actions.push(`${new Date().toISOString()} ${label} ${tx.hash}`);
    log(SERVICE, label, { tx: tx.hash });
    return true;
  }

  await loop(SERVICE, envNumber('KEEPER_POLL_SECONDS', 60) * 1000, async () => {
    try {
      await attempt('closeEpoch', 'closeEpoch');
      // clear every epoch that is ready, oldest first
      await drainCursor(
        () => attempt('clearRedeems', 'clearRedeems'),
        async () => BigInt((await vault.cursors())[1]),
        { label: 'clearRedeems' },
      );
      await drainCursor(
        () => attempt('clearDeposits', 'clearDeposits'),
        async () => BigInt((await vault.cursors())[0]),
        { label: 'clearDeposits' },
      );

      const [, nextRedeem, nextFund] = await vault.cursors();
      if (nextFund < nextRedeem) {
        const owed = BigInt((await vault.getEpoch(nextFund)).assetsOwed);
        const free = BigInt(await vault.freeCash());
        if (owed <= free) await attempt('fund', 'fund');
        else if (executor) await recall(owed - free);
      }

      if (claimForUsers) await claims();
      lastPass = Date.now();
      lastError = '';
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  });

  /** Hub-local recall: strategy -> agent idle -> vault. Cross-chain recalls are the rebalancer's job. */
  async function recall(shortfall: bigint) {
    const agent = new Contract(hub.manifest.contracts.ChainAgent, CHAIN_AGENT, executor);
    let idle = BigInt(await agent.idle());
    if (idle < shortfall) {
      const strategy = new Contract(await agent.strategy(), STRATEGY, hub.provider);
      const available = BigInt(await strategy.convertToAssets(await agent.strategyShares()));
      const pull = shortfall - idle < available ? shortfall - idle : available;
      if (pull > 0n) {
        const tx = await sendWithGasMargin(agent, 'deallocate', [pull]);
        await tx.wait();
        actions.push(`${new Date().toISOString()} deallocate ${pull} ${tx.hash}`);
        idle += pull;
      }
    }
    const amount = idle < shortfall ? idle : shortfall;
    if (amount > 0n) {
      const tx = await sendWithGasMargin(agent, 'returnToVault', [amount]);
      await tx.wait();
      actions.push(`${new Date().toISOString()} returnToVault ${amount} ${tx.hash}`);
      log(SERVICE, 'recalled hub liquidity', { amount, tx: tx.hash });
    }
    if (amount < shortfall) log(SERVICE, 'unfunded redemptions exceed hub liquidity: cross-chain recall needed', { remaining: shortfall - amount });
  }

  async function claims() {
    const head = await hub.provider.getBlockNumber();
    if (head > scannedTo) {
      await scanMany(vault, ['DepositRequested', 'RedeemRequested'], scannedTo + 1, head, (batch, through) => {
        for (const e of batch) openRequests.add(e.args.requestId.toString());
        scannedTo = through;
      });
    }
    for (const id of [...openRequests]) {
      const r = await vault.getRequest(id);
      if (Number(r.status) !== 1) {
        openRequests.delete(id);
        continue;
      }
      if (await attempt(`claim #${id}`, 'claim', id)) openRequests.delete(id);
    }
  }
}

main().catch((e) => {
  log(SERVICE, 'fatal', { error: String(e) });
  process.exit(1);
});
