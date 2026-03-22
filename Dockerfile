# We use node:slim (Debian-based) instead of Alpine because
# Prisma's native query engine binaries require glibc, which Alpine lacks.
ARG NODE=node:20-slim

# =============================================================
# STAGE 1: BUILD
# Install deps, generate Prisma client, compile TypeScript
# =============================================================
FROM $NODE AS builder

WORKDIR /app

# Install system packages needed at build time:
#   python3, build-essential → native npm addon compilation
#   openssl                  → required by Prisma client generation
RUN apt-get update && apt-get install -y \
    python3 \
    build-essential \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm globally — the linker backend uses pnpm, not npm.
# We pin the version for reproducibility.
RUN npm install -g pnpm@9

# Copy manifest files first for Docker layer caching.
# Docker only re-runs pnpm install when these change.
COPY package.json pnpm-lock.yaml ./

# --frozen-lockfile = equivalent of npm ci
# Fails if pnpm-lock.yaml is out of sync with package.json
RUN pnpm install --no-frozen-lockfile

# Copy source code and the Prisma schema
COPY . .

# Generate the Prisma Client from your schema.
# This creates type-safe DB access code in node_modules/@prisma/client.
# MUST run before the TypeScript build because NestJS imports it.
RUN pnpm exec prisma generate

# Compile TypeScript → JavaScript into ./dist/
RUN pnpm run build

# =============================================================
# STAGE 2: PRODUCTION IMAGE
# Copy only what is needed to run — no dev dependencies
# =============================================================
# STAGE 2: PRODUCTION IMAGE
FROM $NODE AS runner

WORKDIR /app

RUN apt-get update && apt-get install -y \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@9

# Copy everything needed to run from the builder stage
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/package.json ./package.json

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

USER node

EXPOSE 3001

ENTRYPOINT ["./entrypoint.sh"]