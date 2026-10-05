/**
 * EpochVault assigns contiguous request IDs starting at 1 and never deletes
 * requests (cancelled/claimed entries retain their status). Enumerating this
 * mapping avoids replaying every block since deployment to discover a few IDs.
 */
export class RequestCursor {
  private next = 1n;
  readonly pending = new Set<string>();

  async scan(read: (id: bigint) => Promise<{ status: bigint | number }>, limit = 100): Promise<void> {
    for (let count = 0; count < limit; count++) {
      const request = await read(this.next);
      const status = Number(request.status);
      if (status === 0) return; // Not created yet; retry this exact ID next pass.
      if (![1, 2, 3].includes(status)) throw new Error(`invalid request status ${status}`);
      if (status === 1) this.pending.add(this.next.toString());
      this.next++;
    }
  }
}
