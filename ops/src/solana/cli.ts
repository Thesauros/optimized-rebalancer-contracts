import fs from 'node:fs';
import { Contract, parseUnits } from 'ethers';
import { AccountMeta, Connection, PublicKey } from '@solana/web3.js';
import { Reserve } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/Reserve';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { routeId } from '../../../deploy/crosschain/registry';
import { CHAIN_AGENT } from '../abi';
import { hubOf, loadChains, signerFor } from '../config';
import { sendWithGasMargin } from '../util';
import { TransferIndex } from '../snapshot';
import { planSolanaAdapter } from './adapter';
import { aliasOf } from './codec';
import { allocateData, executeInstruction } from './instructions';
import { collateralForAssets, readKaminoRates, strategyAdapter } from './kamino';
import { bridgeFromSolana, receiveOnSolana } from './operations';
import { planHubActivation } from './plan';
import { SolanaSpoke } from './spoke';
import { sendNative, solanaSigner, nativeWriteGate } from './transactions';

async function main() {
  const args = process.argv.slice(2),
    send = args.includes('--yes');
  const positional = args.filter((a) => a !== '--yes');
  const [command, first, second] = positional;
  if (command === 'rates') {
    if (!process.env.RPC_SOLANA) throw new Error('RPC_SOLANA is not set');
    const connection = new Connection(process.env.RPC_SOLANA, 'finalized');
    for (const s of SOLANA.strategies)
      console.log(
        JSON.stringify(
          await readKaminoRates(connection, new PublicKey(s.reserve), new PublicKey(s.market)),
          (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
          2,
        ),
      );
    return;
  }
  if (command === 'adapter') {
    if (!first || !second) throw new Error('adapter <program-id> <seed-hex>');
    console.log(JSON.stringify(planSolanaAdapter(first, second), null, 2));
    return;
  }
  const spoke = SolanaSpoke.fromEnvironment();
  if (command === 'prepare') {
    if (!first) throw new Error('prepare <public-role-and-limit-config.json>');
    const { prepareNative } = await import('./prepare');
    console.log(JSON.stringify(await prepareNative(spoke, JSON.parse(fs.readFileSync(first, 'utf8'))), null, 2));
    return;
  }
  if (command === 'plan') {
    if (!first) throw new Error('plan <public-role-and-limit-config.json>');
    const limits = JSON.parse(fs.readFileSync(first, 'utf8'));
    const hub = hubOf(loadChains());
    const alias = aliasOf(spoke.agent);
    const governance = await planHubActivation(hub, spoke.manifest, alias, limits);
    console.log(
      JSON.stringify(
        {
          family: SOLANA.family,
          network: SOLANA.network,
          accountingId: SOLANA.accountingId.toString(),
          nativeAgent: spoke.agent.toBase58(),
          alias,
          constructor: planSolanaAdapter(spoke.manifest.program, spoke.manifest.seed, spoke.manifest.hubAgent).constructorArgs,
          governance,
        },
        null,
        2,
      ),
    );
    return;
  }
  const state = await spoke.state();
  if (command === 'status') {
    const index = new TransferIndex();
    await spoke.sync(index);
    // A retired strategy holds nothing and its reserve may be gone; reading it
    // must not be able to take the status report down.
    const positions = await Promise.all(
      state.strategies.filter((s) => !s.retired).map((s) => strategyAdapter(s).read(spoke.connection, spoke.agent, s)),
    );
    console.log(
      JSON.stringify(
        {
          family: SOLANA.family,
          network: SOLANA.network,
          protocols: positions,
          agent: spoke.agent.toBase58(),
          paused: state.paused,
          checkpoint: spoke.checkpoints.at(-1),
          pendingSent: index.sent.size,
          received: index.received.size,
        },
        (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
        2,
      ),
    );
    return;
  }
  if (command === 'bridge') {
    if (!first) throw new Error('bridge <USDC> [minimumUSDC]');
    console.log(await bridgeFromSolana(spoke, parseUnits(first, 6), parseUnits(second ?? first, 6), send));
    return;
  }
  if (command === 'bridge-in') {
    const hub = hubOf(loadChains());
    if (hub.manifest.contracts.ChainAgent.toLowerCase() !== spoke.manifest.hubAgent.toLowerCase())
      throw new Error('Base manifest/agent mismatch');
    const agent = new Contract(spoke.manifest.hubAgent, CHAIN_AGENT, signerFor(hub, 'EXECUTOR_PRIVATE_KEY'));
    const amount = parseUnits(first, 6),
      minimum = parseUnits(second ?? first, 6);
    const params = [
      routeId(hub.chainId, SOLANA.accountingId),
      amount,
      minimum,
      `0x${Buffer.alloc(32).toString('hex')}`,
    ];
    await agent.bridgeOut.staticCall(...params);
    if (!send) {
      console.log('simulated');
      return;
    }
    const tx = await sendWithGasMargin(agent, 'bridgeOut', params);
    await tx.wait();
    console.log(tx.hash);
    return;
  }
  if (command === 'receive') {
    if (!first) throw new Error('receive <attestation.json>');
    const att = JSON.parse(fs.readFileSync(first, 'utf8'));
    console.log(await receiveOnSolana(spoke, att.message, att.attestation, send));
    return;
  }
  if (!['observe', 'allocate', 'withdraw', 'redeem-all'].includes(command))
    throw new Error(
      'commands: rates | adapter <program-id> <seed-hex> | status | prepare <public-config.json> | plan <public-config.json> | observe | allocate <index> <USDC> | withdraw <index> <USDC> | redeem-all <index> | bridge-in <USDC> [minimumUSDC] | bridge <USDC> [minimumUSDC] | receive <attestation.json>; writes simulate unless --yes',
    );
  await nativeWriteGate(async () => {
    const fresh = await spoke.state(),
      payer = solanaSigner(command === 'observe' ? 'SOLANA_CHECKPOINT_KEYPAIR' : 'SOLANA_EXECUTOR_KEYPAIR');
    let data: Buffer = Buffer.from([0]);
    let prefix: AccountMeta[] = [];
    if (command !== 'observe') {
      const index = Number(first),
        strategy = fresh.strategies[index];
      if (!Number.isInteger(index) || !strategy) throw new Error('invalid strategy index');
      const adapter = strategyAdapter(strategy),
        deposit = command === 'allocate';
      // Retirement is terminal for deposits; exits stay open until the custody
      // is empty. The program enforces both.
      if (deposit && strategy.retired) throw new Error('strategy is retired');
      const position = await adapter.read(spoke.connection, spoke.agent, strategy);
      let amount: bigint, minimum: bigint;
      if (deposit) {
        amount = parseUnits(second, 6);
        const info = await spoke.connection.getAccountInfo(strategy.reserve, 'finalized');
        if (!info) throw new Error('reserve unavailable');
        const quote = collateralForAssets(Reserve.decode(info.data), amount);
        minimum = ((quote - 1n) * 9990n) / 10000n;
      } else if (command === 'redeem-all') {
        amount = position.collateralUnits;
        minimum = (position.value * 9990n) / 10000n;
      } else {
        minimum = parseUnits(second, 6);
        const info = await spoke.connection.getAccountInfo(strategy.reserve, 'finalized');
        if (!info) throw new Error('reserve unavailable');
        amount = collateralForAssets(Reserve.decode(info.data), minimum);
      }
      if (amount <= 0n || minimum <= 0n) throw new Error('operation has no positive amount/minimum');
      if (!deposit && minimum > position.freelyAvailableLiquidity)
        throw new Error('Kamino currently has insufficient freely available USDC');
      data = allocateData(index, amount, minimum, deposit);
      prefix = adapter.executionAccounts(spoke.agent, spoke.idle, strategy, deposit);
    }
    const ix = executeInstruction(
      spoke.program,
      spoke.agent,
      spoke.idle,
      payer.publicKey,
      fresh.sequence,
      fresh.strategies,
      data,
      prefix,
    );
    console.log(await sendNative(spoke, [ix], payer, [], `${command}-${fresh.sequence}`, send));
  });
}
main().catch((e) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exitCode = 1;
});
