/**
 * Small shared utilities: logging, log scanning, block search, HTTP status
 * server and Telegram alerts (same TELEGRAM_TOKEN / TELEGRAM_CHAT_ID variables
 * as the Thesauros-Rebalance-Engine alert manager).
 */
import http from 'http';
import { Contract, Log, Provider } from 'ethers';

export function log(service: string, msg: string, extra?: unknown): void {
  const line = { t: new Date().toISOString(), service, msg, ...(extra ? { extra } : {}) };
  console.log(JSON.stringify(line, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Bounds how many async operations run at once, process-wide.
 *
 * Read APIs issue dozens of independent provider calls per request and providers are built with
 * `batchMaxCount: 1`, so an unbounded `Promise.all` opens one TLS socket per call in the same
 * instant. Both Moralis and public endpoints drop that burst ("Client network socket disconnected
 * before secure TLS connection was established"), which ends up slower than the sequential code it
 * replaced. A small bound keeps most of the speed-up without the failures.
 *
 * The slot is handed directly to the next waiter instead of being released and re-taken, so the
 * count stays exact under contention. Callers must not await a limited call from inside another
 * limited call: with every slot held by an outer call waiting on an inner one, that deadlocks.
 */
export function semaphore(size: number) {
  const limit = Math.max(1, size);
  let active = 0;
  const queue: (() => void)[] = [];
  return async function run<T>(fn: () => Promise<T>): Promise<T> {
    if (active >= limit) await new Promise<void>((resolve) => queue.push(resolve));
    else active++;
    try {
      return await fn();
    } finally {
      const next = queue.shift();
      if (next) next();
      else active--;
    }
  };
}

/**
 * True for transport-level failures, which are transient and worth retrying: dropped sockets,
 * reset connections, DNS hiccups and request timeouts. Deliberately does not match a contract
 * revert or a bad argument, because those are deterministic and retrying only wastes the budget.
 */
function isTransient(e: unknown): boolean {
  const text = String((e as any)?.cause?.message ?? (e as any)?.shortMessage ?? (e as any)?.message ?? e);
  return /socket disconnected|socket hang up|fetch failed|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EPIPE|EAI_AGAIN|other side closed|timeout|bad gateway|409 conflict|error code: 1001|502|503|504|429/i.test(text);
}

/**
 * Retries a provider read on transport failures with exponential backoff.
 *
 * Both Moralis and public endpoints drop connections intermittently under load; measured on the
 * stand, roughly two in five live reads failed this way while sequential indexing stayed healthy.
 * Without a retry a read API turns that into a 500 the caller cannot distinguish from a real fault.
 */
export async function retryTransient<T>(fn: () => Promise<T>, attempts = 3, baseMs = 150): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i + 1 >= attempts || !isTransient(e)) throw e;
      await sleep(baseMs * 2 ** i);
    }
  }
}

/** A decoded log; the fields callers read from ethers' EventLog. */
export interface ScannedEvent {
  eventName: string;
  args: any;
  blockNumber: number;
  transactionHash: string;
  logIndex: number;
}

/**
 * Blocks per eth_getLogs request, minus one (ranges are inclusive). Starts at
 * LOG_RANGE and shrinks to whatever the provider says its limit is: Moralis caps
 * at 100 blocks, public endpoints at a few thousand, paid ones at 10k or more.
 */
let logStep = Number(process.env.LOG_RANGE ?? 9_000);

function providerRangeLimit(e: unknown): number | undefined {
  const text = String((e as any)?.info?.responseBody ?? (e as any)?.error?.message ?? (e as any)?.message ?? e);
  if (!/range|limit|too many|10000 results/i.test(text)) return undefined;
  const m = text.match(/(?:block range|range)[^0-9]{0,40}(\d{2,7})/i);
  const n = m ? Number(m[1]) : undefined;
  return n && n > 1 ? n - 1 : 0;
}

/**
 * Every named event of one contract, in log order, with one eth_getLogs per
 * block range: a topic-0 OR filter instead of one request per event name.
 * Log order matters to callers that replay state (a cancel after its request).
 */
