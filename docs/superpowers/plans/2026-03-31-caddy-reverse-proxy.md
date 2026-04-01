# Replace Nginx with Caddy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace nginx with Caddy inside the goclaw container, enabling optional auto HTTPS via `GOCLAW_DOMAIN` environment variable.

**Architecture:** Two Caddyfile templates (HTTP-only and HTTPS) selected by the entrypoint script based on `GOCLAW_DOMAIN`. Caddy listens on high ports (8080/8443) to preserve `no-new-privileges:true`. Docker port mapping translates host 80/443 → container 8080/8443.

**Tech Stack:** Caddy 2 (Alpine apk), gettext-envsubst, Docker, docker-compose

**Spec:** `docs/superpowers/specs/2026-03-31-caddy-reverse-proxy-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Caddyfile.http` | HTTP-only reverse proxy + static file server (behind proxy / local dev) |
| Create | `Caddyfile.https` | Auto HTTPS reverse proxy + static file server (direct VPS deploy) |
| Modify | `Dockerfile:28-51` | Replace nginx with caddy, change static files path, update EXPOSE/HEALTHCHECK |
| Modify | `entrypoint.sh:7-31,124-160` | Remove nginx refs, add /data chown, replace nginx startup with Caddy |
| Modify | `docker-compose.yml:6-8,17,21-26,79-84` | Update ports, add caddy-data volume, add GOCLAW_DOMAIN env |
| Modify | `docker-compose-build.yml:10-12,20,27-31,85-89` | Same changes as docker-compose.yml |
| Modify | `.env.example:33-34` | Replace GOCLAW_HOST_PORT with new env vars |
| Modify | `docs/deployment-guide.md` | Update port/nginx references to Caddy |
| Modify | `README.md` | Update port/nginx references |
| Modify | `docs/troubleshooting.md` | Update nginx-specific commands to Caddy equivalents |
| Modify | `docs/system-architecture.md` | Update architecture diagrams and routing descriptions |
| Modify | `docs/codebase-summary.md` | Update nginx references and file listings |
| Delete | `nginx.conf` | Replaced by Caddyfile.http / Caddyfile.https |
| Delete | `nginx-main.conf` | No longer needed (Caddy has no separate main config) |

---

### Task 1: Create Caddyfile.http

**Files:**
- Create: `Caddyfile.http`

- [ ] **Step 1: Create Caddyfile.http**

```caddyfile
:8080 {
    root * /app/dist
    encode gzip

    request_body {
        max_size 50MB
    }

    handle /v1/* {
        reverse_proxy 127.0.0.1:18790
    }

    handle /ws {
        reverse_proxy 127.0.0.1:18790 {
            transport http {
                read_timeout 86400s
            }
        }
    }

    handle /health {
        reverse_proxy 127.0.0.1:18790
    }

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    @assets path /assets/*
    header @assets Cache-Control "public, max-age=31536000, immutable"

    try_files {path} /index.html
    file_server
}
```

- [ ] **Step 2: Commit**

```bash
git add Caddyfile.http
git commit -m "feat: add Caddyfile.http for HTTP-only reverse proxy mode"
```

---

### Task 2: Create Caddyfile.https

**Files:**
- Create: `Caddyfile.https`

- [ ] **Step 1: Create Caddyfile.https**

```caddyfile
{
    http_port 8080
    https_port 8443
    storage file_system /data
}

${GOCLAW_DOMAIN} {
    root * /app/dist
    encode gzip

    request_body {
        max_size 50MB
    }

    handle /v1/* {
        reverse_proxy 127.0.0.1:18790
    }

    handle /ws {
        reverse_proxy 127.0.0.1:18790 {
            transport http {
                read_timeout 86400s
            }
        }
    }

    handle /health {
        reverse_proxy 127.0.0.1:18790
    }

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    @assets path /assets/*
    header @assets Cache-Control "public, max-age=31536000, immutable"

    try_files {path} /index.html
    file_server
}
```

