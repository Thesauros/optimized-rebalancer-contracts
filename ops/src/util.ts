/**
 * Small shared utilities: logging, log scanning, block search, HTTP status
 * server and Telegram alerts (same TELEGRAM_TOKEN / TELEGRAM_CHAT_ID variables
 * as the Thesauros-Rebalance-Engine alert manager).
 */
import http from 'http';
import { Contract, EventLog, Log, Provider } from 'ethers';

export function log(service: string, msg: string, extra?: unknown): void {
  const line = { t: new Date().toISOString(), service, msg, ...(extra ? { extra } : {}) };
  console.log(JSON.stringify(line, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** queryFilter in bounded block ranges (public RPCs cap eth_getLogs ranges). */
export async function scanEvents(
  contract: Contract,
  eventName: string,
  fromBlock: number,
  toBlock: number,
  step = Number(process.env.LOG_RANGE ?? 9_000),
): Promise<EventLog[]> {
  const out: EventLog[] = [];
  for (let start = fromBlock; start <= toBlock; start += step + 1) {
    const end = Math.min(toBlock, start + step);
    const logs = (await contract.queryFilter(contract.getEvent(eventName), start, end)) as (EventLog | Log)[];
    for (const l of logs) if ((l as EventLog).args) out.push(l as EventLog);
  }
  return out;
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
