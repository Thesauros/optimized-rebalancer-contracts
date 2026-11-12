import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import { AddressInfo } from 'node:net';
import { NonceManager, Wallet, parseEther } from 'ethers';
import { RoutedProvider } from '../src/config';

test('HTTP 429 retries are bounded and do not invoke ethers hidden retry loop', async (t) => {
  let requests = 0;
  const server = http.createServer((_req, res) => {
    requests++;
    res.writeHead(429, { 'content-type': 'application/json' });
    res.end('{"message":"Rate limit exceeded"}');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const provider = new RoutedProvider(url, url, 31337);
  t.after(() => { provider.destroy(); provider.sender.destroy(); server.close(); });
  await assert.rejects(provider.send('eth_blockNumber', []), /429/);
  assert.equal(requests, 3);
});

const hasAnvil = spawnSync('anvil', ['--version']).status === 0;

/** Forwards JSON-RPC to `target` and records every method it sees. */
function recordingProxy(target: string): Promise<{ url: string; methods: string[]; close: () => void }> {
  const methods: string[] = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', async () => {
      const parsed = JSON.parse(body);
      for (const p of Array.isArray(parsed) ? parsed : [parsed]) methods.push(p.method);
      const r = await fetch(target, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
      res.setHeader('content-type', 'application/json');
      res.end(await r.text());
    });
  });
  return new Promise((resolve) =>
    server.listen(0, '127.0.0.1', () =>
      resolve({ url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, methods, close: () => server.close() }),
    ),
  );
}

test('signed transactions go to the send RPC, everything else to the read RPC', { skip: !hasAnvil && 'anvil not installed' }, async () => {
  const port = 18600 + Math.floor(Math.random() * 300);
  const anvil = spawn('anvil', ['--port', String(port), '--chain-id', '31337', '--silent']);
  const node = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(node, { method: 'POST', body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}', headers: { 'content-type': 'application/json' } })).ok) break;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  const read = await recordingProxy(node);
  const send = await recordingProxy(node);
  try {
    const provider = new RoutedProvider(read.url, send.url, 31337);
    // anvil's first default account
    const wallet = new NonceManager(new Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider));
    const tx = await wallet.sendTransaction({ to: '0x000000000000000000000000000000000000dEaD', value: parseEther('0.01') });
    const receipt = await tx.wait();
    assert.equal(receipt?.status, 1);
    assert.deepEqual(send.methods, ['eth_sendRawTransaction'], 'only the broadcast reaches the send RPC');
    assert.ok(!read.methods.includes('eth_sendRawTransaction'), 'the read RPC never sees the broadcast');
    assert.ok(read.methods.includes('eth_getTransactionReceipt') || read.methods.includes('eth_getTransactionByHash'), 'confirmation is read from the read RPC');
  } finally {
    read.close();
    send.close();
    anvil.kill();
  }
});
