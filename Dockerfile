# syntax=docker/dockerfile:1.19
# RevCode server image for Railway.
#
# The app builds and runs in one stage on purpose: the packed server bundle
# keeps its native dependencies external (see scripts/lib/cli-external-packages.ts),
# so those packages must resolve from a real pnpm node_modules tree at runtime.
# Copying a pnpm store between stages is where that quietly breaks, so we build
# and run in one tree and prune dev dependencies instead.
# Offline npm cache (cacache) for the pinned provider CLIs and their Linux x64
# glibc native packages. Used only by the provider-clis stage, so it never
# lands in the final image.
# npm-cli-cache/ holds the cache index and the trimmed registry packuments. The
# four tarballs come from the official npm registry, pinned by sha256, and land
# at the content path their sha512 integrity names, so npm still verifies them.
FROM scratch AS npm-cli-cache
COPY npm-cli-cache /npm-cli-cache
ADD --checksum=sha256:44d28caf1711767c14a0388db56b13f49dbd8d3e1db635dd98aa3115c760cf27 https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.251.tgz /npm-cli-cache/_cacache/content-v2/sha512/78/6f/993cfa56d836e69e7b5fd45cfdfd3f5ec12f08f1229f735b5c5363ea4b099fb5f8d13cfec15cf682c8bb99f24be04dd88f9c98bfdbf2674ef4d189e9de11
ADD --checksum=sha256:7e2d6d13baccd64cd2d9a8781643ae23a48db009ad746d1df0cfec38d5ed0a44 https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.251.tgz /npm-cli-cache/_cacache/content-v2/sha512/1c/9c/82635ca7ce5b0193e374d8825e04d3599b3c9de3794cb9f7f8f485ed6d40c61e57f65c51dcc706091160b0216e752771e5e0cbeba8ce987bc3c6a4944888
ADD --checksum=sha256:9be29b0858b3c9bb1214569f1d8e48a783956c8f5093cc6dcd86717e2cd8c5a3 https://registry.npmjs.org/opencode-ai/-/opencode-ai-1.18.25.tgz /npm-cli-cache/_cacache/content-v2/sha512/a5/2e/11289f5e2b053b0e9e46e69763d6b84c9e91b900f8b15f37d328da05aaff5a155237e919f36b68c44af2a27f1c8f665b00eb9310074dd6080ad8d042ba9a
ADD --checksum=sha256:3e6d285607b6e9acd1f60ec350cc3954d7351d9dcad970ded390f7b733e34280 https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-1.18.25.tgz /npm-cli-cache/_cacache/content-v2/sha512/6d/d4/5227a81b2bf1272cd5b144e3906171578947aa785c46cfc0c83bc2c2aa78a2f7d036396140c99dc36b9829bdf4f562ba7dfe560be799ffb4cdda95ee6c9a

FROM node:24.22.1-bookworm-slim AS base