> Note: `${GOCLAW_DOMAIN}` is a placeholder — `envsubst` replaces it at runtime in entrypoint.sh.

- [ ] **Step 2: Commit**

```bash
git add Caddyfile.https
git commit -m "feat: add Caddyfile.https for auto HTTPS mode with domain"
```

---

### Task 3: Update Dockerfile

**Files:**
- Modify: `Dockerfile:28-51`

- [ ] **Step 1: Replace nginx with caddy + gettext-envsubst**

Change line 31:
```dockerfile
# Old:
RUN apk add --no-cache nginx

# New:
RUN apk add --no-cache caddy gettext-envsubst
```

- [ ] **Step 2: Change static files destination**

Change line 34:
```dockerfile
# Old:
COPY --from=webbuilder /app/dist /usr/share/nginx/html

# New:
COPY --from=webbuilder /app/dist /app/dist
```

- [ ] **Step 3: Replace nginx config COPY with Caddyfile COPY**

Replace lines 37-38:
```dockerfile
# Old:
COPY nginx-main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/http.d/default.conf

# New:
COPY Caddyfile.http Caddyfile.https /app/
```

- [ ] **Step 4: Update comment, EXPOSE, and HEALTHCHECK**

Replace lines 30, 44-48:
```dockerfile
# Old comment (line 30):
# Add nginx for serving web UI + reverse proxying to goclaw backend

# New comment:
# Add caddy for serving web UI + reverse proxying to goclaw backend (supports auto HTTPS)

# Old (line 44-45):
# nginx listens on 8080, goclaw on 18790 (internal)
EXPOSE 8080

# New:
# caddy listens on 8080 (HTTP) and 8443 (HTTPS), goclaw on 18790 (internal)
EXPOSE 8080 8443

# Old (line 47-48):
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

# New (same port, just confirming no change needed):
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1
```

> Note: HEALTHCHECK port stays 8080 — Caddy HTTP port is the same as old nginx port.

- [ ] **Step 5: Update remaining nginx comments in Dockerfile**

Line 3: Change `core + nginx + web UI` → `core + caddy + web UI`
Line 40: Change `manages both goclaw + nginx` → `manages both goclaw + caddy`

- [ ] **Step 6: Verify Dockerfile is syntactically valid**

```bash
docker buildx build --check -f Dockerfile .
```

Expected: No syntax errors.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile
git commit -m "feat: replace nginx with caddy in Dockerfile"
```

---

### Task 4: Update entrypoint.sh

**Files:**
- Modify: `entrypoint.sh:7-31,124-160`

- [ ] **Step 1: Add /data volume ownership fix**

After line 31 (`mkdir -p /home/goclaw/.goclaw && chown -R goclaw:goclaw /home/goclaw`), add inside the `if [ "$(id -u)" = "0" ]` block:

```bash
  # Caddy data volume — certificates persist here
  chown goclaw:goclaw /data 2>/dev/null || true
```

- [ ] **Step 2: Update shutdown() function**

Replace lines 124-130:
```bash
# Old:
# Graceful shutdown: kill both processes
shutdown() {
    kill "$GOCLAW_PID" 2>/dev/null
    kill "$NGINX_PID" 2>/dev/null
    wait "$GOCLAW_PID" "$NGINX_PID" 2>/dev/null
    exit 0
}

# New:
# Graceful shutdown: kill both processes
shutdown() {
    kill "$GOCLAW_PID" "$CADDY_PID" 2>/dev/null
    wait "$GOCLAW_PID" "$CADDY_PID" 2>/dev/null
    exit 0
}
```

- [ ] **Step 3: Replace nginx startup with Caddy in serve case**

Replace lines 142-159 (keep line 160 `shutdown` unchanged):
```bash
# Old:
        # Prepare nginx writable dirs under /tmp (read-only filesystem)
        mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi \
                 /tmp/nginx/uwsgi /tmp/nginx/scgi /tmp/nginx/logs /tmp/nginx/run

        # Start goclaw in background (as goclaw user)
        run_as_goclaw /app/goclaw &
        GOCLAW_PID=$!

        # Start nginx (writable paths configured in nginx-main.conf → /tmp/nginx/)
        nginx -e /tmp/nginx/error.log -g 'daemon off;' &
        NGINX_PID=$!

        trap shutdown SIGTERM SIGINT

        # Exit when either process dies
        while kill -0 "$GOCLAW_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
            sleep 1
        done

