# GoClaw Deploy

All-in-one Docker deployment for [GoClaw](https://github.com/itsddvn/goclaw) — an AI agent gateway platform with a React web dashboard, multi-LLM support, and chat channel integrations.

## Version

| Component | Version | Source |
|---|---|---|
| **goclaw-core** | `v2.56.6` | Git submodule → `./goclaw-core` |
| **Docker image** | `itsddvn/goclaw:v2.56.6` | Pre-built on Docker Hub |
| **PostgreSQL** | 18 + pgvector | `pgvector/pgvector:pg18` |

> The `goclaw-core` submodule is pinned to a specific tag. To upgrade, see [Upgrading](#upgrading) below.

## Quick Start

### Option A: Standalone (no clone needed)

Download just `docker-compose.yml`, edit the gateway tokens, and start:

```bash
# Generate gateway secrets
openssl rand -hex 32  # → GOCLAW_GATEWAY_TOKEN
openssl rand -hex 32  # → GOCLAW_ENCRYPTION_KEY

# Edit environment variables in docker-compose.yml, then:
docker compose up -d
```

LLM provider keys and channels can be configured via the web dashboard after startup.

### Option B: Clone (for local builds or customization)

```bash
git clone --recurse-submodules git@github.com:itsddvn/goclaw-deploy.git
cd goclaw-deploy
cp .env.example .env
```

Edit `.env` and set:

| Variable | Required | Description |
|---|---|---|
| `GOCLAW_GATEWAY_TOKEN` | Yes | Random token (`openssl rand -hex 32`) |
| `GOCLAW_ENCRYPTION_KEY` | Yes | Random key (`openssl rand -hex 32`) |
| `POSTGRES_PASSWORD` | Yes | Database password |

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### Start

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
| `docker-compose.yml` | Production | Docker Hub `itsddvn/goclaw:v2.56.6` |
| `docker-compose-build.yml` | Development / local build | Built from `./goclaw-core` submodule |
| `docker-compose-dokploy.yml` | Dokploy PaaS | Docker Hub (external network) |

All variants include PostgreSQL 18 + pgvector (internal, not exposed) and pgAdmin.

## Upgrading

### Update goclaw-core to a new tag

```bash
# Update to latest tag (fetches tags and checks out the newest vX.Y.Z)
make update

# Or pin to a specific version
make update TAG=v2.56.6

# Commit the submodule pin + compose changes
git add goclaw-core docker-compose.yml docker-compose-dokploy.yml
git commit -m "chore: upgrade goclaw-core to v2.56.6"
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
make update                   # Update submodule to latest tag
make update TAG=v2.56.6       # Update submodule to specific tag
```

### Using Docker directly

```bash
docker buildx build \
  --build-context deploy=. \
  --build-arg VERSION=v2.56.6 \
  -f Dockerfile \
  -t itsddvn/goclaw:v2.56.6 \
  ./goclaw-core
```

## Environment Variables

> LLM provider keys and channel integrations are configured via the web dashboard.

| Variable | Required | Default | Description |
|---|---|---|---|
| `GOCLAW_GATEWAY_TOKEN` | Yes | — | Security token (generate: `openssl rand -hex 32`) |
| `GOCLAW_ENCRYPTION_KEY` | Yes | — | Encryption key (generate: `openssl rand -hex 32`). **Must be preserved** when migrating or re-deploying — changing it will make existing encrypted data unreadable. |
| `POSTGRES_PASSWORD` | Yes | `goclaw` | PostgreSQL password. **Must match the original value** when migrating or re-deploying against an existing database. |
| `POSTGRES_USER` | No | `goclaw` | PostgreSQL username |
| `POSTGRES_DB` | No | `goclaw` | PostgreSQL database name |
| `GOCLAW_DOMAIN` | No | — | Domain for auto HTTPS via Let's Encrypt |
| `GOCLAW_HTTP_PORT` | No | `80` | Host HTTP port (maps to container 8080) |
| `GOCLAW_HTTPS_PORT` | No | `443` | Host HTTPS port (maps to container 8443, requires `GOCLAW_DOMAIN`) |
| `GOCLAW_SKILLS_STORE` | No | `/opt/goclaw/data/skills-store` | Host path for skills persistence |
| `PGADMIN_EMAIL` | No | `admin@admin.com` | pgAdmin login email |
| `PGADMIN_PASSWORD` | No | `admin` | pgAdmin login password |
| `PGADMIN_PORT` | No | `5050` | pgAdmin host port |
| `GOCLAW_DATA_VOLUME` | No | `goclaw-data` | Named volume for data (Dokploy only) |
| `GOCLAW_WORKSPACE_VOLUME` | No | `goclaw-workspace` | Named volume for workspace (Dokploy only) |
| `GOCLAW_IMAGE` | No | `itsddvn/goclaw` | Override image name (build mode only) |
| `GOCLAW_VERSION` | No | `latest` | Override image tag (build mode only) |

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
| `goclaw-core/` | Upstream source (git submodule, pinned to `v2.56.6`) |
| `Dockerfile` | Multi-stage build: Go binary → Alpine runtime |
| `Caddyfile` | Caddy reverse proxy config (HTTP/HTTPS, SPA, WebSocket) |
| `entrypoint.sh` | Startup: permission fixes, pkg-helper, su-exec privilege drop |
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

- GoClaw core: https://github.com/itsddvn/goclaw
- Deployment guides: see `docs/` directory
