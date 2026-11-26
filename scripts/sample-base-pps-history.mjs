/**
 * Read-only reconstruction of the Base cross-chain Strategy's share price (PPS)
 * history from archive state, to bound the historical maximum used as the
 * attested high-water mark for initializeSecurityAccounting().
 *
 * PPS is sampled through Multicall3 at a fixed block step. Between samples the
 * price can only move by accrued provider yield or by a loss event, so the
 * reported maximum is a lower bound of the true peak; the residual gap is
 * bounded by (observed APY * step duration) and is reported explicitly.
 */
import { JsonRpcProvider, Contract, AbiCoder, getAddress } from 'ethers';
import fs from 'node:fs';

const RPC_URL = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const STRATEGY = getAddress('0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33');
const MULTICALL3 = getAddress('0xcA11bde05977b3631167028862bE2a173976CA11');
const START = Number(process.env.START_BLOCK || 51905747);
const STEP = Number(process.env.STEP || 4500); // ~1 hour on Base at ~0.8s/block
const WAD = 10n ** 18n;
const SEL_TOTAL_ASSETS = '0x01e1d114';
const SEL_TOTAL_SUPPLY = '0x18160ddd';
const CONCURRENCY = Number(process.env.CONCURRENCY || 3);

const coder = AbiCoder.defaultAbiCoder();
const provider = new JsonRpcProvider(RPC_URL, 8453, { staticNetwork: true, batchMaxCount: 1 });
const multicall = new Contract(
  MULTICALL3,
  ['function aggregate3((address,bool,bytes)[]) view returns ((bool,bytes)[])'],
  provider,
);

async function sample(block) {
  const calls = [
    [STRATEGY, true, SEL_TOTAL_ASSETS],
    [STRATEGY, true, SEL_TOTAL_SUPPLY],
  ];
  for (let attempt = 0; ; ++attempt) {
    try {
      const res = await multicall.aggregate3.staticCall(calls, { blockTag: block });
      const assets = BigInt(res[0][1]);
      const supply = BigInt(res[1][1]);
      if (!res[0][0] || !res[1][0]) throw new Error(`subcall failed at ${block}`);
      return { block, assets: assets.toString(), supply: supply.toString(), pps: supply === 0n ? null : ((assets * WAD + supply - 1n) / supply).toString() };
    } catch (error) {
      if (attempt >= 5) throw error;
      await new Promise((r) => setTimeout(r, 300 * 2 ** attempt));
    }
  }
}

async function pooled(blocks) {
  const out = new Array(blocks.length);
  let next = 0;
  const worker = async () => {
    while (next < blocks.length) {
      const i = next++;
      out[i] = await sample(blocks[i]);
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return out;
}

const head = await provider.getBlockNumber();
const headBlock = await provider.getBlock(head);
const startBlock = await provider.getBlock(START);
const blocks = [];
for (let b = START; b <= head; b += STEP) blocks.push(b);
if (blocks[blocks.length - 1] !== head) blocks.push(head);

const series = await pooled(blocks);
const priced = series.filter((s) => s.pps !== null);
let max = priced[0];
let drops = 0;
let maxDropPpm = 0n;
for (let i = 0; i < priced.length; ++i) {
  if (BigInt(priced[i].pps) > BigInt(max.pps)) max = priced[i];
  if (i > 0) {
    const prev = BigInt(priced[i - 1].pps);
    const cur = BigInt(priced[i].pps);
    if (cur < prev) {
      drops += 1;
      const ppm = ((prev - cur) * 1000000n) / prev;
      if (ppm > maxDropPpm) maxDropPpm = ppm;
    }
  }
}
const lifetimeSeconds = headBlock.timestamp - startBlock.timestamp;
const stepSeconds = lifetimeSeconds / (blocks.length - 1);
const firstPps = BigInt(priced[0].pps);
const maxPps = BigInt(max.pps);
const observedApyPpm = Number(((maxPps - firstPps) * 1000000n) / firstPps) / (lifetimeSeconds / (365 * 86400));
const unsampledCeilingPpm = Math.ceil((observedApyPpm / 1e6) * stepSeconds * 1e6);

const result = {
  generatedAtUtc: new Date().toISOString(),
  mode: 'READ_ONLY_ARCHIVE_SAMPLING',
  rpcHost: new globalThis.URL(RPC_URL).host,
  chainId: 8453,
  strategy: STRATEGY,
  startBlock: START,
  startBlockTimestamp: startBlock.timestamp,
  headBlock: head,
  headBlockHash: headBlock.hash,
  headBlockTimestamp: headBlock.timestamp,
  step: STEP,
  stepSeconds: Math.round(stepSeconds),
  samples: series.length,
  pricedSamples: priced.length,
  firstSample: priced[0],
  headSample: series[series.length - 1],
  maxSample: max,
  decreasesObserved: drops,
  maxObservedDecreasePpm: Number(maxDropPpm),
  observedApyPpmPerYear: Math.round(observedApyPpm),
  unsampledIntervalCeilingPpm: unsampledCeilingPpm,
  series,
};
fs.writeFileSync(process.env.OUT || '/tmp/hwm-series.json', JSON.stringify(result, null, 2));
console.log(JSON.stringify({
  samples: series.length,
  startBlock: START,
  headBlock: head,
  firstPps: priced[0].pps,
  headPps: series[series.length - 1].pps,
  maxPps: max.pps,
  maxAtBlock: max.block,
  decreases: drops,
  maxDropPpm: Number(maxDropPpm),
  observedApyPpmPerYear: Math.round(observedApyPpm),
  unsampledIntervalCeilingPpm,
  out: process.env.OUT || '/tmp/hwm-series.json',
}, null, 2));
process.exit(0);
