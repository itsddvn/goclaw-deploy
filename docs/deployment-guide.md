# Deployment Guide

Step-by-step instructions for deploying GoClaw using all three compose variants.

## Prerequisites

### System Requirements
- Docker & Docker Compose v2+
- 2GB+ RAM available
- 2GB+ disk space for image and volumes
- Port 80 (or custom GOCLAW_HTTP_PORT) available
- PostgreSQL runs internally (no external port needed)

### Software Versions
- Docker: 20.10+
- Docker Compose: 2.0+
- docker buildx: 0.8+ (for local builds only)

### Credentials Required
- At least one LLM provider API key:
  - Anthropic (GOCLAW_ANTHROPIC_API_KEY)
  - OpenAI (GOCLAW_OPENAI_API_KEY)
  - Gemini (GOCLAW_GEMINI_API_KEY)
  - Or any of: OpenRouter, Deepseek, Groq, Mistral, xAI, Cohere, Perplexity, MiniMax

## Setup: Common Steps

All variants share these initial setup steps.

### 1. Clone or Navigate to Repository

```bash
cd /path/to/goclaw-deploy
ls -la
# Should see: Dockerfile, docker-compose.yml, etc.
```

### 2. Create Environment File

```bash
cp .env.example .env
```

This creates a git-ignored `.env` file with placeholders.

### 3. Configure Environment Variables

Edit `.env` and fill in required values:

```bash
nano .env  # or vim, code, etc.
```

**Minimum required:**

```env
# At least ONE LLM provider key (example: Anthropic)
GOCLAW_ANTHROPIC_API_KEY=sk-ant-...

# Generate these: openssl rand -hex 32
GOCLAW_GATEWAY_TOKEN=<random-32-hex-chars>
GOCLAW_ENCRYPTION_KEY=<random-32-hex-chars>

# PostgreSQL (required for managed mode)
POSTGRES_PASSWORD=<strong-password>
```

**Generate random values:**

```bash
# macOS/Linux
openssl rand -hex 32

# Result: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6...
# Use this value
```

**Optional configurations:**

```env
# Change HTTP port (default: 80)
GOCLAW_HTTP_PORT=8000

# Add additional LLM providers
GOCLAW_OPENAI_API_KEY=sk-...
GOCLAW_GEMINI_API_KEY=...

# Add chat channels
GOCLAW_TELEGRAM_TOKEN=...
GOCLAW_DISCORD_TOKEN=...

# Change database credentials (non-default)
POSTGRES_USER=myuser
POSTGRES_DB=mydb
```

### 4. Verify Configuration

```bash
docker compose config  # Syntax check
# Should show valid YAML without errors
```

---

## Method 1: Production Deployment (Pre-Built Image)

**Use case:** Fastest deployment, uses image from Docker Hub, no build required.

**Time to ready:** ~30 seconds

### Command

```bash
docker compose up -d
```

### Detailed Steps

#### Step 1: Pull Image

```bash
docker compose pull
# Pulls: itsddvn/goclaw:v0.4.0-12-g231e112
#        pgvector/pgvector:pg18
```

Status output:
```
Pulling goclaw ... done
Pulling postgres ... done
```

#### Step 2: Start Services

```bash
docker compose up -d
```

This runs both services in background.

Output:
```
[+] Running 3/3
 ⠿ Network goclaw-deploy_default  Created
 ⠿ Container goclaw-deploy-postgres-1   Started
 ⠿ Container goclaw-deploy-goclaw-1      Started
```

#### Step 3: Verify Health

```bash
# Check container status
docker compose ps

# Output:
# NAME                  COMMAND                  STATUS
# goclaw-deploy-postgres-1  "docker-entrypoint..."  Up 5s (healthy)
# goclaw-deploy-goclaw-1    "/app/entrypoint.sh"    Up 3s (starting)
```

Wait for STATUS to show "healthy" (takes ~10s):

```bash
# Watch status updates
docker compose ps --no-trunc

# Or poll health endpoint
curl http://localhost/health
```

Expected response:
```json
{"status":"ok",...}
```

#### Step 4: Access Dashboard

Open in browser: **http://localhost**

You should see GoClaw web interface.

### Troubleshooting Production Deploy

**Port already in use:**
```bash
lsof -i :80
# Kill process or use different port:
GOCLAW_HTTP_PORT=8000 docker compose up -d
```

**Image pull fails:**
```bash
docker login  # Authenticate if needed
docker compose pull --no-cache
```

**Healthcheck fails (unhealthy status):**
```bash
docker compose logs goclaw --tail=50
# Check for errors: database connection, migration failures
```

**PostgreSQL won't start:**
```bash
docker compose logs postgres --tail=20
# Common: corrupted data volume, insufficient disk
```

---

## Method 2: Local Development Build

