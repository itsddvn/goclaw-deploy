# System Architecture

Complete overview of GoClaw Deploy architecture, component interactions, and data flow.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ User Browser                                                │
│ http://localhost (or https://your-domain)                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTP/WebSocket
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Docker Container (Alpine Linux)                             │
│ ┌───────────────────────────────────────────────────────┐   │
│ │ Caddy (Port 8080 HTTP / 8443 HTTPS)                   │   │
│ │ - Reverse proxy for API (http://127.0.0.1:18790)     │   │
│ │ - WebSocket proxy for real-time updates              │   │
│ │ - Static SPA files (React)                           │   │
│ │ - Auto HTTPS via Let's Encrypt (when GOCLAW_DOMAIN   │   │
│ │   is set)                                            │   │
│ └───────────────────┬───────────────────────────────────┘   │
│                     │                                        │
│ ┌───────────────────▼───────────────────────────────────┐   │
│ │ GoClaw Backend (Port 18790)                           │   │
│ │ - Go binary                                           │   │
│ │ - LLM API routing (OpenAI, Anthropic, etc.)          │   │
│ │ - Agent orchestration                                │   │
│ │ - Multi-channel support (Telegram, Discord, etc.)    │   │
│ │ - Session management                                 │   │
│ └───────────────────┬───────────────────────────────────┘   │
│                     │ postgres:// (internal only)            │
│ ┌───────────────────▼───────────────────────────────────┐   │
│ │ Process Management (entrypoint.sh)                    │   │
│ │ - SIGTERM/SIGINT → graceful shutdown                 │   │
│ │ - Monitors both processes                            │   │
│ └───────────────────────────────────────────────────────┘   │
└─────────────────────┬──────────────────────────────────────┘
                      │ Docker network only
                      ▼
         ┌────────────────────────────┐
         │ PostgreSQL 18 + pgvector   │
         │ - User data & credentials  │
         │ - Session store            │
         │ - Config & settings        │
         │ - Vector embeddings        │
         │ (Not exposed externally)    │
         └────────────────────────────┘
```

## Container Architecture

### Three-Stage Docker Build

#### Stage 1: Go Builder
```
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS go-builder

Purpose: Compile Go binary with cross-platform support
Input:   ./goclaw-core (go.mod, *.go, migrations/)
Output:  /out/goclaw (stripped, static binary)

Steps:
1. Download go.mod dependencies
2. Copy source (.)
3. Cross-compile: CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH
4. Strip debug symbols (-s -w flags)
5. Embed version via ldflags (-X github.com/nextlevelbuilder/goclaw/cmd.Version=...)
```

**Why BUILDPLATFORM/TARGETARCH?**
- Build on host platform (fast compilation)
- Produce binary for target platform (amd64, arm64, etc.)
- Enables macOS → Linux cross-compilation without QEMU

#### Stage 2: Web Builder
```
FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder

Purpose: Build React SPA
Input:   ./goclaw-core/ui/web/ (source + pnpm-lock.yaml)
Output:  /app/dist (Vite static bundle)

Steps:
1. Enable corepack, install pnpm@10.28.2
2. Install dependencies (frozen-lockfile for reproducibility)
3. Build SPA (pnpm build → dist/)
```

**Output:** Static files (JS, CSS, HTML), no server required.

#### Stage 3: Runtime
```
FROM alpine:3.22

Purpose: Minimal runtime environment
Inputs:
  - /out/goclaw from go-builder
  - /src/migrations/ from go-builder
  - /app/dist from web-builder
  - Caddyfile.http and Caddyfile.https from deploy context
  - entrypoint.sh from deploy context

Outputs:
  - Image: ~500MB total
  - User: goclaw:goclaw (non-root)
  - Exposed: Port 8080 (HTTP), 8443 (HTTPS)

Setup:
1. Install ca-certificates, caddy
2. Create non-root user/group
3. Copy binary, migrations, SPA, configs
4. Create app directories (/app/workspace, /app/data, etc.)
5. Set permissions (goclaw:goclaw owns everything)
6. Set environment variables
7. Define healthcheck
8. Set entrypoint
```

### Container Filesystem Layout

```
/app/
├── goclaw                    # Go binary (from builder)
├── migrations/               # Database migrations (from builder)
├── entrypoint.sh            # Startup script (from deploy)
├── config.json              # Runtime config (mounted or generated)
├── data/                    # Persistent data (volume mount)
│   ├── embeddings/          # Vector embeddings
│   └── uploads/             # User uploads
├── workspace/               # Agent workspace (volume mount)
├── skills/                  # Custom skills/tools (volume mount)
├── sessions/                # Session store (volume mount)
└── .goclaw/                 # Hidden dotdir (volume mount)

