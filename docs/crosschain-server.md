# Cross-chain ops: server runbook

Every off-chain service of the cross-chain vault runs on the server, in Docker,
and nowhere else. This page takes a clean host to a running stand and covers
day-to-day operation. Background: `crosschain-deployment.md` (contracts and
phases), `ops/README.md` (services and the operator CLI).

## What runs

| Container | Profile | Keys | Port (127.0.0.1) | Does |
|---|---|---|---|---|
| `preflight` | stand, production | yes | — | One-shot check; every other service waits for it to pass |
| `operators` | stand | yes | 8081 8082 8083 | NAV updater + keeper + relayer in **one process** |
| `nav`, `keeper`, `relayer` | production | yes | 8081 / 8082 / 8083 | The same three, one process and one key each |
| `monitor` | stand, production | no | 8084 | Checks, Telegram alerts, `/health`, `/metrics` |
| `indexer` | stand, production | no | 8085 | Read API for the frontend |
| `exec` | tools | yes | — | Operator CLI, run on demand |

Why `operators` on the stand: every role there is the deployer key
`0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D`. Three processes signing with one
address would each keep their own nonce counter and overwrite each other's
transactions. In one process they share one counter. `preflight --layout separate`
refuses a shared key, so the production layout cannot be started by mistake with
stand keys.

State (transfer index, indexer database) lives in the `ops-data` volume. It is a
cache: losing it costs one full re-scan (about 10 minutes against Moralis' 100-block
log limit), not funds.

## Requirements

* Linux host, Docker Engine 24+ with the compose plugin, outbound HTTPS.
* 1 vCPU, 1 GB RAM, 5 GB disk are enough.
* Nothing listens publicly: every port is bound to 127.0.0.1. Expose the indexer
  API through a TLS reverse proxy (nginx, Caddy) only.

## First start

```bash
git clone <repo> optimized-rebalancer-contracts && cd optimized-rebalancer-contracts
git checkout <release commit>          # the commit that carries deployments/*/crosschain.json

cp ops/.env.server.example ops/.env.server
cp ops/.env.keys.example   ops/.env.keys
chmod 600 ops/.env.server ops/.env.keys
# fill both: Moralis project URLs in RPC_BASE / RPC_ARBITRUM, the deployer key in
# all four *_PRIVATE_KEY on the stand, Telegram token and chat id, CORS origin

docker compose -f ops/docker-compose.yml build
docker compose -f ops/docker-compose.yml --profile tools run --rm preflight
```

`preflight` must end with `PREFLIGHT PASSED`. It checks, and fails on:

* read and send RPCs answer with the right chain id; logs and archive reads work;
* every manifest contract has code and the deployment reached phase 3;
* `CROSSCHAIN_PROFILE` equals the profile the manifests were deployed with
  (otherwise every deployment check fails and the monitor pages critical all day);
* the NAV key holds `NAV_UPDATER_ROLE`, the executor key `EXECUTOR_ROLE`;
* the signing layout matches the keys (one shared key only with `operators`);
* each signer has gas where it sends; the state volume is writable;
* Circle Iris answers; the Telegram token is valid when set.

Then start:

```bash
docker compose -f ops/docker-compose.yml --profile stand up -d
docker compose -f ops/docker-compose.yml ps          # all "healthy" within ~10 min
```

The first start scans bridge history since deployment; `indexer` and `monitor`
report healthy once that finishes. `operators` is healthy as soon as the first
Tick lands.

## Daily operation

```bash
# health of everything
for p in 8081 8082 8083 8084 8085; do curl -s localhost:$p/health; echo; done
curl -s localhost:8084/status | jq '.checks[] | select(.severity != "ok")'

# logs (JSON lines, tagged by service)
docker compose -f ops/docker-compose.yml logs -f --since 1h operators
docker compose -f ops/docker-compose.yml logs operators | grep '"service":"relayer"'

# operator CLI: every write is a dry run without --yes
alias xc='docker compose -f ops/docker-compose.yml --profile tools run --rm exec'
xc status
xc transfers
xc push 5 --yes
xc bridge base arbitrum 5 --yes
```

On the stand the CLI signs with the same key as `operators`. Nonces are read from
the chain, so a CLI transaction does not corrupt the service's counter, but a
send at the very same moment as a service transaction can fail with "nonce too
low"; the CLI then errors and is simply re-run, the service re-syncs on its next
pass.

## Upgrading

```bash
git fetch && git checkout <new release commit>
docker compose -f ops/docker-compose.yml build
docker compose -f ops/docker-compose.yml --profile tools run --rm preflight
docker compose -f ops/docker-compose.yml --profile stand up -d
```

The volume survives upgrades. After a contract redeploy (new manifests) wipe it,
because the cached index belongs to the old agents (it would be discarded anyway,
it is bound to their addresses): `docker volume rm <project>_ops-data`.

## Moving from the stand to production

1. Rotate on-chain (`06-rotate-governance.ts`, `crosschain-deployment.md` §1a).
2. Put the four new keys in `ops/.env.keys`, set `OPS_LAYOUT=separate`,
   `CROSSCHAIN_PROFILE=production` once phase 5 has raised the limits, and the new
   identities in `ops/.env.server`.
3. `docker compose -f ops/docker-compose.yml --profile stand down`, then preflight,
   then `--profile production up -d`.

## Why the RPCs are split

Reads (logs, archive state) go to Moralis; signed transactions go to the chains'
public endpoints (`RPC_SEND_*`). During the Base deployment Moralis twice accepted
a signed transaction and never propagated it. The public endpoints are not
archive nodes, so they cannot replace Moralis for reads; preflight fails when the
read RPC cannot serve historical state.

## Verified before shipping

The image was built and the whole stand stack was run against forks of Base and
Arbitrum that carry the real stand deployment (reads and sends to the forks only):
preflight passed; `operators` committed a Tick, the keeper closed and cleared the
overdue epoch; `monitor` reported 47 checks with only the two expected stand-mode
warnings; `indexer` synced both chains; after a restart state resumed from the
volume. The same run is what found the `CROSSCHAIN_PROFILE` trap preflight now
blocks.
