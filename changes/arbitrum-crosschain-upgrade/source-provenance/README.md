# Historical source identity

These exact standard JSON inputs reconstruct the verified deployed non-proxy
ProviderManager and Aave PoolAddressesProvider runtimes. Input SHA-256 hashes,
compiled/live runtime hashes and canonical coverage are recorded in
`../source-scope-closure.json`.

Compile `pm-standard-input.json` with official native Solidity
0.8.33+commit.64118f21 and `ap-standard-input.json` with official native Solidity
0.8.10+commit.fc410830, using `solc --standard-json < INPUT > OUTPUT`. Compiler
settings and dependency contents are embedded in each input. The official 0.8.10
compiler download hash verification is in `ap-compiler-proof.json`.

Compare `evm.deployedBytecode.object` for the named contracts with `eth_getCode`
at deployment block 509725811 and snapshot block 526525483. Both runtimes match
byte-for-byte. Inspect the actual mutators: every ProviderManager yield/market
mapping update and every Aave pool-mapping update emits the listed event.
Full-address canonical `eth_getLogs` over that range contains no PM event and
only the previously reviewed Aave Pool implementation upgrade. This closes the
source retarget/alias condition independently of owner EIP7702 delegation or
incomplete explorer account-call histories.

This is evidence through the recorded snapshot, not an executable migration
attestation. Refresh events, mappings, holdings, PPS and canonical headers before
signing a current upgrade plan.
