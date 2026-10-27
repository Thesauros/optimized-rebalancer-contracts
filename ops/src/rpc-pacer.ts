/** Spaces request starts; no accumulated permits after an idle period. */
export class RequestPacer {
  private next = 0;
  private tail: Promise<void> = Promise.resolve();

  constructor(private readonly rate: number) {
    if (!Number.isFinite(rate) || rate <= 0) throw new Error('RPC_REQUESTS_PER_SECOND must be positive');
  }

  acquire(weight = 1): Promise<void> {
    if (!Number.isFinite(weight) || weight <= 0) throw new Error('request weight must be positive');
    this.tail = this.tail.then(async () => {
      const delay = this.next - performance.now();
      if (delay > 0) await new Promise<void>((resolve) => setTimeout(resolve, Math.ceil(delay)));
      this.next = performance.now() + 1000 * weight / this.rate;
    });
    return this.tail;
  }
}

/** Conservative Moralis standard RPC weights; unknown methods use 12 CU. */
export function rpcWeight(method: string, params: unknown[] = []): number {
  const latest = (tag: unknown) => tag === 'latest' || tag === 'pending';
  switch (method) {
    case 'eth_call': case 'eth_getBalance': case 'eth_getCode':
      return latest(params[1]) ? 3 : 12;
    case 'eth_getStorageAt': return latest(params[2]) ? 3 : 12;
    case 'eth_getBlockByNumber': return latest(params[0]) ? 3 : 12;
    case 'eth_getTransactionCount': return latest(params[1]) ? 2 : 8;
    case 'eth_estimateGas': return 5;
    case 'eth_getTransactionReceipt': return 8;
    case 'eth_maxPriorityFeePerGas': return 2;
    case 'eth_blockNumber': case 'eth_chainId': case 'eth_gasPrice': case 'eth_feeHistory': return 3;
    default: return 12;
  }
}
