# GoClaw Deploy

All-in-one Docker deployment for [GoClaw](https://github.com/nextlevelbuilder/goclaw) — an AI agent gateway platform with a React web dashboard, multi-LLM support, and chat channel integrations.

## Version

| Component | Version | Source |
|---|---|---|
| **goclaw-core** | `v2.50.0` | Git submodule → `./goclaw-core` |
| **Docker image** | `itsddvn/goclaw:v2.50.0` | Pre-built on Docker Hub |
| **PostgreSQL** | 18 + pgvector | `pgvector/pgvector:pg18` |

> The `goclaw-core` submodule is pinned to a specific tag. To upgrade, see [Upgrading](#upgrading) below.

## Quick Start

### 1. Clone (with submodule)

```bash
git clone --recurse-submodules git@github.com:vutadev/goclaw-deploy.git
cd goclaw-deploy
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` and set:

| Variable | Required | Description |
|---|---|---|
| `GOCLAW_ANTHROPIC_API_KEY` | At least one LLM key | Anthropic (Claude) |
| `GOCLAW_OPENAI_API_KEY` | | OpenAI |
| `GOCLAW_GEMINI_API_KEY` | | Google Gemini |
| `GOCLAW_DEEPSEEK_API_KEY` | | DeepSeek |
| `GOCLAW_OPENROUTER_API_KEY` | | OpenRouter (multi-provider) |
| `GOCLAW_GATEWAY_TOKEN` | Yes | Random token (`openssl rand -hex 32`) |
| `GOCLAW_ENCRYPTION_KEY` | Yes | Random key (`openssl rand -hex 32`) |
| `POSTGRES_PASSWORD` | Yes | Database password |

### 3. Start

**Production (pre-built image):**

```bash
docker compose up -d
```

**Local build (from submodule source):**

```bash
docker compose -f docker-compose-build.yml up -d --build
```

**Dokploy PaaS:**

```bash
docker compose -f docker-compose-dokploy.yml up -d
```

### 4. Access

| Service | URL |
|---|---|
| Dashboard | http://localhost |
| API | http://localhost/v1/ |
| pgAdmin | http://localhost:5050 |

## Compose Variants

| File | Use Case | Image Source |
|---|---|---|
| `docker-compose.yml` | Production | Docker Hub `itsddvn/goclaw:v2.50.0` |
| `docker-compose-build.yml` | Development / local build | Built from `./goclaw-core` submodule |
| `docker-compose-dokploy.yml` | Dokploy PaaS | Docker Hub (external network) |

All variants include PostgreSQL 18 + pgvector (internal, not exposed) and pgAdmin.

## Upgrading

### Update goclaw-core to a new tag

```bash
# See available tags
cd goclaw-core && git fetch --tags && git tag --sort=-v:refname | head -10

# Pin to a specific version
git checkout v2.51.0
cd ..

# Update compose files to match
# Edit docker-compose.yml and docker-compose-dokploy.yml:
#   image: itsddvn/goclaw:<new-version>

# Commit the submodule pin + compose changes
git add goclaw-core docker-compose.yml docker-compose-dokploy.yml
git commit -m "chore: upgrade goclaw-core to v2.51.0"
```

### Automated release (build + push)

```bash
./release.sh sync       # Sync upstream, merge changes
./release.sh publish    # Tag, build, push to Docker Hub, smoke test
./release.sh full       # sync + publish (default)
```

## Building

### Using Make

```bash
make build-local              # Build for current platform
make push                     # Build multi-arch + push to Docker Hub
make version                  # Show version from submodule git tag
```

### Using Docker directly

```bash
docker buildx build \
  --build-context deploy=. \
  --build-arg VERSION=v2.50.0 \
  -f Dockerfile \
  -t itsddvn/goclaw:v2.50.0 \
  ./goclaw-core
```

## Environment Variables

### LLM Providers (at least one required)

```
GOCLAW_OPENROUTER_API_KEY=
GOCLAW_ANTHROPIC_API_KEY=
GOCLAW_OPENAI_API_KEY=
GOCLAW_GEMINI_API_KEY=
GOCLAW_DEEPSEEK_API_KEY=
GOCLAW_GROQ_API_KEY=
GOCLAW_MISTRAL_API_KEY=
GOCLAW_XAI_API_KEY=
GOCLAW_COHERE_API_KEY=
GOCLAW_PERPLEXITY_API_KEY=
GOCLAW_MINIMAX_API_KEY=
```

### Gateway Security (required)

```
GOCLAW_GATEWAY_TOKEN=             # openssl rand -hex 32
GOCLAW_ENCRYPTION_KEY=            # openssl rand -hex 32
```

### Channels (optional)

```
GOCLAW_TELEGRAM_TOKEN=
GOCLAW_DISCORD_TOKEN=
GOCLAW_LARK_APP_ID=
GOCLAW_LARK_APP_SECRET=
GOCLAW_ZALO_TOKEN=
```

### Database

```
POSTGRES_USER=goclaw             # Default
POSTGRES_PASSWORD=               # Required
POSTGRES_DB=goclaw               # Default
```

### Ports

```
GOCLAW_HTTP_PORT=80              # HTTP host port (maps to container port 8080)
GOCLAW_HTTPS_PORT=443            # HTTPS host port (maps to container port 8443, requires GOCLAW_DOMAIN)
GOCLAW_DOMAIN=                   # Set to enable auto HTTPS via Caddy (e.g. goclaw.example.com)
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Container (Alpine Linux)                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Caddy (port 8080 HTTP / 8443 HTTPS)            │   │
│  │  - Reverse proxy for API and WebSocket          │   │
│  │  - Serves React SPA static files               │   │
│  │  - Auto HTTPS via Let's Encrypt (GOCLAW_DOMAIN) │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  GoClaw backend (port 18790)                    │   │
│  │  - Go binary with auto-migrations              │   │
│  │  - Serves API (/v1/) + WebSocket (/ws) + SPA   │   │
│  │  - Runs as goclaw user via su-exec              │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  pkg-helper (Unix socket /tmp/pkg.sock)         │   │
│  │  - Root-privileged package installer            │   │
│  │  - Handles apk installs for skills on-demand    │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
           ↓ (port 80 → 8080, port 443 → 8443)
┌─────────────────────────────────────────────────────────┐
│  PostgreSQL 18 + pgvector                               │
│  - Vector database for embeddings                       │
│  - User, config, skills storage                         │
└─────────────────────────────────────────────────────────┘
```

## File Structure

| File | Purpose |
|---|---|
| `goclaw-core/` | Upstream source (git submodule, pinned to `v2.50.0`) |
| `Dockerfile` | Multi-stage build: Go binary → Alpine runtime |
| `docker-entrypoint.sh` | Startup: permission fixes, pkg-helper, su-exec privilege drop |
| `docker-compose.yml` | Production: pre-built image |
| `docker-compose-build.yml` | Development: builds from submodule source |
| `docker-compose-dokploy.yml` | Dokploy: external network config |
| `Makefile` | Multi-arch build/push targets |
| `release.sh` | Automated release: sync, build, push, smoke test |
| `.env.example` | Environment variable template |

## Security

- Runs as non-root `goclaw` user via `su-exec`
- `no-new-privileges` security option
- All capabilities dropped except `SETUID`, `SETGID`, `CHOWN` (required for su-exec)
- `init: true` for proper signal handling and zombie reaping
- `/tmp` mounted noexec for exploit prevention
- Resource limits: 1GB RAM, 2 CPU, 200 PIDs

## Troubleshooting

### Health check failed

```bash
docker compose logs goclaw --tail=50
```

Common causes:
- Database not ready: Check `docker compose ps` for postgres health
- Migration failed: Check logs for SQL errors
- Port conflict: `lsof -i :80`

### Submodule is empty

```bash
git submodule update --init --recursive
```

### Containers won't start

```bash
docker compose down -v    # Remove volumes
docker compose up -d      # Fresh start
```

### Build errors (local build)

```bash
# Verify submodule is checked out
ls ./goclaw-core/main.go

# Check pinned version
cd goclaw-core && git describe --tags
cd ..

# Rebuild without cache
docker compose -f docker-compose-build.yml up -d --build --no-cache
```

## Support

- GoClaw core: https://github.com/nextlevelbuilder/goclaw
- Deployment guides: see `docs/` directory