# New:
        # Select Caddyfile based on GOCLAW_DOMAIN
        if [ -n "$GOCLAW_DOMAIN" ]; then
            envsubst '$GOCLAW_DOMAIN' < /app/Caddyfile.https > /tmp/Caddyfile
        else
            cp /app/Caddyfile.http /tmp/Caddyfile
        fi

        # Start goclaw in background (as goclaw user)
        run_as_goclaw /app/goclaw &
        GOCLAW_PID=$!

        # Start Caddy as goclaw user (high ports, no special capabilities needed)
        run_as_goclaw caddy run --config /tmp/Caddyfile --adapter caddyfile &
        CADDY_PID=$!

        trap shutdown SIGTERM SIGINT

        # Exit when either process dies
        while kill -0 "$GOCLAW_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
            sleep 1
        done
        shutdown
```

> Lines 159-160 (`done` / `shutdown`) are included in the replacement block.

- [ ] **Step 4: Verify no remaining nginx references**

```bash
grep -n -i nginx entrypoint.sh
```

Expected: No output (zero matches).

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: replace nginx with caddy in entrypoint"
```

---

### Task 5: Update docker-compose.yml

**Files:**
- Modify: `docker-compose.yml:6-8,16-17,21-26,79-84`

- [ ] **Step 1: Update header comments**

Replace lines 6-8:
```yaml
# Old:
# Dashboard: http://localhost:3000
# API:       http://localhost:3000/v1/
# pgAdmin:   http://localhost:5050

# New:
# Dashboard: http://localhost (or https://<domain> if GOCLAW_DOMAIN is set)
# API:       http://localhost/v1/
# pgAdmin:   http://localhost:5050
```

- [ ] **Step 2: Update ports mapping**

Replace line 17:
```yaml
# Old:
      - "${GOCLAW_HOST_PORT:-3000}:8080"

# New:
      - "${GOCLAW_HTTP_PORT:-80}:8080"
      - "${GOCLAW_HTTPS_PORT:-443}:8443"
```

- [ ] **Step 3: Add GOCLAW_DOMAIN to environment**

After line 25 (`GOCLAW_POSTGRES_DSN: ...`), add:
```yaml
      GOCLAW_DOMAIN: ${GOCLAW_DOMAIN:-}
```

- [ ] **Step 4: Add caddy-data volume**

After `goclaw-workspace:/app/workspace` in the goclaw service volumes, add:
```yaml
      - caddy-data:/data
```

Add to the top-level volumes section (after line 83):
```yaml
  caddy-data:
```

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: update docker-compose.yml for caddy (ports, volumes, env)"
```

---

### Task 6: Update docker-compose-build.yml

**Files:**
- Modify: `docker-compose-build.yml:9-11,19-20,85-90`

- [ ] **Step 1: Update header comments**

Replace lines 9-11:
```yaml
# Old:
# Dashboard: http://localhost:3000
# API:       http://localhost:3000/v1/
# pgAdmin:   http://localhost:5050

# New:
# Dashboard: http://localhost (or https://<domain> if GOCLAW_DOMAIN is set)
# API:       http://localhost/v1/
# pgAdmin:   http://localhost:5050
```

- [ ] **Step 2: Update ports mapping**

Replace line 20:
```yaml
# Old:
      - "${GOCLAW_HOST_PORT:-3000}:8080"

# New:
      - "${GOCLAW_HTTP_PORT:-80}:8080"
      - "${GOCLAW_HTTPS_PORT:-443}:8443"