/app/dist/                   # SPA static files (from builder)
├── index.html
├── assets/
│   ├── index-*.js          # Vite-hashed JS chunks
│   └── index-*.css         # Vite-hashed CSS chunks
└── ...

/tmp/Caddyfile               # Runtime-rendered Caddy config (HTTP or HTTPS mode)
# Caddy logs to stderr (captured by Docker: docker compose logs goclaw)
```

## Process Management

### Entrypoint Startup Sequence

```
1. Parse command: ${1:-serve}
   ├── serve (default)    → Start services
   ├── upgrade             → Run migration only
   ├── migrate             → Database migration
   ├── onboard             → Interactive setup
   ├── version             → Print version
   └── [anything else]     → Pass to goclaw

2. If serve + managed mode:
   ├── Check GOCLAW_MODE == "managed"
   ├── Check GOCLAW_POSTGRES_DSN not empty
   └── Execute: /app/goclaw upgrade
      └── Runs schema migrations, data hooks
      └── Idempotent (safe to re-run)
      └── May fail if already up-to-date (warning only)

3. Start background processes:
   ├── /app/goclaw &
   │   └── Sets GOCLAW_PID
   │   └── Port 18790
   └── caddy run --config /tmp/Caddyfile &
       └── Sets CADDY_PID
       └── Port 8080 (HTTP) / 8443 (HTTPS)

4. Set signal trap:
   └── trap shutdown SIGTERM SIGINT
       ├── Kill both processes on signal
       └── Wait for graceful shutdown

5. Monitor loop:
   └── while kill -0 "$GOCLAW_PID" "$CADDY_PID"; do sleep 1; done
       ├── Exit when either process dies
       └── Call shutdown (kills survivor)
