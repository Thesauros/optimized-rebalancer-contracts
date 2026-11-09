# Cross-chain ops services. Build from the repository root:
#   docker compose -f ops/docker-compose.yml build
# The image carries the code, the registry and the committed deployment
# manifests; secrets come only from the env files on the server.
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

WORKDIR /app
# dependencies live in /app/node_modules so both ops/src and
# deploy/crosschain/registry.ts (which requires ethers) resolve them
COPY ops/package.json ops/package-lock.json ./
RUN npm ci --ignore-scripts && npm cache clean --force

COPY ops/tsconfig.json ops/tsconfig.json
COPY ops/src ops/src
COPY deploy/crosschain/registry.ts deploy/crosschain/registry.ts
# .dockerignore admits only crosschain.json files, preserving network directories.
# New supported chains do not become runtime dependencies until actually deployed.
COPY deployments/ deployments/

ENV NODE_ENV=production \
    TRANSFER_INDEX_FILE=/data/transfer-index.json \
    INDEXER_DB=/data/indexer.sqlite
RUN mkdir -p /data && chown node:node /data
USER node
WORKDIR /app/ops
ENTRYPOINT ["node", "--require", "/app/node_modules/ts-node/register/transpile-only"]
