/** Spaces request starts; no accumulated permits after an idle period. */
export class RequestPacer {
  private next = 0;
  private tail: Promise<void> = Promise.resolve();

  constructor(private readonly rate: number) {
    if (!Number.isFinite(rate) || rate <= 0) throw new Error('RPC_REQUESTS_PER_SECOND must be positive');
  }

  acquire(): Promise<void> {
    this.tail = this.tail.then(async () => {
      const delay = this.next - performance.now();
      if (delay > 0) await new Promise<void>((resolve) => setTimeout(resolve, Math.ceil(delay)));
      this.next = performance.now() + 1000 / this.rate;
    });
    return this.tail;
  }
}
