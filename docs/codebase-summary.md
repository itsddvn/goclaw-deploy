# GoClaw Deploy — Codebase Summary

Complete breakdown of the goclaw-deploy repository structure, file purposes, and key components.

## Repository Overview

**Purpose:** Docker all-in-one packaging for GoClaw, a multi-LLM AI agent gateway platform.

**Scope:** 8 source files, ~1,039 LOC total, focused on deployment and containerization.

**Key Technologies:**
- Docker & Docker Compose (container orchestration)
- Dockerfile (3-stage multi-arch build)
- Caddy (reverse proxy & SPA server, auto HTTPS)
- PostgreSQL 18 + pgvector (vector database)
- Go 1.25 (backend binary compilation)
- Node 22 + pnpm (React SPA build)
- Alpine Linux 3.22 (runtime)
- Shell scripting (release automation, container entrypoint)

## File-by-File Breakdown

### Core Container Files

#### Dockerfile (86 LOC)
Multi-stage container build orchestrating Go binary compilation, React SPA build, and Alpine runtime.

**Stages:**
1. **go-builder** (`golang:1.25-bookworm`): Compiles Go binary with cross-compilation support (TARGETARCH), strips binaries, embeds VERSION
2. **web-builder** (`node:22-alpine`): Installs pnpm, builds React SPA from `ui/web/` source
3. **runtime** (`alpine:3.22`): Alpine OS + Caddy, copies compiled binary and SPA, runs as non-root

**Key Features:**
- Cross-platform support via BUILDPLATFORM/TARGETARCH
- cgexecGO disabled (statically linked binary)
- Migrations copied from source
- Non-root user (goclaw:goclaw)
- Environment defaults set (GOCLAW_* paths, GOCLAW_PORT=18790)
- Healthcheck via wget on /health
- Security: CAP_DROP ALL, tmpfs /tmp with noexec/nosuid

**Exposed Ports:** 8080 (Caddy HTTP), 8443 (Caddy HTTPS)

#### entrypoint.sh (86 LOC)
Container startup script handling volume permissions, Caddyfile selection, and process lifecycle.

**Modes:**
- `serve` (default): Fix volume ownership, select Caddyfile (HTTP or HTTPS based on GOCLAW_DOMAIN), delegate to core entrypoint for shared init, start Caddy, graceful shutdown trap
- `*`: Delegate to core entrypoint (`/app/docker-entrypoint.sh`)

**Critical Logic:**
```bash
# Caddyfile selection based on GOCLAW_DOMAIN
if [ -n "$GOCLAW_DOMAIN" ]; then
    envsubst '$GOCLAW_DOMAIN' < /app/Caddyfile.https > /tmp/Caddyfile
else
    cp /app/Caddyfile.http /tmp/Caddyfile
fi
```

**Process Management:** Runs goclaw (via core entrypoint) & Caddy as background processes, kills both on SIGTERM/SIGINT.

#### nginx.conf — REMOVED
Replaced by `Caddyfile.http` and `Caddyfile.https`. See below.

#### Caddyfile.http (37 LOC)
HTTP-only Caddy reverse proxy configuration. Used when `GOCLAW_DOMAIN` is unset (default).

**Key Routes:**
| Location | Target | Purpose |
|---|---|---|
| `/v1/*` | http://127.0.0.1:18790 | API reverse proxy |
| `/ws` | http://127.0.0.1:18790 | WebSocket proxy with 86400s read timeout |
| `/health` | http://127.0.0.1:18790 | Health check proxy |
| `/assets/*` | Static files | Cache 1 year, immutable (Vite hashed names) |
| `/` (SPA fallback) | /index.html | try_files, fall back to index.html |

**Security Headers:** X-Content-Type-Options, X-Frame-Options, Referrer-Policy

#### Caddyfile.https (43 LOC)
Auto HTTPS Caddy configuration using `${GOCLAW_DOMAIN}` placeholder (rendered via `envsubst`). Used when `GOCLAW_DOMAIN` is set.

Same routing as Caddyfile.http, plus:
- `http_port 8080`, `https_port 8443` (high ports for no-new-privileges)
- `storage file_system /data` (certificate persistence via caddy-data volume)
- Auto HTTPS via Let's Encrypt (ACME HTTP-01 challenge)

### Docker Compose Files

#### docker-compose.yml (65 LOC)
Production composition: uses pre-built image from Docker Hub, no build step.

