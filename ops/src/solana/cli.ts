import fs from 'node:fs';
import { Contract, Interface, parseUnits, zeroPadValue } from 'ethers';
import { AccountMeta, Connection, PublicKey } from '@solana/web3.js';
import { Reserve } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/Reserve';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { routeId } from '../../../deploy/crosschain/registry';
import { CHAIN_AGENT } from '../abi';
import { hubOf, loadChains, signerFor } from '../config';
import { sendWithGasMargin } from '../util';
import { TransferIndex } from '../snapshot';
import { aliasOf } from './codec';
import { allocateData, executeInstruction } from './instructions';
import { collateralForAssets, readKaminoRates, strategyAdapter } from './kamino';
import { bridgeFromSolana, receiveOnSolana } from './operations';
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
    const hub = hubOf(loadChains()),
      agent = new Contract(spoke.manifest.hubAgent, CHAIN_AGENT, hub.provider);
    const chainIds: bigint[] = await new Contract(
      hub.manifest.contracts.TickAccountant,
      ['function chainIds() view returns (uint64[])'],
      hub.provider,
    ).chainIds();
    const alias = aliasOf(spoke.agent);
    const adminInterface = new Interface([
      'function setAdapter(address,bool)',
      'function setPeer(uint64,address,bool)',
      'function addRoute(bytes32,address,uint64,address,uint16,uint128,uint128,uint128)',
      'function setAgent(uint64,address,bool)',
      'function setChains(uint64[])',
    ]);
    const wanted = [...new Set([...chainIds, SOLANA.accountingId])].sort((a, b) => (a < b ? -1 : 1));
    const actions = [
      {
        label: 'ChainAgent.setAdapter',
        target: spoke.manifest.hubAgent,
        data: adminInterface.encodeFunctionData('setAdapter', [spoke.manifest.hubAdapter, true]),
      },
      {
        label: 'ChainAgent.setPeer',
        target: spoke.manifest.hubAgent,
        data: adminInterface.encodeFunctionData('setPeer', [SOLANA.accountingId, alias, true]),
      },
      {
        label: 'ChainAgent.addRoute',
        target: spoke.manifest.hubAgent,
        data: adminInterface.encodeFunctionData('addRoute', [
          routeId(hub.chainId, SOLANA.accountingId),
          spoke.manifest.hubAdapter,
          SOLANA.accountingId,
          alias,
          limits.maxFeeBps,
          BigInt(limits.maxPerTransfer),
          BigInt(limits.capacity),
          BigInt(limits.refillPerSecond),
        ]),
      },
      {
        label: 'TickAccountant.setAgent',
        target: hub.manifest.contracts.TickAccountant,
        data: adminInterface.encodeFunctionData('setAgent', [SOLANA.accountingId, alias, true]),
      },
      {
        label: 'TickAccountant.setChains',
        target: hub.manifest.contracts.TickAccountant,
        data: adminInterface.encodeFunctionData('setChains', [wanted]),
      },
    ].map((a) => ({ ...a, value: '0' }));
    console.log(
      JSON.stringify(
        {
          family: SOLANA.family,
          network: SOLANA.network,
          accountingId: SOLANA.accountingId.toString(),
          nativeAgent: spoke.agent.toBase58(),
          alias,
          constructor: {
            asset: hub.entry.usdc,
            agent: spoke.manifest.hubAgent,
            tokenMessenger: hub.entry.cctp.tokenMessenger,
            messageTransmitter: hub.entry.cctp.messageTransmitter,
            remoteAgent: zeroPadValue(`0x${spoke.agent.toBuffer().toString('hex')}`, 32),
            remoteTokenAccount: `0x${spoke.idle.toBuffer().toString('hex')}`,
            remoteMint: `0x${new PublicKey(SOLANA.asset.mint).toBuffer().toString('hex')}`,
            remoteTokenMessenger: `0x${new PublicKey(SOLANA.cctp.tokenMessenger).toBuffer().toString('hex')}`,
          },
          governance: {
            agent: spoke.manifest.hubAgent,
            adapter: spoke.manifest.hubAdapter,
            peer: alias,
            routeId: routeId(hub.chainId, SOLANA.accountingId),
            chains: [...new Set([...chainIds, SOLANA.accountingId])].sort((a, b) => (a < b ? -1 : 1)).map(String),
            prerequisite:
              'Deploy/verify CctpSolanaAdapter first; activate only after native checkpoint, lookup table and relayer readiness. These are unsigned Timelock actions.',
            actions,
            alreadyPeer: await agent.isPeer(SOLANA.accountingId, alias),
          },
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
    const positions = await Promise.all(
      state.strategies.map((s) => strategyAdapter(s).read(spoke.connection, spoke.agent, s)),
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
      'commands: rates | status | prepare <public-config.json> | plan <public-config.json> | observe | allocate <index> <USDC> | withdraw <index> <USDC> | redeem-all <index> | bridge-in <USDC> [minimumUSDC] | bridge <USDC> [minimumUSDC] | receive <attestation.json>; writes simulate unless --yes',
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