export async function scanMany(contract: Contract, eventNames: string[], fromBlock: number, toBlock: number): Promise<ScannedEvent[]> {
  const topics = eventNames.map((n) => contract.interface.getEvent(n)!.topicHash);
  const address = await contract.getAddress();
  const provider = contract.runner?.provider ?? (contract.runner as unknown as Provider);
  const out: ScannedEvent[] = [];
  const concurrency = Math.max(1, Number(process.env.LOG_CONCURRENCY ?? 1) || 1);
  for (let start = fromBlock; start <= toBlock; ) {
    const ranges: { from: number; to: number }[] = [];
    for (let cursor = start; cursor <= toBlock && ranges.length < concurrency; cursor += logStep + 1) {
      ranges.push({ from: cursor, to: Math.min(toBlock, cursor + logStep) });
    }

    const results = await Promise.allSettled(
      ranges.map((range) => retryTransient(
        () => provider!.getLogs({ address, topics: [topics], fromBlock: range.from, toBlock: range.to }),
      )),
    );
    const failed = results.findIndex((r) => r.status === 'rejected');
    if (failed >= 0) {
      const error = (results[failed] as PromiseRejectedResult).reason;
      const limit = providerRangeLimit(error);
      const span = ranges[failed].to - ranges[failed].from;
      if (limit === undefined || span === 0) throw error;
      // Discard successful siblings and retry the batch at the smaller range.
      // Re-reading an eth_getLogs range is harmless and keeps output ordered.
      logStep = limit > 0 && limit < span ? limit : Math.floor(span / 2);
      continue;
    }

    for (const result of results as PromiseFulfilledResult<Log[]>[]) {
      for (const l of result.value) {
        const parsed = contract.interface.parseLog(l);
        if (!parsed) continue;
        out.push({ eventName: parsed.name, args: parsed.args, blockNumber: l.blockNumber, transactionHash: l.transactionHash, logIndex: l.index });
      }
    }
    start = ranges[ranges.length - 1].to + 1;
  }
  return out;
}

/** One event name; kept for callers that need a single kind. */
export async function scanEvents(contract: Contract, eventName: string, fromBlock: number, toBlock: number): Promise<ScannedEvent[]> {
  return scanMany(contract, [eventName], fromBlock, toBlock);
}

/**
 * Accumulates events across passes so a long-running loop scans only the blocks
 * it has not seen, instead of re-reading history on every pass.
 */
export class EventCache {
  private readonly state = new Map<string, { to: number; events: ScannedEvent[] }>();

  async get(key: string, contract: Contract, eventNames: string[], fromBlock: number, head: number): Promise<ScannedEvent[]> {
    const s = this.state.get(key) ?? { to: fromBlock - 1, events: [] };
    if (head > s.to) {
      s.events.push(...(await scanMany(contract, eventNames, Math.max(fromBlock, s.to + 1), head)));
      s.to = head;
    }
    this.state.set(key, s);
    return s.events;
  }
}

/** Highest block with timestamp <= t, searching in [lo, hi]. */
export async function blockAtOrBefore(provider: Provider, t: number, lo: number, hi: number): Promise<number> {
  const tsOf = async (n: number) => (await provider.getBlock(n))!.timestamp;
  if ((await tsOf(hi)) <= t) return hi;
  if ((await tsOf(lo)) > t) throw new Error(`no block at or before ${t} in [${lo}, ${hi}]`);
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    if ((await tsOf(mid)) <= t) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

export interface StatusProvider {
  healthy(): boolean;
  status(): unknown;
  metrics?(): string;
}

/** /health (200 or 503), /status (JSON), /metrics (Prometheus text). */
export function serveStatus(service: string, port: number, p: StatusProvider): http.Server | undefined {
  if (process.argv.includes('--once')) return undefined; // single pass: no server keeping the process alive
  const server = http.createServer((req, res) => {
    const json = (code: number, body: unknown) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
    };
    if (req.url === '/health') return json(p.healthy() ? 200 : 503, { service, healthy: p.healthy() });
    if (req.url === '/status') return json(200, p.status());
    if (req.url === '/metrics' && p.metrics) {
      res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' });
      return res.end(p.metrics());
    }
    json(404, { error: 'not found' });
  });
  server.listen(port, () => log(service, `status server on :${port}`));
  return server;
}

export async function telegram(text: string): Promise<void> {
  const token = process.env.TELEGRAM_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;
  if (!token || !chatId) return;
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    log('alerts', 'telegram send failed', { error: String(e) });
  }
}

const errorHooks: (() => void)[] = [];

/** Registers a callback run after a failed loop iteration (e.g. nonce re-sync). */
export function onError(hook: () => void): void {
  errorHooks.push(hook);
}

/** Runs `fn` every `intervalMs`, never overlapping; `--once` runs a single pass. */
export async function loop(service: string, intervalMs: number, fn: () => Promise<void>): Promise<void> {
  const once = process.argv.includes('--once');
  for (;;) {
    try {
      await fn();
    } catch (e) {
      log(service, 'iteration failed', { error: e instanceof Error ? e.message : String(e) });
      for (const hook of errorHooks) hook();
      if (once) throw e;
    }
    if (once) return;
    await sleep(intervalMs);
  }
}
