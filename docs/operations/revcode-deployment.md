# RevCode deployment and provider setup

> Fork-specific runbook. Upstream architecture is unchanged; this covers what
> differs in the Rev-Box fork.

## Node version

The server requires `^22.16 || ^23.11 || >=24.10`, and the repo root asks for
`^24.13.1`. Homebrew's plain `node` formula has moved past that range, so this
fork is developed against the keg-only `node@24`:

```sh
brew install node@24
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
```

Keg-only keeps the machine's global `node` untouched. A Node older than 24.10
fails at startup rather than at install time, so check `node -v` first when the
server will not boot.

## Local server

```sh
pnpm dev
```

Prints a one-time pairing URL. Open that, not the bare origin — the token is the
only way in, and it is consumed on use. Restarting mints a fresh one.

## Packaged macOS app

```sh
pnpm dist:desktop:artifact
```

Emits `release/RevCode-<version>-<arch>.dmg` plus a `.zip`. The `.app` inside is
`RevCode.app`.

This build compiles `native/resource-monitor`, so **Rust is required**:

```sh
brew install rust
```

Without it the build fails with `spawn cargo ENOENT` partway through staging.

The bundle identifier stays `com.t3tools.t3code`. That is deliberate: it is the
key to the existing userData directory, and changing it orphans real state along
with the migration path that reads it.

## Railway

One service builds from the repo `Dockerfile`.

| Setting             | Value                                                          |
| ------------------- | -------------------------------------------------------------- |
| Volume              | `/data` — **required**; without it every redeploy starts empty |
| `T3CODE_HOME`       | `/data`                                                        |
| `T3CODE_MODE`       | `web`                                                          |
| `T3CODE_HOST`       | `0.0.0.0`                                                      |
| `T3CODE_NO_BROWSER` | `true`                                                         |

Deploy from a working tree with:

```sh
railway up -s revcode-server -c
```

`.railwayignore` keeps the upload small — chiefly by excluding `.repos`, which is
~13k tracked files the build never reads.

### Reading the pairing URL

The container logs the pairing URL as `http://localhost:8080/...` because the
server derives it from its bind address and has no way to know its public
hostname. The token is valid; substitute the real host:

```
https://<service>.up.railway.app/pair#token=<token from deploy logs>
```

### Why the image is single-stage

The packed server keeps its native dependencies external (see
`scripts/lib/cli-external-packages.ts`), so they must resolve from a real pnpm
tree at runtime. Copying a pnpm store between build stages is where that breaks
silently, so the image builds and runs in one tree and prunes dev dependencies
instead.

`pnpm prune --prod` runs its lifecycle scripts, which fail once devDependencies
are gone; that step is guarded and the failure is expected.

### Provider CLIs in the image

npm 11 skips lifecycle scripts by default, and both provider CLIs download their
platform binary in `postinstall`. They therefore need `--allow-scripts`:

```dockerfile
RUN npm install -g \
      --allow-scripts=@anthropic-ai/claude-code,opencode-ai \
      @anthropic-ai/claude-code opencode-ai
RUN claude --version && opencode --version
```

Without the flag the install reports success and leaves two CLIs that cannot
execute. The version check exists so that fails the build rather than the first
agent turn.

## OpenRouter

RevCode drives provider CLIs; it does not call model APIs. OpenRouter therefore
attaches to a CLI, and no code change is involved — provider instances carry
their own environment variables, which the server merges into the spawned
process.

Never commit a key. Enter it in the provider instance's **Environment
variables** panel (sensitive values are stored separately and are not returned to
the client) or as a Railway variable.

### Anthropic models through Claude Code

Create a second Claude instance and give it:

| Variable               | Value                           |
| ---------------------- | ------------------------------- |
| `ANTHROPIC_BASE_URL`   | `https://openrouter.ai/api`     |
| `ANTHROPIC_AUTH_TOKEN` | your OpenRouter key (sensitive) |

Set that instance's `CLAUDE_CONFIG_DIR` to a path of its own. Claude Code
otherwise prefers cached OAuth from the shared config directory, and the API key
is ignored. A separate directory also leaves an existing interactive login
working alongside it.

OpenRouter's native Anthropic endpoint maps Claude Code's own model names, so
the existing model picker entries route through OpenRouter with no custom slugs.
OpenRouter documents this path as guaranteed only for Anthropic models.

If `ANTHROPIC_API_KEY` is set in the server's environment, add it to the instance
with an empty value so it cannot take precedence.

### Everything else through OpenCode

```sh
opencode auth login -p openrouter
```

Then enable OpenCode in **Settings → Providers**. It is off by default. This is
the path to non-Anthropic models — GPT, Gemini, DeepSeek, Qwen and the rest.

In a container there is no browser for OAuth, so an API key is the only provider
auth that works; set it as a Railway variable.

## Branding

Five seams carry the product name: the web branding module fallback, the desktop
base-name constant, the pre-React boot title in `index.html`, the packaged
`productName`, and the sidebar wordmark. Mobile has its own lockup.

Two strings deliberately keep the old name: `legacyUserDataDirName`, which names
the directory being migrated _from_, and the bundle identifier above.

The production build stamps `assets/prod/t3-black-web-*` over `dist/client`
favicons. Replacing only `apps/web/public` is not enough — a production build
ships the old icons regardless. Change both.

`vp run icons:check` needs an Icon Composer 2.x exporter from Xcode and cannot
run without one; it fails at tool resolution before comparing anything.
