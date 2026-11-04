/**
 * Server preflight: verifies the environment before any service starts, and
 * exits non-zero on the first class of problem that would otherwise surface as
 * a silent stall hours later (a dead RPC, a key without its role, an empty gas
 * tank, an unwritable state directory, two processes sharing one nonce).
 *
 *   npm run preflight -- --layout operators   # stand: nav+keeper+relayer share one key, one process
 *   npm run preflight -- --layout separate    # production: one key and one process per role
 *
 * Read-only: it sends nothing.
 */
import fs from 'fs';
import path from 'path';
import { Contract, JsonRpcProvider, Wallet, formatEther, id } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, TICK_ACCOUNTANT } from './abi';
import { Chain, hubOf, loadChains, rpcUrl } from './config';
import { TRANSFER_INDEX_FILE } from './snapshot';
import { PROFILE } from '../../deploy/crosschain/registry';

type Result = { ok: boolean; warn?: boolean; label: string; detail?: string };
const results: Result[] = [];
const pass = (label: string, detail?: string) => results.push({ ok: true, label, detail });
const fail = (label: string, detail?: string) => results.push({ ok: false, label, detail });
const warn = (label: string, detail?: string) => results.push({ ok: true, warn: true, label, detail });

const layoutArg = process.argv.indexOf('--layout');
const layout = layoutArg > 0 ? process.argv[layoutArg + 1] : undefined;
const MIN_GAS_WEI = BigInt(process.env.PREFLIGHT_MIN_GAS_WEI ?? '100000000000000'); // 0.0001 ETH

async function withTimeout<T>(p: Promise<T>, ms = 20_000): Promise<T> {
  return Promise.race([p, new Promise<T>((_, rej) => setTimeout(() => rej(new Error(`timeout after ${ms} ms`)), ms))]);
}

function addressOf(envKey: string): string | undefined {
  const pk = process.env[envKey];
  if (!pk) return undefined;
  try {
    return new Wallet(pk).address;
  } catch {
    fail(`${envKey} is a valid private key`);
    return undefined;
  }
}

async function checkRpc(c: Chain) {
  const read = rpcUrl(c.key);
  const send = process.env[`RPC_SEND_${c.key.toUpperCase()}`];
  for (const [label, url] of [['read', read], ['send', send]] as const) {
    if (!url) {
      if (label === 'send') warn(`${c.key} RPC_SEND_${c.key.toUpperCase()} set`, 'broadcasts go through the read RPC');
      continue;
    }
    try {
      const p = new JsonRpcProvider(url, undefined, { batchMaxCount: 1 });
      const id = BigInt(await withTimeout(p.send('eth_chainId', [])));
      if (id === c.chainId) pass(`${c.key} ${label} RPC chain id ${id}`);
      else fail(`${c.key} ${label} RPC chain id`, `${id}, expected ${c.chainId}`);
      p.destroy();
    } catch (e) {
      fail(`${c.key} ${label} RPC reachable`, String((e as Error).message).slice(0, 160));
    }
  }
  try {
    const head = await withTimeout(c.provider.getBlockNumber());
    const logs = await withTimeout(c.provider.getLogs({ address: c.manifest.contracts.ChainAgent, fromBlock: head - 50, toBlock: head }));
    pass(`${c.key} eth_getLogs`, `${logs.length} agent logs in the last 50 blocks`);
    const past = await withTimeout(c.provider.getBalance(c.manifest.contracts.ChainAgent, c.manifest.startBlock));
    pass(`${c.key} archive reads`, `state at the deployment block served (${past} wei)`);
  } catch (e) {
    fail(`${c.key} logs and archive reads`, String((e as Error).message).slice(0, 160));
  }
}

async function checkContracts(c: Chain) {
  for (const [name, address] of Object.entries(c.manifest.contracts)) {
    const code = await withTimeout(c.provider.getCode(address));
    if (code === '0x') fail(`${c.key} ${name} has code`, address);
  }
  pass(`${c.key} manifest contracts have code`, `${Object.keys(c.manifest.contracts).length} contracts, profile ${c.manifest.profile ?? 'production'}, phase ${c.manifest.phase}`);
  if (c.manifest.phase < 3) fail(`${c.key} deployment finished`, `manifest at phase ${c.manifest.phase}; run phases 1-4 first`);
}

async function checkGas(c: Chain, label: string, address: string) {
  const b = await withTimeout(c.provider.getBalance(address));
  if (b === 0n) fail(`${label} has gas on ${c.key}`, `${address}: 0 ETH`);
  else if (b < MIN_GAS_WEI) warn(`${label} gas on ${c.key}`, `${address}: ${formatEther(b)} ETH, below ${formatEther(MIN_GAS_WEI)}`);
  else pass(`${label} gas on ${c.key}`, `${address}: ${formatEther(b)} ETH`);
}

function checkWritable(label: string, file: string) {
  const dir = path.dirname(path.resolve(file));
  try {
    fs.mkdirSync(dir, { recursive: true });
    const probe = path.join(dir, `.preflight-${process.pid}`);
    fs.writeFileSync(probe, 'ok');
    fs.unlinkSync(probe);
    pass(`${label} writable`, path.resolve(file));
  } catch (e) {
    fail(`${label} writable`, `${dir}: ${(e as Error).message}`);
  }
}

