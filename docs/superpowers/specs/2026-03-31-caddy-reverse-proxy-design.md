# Design: Replace Nginx with Caddy for Reverse Proxy & Auto HTTPS

**Date:** 2026-03-31
**Status:** Approved
**Scope:** goclaw-deploy container internals + docker-compose configuration

## Summary

Replace nginx with Caddy inside the goclaw container to serve as reverse proxy and static file server. Add auto HTTPS capability via `GOCLAW_DOMAIN` environment variable, while maintaining backward-compatible HTTP-only mode for behind-proxy deployments.

## Goals

1. Replace nginx with Caddy as the in-container reverse proxy and static file server
2. Enable auto HTTPS (Let's Encrypt) when `GOCLAW_DOMAIN` is set
3. Fall back to HTTP-only mode (port 80) when no domain is configured
4. Allow users to override port mapping externally via docker-compose
5. Persist certificates across container restarts

## Non-Goals

- Adding Caddy as a separate container (sidecar)
- Changing the goclaw backend application
- Modifying the Dokploy deployment variant

## Architecture

### Current Flow

```
Host:3000 → Container:8080 (nginx)
           ├→ /v1/*    → 127.0.0.1:18790 (API)
           ├→ /ws      → 127.0.0.1:18790 (WebSocket)
           ├→ /health  → 127.0.0.1:18790 (Health)
           └→ /*       → Static SPA files
```

### New Flow

**HTTP mode (no domain):**
```
Host:{GOCLAW_HTTP_PORT:-80} → Container:8080 (Caddy)
                              ├→ /v1/*    → 127.0.0.1:18790 (API)
                              ├→ /ws      → 127.0.0.1:18790 (WebSocket, 24h timeout)
                              ├→ /health  → 127.0.0.1:18790 (Health)
                              └→ /*       → Static SPA files (/app/dist)
```

**HTTPS mode (with domain):**
```
Host:{GOCLAW_HTTP_PORT:-80}   → Container:8080 (Caddy, redirect → HTTPS)
Host:{GOCLAW_HTTPS_PORT:-443} → Container:8443 (Caddy, auto TLS)
                                ├→ /v1/*    → 127.0.0.1:18790 (API)
                                ├→ /ws      → 127.0.0.1:18790 (WebSocket, 24h timeout)
                                ├→ /health  → 127.0.0.1:18790 (Health)
                                └→ /*       → Static SPA files (/app/dist)
```

> **Note:** Caddy listens on high ports (8080/8443) inside the container to avoid
> needing `NET_BIND_SERVICE` capability, preserving `no-new-privileges:true`.
> Docker port mapping translates host ports 80/443 → container 8080/8443.

## Approach

**Caddyfile template + entrypoint selection** — Two Caddyfile templates (`Caddyfile.http` and `Caddyfile.https`). The entrypoint script selects and renders the appropriate template based on `GOCLAW_DOMAIN`.

### Why This Approach

- Simple, no extra dependencies beyond `envsubst`/`sed`
- Two separate files are easier to read/debug than conditional logic in one file
- Caddy does not support if/else in Caddyfile, making a single-file approach impractical
- Consistent with existing entrypoint pattern (entrypoint.sh already handles environment-based configuration)

## Detailed Design

### 1. Caddyfile Templates

**`Caddyfile.http`** — HTTP-only mode (behind proxy or local dev):

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

**`Caddyfile.https`** — Auto HTTPS mode with domain:

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

**Preserved from current nginx config:**
- Gzip compression
- Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy)
- 1-year cache for `/assets/*` (Vite hashed filenames)
- SPA fallback (`try_files`)
- WebSocket proxy (`/ws`) with 24-hour read timeout (matches nginx `proxy_read_timeout 86400s`)
- Max request body 50MB (matches nginx `client_max_body_size 50m`)

**Behavioral notes:**
- Caddy's `reverse_proxy` automatically sets `X-Real-IP`, `X-Forwarded-For`, `Host` headers (matching current nginx config)
- Caddy's `encode gzip` compresses all compressible MIME types by default (nginx config specified explicit types — Caddy's default is a superset)
- Caddy logs to stderr by default, which Docker captures — no separate log files needed (nginx wrote to `/tmp/nginx/`)
- In HTTPS mode, Caddy automatically redirects HTTP → HTTPS. Port 80 must be publicly accessible for ACME HTTP-01 challenges

### 2. Entrypoint Changes

Full replacement of nginx-related code in `entrypoint.sh`:

**Remove:**
- nginx temp directory creation (`mkdir -p /tmp/nginx/client_body ...`)
- nginx startup line (`nginx -c /app/nginx-main.conf &`)
- All `NGINX_PID` references

**Add to root init block** (after existing volume ownership fixes):
```bash
# Fix caddy data volume ownership
chown goclaw:goclaw /data 2>/dev/null || true
```

**Replace nginx startup with Caddy** (in `serve` case):
```bash
# Select Caddyfile based on GOCLAW_DOMAIN
if [ -n "$GOCLAW_DOMAIN" ]; then
    envsubst '$GOCLAW_DOMAIN' < /app/Caddyfile.https > /tmp/Caddyfile
else
    cp /app/Caddyfile.http /tmp/Caddyfile
fi

# Start Caddy as goclaw user (high ports, no special capabilities needed)
run_as_goclaw caddy run --config /tmp/Caddyfile --adapter caddyfile &
CADDY_PID=$!
```

