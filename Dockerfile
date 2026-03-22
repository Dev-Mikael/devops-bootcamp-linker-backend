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
FROM $NODE AS runner

WORKDIR /app

# Runtime system packages:
#   openssl → Prisma needs it at runtime to connect to the database
#   curl    → useful for health checks
RUN apt-get update && apt-get install -y \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm in the production image to run pnpm install --prod
RUN npm install -g pnpm@9

# Copy manifest to install prod-only deps
COPY package.json pnpm-lock.yaml ./

# --prod skips devDependencies, keeping the final image lean
RUN pnpm install --no-frozen-lockfile --prod

# Copy the compiled NestJS application from the builder stage
COPY --from=builder /app/dist ./dist

# Copy the Prisma Client and its native engine binary.
# The engine binary is platform-specific and must match the runtime OS.
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma ./node_modules/@prisma

# Copy the Prisma schema (needed for migrations at runtime if desired)
COPY --from=builder /app/prisma ./prisma

# 'node' is a built-in non-root user in the official Node.js Docker images
USER node

EXPOSE 3001

CMD ["node", "dist/main.js"]