# git      - the VCS driver shells out to it for checkpoints and diffs
# bash     - terminal sessions and provider CLIs expect a real shell
# python3/make/g++ - node-gyp fallback for node-pty when no prebuild matches
# openssh-client   - remote environments and git over ssh
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      bash \
      ca-certificates \
      curl \
      openssh-client \
      python3 \
      make \
      g++ \
    && rm -rf /var/lib/apt/lists/*

# Fail the build if the Node or Bookworm trust stores contain an excluded SPKI.
COPY ca-security/node_ca_guard.mjs /opt/ca-security/node_ca_guard.mjs
RUN node /opt/ca-security/node_ca_guard.mjs

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    # apps/desktop pulls electron as a dev dependency. The server image never
    # runs it, and the binary is ~300MB of pure waste in this context.
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    CI=1

# pnpm version comes from the root package.json "packageManager" field.
RUN corepack enable

# Provider CLIs. RevCode drives these; it does not ship them. Authentication is
# supplied at runtime through provider instance environment variables.
#
# Preserve the exact providers and script allowlist. Separate, visible, bounded
# installs identify a network/lifecycle stall without waiting indefinitely.
# Installs run offline from the bundled npm cache (exact versions, registry
# integrity checked by npm). npm_config settings also reach OpenCode's fallback
# child npm install, so it resolves from the same cache.
FROM base AS provider-clis
COPY --from=npm-cli-cache /npm-cli-cache /tmp/npm-cli-cache
RUN npm_config_cache=/tmp/npm-cli-cache npm_config_offline=true \
    timeout --kill-after=30s 10m npm install -g \
      --foreground-scripts --loglevel=info --no-audit --no-fund \
      --allow-scripts=@anthropic-ai/claude-code \
      @anthropic-ai/claude-code@2.1.251
RUN npm_config_cache=/tmp/npm-cli-cache npm_config_offline=true \
    timeout --kill-after=30s 10m npm install -g \
      --foreground-scripts --loglevel=info --no-audit --no-fund \
      --allow-scripts=opencode-ai \
      opencode-ai@1.18.25 \
    && rm -rf /tmp/npm-cli-cache \
    && npm cache clean --force
RUN claude --version && opencode --version

FROM base AS app

WORKDIR /app

COPY --exclude=npm-cli-cache . .

# Dev dependencies are required to build: vite-plus provides `vp`, and the
# server's build task depends on @t3tools/web#build.
# Slow registry responses need time to finish, with fewer concurrent downloads.
# Retry individual requests in this install so completed packages remain available.
# pnpm 11 reads pnpm_config_*; cap the whole step without restarting the install.
RUN pnpm_config_fetch_timeout=1800000 pnpm_config_fetch_retries=1 \
    pnpm_config_fetch_retry_factor=2 pnpm_config_fetch_retry_mintimeout=10000 \
    pnpm_config_fetch_retry_maxtimeout=30000 pnpm_config_network_concurrency=8 \
    timeout --kill-after=30s 65m pnpm install --frozen-lockfile --reporter=append-only

# Builds the web client, packs the server to dist/bin.mjs, and copies the web
# build into dist/client. Must go through `vp run`: the `build` task is defined
# in apps/server/vite.config.ts, not as a package.json script.
RUN node_modules/.bin/vp run --filter t3 build

# Fail the build rather than the deploy if the artifacts are not where the
# server expects them.
RUN test -f apps/server/dist/bin.mjs \
    && test -f apps/server/dist/client/index.html

# Drop dev dependencies now that the bundle and client exist.
RUN pnpm prune --prod || true

# Only the two installed CLI package trees (native packages are nested in each
# one's node_modules). The npm, corepack and node binaries stay from base.
COPY --from=provider-clis /usr/local/lib/node_modules/@anthropic-ai/claude-code /usr/local/lib/node_modules/@anthropic-ai/claude-code
COPY --from=provider-clis /usr/local/lib/node_modules/opencode-ai /usr/local/lib/node_modules/opencode-ai
# Recreate npm's relative bin symlinks from each package.json "bin" field.
# COPY would follow a symlink and copy the binary instead. symlinkSync fails
# rather than overwrite an existing command.
RUN node -e 'const fs = require("fs"), path = require("path"); for (const name of ["@anthropic-ai/claude-code", "opencode-ai"]) { const dir = path.join("/usr/local/lib/node_modules", name); const { bin } = require(path.join(dir, "package.json")); const bins = typeof bin === "string" ? { [name.split("/").pop()]: bin } : bin; for (const [cmd, rel] of Object.entries(bins)) { fs.symlinkSync(path.relative("/usr/local/bin", path.join(dir, rel)), path.join("/usr/local/bin", cmd)); } }'

# Prove both CLIs actually run. Catches a skipped postinstall at build time
# instead of at the first agent turn.
RUN claude --version && opencode --version

# State (sqlite, projects, attachments, environment id) lives on the Railway
# volume mounted here. Without the volume this directory is ephemeral and every
# redeploy starts empty.
ENV T3CODE_HOME=/data \
    T3CODE_MODE=web \
    T3CODE_HOST=0.0.0.0 \
    T3CODE_NO_BROWSER=true \
    NODE_ENV=production

RUN mkdir -p /data

# Shell form so Railway's injected $PORT expands at container start.
CMD node apps/server/dist/bin.mjs --host 0.0.0.0 --port ${PORT:-8080}
