# Base monitor baseline, 19 November 2026

The stand monitor still used the initial Base Strategy deployment. The running
Strategy was upgraded by its ProxyAdmin owner on 13 November, and its provider
list expanded through the Timelock on 15 November. The new implementation's
complete creation and runtime bytecode reproduce the reviewed preparation
artifact from commit `2fb3978f2db6bdfbfe51fd35345a9190f500b36d`.

This release records those executed changes and updates the monitor's expected
provider list, source identities, runtime hashes and existing caps. Unknown
future implementations, sources, code or providers must still fail integrity
checks. Transaction evidence is recorded with the Base deployment manifest.

## Runtime scope

The running image is
`sha256:c8106a450baf68fb7a68c02d18bfe688df5800e8f7f0987ed995784c1ae8cab7`.
Its original registry, deployment checker and Base manifest match source commit
`bdb0c7d`. `ops/Dockerfile.monitor-baseline` derives from that exact image and
replaces only those three files. Use the resulting immutable image ID only for
the `monitor` service, with `--no-deps --no-build`. Preserve the old monitor
image and service configuration for rollback. The operators container must keep
its original image, start time and process; the allocator is a separate service.

The runtime source commit is `6db15ffa06324efd46cc9a81c3c32cb204d74425`; its
derived image is
`sha256:73ed7b1e74ad456770c99e368b2e3e504ca22f5cd9a3989e66f7eebab47ef3cd`.
The stand watchdog runs Compose from the repository root. To keep this image
during recreation on that stand, set the following interpolation values in
the Compose project directory's `ops/.env` file or in the watchdog service environment.
Use the same values for manual Compose commands targeting this monitor.

```dotenv
CROSSCHAIN_MONITOR_IMAGE=sha256:73ed7b1e74ad456770c99e368b2e3e504ca22f5cd9a3989e66f7eebab47ef3cd
CROSSCHAIN_MONITOR_PULL_POLICY=never
```

On a fresh deployment the monitor uses the shared `CROSSCHAIN_OPS_IMAGE`.
To reproduce the historical stand image, build `ops/Dockerfile.monitor-baseline`
from a checkout of `6db15ffa06324efd46cc9a81c3c32cb204d74425`, using that checkout as
the build context. Current monitor sources also depend on the newer registry,
ABI and native spoke modules distributed together in the full ops image.
Before the historical build, tag the inspected original image as
`thesauros/crosschain-ops:monitor-baseline-source-20261119`, and verify
that the tag resolves to the original image ID above. Pass the source
commit as the `SOURCE_SHA` build argument. After activation, require
`governance.base` to pass on `/status`, `/health` to return 200, and verify that
the other services still run their original images.

## Separate allocator warning

The `readSignals` 168-hour warning comes from `xc-allocator.service`, not the
monitor. Its sampler calls the provider adapters at historical blocks. Fluid
was created at block 56857984 (13 November, 09:26:12 UTC), and Morpho V2 at
56857994 (09:26:14 UTC). Both return no code at the required 13 November 00:00
sample, while an Aave call at the same block succeeds. This is adapter age,
not an archive RPC or indexer outage.

Under the current sampler's 12-hour UTC alignment, that last predeployment sample
leaves the window after 20 November 00:00:00 UTC. Historical calls must still
succeed. The deployed allocator also lacks market-reader/registry support for
these two venues, so elapsed time alone does not enable allocations. Keep this
separate from the monitor baseline; do not shorten history windows or fabricate
rates to remove the warning.
