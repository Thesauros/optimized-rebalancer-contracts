# Base buffer review

The 2026-11-09 review concerns only the fixed 5 USDC minimum. The proposed change
preserves the current 10% ratio and every other live limit. Preparation is
read-only; JSON files contain unsigned requests, not executed transactions.

Use `ops/src/prepare-buffer-10pct.ts prepare FILE` for a fresh proposal or
`check FILE` to re-read its status and simulate the currently permitted action.
Both commands reject signing/broadcast methods and do not load keys. Check the
actual limits and queue/execution deadlines again before signing externally.

Do not use `buffer-governance.ts` for this proposal: that separate legacy tool
targets a 5% ratio. Do not assume the old October unsigned plan was queued.