> Uses `envsubst` instead of `sed` to avoid issues with special characters in domain names.

**Update `shutdown()` function:**
```bash
shutdown() {
    kill "$GOCLAW_PID" "$CADDY_PID" 2>/dev/null
    wait "$GOCLAW_PID" "$CADDY_PID" 2>/dev/null
}
```

**Update process monitor `while` loop:**
```bash
while kill -0 "$GOCLAW_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
    sleep 1
done
```

### 3. Dockerfile Changes

```dockerfile
# Replace: apk add nginx
# With:    apk add caddy gettext-envsubst

# Change static files destination (was /usr/share/nginx/html)
COPY --from=webbuilder /app/dist /app/dist

# Remove: COPY nginx.conf nginx-main.conf
# Add:    COPY Caddyfile.http Caddyfile.https /app/

# Change exposed ports (high ports, no root needed)
EXPOSE 8080 8443

# Update healthcheck
HEALTHCHECK CMD wget -qO- http://localhost:8080/health
```

### 4. Docker Compose Changes

**docker-compose.yml** and **docker-compose-build.yml:**

```yaml
services:
  goclaw:
    ports:
      - "${GOCLAW_HTTP_PORT:-80}:8080"
      - "${GOCLAW_HTTPS_PORT:-443}:8443"
    volumes:
      - caddy-data:/data
      # ... existing volumes unchanged
    environment:
      - GOCLAW_DOMAIN=${GOCLAW_DOMAIN:-}
      # ... existing env unchanged
    # No new capabilities needed — Caddy uses high ports (8080/8443)
    # Existing cap_add (SETUID, SETGID, CHOWN) and no-new-privileges:true unchanged

volumes:
  caddy-data:
  # ... existing volumes unchanged
```

**docker-compose-dokploy.yml** — no changes to compose file itself, but the
shared Dockerfile changes (port 8080, caddy instead of nginx) apply. Dokploy
auto-detects the EXPOSE port, so the change from 8080 (nginx) to 8080 (caddy)
is transparent. Verify Dokploy routing after deployment.

### 5. Environment Variables

**.env.example** additions:

```bash
# Domain for auto HTTPS via Let's Encrypt (leave empty to disable)
# When set: Caddy serves HTTPS on 443, redirects HTTP 80 → 443
# When empty: Caddy serves HTTP on port 80 (for behind-proxy or local dev)
# GOCLAW_DOMAIN=example.com

# Port mapping (host ports, container listens on 8080/8443)
# GOCLAW_HTTP_PORT=80
# GOCLAW_HTTPS_PORT=443
```

### 6. Security

**Improvements over nginx:**
- Caddy runs as non-root user `goclaw` (nginx currently runs as root)
- No additional capabilities needed — Caddy uses high ports (8080/8443)
- `no-new-privileges:true` preserved (no conflict with high ports)
- All existing security settings unchanged (cap_drop ALL, tmpfs noexec, resource limits)

**Certificate storage:**
- Volume `caddy-data:/data` persists Let's Encrypt certificates
- Contains: certs, ACME account keys, OCSP staples
- Entrypoint runs `chown goclaw:goclaw /data` on startup to ensure write permission

**ACME requirements (HTTPS mode only):**
- Port 80 must be publicly accessible for HTTP-01 challenges
- DNS A/AAAA record must point to the server's IP
- Users behind NAT or restrictive firewalls will get certificate failures

## Migration Notes

**Breaking change: container port 8080 → 8080 (same), but host port default changes.**

Existing users with `GOCLAW_HOST_PORT=3000` mapping to container port 8080 need to update:
- Old: `${GOCLAW_HOST_PORT:-3000}:8080`
- New: `${GOCLAW_HTTP_PORT:-80}:8080`

To keep the same behavior, set `GOCLAW_HTTP_PORT=3000` in `.env`.

**Rollback:** Pin to the previous image tag (before Caddy migration) in docker-compose.yml.

## Usage Scenarios

| Scenario | Environment Config | Port Mapping |
|----------|-------------------|--------------|
| VPS with auto HTTPS | `GOCLAW_DOMAIN=example.com` | `80:8080`, `443:8443` |
| Behind external proxy | No domain set, `GOCLAW_HTTP_PORT=8080` | `8080:8080` |
| Local development | No domain set, `GOCLAW_HTTP_PORT=3000` | `3000:8080` |

## Files Changed

| Action | File |
|--------|------|
| Add | `Caddyfile.http` |
| Add | `Caddyfile.https` |
| Modify | `Dockerfile` |
| Modify | `entrypoint.sh` |
| Modify | `docker-compose.yml` |
| Modify | `docker-compose-build.yml` |
| Modify | `.env.example` |
| Modify | `Makefile` (if any healthcheck/port references exist) |
| Modify | `docs/deployment-guide.md` |
| Delete | `nginx.conf` |
| Delete | `nginx-main.conf` |
