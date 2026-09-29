import { sleep } from './util';

export interface CursorDrainOptions {
  label: string;
  pollMs?: number;
  maxPolls?: number;
  pause?: (ms: number) => Promise<void>;
}

/**
 * Repeats a cursor-based keeper action without trusting an immediately stale
 * read after the transaction receipt. The read RPC can trail the sequencer even
 * after it returns the receipt; waiting for the cursor prevents a duplicate
 * transaction from being broadcast against the old state.
 */
export async function drainCursor(
  attempt: () => Promise<boolean>,
  readCursor: () => Promise<bigint>,
  options: CursorDrainOptions,
): Promise<number> {
  const pollMs = options.pollMs ?? 1_000;
  const maxPolls = options.maxPolls ?? 30;
  const pause = options.pause ?? sleep;
  let cursor = await readCursor();
  let completed = 0;

  for (;;) {
    if (!(await attempt())) return completed;
    completed += 1;

    let advanced = false;
    for (let poll = 0; poll < maxPolls; poll += 1) {
      const next = await readCursor();
      if (next > cursor) {
        cursor = next;
        advanced = true;
        break;
      }
      if (poll + 1 < maxPolls) await pause(pollMs);
    }
    if (!advanced) throw new Error(`${options.label} confirmed but the read RPC cursor did not advance after ${maxPolls} polls`);
  }
}
