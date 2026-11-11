# Cross-chain ops services. Build from the repository root:
#   docker compose -f ops/docker-compose.yml build
# The image carries the code, the registry and the committed deployment
# manifests; secrets come only from the env files on the server.
FROM node:22-slim

WORKDIR /app
# dependencies live in /app/node_modules so both ops/src and
# deploy/crosschain/registry.ts (which requires ethers) resolve them
COPY ops/package.json ops/package-lock.json ./
RUN npm ci --ignore-scripts && npm cache clean --force

COPY ops/tsconfig.json ops/tsconfig.json
COPY ops/src ops/src
# extract-errors.js, the script that wrote the committed src/errors.json. It needs
# artifacts/, which the image does not carry, so it never runs here; the COPY stays
# because the image is meant to hold the ops source tree whole.
COPY ops/scripts ops/scripts
COPY deploy/crosschain/registry.ts deploy/crosschain/registry.ts
# One COPY for every manifest instead of one per network. A registry entry whose
# chain has not been deployed yet has no deployments/<key>/crosschain.json, and
# naming that file here fails the build of every release from this branch until the
# chain ships, hotfixes included. .dockerignore is a deny-all allowlist admitting
# only deployments/*/crosschain.json, so this copies manifests and nothing else:
# no solcInputs, no per-provider deployment records. The runtime check is not
# weakened by it - loadChains() still throws `missing manifest` for a chain whose
# manifest is absent, so an undeployed network fails loudly at startup.
COPY deployments deployments

ENV NODE_ENV=production \
    TRANSFER_INDEX_FILE=/data/transfer-index.json \
    INDEXER_DB=/data/indexer.sqlite
RUN mkdir -p /data && chown node:node /data
USER node
WORKDIR /app/ops
ENTRYPOINT ["node", "--require", "/app/node_modules/ts-node/register/transpile-only"]
