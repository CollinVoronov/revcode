# RevCode server image for Railway.
#
# Single stage on purpose: the packed server bundle keeps its native
# dependencies external (see scripts/lib/cli-external-packages.ts), so those
# packages must resolve from a real pnpm node_modules tree at runtime. Copying
# a pnpm store between stages is where that quietly breaks, so we build and run
# in one tree and prune dev dependencies instead.
FROM node:24-bookworm-slim

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

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    # apps/desktop pulls electron as a dev dependency. The server image never
    # runs it, and the binary is ~300MB of pure waste in this context.
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    CI=1

# pnpm version comes from the root package.json "packageManager" field.
RUN corepack enable

WORKDIR /app

COPY . .

# Dev dependencies are required to build: vite-plus provides `vp`, and the
# server's build task depends on @t3tools/web#build.
RUN pnpm install --frozen-lockfile

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

# Provider CLIs. RevCode drives these; it does not ship them. Authentication is
# supplied at runtime through provider instance environment variables.
#
# --allow-scripts is required, not optional: npm 11 skips lifecycle scripts by
# default, and both packages download their platform binary in postinstall.
# Without it the install "succeeds" and leaves two CLIs that cannot execute.
RUN npm install -g \
      --allow-scripts=@anthropic-ai/claude-code,opencode-ai \
      @anthropic-ai/claude-code opencode-ai \
    && npm cache clean --force

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