**Use case:** Test changes to code, modify Dockerfile/config, don't push to Docker Hub.

**Prerequisites:** `./goclaw-core` git submodule with source code.

**Time to ready:** ~90 seconds (includes build)

### Command

```bash
docker compose -f docker-compose-build.yml up -d --build
```

### Detailed Steps

#### Step 1: Verify Source

```bash
# Check that goclaw-core exists
ls -la ./goclaw-core/go.mod
ls -la ./goclaw-core/ui/web/package.json
ls -la ./goclaw-core/migrations/

# All should exist
```

If missing:
```bash
git submodule update --init --recursive
```

#### Step 2: Build Image

```bash
docker compose -f docker-compose-build.yml up -d --build
```

This executes the three-stage build:
1. **Stage 1 (go-builder):** Compile Go binary (~30s)
2. **Stage 2 (web-builder):** Build React SPA (~40s)
3. **Stage 3 (runtime):** Create Alpine image (~10s)

Console output:
```
[+] Building 3/3
 ⠿ Building goclaw-deploy-goclaw-1  Built                           20s
[+] Running 2/2
 ⠿ Container goclaw-deploy-postgres-1   Created
 ⠿ Container goclaw-deploy-goclaw-1      Created
```

#### Step 3: Wait for Health

```bash
# Monitor health
docker compose -f docker-compose-build.yml ps

# When healthy:
curl http://localhost/health
```

#### Step 4: Access Dashboard

Open: **http://localhost**

### Development Workflow

**Make changes to goclaw-core source:**

```bash
cd ./goclaw-core
# Edit files, commit
git add .
git commit -m "..."
```

**Rebuild container:**

```bash
cd ../goclaw-deploy
docker compose -f docker-compose-build.yml up -d --build
```

Container rebuilds with your changes.

**Faster iteration (rebuild only go/web):**

```bash
# Skip caching (forces full rebuild)
docker compose -f docker-compose-build.yml up -d --build --no-cache
```

### Troubleshooting Development Build

**Build fails at stage 1 (Go):**
```bash
docker compose -f docker-compose-build.yml logs goclaw | grep -i error
# Check go.mod, golang version, syntax errors
```

**Build fails at stage 2 (Web):**
```bash
docker compose -f docker-compose-build.yml logs goclaw | grep -i error
# Check package.json, pnpm versions, React syntax
```

**Source changes not reflected:**
```bash
# Clear build cache
docker builder prune --all
docker compose -f docker-compose-build.yml up -d --build --no-cache
```

**High CPU/memory during build:**
```bash
# Normal during stage 1 & 2, monitor with:
docker stats
```

---

## Method 3: Dokploy PaaS Deployment

**Use case:** Deploy on Dokploy (self-hosted PaaS), uses external network for reverse proxy and DNS.

**Prerequisites:** Dokploy instance running with dokploy-network created.

**Time to ready:** ~30 seconds (pre-built image)

### Pre-Deployment Setup on Dokploy

#### 1. Create External Network (One-Time)

```bash
# On Dokploy host:
docker network create dokploy-network
```

Verify:
```bash
docker network ls | grep dokploy-network
```

#### 2. Configure DNS (One-Time)

Dokploy handles reverse proxy:
- Configure subdomain (e.g., goclaw.example.com)
- Map to Dokploy reverse proxy
- Let Dokploy handle SSL certificates

### Deployment Steps

#### Step 1: Prepare Environment

```bash
# In goclaw-deploy directory on Dokploy host
cp .env.example .env
nano .env
# Fill in credentials as before
```

#### Step 2: Deploy

```bash
docker compose -f docker-compose-dokploy.yml up -d
```

This:
- Pulls image from Docker Hub
- Joins dokploy-network
- Starts PostgreSQL
- Starts goclaw

#### Step 3: Verify

```bash
docker compose -f docker-compose-dokploy.yml ps

# Both should show healthy
```

#### Step 4: Configure Dokploy Reverse Proxy

In Dokploy dashboard:
1. Add application
2. Forward requests to: goclaw:8080 (internal network address)
3. Configure domain: goclaw.example.com
4. Enable SSL (Dokploy auto-provisions certificate)
5. Save

#### Step 5: Access

Open: **https://goclaw.example.com**

(Dokploy handles SSL termination)

### Dokploy-Specific Configuration

**Internal vs External:**
- Internal: Container talks to postgres via `postgres` hostname on dokploy-network
- External: Browser talks to Dokploy reverse proxy (not directly to container)

**Debugging Network Issues:**

```bash
# Check network attachment
docker inspect goclaw-deploy-goclaw-1 | grep -A 20 NetworkSettings

# Verify DNS resolution
docker exec goclaw-deploy-goclaw-1 ping postgres
```

### Troubleshooting Dokploy Deploy