**Services:**
- **goclaw**: image `itsddvn/goclaw:v2.50.0` (pinned version)
  - Managed mode with PostgreSQL DSN
  - 3 named volumes: data, workspace, caddy-data
  - Port mapping: GOCLAW_HTTP_PORT (default 80) → 8080, GOCLAW_HTTPS_PORT (default 443) → 8443
  - Security: no-new-privileges, CAP_DROP ALL (except SETUID/SETGID/CHOWN), tmpfs /tmp
  - Resources: 1GB RAM, 2 CPU, 200 PIDs limit
  - Health check dependency on postgres

- **postgres**: image `pgvector/pgvector:pg18`
  - Vector database with pgvector extension (internal only)
  - Environment credentials from .env
  - Healthcheck: pg_isready
  - Not exposed externally on port 5432

**Volumes:** Named Docker volumes for data persistence.

**Environment:** Loads .env (optional), sets GOCLAW_MODE=managed and GOCLAW_POSTGRES_DSN.

#### docker-compose-build.yml (75 LOC)
Development composition: builds from source, useful for testing changes.

**Differences from docker-compose.yml:**
- `build:` instead of `image:` — builds Dockerfile from ./goclaw-core context
- Dockerfile from $(PWD)/Dockerfile (deploy repo)
- Additional contexts: deploy=. (enables COPY --from=deploy)
- Platform: linux/amd64 (explicit, no multi-arch)
- GOCLAW_VERSION build arg (default: dev)
- Otherwise identical to production (volumes, security, resources)

**Prerequisites:** Requires the goclaw-core git submodule at ./goclaw-core with go.mod, ui/web/, migrations/.

#### docker-compose-dokploy.yml (71 LOC)
Dokploy PaaS deployment with external network.

**Differences:**
- External network: dokploy-network (for Dokploy-managed reverse proxy)
- Both services join dokploy-network
- Otherwise identical to docker-compose.yml (pre-built image)

**Use Case:** When Dokploy handles DNS, SSL, and reverse proxying externally.

### Configuration & Automation

#### release.sh (391 LOC)
Fully automated release workflow: sync upstream, review configs, build, push, smoke test.

**Commands:**
- `./release.sh sync` — Fetch upstream, merge into main & develop, auto-review configs, test build
- `./release.sh publish` — Tag version, build multi-arch, push to Docker Hub, smoke test
- `./release.sh full` — sync + publish (default)

**Preflight Checks:**
- goclaw-core git submodule is initialized at ./goclaw-core
- Upstream remote configured in goclaw-core
- Docker and docker buildx available
- Lock file (prevents concurrent runs)

**Detailed Workflow:**

*Sync phase:*
1. Checkout main, fetch upstream, merge upstream/main
2. Checkout develop, merge main into develop
3. Auto-review: diff deploy configs (Dockerfile, Caddyfile.http) vs core
4. Clean: stop containers, remove volumes
5. Test build: docker-compose-build.yml up, health check

*Publish phase:*
1. Get VERSION from git tags in goclaw-core
2. Confirm push to Docker Hub
3. Build multi-arch (linux/amd64) with docker buildx
4. Verify image can be pulled
5. Update docker-compose.yml and docker-compose-dokploy.yml with new version tag
6. Smoke test: docker-compose.yml up, health check
7. Commit compose files with message "release: update image to {VERSION}"

**Helpers:**
- `health_check()` — Polls endpoint (default 30 attempts, 5s interval)
- `sed_i()` — Platform-agnostic sed (macOS/Linux compatibility)
- `escape_sed()` — Escapes special chars for sed substitution


#### .env.example (35 LOC)
Template for environment variables (copy to .env before running).

**Sections:**
1. **LLM Providers** (11 keys) — At least one required (OpenRouter, Anthropic, OpenAI, Gemini, Deepseek, Groq, Mistral, xAI, Cohere, Perplexity, MiniMax)
2. **Gateway** (2 keys) — GOCLAW_GATEWAY_TOKEN, GOCLAW_ENCRYPTION_KEY (generate random values)
3. **Channels** (5 keys) — Telegram, Discord, Lark, Zalo integrations (optional)
4. **Database** (1 key) — POSTGRES_PASSWORD (managed mode only)
5. **Ports** (3 keys, commented) — GOCLAW_HTTP_PORT (default 80), GOCLAW_HTTPS_PORT (default 443), GOCLAW_DOMAIN (optional, enables auto HTTPS)

#### .gitignore (3 items)
Ignores:
- `.env` — Secrets, API keys
- `config.json` — Generated config
- `plans/` — Development/documentation plans

