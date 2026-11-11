# Cross-chain ops services. Build from the repository root:
#   docker compose -f ops/docker-compose.yml build
# The image carries the code, the registry and the committed deployment
# manifests; secrets come only from the env files on the server.
FROM node:22-slim

WORKDIR /app
# dependencies live in /app/node_modules so both ops/src and
# deploy/crosschain/registry.ts (which requires ethers) resolve them
COPY ops/package.json ops/package-lock.json ./
COPY ops/.npmrc ./
COPY ops/vendor vendor
RUN npm ci --ignore-scripts && npm cache clean --force

COPY ops/tsconfig.json ops/tsconfig.json
COPY ops/src ops/src
# extract-errors.js, the script that wrote the committed src/errors.json. It needs
# artifacts/, which the image does not carry, so it never runs here; the COPY stays
# because the image is meant to hold the ops source tree whole.
COPY ops/scripts ops/scripts
COPY deploy/crosschain/registry.ts deploy/crosschain/registry.ts
COPY deploy/crosschain/native-registry.ts deploy/crosschain/native-registry.ts
# Manifests are copied as a directory, not one line per chain. The Ethereum spoke is
# in the registry but not deployed, so deployments/mainnet/crosschain.json exists on
# no branch, and a named COPY of an absent file fails the build of every release from
# this tree, unrelated hotfixes included. .dockerignore still decides which manifests
# enter the context. This does not weaken the runtime check: config.ts throws
# "missing manifest" for any registry chain without one (ops/src/config.ts).
COPY deployments/ deployments/

ENV NODE_ENV=production \
    TRANSFER_INDEX_FILE=/data/transfer-index.json \
    INDEXER_DB=/data/indexer.sqlite
RUN mkdir -p /data && chown node:node /data
USER node
WORKDIR /app/ops
ENTRYPOINT ["node", "--require", "/app/node_modules/ts-node/register/transpile-only"]