**Network error (cannot reach postgres):**
```bash
# Verify dokploy-network exists
docker network inspect dokploy-network

# Verify both containers on same network
docker network inspect dokploy-network | grep Containers
```

**Reverse proxy returns 502:**
```bash
# Check container health
docker compose -f docker-compose-dokploy.yml logs goclaw
docker compose -f docker-compose-dokploy.yml ps

# Verify port binding (should be 8080, not exposed)
```

**SSL certificate not issued:**
```bash
# Check Dokploy logs for Let's Encrypt issues
# May need to whitelist domain or wait for DNS propagation
```

---

## Upgrade & Rollback

### Upgrade to New Version

**Production (docker-compose.yml):**

Release workflow (release.sh):
```bash
# In goclaw-deploy repo, release maintainers run:
./release.sh sync       # Merge upstream main/develop
./release.sh publish    # Build, push, update compose files
# Or simply:
./release.sh full       # Both sync and publish

# Workflow:
# 1. Checkout main in goclaw-core, fetch upstream, merge upstream/main
# 2. Checkout develop, merge main into develop
# 3. Auto-review config diffs (Dockerfile, Caddyfile.http)
# 4. Clean containers, test build
# 5. Build multi-arch (linux/amd64), push to Docker Hub
# 6. Update docker-compose.yml and docker-compose-dokploy.yml
# 7. Smoke test, commit
```

Then deploy the updated version:
```bash
git pull
docker compose pull
docker compose up -d
```

**Development (docker-compose-build.yml):**

```bash
# Pull latest source
cd ./goclaw-core
git pull origin main

# Rebuild container
cd ../goclaw-deploy
docker compose -f docker-compose-build.yml up -d --build
```

### Rollback to Previous Version

**If new version is broken:**

```bash
# Edit compose file, change image tag to previous version
nano docker-compose.yml
# Change: image: itsddvn/goclaw:v0.4.0-12-g231e112
#     To: image: itsddvn/goclaw:v0.3.0-7-g53cd9ce
#     (use any previous version tag)

# Restart with old image
docker compose pull
docker compose up -d
```

All volumes retained, no data loss. Check docker image history for available versions:
```bash
docker image history itsddvn/goclaw | grep TAG
```

---

## Database Management

### Initial Setup

Database is auto-initialized:
1. PostgreSQL container starts
2. entrypoint.sh runs `goclaw upgrade`
3. Schema created, tables initialized

No manual steps needed.

### Backup Database

```bash
# Backup to SQL file
docker compose exec postgres pg_dump \
  -U goclaw -d goclaw > backup-$(date +%Y%m%d).sql

# Backup to compressed file (smaller)
docker compose exec postgres pg_dump \
  -U goclaw -d goclaw | gzip > backup-$(date +%Y%m%d).sql.gz
```

### Restore Database

```bash
# From SQL file
docker compose exec postgres psql \
  -U goclaw -d goclaw < backup-20260301.sql

# From compressed file
gunzip < backup-20260301.sql.gz | \
  docker compose exec -T postgres psql \
  -U goclaw -d goclaw
```

### Reset Database (Clean Slate)

```bash
# WARNING: Deletes all data
docker compose down -v

# Restart (fresh database)
docker compose up -d
```

---

## Volume Management

### View Volumes

```bash
docker volume ls | grep goclaw
```

Output:
```
goclaw-deploy_goclaw-data
goclaw-deploy_goclaw-workspace
goclaw-deploy_goclaw-skills
goclaw-deploy_goclaw-sessions
goclaw-deploy_goclaw-dotdir
goclaw-deploy_pgdata
```

### Inspect Volume

```bash
docker volume inspect goclaw-deploy_goclaw-data
```

Shows mountpoint and metadata.

### Backup Volumes

```bash
# Create tar archive of volume
docker run --rm \
  -v goclaw-deploy_goclaw-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/data-backup.tar.gz /data

# Verify
ls -lh data-backup.tar.gz
```

### Restore Volumes

```bash
# Create fresh container with volume
docker run --rm \
  -v goclaw-deploy_goclaw-data:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/data-backup.tar.gz -C /
```

### Remove Volumes

```bash
# With containers
docker compose down -v  # Removes volumes too

# Just volumes
docker volume rm goclaw-deploy_goclaw-data
```

---

## Monitoring & Logs

### View Logs

```bash
# All services
docker compose logs

# Specific service
docker compose logs goclaw
docker compose logs postgres

# Last N lines
docker compose logs --tail=50

# Follow (stream)
docker compose logs -f
docker compose logs -f goclaw
```

### Container Status

```bash
# Quick overview
docker compose ps

# Detailed JSON
docker compose ps --format json
```

### Resource Usage

```bash
# Live stats (exit with Ctrl+C)
docker stats

# One-time snapshot
docker stats --no-stream
```

### Health Status