async function main() {
  if (layout !== 'operators' && layout !== 'separate') {
    console.error('usage: preflight --layout operators|separate');
    process.exit(2);
  }
  let chains: Chain[];
  try {
    chains = loadChains();
  } catch (e) {
    console.error(`FAIL configuration: ${(e as Error).message}`);
    process.exit(1);
  }
  const hub = hubOf(chains);

  // the registry picks expected limits by CROSSCHAIN_PROFILE; a mismatch with the
  // deployed profile makes every deployment check fail and the monitor page
  // critical around the clock
  for (const c of chains) {
    const deployed = c.manifest.profile ?? 'production';
    if (deployed === PROFILE) pass(`${c.key} CROSSCHAIN_PROFILE matches the deployment`, PROFILE);
    else fail(`${c.key} CROSSCHAIN_PROFILE matches the deployment`, `env selects "${PROFILE}", manifest was deployed as "${deployed}"`);
  }

  for (const c of chains) {
    await checkRpc(c);
    await checkContracts(c);
  }

  // keys and roles
  const nav = addressOf('NAV_UPDATER_PRIVATE_KEY');
  const keeper = addressOf('KEEPER_PRIVATE_KEY');
  const relayer = addressOf('RELAYER_PRIVATE_KEY');
  const autofund = process.env.KEEPER_AUTOFUND === 'true';
  const executor = addressOf('EXECUTOR_PRIVATE_KEY');
  for (const [k, a] of [['NAV_UPDATER_PRIVATE_KEY', nav], ['KEEPER_PRIVATE_KEY', keeper], ['RELAYER_PRIVATE_KEY', relayer]] as const) {
    if (!a) fail(`${k} set`);
  }
  if (autofund && !executor) fail('EXECUTOR_PRIVATE_KEY set', 'KEEPER_AUTOFUND=true needs it');

  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  if (nav) {
    if (await accountant.hasRole(id('NAV_UPDATER_ROLE'), nav)) pass('NAV updater holds NAV_UPDATER_ROLE', nav);
    else fail('NAV updater holds NAV_UPDATER_ROLE', `${nav} does not`);
  }
  if (executor) {
    const onVault = await vault.hasRole(id('EXECUTOR_ROLE'), executor);
    const onAgents = await Promise.all(chains.map((c) => new Contract(c.manifest.contracts.ChainAgent, CHAIN_AGENT, c.provider).hasRole(id('EXECUTOR_ROLE'), executor)));
    if (onVault && onAgents.every(Boolean)) pass('executor holds EXECUTOR_ROLE on the vault and every agent', executor);
    else (autofund ? fail : warn)('executor holds EXECUTOR_ROLE', `${executor}: vault ${onVault}, agents ${onAgents.join(',')}`);
  }

  // one address sending from two processes overwrites its own transactions
  const signing = [nav, keeper, relayer].filter(Boolean) as string[];
  const distinct = new Set(signing.map((a) => a.toLowerCase())).size;
  if (layout === 'separate' && distinct < signing.length) {
    fail('one key per process', 'NAV updater, keeper and relayer share a key; run the operators layout (docker compose --profile stand)');
  } else if (layout === 'operators' && distinct === signing.length && signing.length === 3) {
    warn('operators layout', 'the three keys are distinct; the separate layout isolates them better');
  } else {
    pass(`signing layout ${layout}`, `${distinct} distinct signer(s) for nav, keeper, relayer`);
  }

  // gas where each role sends
  if (nav) await checkGas(hub, 'NAV updater', nav);
  if (keeper && keeper !== nav) await checkGas(hub, 'keeper', keeper);
  if (relayer) for (const c of chains) await checkGas(c, 'relayer', relayer);

  // state and external services
  checkWritable('TRANSFER_INDEX_FILE', TRANSFER_INDEX_FILE);
  checkWritable('INDEXER_DB', process.env.INDEXER_DB ?? 'crosschain-indexer.sqlite');
  const mode = process.env.RELAYER_ATTESTATION ?? 'iris';
  if (mode !== 'iris') fail('RELAYER_ATTESTATION=iris', `is "${mode}"; the local attester exists only on forks`);
  try {
    const base = process.env.IRIS_API_URL ?? 'https://iris-api.circle.com';
    const r = await withTimeout(fetch(`${base}/v2/messages/${hub.entry.cctp.domain}?transactionHash=0x${'00'.repeat(32)}`));
    if (r.status === 404 || r.status === 400 || r.ok) pass('Circle Iris reachable', `${base} answered ${r.status}`);
    else fail('Circle Iris reachable', `${base} answered ${r.status}`);
  } catch (e) {
    fail('Circle Iris reachable', (e as Error).message);
  }
  if (process.env.TELEGRAM_TOKEN && process.env.TELEGRAM_CHAT_ID) {
    try {
      const r = await withTimeout(fetch(`https://api.telegram.org/bot${process.env.TELEGRAM_TOKEN}/getMe`));
      if (r.ok) pass('Telegram bot token valid');
      else fail('Telegram bot token valid', `getMe answered ${r.status}`);
    } catch (e) {
      fail('Telegram reachable', (e as Error).message);
    }
  } else {
    warn('Telegram alerts configured', 'TELEGRAM_TOKEN / TELEGRAM_CHAT_ID unset: alerts go only to the logs');
  }

  for (const r of results) console.log(`${r.ok ? (r.warn ? 'WARN' : ' ok ') : 'FAIL'}  ${r.label}${r.detail ? `  (${r.detail})` : ''}`);
  const failed = results.filter((r) => !r.ok).length;
  console.log(failed ? `\nPREFLIGHT FAILED: ${failed} problem(s)` : `\nPREFLIGHT PASSED (${results.filter((r) => r.warn).length} warning(s))`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(`FAIL preflight crashed: ${e instanceof Error ? e.stack : e}`);
  process.exit(1);
});