#### .dockerignore (3 items)
Prevents bloat in build context:
- `.git/` — Git metadata
- `.env` — Secrets
- `*.md` — Documentation

#### LICENSE (MIT)
Copyright 2026 Duc Nguyen.

## Architecture Patterns

### Multi-Stage Docker Build
Separates concerns:
1. **Go compilation** — Heavy toolchain, discarded
2. **React bundling** — Build tools removed, output only
3. **Runtime** — Minimal Alpine with only binary + SPA + Caddy

Result: ~500MB final image (Alpine 3.22 base ~7MB + GoClaw ~150MB + Caddy ~40MB + React SPA ~100MB).

### Named Docker Build Context
Allows copying deploy repo files into image without including entire deploy repo in Docker build context:
```dockerfile
COPY Caddyfile.http Caddyfile.https /app/
COPY entrypoint.sh /app/entrypoint.sh
```

Build command:
```bash
docker buildx build --build-context deploy=. -f Dockerfile -t image:tag ./goclaw-core
```

### Managed Mode + Auto-Migration
Core entrypoint detects environment and auto-upgrades schema on startup:
```bash
# Core docker-entrypoint.sh handles:
# - Runtime directory setup
# - Database migration (goclaw upgrade)
# - su-exec privilege drop
```

Deploy entrypoint delegates to core for shared init, then manages Caddy alongside:

### Compose Variants for Different Scenarios
Single Dockerfile, three compositions:
- **docker-compose.yml** — Fast production (pre-built)
- **docker-compose-build.yml** — Dev (from source)
- **docker-compose-dokploy.yml** — PaaS (external network)

Reduces duplication (all share same services, volumes, env) while supporting different deployment patterns.

### Release Automation
Fully scripted pipeline:
1. Version from git tags (immutable)
2. Auto-merge upstream with conflict detection
3. Config review (diffs highlighted)
4. Local test build before push
5. Multi-arch cross-compilation (linux/amd64 minimum)
6. Smoke test post-push
7. Compose file updates + commit

Reduces human error and ensures consistency.

## Dependencies

### External Docker Images
- `golang:1.25-bookworm` — Go compiler, build-only
- `node:22-alpine` — Node.js + pnpm, build-only
- `alpine:3.22` — Minimal runtime OS
- `pgvector/pgvector:pg18` — PostgreSQL 18 with vector extension

### Build Requirements
- Docker & Docker Compose (v2+)
- docker buildx (multi-arch support)
- bash 4+ (for release.sh)
- git (for version detection)
- curl, wget (for health checks)

### Runtime Requirements
- Docker daemon with buildx capability
- 2GB+ RAM per container (default limit 1GB)
- ~500MB disk per image layer

## Environment Variable Flow

```
.env (git-ignored)
  ↓
docker compose up
  ↓
Passes to goclaw container via env_file + environment: {}
  ↓
entrypoint.sh uses GOCLAW_MODE, GOCLAW_POSTGRES_DSN
  ↓
goclaw binary reads all GOCLAW_* vars
```

## Security Considerations

### Container-Level
- Non-root user (goclaw:goclaw)
- `security_opt: no-new-privileges:true`
- `cap_drop: ALL` (no capabilities)
- tmpfs /tmp with noexec, nosuid (prevents exploit execution)
- Resource limits (prevent DoS)

### Network
- Caddy security headers (XSS, clickjacking prevention)
- Reverse proxy (API backend not directly exposed)
- WebSocket proxying (long-lived connections with 86400s read timeout)
- Request body max size limit (50MB)
- Auto HTTPS via Let's Encrypt when GOCLAW_DOMAIN is set

### Data
- PostgreSQL credentials from .env (git-ignored)
- Vector embeddings stored in pgvector
- Session storage in named volume
- Config persistence in /app/data

## Common Operations

### Upgrade to New Version
```bash
# In goclaw-deploy repo
./release.sh full
git push
# Compose files updated with new tag
```

### Local Development Build
```bash
docker compose -f docker-compose-build.yml up -d --build
# Edits to ./goclaw-core reflect on rebuild
```

### Reset Database
```bash
docker compose down -v
docker compose up -d
# Fresh PostgreSQL init
```

### View Logs
```bash
docker compose logs goclaw -f --tail=50
docker compose logs postgres -f
```

### Inspect Health
```bash
docker compose ps
curl http://localhost/health
docker exec -it <container> /app/goclaw version
```
