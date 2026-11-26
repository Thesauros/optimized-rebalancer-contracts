# Thesauros native Solana strategies

The USDC vault and user requests stay on Base. This workspace contains the
program-controlled Solana strategy agent and a local-only protocol test double.

- `programs/chain-agent`: PDA custody, protocol adapters, CCTP CPI, role/route
  controls, immutable historical checkpoints and governance write-downs.
- `tests/mock-kamino`: explicit local validator CPI double, never a production
  protocol implementation.
- `../ops/src/solana`: native RPC, Kamino SDK position/rate reader, instruction
  builders, source indexing, persistent cache/journal and operators.

Read the [architecture and operations guide](../docs/solana-kamino.md) and
[SDD](../specs/solana-kamino-crosschain/spec.md) before deployment or extension.
The source program ID is a build identity, not a claim of a deployed program or
an included deployment keypair. Choose the intended deployment identity,
governance and cluster-compatible SBPF version, rebuild and verify first.