```

**Why this design?**
- **Co-location:** API & SPA on same container, efficient
- **Graceful shutdown:** Trap SIGTERM for clean shutdown
- **Auto-migration:** Transparent schema updates on new image
- **Healthcheck:** Container visible as healthy only after both ready

### Process Lifecycle

```
Start → Migrations → Both Ready → Serve → Signal → Graceful Shutdown
```

**Managed Mode vs Unmanaged:**
- **Managed:** GOCLAW_MODE=managed + GOCLAW_POSTGRES_DSN → auto-upgrade on start
- **Unmanaged:** No auto-upgrade, manual migration via entrypoint.sh migrate

## Networking & Reverse Proxy

### Caddy Port Mapping

```
Host Port              Container Port           Target
80 (default)      →    8080 (Caddy HTTP)   →   Internal routing
443 (HTTPS mode)  →    8443 (Caddy HTTPS)  →   Internal routing (requires GOCLAW_DOMAIN)
                                               ├── /v1/* → goclaw:18790
                                               ├── /ws → goclaw:18790 (WebSocket)
                                               ├── /health → goclaw:18790
                                               ├── /assets/* → Static (SPA)
                                               └── /* → /index.html (SPA fallback)
```

### Caddy Routing Rules

The active Caddyfile is rendered at runtime to `/tmp/Caddyfile`. Two templates are provided:

- `Caddyfile.http` — HTTP-only mode (default, no `GOCLAW_DOMAIN`)
- `Caddyfile.https` — Auto HTTPS mode (used when `GOCLAW_DOMAIN` is set)

#### API Proxy (/v1/)
```caddy
reverse_proxy /v1/* 127.0.0.1:18790 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
}
```

**Headers:**
- `Host` — Original host (important for virtual hosting)
- `X-Real-IP` — Client's real IP (not proxy IP)
- `X-Forwarded-For` — Chain of proxy IPs

#### WebSocket Proxy (/ws)
Caddy handles WebSocket upgrades automatically when proxying — no special configuration needed. Long-lived connections are supported natively.

#### Static Assets (/assets/)
```caddy
@assets path /assets/*
header @assets Cache-Control "public, max-age=31536000, immutable"
```

**Why aggressive caching?**
- Vite generates hashed filenames (index-abc123.js)
- Hash changes when content changes
- Safe to cache 1 year

#### SPA Fallback (/)
```caddy
root * /app/dist
try_files {path} /index.html
file_server
```

**Why necessary?**
- React Router client-side routes (e.g., /agents, /settings)
- Static files don't exist; serve index.html
- Browser loads index.html, React Router handles routing

### Security Headers

```caddy
header {
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
}
```

| Header | Value | Purpose |
|---|---|---|
| X-Content-Type-Options | nosniff | Prevent MIME-sniffing attacks |
| X-Frame-Options | SAMEORIGIN | Allow framing only from same origin (clickjacking prevention) |
| Referrer-Policy | strict-origin-when-cross-origin | Send referrer only to same origin |

## Database Architecture

### PostgreSQL Configuration

**Image:** `pgvector/pgvector:pg18`
- PostgreSQL 18 (latest stable)
- pgvector extension (vector similarity search for embeddings)
- Default port: 5432

**Environment Variables (from .env):**
```bash
POSTGRES_USER=goclaw              # Default user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}  # From .env, required
POSTGRES_DB=goclaw                # Default database
```

**Healthcheck:**
```bash
CMD-SHELL: pg_isready -U goclaw
Interval: 5s
Timeout: 5s
Retries: 10
```

### Database Schema

Managed by goclaw-core via migrations/:
- Users & credentials
- Sessions (for multi-user support)
- Config & settings
- LLM conversation history
- Vector embeddings (pgvector)
- Agent metadata

**Auto-Migration:**
- Triggered on container startup (managed mode)
- Runs: `goclaw upgrade`
- Idempotent (safe to re-run)
- Detects schema version, applies pending migrations

### Volume Mounts for Persistence

| Volume | Mount Point | Purpose | Persistence |
|---|---|---|---|
| goclaw-data | /app/data | Config, uploads, embeddings | Required |
| goclaw-workspace | /app/workspace | Agent workspace, knowledge base | Required |
| goclaw-skills | /app/skills | Custom skills/tools | Optional |
| goclaw-sessions | /app/sessions | Session store | Optional (can use DB) |
| goclaw-dotdir | /app/.goclaw | Hidden config directory | Optional |
| pgdata | /var/lib/postgresql | PostgreSQL data | Required |

**Volume Strategy:**
- Named Docker volumes (not bind mounts)
- Portable across hosts
- Backed up independently from containers
- Persisted through container restarts

## Data Flow

### Chat Request Flow

```
User Browser
    ↓
HTTP POST /v1/chat
    ↓
Caddy (reverse proxy)
    ↓
GoClaw Backend (port 18790)
    ├─ Parse request
    ├─ Load LLM config from postgres
    ├─ Call LLM API (OpenAI, Anthropic, etc.)
    ├─ Store conversation in postgres
    ├─ Generate embeddings (pgvector)
    └─ Return response
    ↓
Caddy (proxy response)
    ↓
User Browser (React SPA updates UI)
```

### WebSocket Real-Time Flow

```
User Browser
    ↓
WebSocket /ws
    ↓
Caddy (upgrade to WebSocket protocol)
    ↓
GoClaw Backend
    ├─ Accept WebSocket connection
    ├─ Stream agent outputs (token-by-token for LLM)
    ├─ Send status updates
    └─ Notify on completion
    ↓
Caddy (stream to browser)
    ↓
User Browser (React updates in real-time)
```

### Startup Data Flow

```
docker compose up
    ↓
PostgreSQL starts, initializes (healthcheck)
    ↓
GoClaw container starts
    ↓
entrypoint.sh runs
    ├─ Check GOCLAW_MODE=managed
    ├─ Run goclaw upgrade (schema migrations)
    ├─ Start goclaw background process
    └─ Start caddy background process
    ↓
Caddy loads /tmp/Caddyfile, listens :8080 (and :8443 if GOCLAW_DOMAIN set)
    ↓
goclaw listens :18790
    ↓
healthcheck probes /health
    ├─ Caddy responds
    └─ goclaw responds
    ↓
Container marked healthy
    ↓
Ready to serve requests
```

## Deployment Modes

### Production (docker-compose.yml)

```
docker compose up -d
    ↓
Pull image: itsddvn/goclaw:v0.4.0-12-g231e112
    ↓
Start container (pre-built, no compilation)
    ↓
Auto-migrate (if GOCLAW_MODE=managed)
    ↓
Ready (~10s)
```

**Sync workflow (release.sh):**
1. Checkout main in goclaw-core
2. Fetch upstream, merge upstream/main into fork/main
3. Checkout develop, merge main into develop
4. Auto-review config diffs (Dockerfile, Caddyfile.http)
5. Clean containers, test build
6. Build multi-arch, push to Docker Hub
7. Update compose files, smoke test, commit

**Advantage:** No build overhead, consistent image across regions.

### Development (docker-compose-build.yml)

```
docker compose -f docker-compose-build.yml up -d --build
    ↓
Build from ./goclaw-core (stage 1: Go, stage 2: Web, stage 3: runtime)
    ↓
Start container
    ↓
Auto-migrate
    ↓
Ready (~90s with build)
```

**Advantage:** Test changes without push to Docker Hub.

### Dokploy (docker-compose-dokploy.yml)

```
PaaS provides: dokploy-network, DNS, reverse proxy, SSL

docker compose -f docker-compose-dokploy.yml up -d
    ↓
Services join dokploy-network
    ↓
Dokploy-managed reverse proxy routes to goclaw
    ↓
Caddy in container only handles /v1/, /ws, static files
    ↓
Platform handles external HTTPS termination
```

**Advantage:** Offload SSL/DNS/load-balancing to platform.

## Security Architecture

### Container Isolation
```
Host OS
│
├─ Linux kernel namespace isolation
│  ├─ Network namespace (isolated networking)
│  ├─ PID namespace (process isolation)
│  ├─ Mount namespace (filesystem isolation)
│  └─ User namespace (user mapping)
│
└─ goclaw container (Alpine)
   ├─ User: goclaw (UID 1000, non-root)
   ├─ Capabilities: NONE (all dropped)
   ├─ Privileges: no-new-privileges
   ├─ tmpfs /tmp: noexec, nosuid (prevents exploit execution)
   └─ cgroup limits: 1GB RAM, 2 CPU, 200 PIDs
```

### Network Isolation
```
Container network only exposes port 8080 (HTTP) and 8443 (HTTPS)
    ↓
Host port 80 / 443 (docker compose mapping)
    ↓
All internal services (goclaw:18790) only accessible from localhost/docker network
    ↓
Database (postgres:5432) only accessible from container via docker network
    (NOT exposed externally on any port)
```

### Credential Management
```
.env file (git-ignored)
    ↓ Contains secrets:
    ├─ LLM API keys
    ├─ Gateway token
    ├─ Encryption key
    ├─ PostgreSQL password
    └─ Channel tokens
    ↓
docker compose loads via env_file: .env
    ↓
Never logged/printed in docker compose logs
```

## Scaling Considerations

### Vertical Scaling
```
Increase resource limits in compose:
deploy:
  resources:
    limits:
      memory: 2G    # Default 1G
      cpus: '4.0'   # Default 2.0
```

**When needed:** Handling more concurrent users, larger models, more agents.

### Horizontal Scaling
```
Multiple containers, load-balanced externally:

LB → Container 1 (port 80)
  → Container 2 (port 8001)
  → Container 3 (port 8002)
    ↓
Shared PostgreSQL (all containers)
Shared volumes (shared NFS or S3)
```

**Consideration:** Requires shared database and storage (not local volumes).

### Database Scaling
PostgreSQL connection pooling via pgBouncer (if needed):
```
containers → pgBouncer (connection pool) → PostgreSQL
```

## Monitoring & Healthchecks

### Docker Healthcheck

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1
```

**Flow:**
1. Every 30s, probe http://localhost:8080/health
2. Timeout after 5s
3. Allow 10s before first probe (start-period)
4. Mark unhealthy after 3 consecutive failures

**Status visibility:**
```bash
docker compose ps
# HEALTH: healthy / unhealthy / starting
```

### Application Health Endpoint

Provided by GoClaw backend (/health):
```json
GET http://localhost/health

Response:
{
  "status": "ok",
  "timestamp": "2026-03-01T...",
  "uptime": 3600,
  "...": "..."
}
```

## Performance Characteristics

### Startup Time
- **Cold start:** ~30s (PostgreSQL init + schema migration)
- **Warm start:** ~10s (containers already running)
- **Image pull:** ~5-10s (500MB download)

### Memory Usage
- **Container limit:** 1GB (soft), may burst slightly
- **caddy:** ~30MB
- **goclaw:** ~100-200MB (depends on loaded agents)
- **PostgreSQL:** ~50-100MB (depends on data size)

### Disk Usage
- **Image:** ~500MB
- **Named volumes:** Grows with data (embeddings, uploads)
- **PostgreSQL data:** Grows with conversation history

### Network
- **Typical request:** <100ms (api → backend → llm)
- **Streaming (websocket):** Real-time (network latency dependent)
- **Bandwidth:** Varies by LLM token size (typically <1MB per request)

## Disaster Recovery

### Backup Strategy
```
Volume backups (docker-compose):
1. Stop container: docker compose stop
2. Backup volumes: docker run --rm -v goclaw-data:/data -v /backup:/backup \
                    alpine tar czf /backup/goclaw-data.tar.gz /data
3. Backup database: docker compose exec postgres pg_dump ... > backup.sql

Regular backups recommended (daily or post-release).
```

### Restore Process
```
1. Restore volumes: docker run --rm -v goclaw-data:/data -v /backup:/backup \
                     alpine tar xzf /backup/goclaw-data.tar.gz -C /
2. Restore database: docker compose exec postgres psql ... < backup.sql
3. docker compose up -d
```

### Version Rollback
```
docker compose down
# Edit docker-compose.yml, change image tag to previous version
docker compose up -d
```

No data loss (volumes preserved), clean upgrade/downgrade.