```

- [ ] **Step 3: Add GOCLAW_DOMAIN to environment and caddy-data volume**

After `GOCLAW_POSTGRES_DSN` in environment, add:
```yaml
      GOCLAW_DOMAIN: ${GOCLAW_DOMAIN:-}
```

After `goclaw-workspace:/app/workspace` in volumes, add:
```yaml
      - caddy-data:/data
```

Add to top-level volumes:
```yaml
  caddy-data:
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose-build.yml
git commit -m "feat: update docker-compose-build.yml for caddy (ports, volumes, env)"
```

---

### Task 7: Update .env.example

**Files:**
- Modify: `.env.example:33-34`

- [ ] **Step 1: Replace GOCLAW_HOST_PORT with new variables**

Replace lines 33-34:
```bash
# Old:
# --- Host port (optional, default 3000) ---
# GOCLAW_HOST_PORT=3000

# New:
# --- Domain & Ports (optional) ---
# Domain for auto HTTPS via Let's Encrypt (leave empty to disable)
# When set: Caddy serves HTTPS, redirects HTTP → HTTPS
# When empty: Caddy serves HTTP only (for behind-proxy or local dev)
# GOCLAW_DOMAIN=

# Port mapping (host ports, container listens on 8080/8443)
# GOCLAW_HTTP_PORT=80
# GOCLAW_HTTPS_PORT=443
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "feat: update .env.example with GOCLAW_DOMAIN and port vars"
```

---

### Task 8: Delete nginx config files

**Files:**
- Delete: `nginx.conf`
- Delete: `nginx-main.conf`

- [ ] **Step 1: Delete nginx config files**

```bash
git rm nginx.conf nginx-main.conf
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove nginx config files (replaced by Caddyfile)"
```

---

### Task 9: Update deployment guide

**Files:**
- Modify: `docs/deployment-guide.md`

- [ ] **Step 1: Replace nginx/port references**

Search and update all references:
- `3000` → `80` (default port) where referring to default host port
- `GOCLAW_PORT` / `GOCLAW_HOST_PORT` → `GOCLAW_HTTP_PORT`
- `nginx` → `caddy` where referring to the reverse proxy
- Add note about `GOCLAW_DOMAIN` for auto HTTPS
- Update firewall section: mention ports 80/443 instead of 3000

Key lines to update (from grep results):
- Line 11: Port requirement `3000` → `80 (and 443 for HTTPS)`
- Line 81: `GOCLAW_HOST_PORT` → `GOCLAW_HTTP_PORT`
- Line 169, 179, 271, 276: `localhost:3000` → `localhost`
- Line 187: `lsof -i :3000` → `lsof -i :80`
- Line 398: `goclaw:8080` — keep (internal port unchanged)
- Line 470: `nginx.conf` → `Caddyfile.http, Caddyfile.https`
- Line 672, 675: `localhost:3000` → `localhost`
- Line 712-714: Port `3000` → `80` in firewall rules
- Line 719: `Nginx (auth required)` → `Reverse proxy (auth required)`
- Line 723: `nginx, Dokploy` → `Caddy, Dokploy`
- Line 808: `3000` → `80`
- Line 815: `localhost:3000` → `localhost`

- [ ] **Step 2: Add HTTPS section to deployment guide**

Add a new section after the existing deployment methods, before troubleshooting:

```markdown
## Auto HTTPS (Optional)

GoClaw supports automatic HTTPS via Caddy and Let's Encrypt.

### Prerequisites
- A domain name pointing to your server (A/AAAA record)
- Ports 80 and 443 publicly accessible (required for ACME HTTP-01 challenges)
- Not behind NAT or restrictive firewalls

### Enable HTTPS

Set `GOCLAW_DOMAIN` in your `.env` file:

\```bash
GOCLAW_DOMAIN=goclaw.example.com
\```

Restart the container. Caddy will automatically obtain and renew certificates.

### Behind a Reverse Proxy

If running behind another reverse proxy (Nginx, Traefik, Cloudflare, etc.),
do NOT set `GOCLAW_DOMAIN`. Instead, map to a custom port:

\```bash
GOCLAW_HTTP_PORT=8080
\```

Configure your external proxy to forward to `localhost:8080`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/deployment-guide.md
git commit -m "docs: update deployment guide for caddy and auto HTTPS"
```

---

### Task 10: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update nginx and port references**

Search and replace throughout:
- `localhost:3000` → `localhost` (lines 73, 74, 183, 203, 245)
- `GOCLAW_PORT=3000` → `GOCLAW_HTTP_PORT=3000` where applicable
- `nginx` → `caddy` where referring to the reverse proxy component

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README.md for caddy migration"
```

---

### Task 11: Update troubleshooting.md

**Files:**
- Modify: `docs/troubleshooting.md`

- [ ] **Step 1: Replace nginx-specific diagnostic commands**

Key changes:
- `cat /etc/nginx/http.d/default.conf` → `cat /tmp/Caddyfile`
- `cat /var/log/nginx/error.log` → `docker compose logs goclaw` (Caddy logs to stderr)
- `/var/log/nginx/` references → explain Caddy logs to stderr (captured by Docker)
- `nginx` → `caddy` where referring to the web server process
- Port `3000` → `80` where referring to the default host port
- `GOCLAW_PORT` / `GOCLAW_HOST_PORT` → `GOCLAW_HTTP_PORT`

- [ ] **Step 2: Commit**

```bash
git add docs/troubleshooting.md
git commit -m "docs: update troubleshooting.md for caddy migration"
```

---

### Task 12: Update system-architecture.md and codebase-summary.md

**Files:**
- Modify: `docs/system-architecture.md`
- Modify: `docs/codebase-summary.md`

- [ ] **Step 1: Update system-architecture.md**

Replace throughout:
- `nginx` → `caddy` (process name, component references)
- Architecture diagrams: update routing descriptions
- Port mapping diagrams: reflect 8080/8443 internal ports
- Process management: replace nginx process description with Caddy

- [ ] **Step 2: Update codebase-summary.md**

Replace throughout:
- `nginx.conf` / `nginx-main.conf` → `Caddyfile.http` / `Caddyfile.https`
- `nginx ~20MB` → update size estimate for caddy
- Port mapping references

- [ ] **Step 3: Commit**

```bash
git add docs/system-architecture.md docs/codebase-summary.md
git commit -m "docs: update architecture and codebase docs for caddy migration"
```

---

### Task 13: Build and smoke test

> This task replaces the old Task 10. Run after all code/doc changes are complete.

**Files:** None (verification only)

- [ ] **Step 1: Build local image**

```bash
make build-local
```

Expected: Build succeeds. Caddy and gettext-envsubst packages install. Caddyfile templates copied. Static files at `/app/dist`.

- [ ] **Step 2: Smoke test HTTP mode (no domain)**

```bash
GOCLAW_HTTP_PORT=3000 docker compose up -d
sleep 5
curl -s http://localhost:3000/health
```

Expected: Health check returns 200 OK.

```bash
curl -sI http://localhost:3000/ | head -5
```

Expected: Returns HTML (SPA index.html) with security headers.

- [ ] **Step 3: Verify no nginx process inside container**

```bash
docker compose exec goclaw sh -c 'ps aux | grep -v grep | grep -E "nginx|caddy"'
```

Expected: Only `caddy` process, no `nginx`.

- [ ] **Step 4: Verify Caddyfile was correctly selected**

```bash
docker compose exec goclaw cat /tmp/Caddyfile
```

Expected: Contents of `Caddyfile.http` (since no GOCLAW_DOMAIN set).

- [ ] **Step 5: Cleanup**

```bash
docker compose down
```

- [ ] **Step 6: Commit (if any fixes were needed)**

Only if smoke test revealed issues that required code changes.