```bash
# Check health
curl http://localhost/health

# Pretty print
curl http://localhost/health | jq .

# Expected:
{
  "status": "ok",
  "timestamp": "2026-03-01T...",
  "...": "..."
}
```

---

## Security Best Practices

### Credentials Management

1. **Never commit .env**
   ```bash
   # Already in .gitignore
   cat .gitignore | grep .env
   ```

2. **Use strong passwords**
   ```bash
   # Generate random password
   openssl rand -base64 32
   ```

3. **Rotate API keys**
   - Update GOCLAW_ANTHROPIC_API_KEY (or other providers)
   - Restart: docker compose up -d
   - No data loss

### Network Security

1. **Use firewall**
   ```bash
   # On host, block port 80/443 from external if needed
   ufw allow from 10.0.0.0/8 to any port 80   # Local network only
   ufw deny from any to any port 80            # External blocked
   ```

2. **Reverse proxy with authentication (Nginx, Caddy, etc.)**
   ```
   External → Nginx (auth required) → goclaw:80
   ```

3. **Use HTTPS in production**
   - Set `GOCLAW_DOMAIN` to enable Caddy's built-in auto HTTPS (Let's Encrypt)
   - Or deploy behind reverse proxy (Dokploy, etc.) for SSL termination
   - Never expose sensitive data over plain HTTP in production

### Regular Updates

```bash
# Check for updated images
docker pull itsddvn/goclaw:latest
docker pull pgvector/pgvector:pg18

# Update compose files
git pull
docker compose pull
docker compose up -d
```

---

## Auto HTTPS with Caddy

GoClaw uses Caddy as its built-in reverse proxy. When `GOCLAW_DOMAIN` is set, Caddy automatically obtains and renews a TLS certificate via Let's Encrypt — no manual certificate management needed.

### Enable Auto HTTPS

Add to your `.env`:

```env
# Set your public domain to enable auto HTTPS
GOCLAW_DOMAIN=goclaw.example.com
```

Then restart:

```bash
docker compose up -d
```

Caddy will:
1. Obtain a certificate from Let's Encrypt on first startup
2. Serve HTTPS on port 443 (`GOCLAW_HTTPS_PORT`, default `443`)
3. Redirect HTTP (port 80) to HTTPS automatically

### Port Variables

| Variable | Default | Description |
|---|---|---|
| `GOCLAW_HTTP_PORT` | `80` | Host port for HTTP traffic |
| `GOCLAW_HTTPS_PORT` | `443` | Host port for HTTPS traffic (auto HTTPS only) |
| `GOCLAW_DOMAIN` | *(unset)* | Domain name; enables auto HTTPS when set |

### Without Auto HTTPS (HTTP Only)

Leave `GOCLAW_DOMAIN` unset (default). Caddy serves HTTP only on port 80. Suitable for local use or when sitting behind an external SSL-terminating proxy (e.g., Dokploy, Nginx, Cloudflare).

### Requirements for Auto HTTPS

- Port 80 and 443 must be reachable from the internet (for ACME HTTP-01 challenge)
- DNS A/AAAA record for `GOCLAW_DOMAIN` must point to your server
- No firewall blocking inbound port 443

---

## Common Operations

### Stop Services

```bash
docker compose stop
# Graceful shutdown, preserves volumes
```

### Start Services

```bash
docker compose start
# Restart existing containers
```

### Restart Services

```bash
docker compose restart
# Stop then start
```

### Remove Services (Keep Data)

```bash
docker compose down
# Removes containers and networks, keeps volumes
```

### Full Cleanup (Delete Everything)

```bash
docker compose down -v
# Removes containers, networks, volumes
# WARNING: Data loss
```

### Shell into Container

```bash
docker compose exec goclaw sh
docker compose exec postgres psql -U goclaw -d goclaw
```

### Run One-Off Command

```bash
# Run migration manually
docker compose exec goclaw /app/goclaw migrate

# Run onboard (setup wizard)
docker compose exec goclaw /app/goclaw onboard

# Check version
docker compose exec goclaw /app/goclaw version
```

---

## Deployment Checklist

Use this before deploying to production:

- [ ] Docker and Docker Compose installed and updated
- [ ] System has 2GB+ free RAM and disk
- [ ] Required ports (80, 443) available
- [ ] .env file created and configured
- [ ] LLM API key added to .env
- [ ] GOCLAW_GATEWAY_TOKEN and GOCLAW_ENCRYPTION_KEY generated
- [ ] POSTGRES_PASSWORD set to strong value
- [ ] docker compose config passes validation
- [ ] Containers start without errors
- [ ] Health check passes (curl http://localhost/health)
- [ ] Dashboard accessible in browser
- [ ] Can log in and create/use agents
- [ ] Backup strategy in place (if production)
- [ ] Monitoring/alerting configured (if production)
- [ ] Documentation reviewed and understood
