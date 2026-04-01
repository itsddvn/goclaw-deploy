# Troubleshooting Guide

Common issues, error messages, and solutions.

## Container & Docker Issues

### Issue: Port Already in Use

**Error:**
```
Error response from daemon: Bind for 0.0.0.0:80 failed: port is already allocated
```

**Cause:** Another process or container is using port 80.

**Solution:**

Option 1: Use different port
```bash
GOCLAW_HTTP_PORT=8000 docker compose up -d
# Access at http://localhost:8000
```

Option 2: Find and stop conflicting process
```bash
# Find what's using port 80
lsof -i :80
# Output: COMMAND  PID  ... (app name and PID)

# Kill the process
kill -9 <PID>

# Or stop container using that port
docker stop <container_name>
docker rm <container_name>
```

Option 3: Wait for port to free up
```bash
# If service just crashed, wait 30s for TIME_WAIT to expire
sleep 30
docker compose up -d
```

---

### Issue: Docker Daemon Not Running

**Error:**
```
Cannot connect to Docker daemon at unix:///var/run/docker.sock
```

**Cause:** Docker daemon not started.

**Solution:**

On macOS:
```bash
# Start Docker Desktop
open /Applications/Docker.app

# Or from command line
docker --version  # Starts daemon if installed
```

On Linux:
```bash
sudo systemctl start docker
sudo usermod -aG docker $USER  # Add user to docker group
# Log out and back in for group changes to take effect
```

---

### Issue: Insufficient Disk Space

**Error:**
```
no space left on device
```

**Cause:** Docker images/volumes filling up disk.

**Solution:**

Check disk usage:
```bash
df -h /
# Check remaining space

# Check Docker usage
docker system df
```

Clean up:
```bash
# Remove unused images
docker image prune -a

# Remove unused volumes
docker volume prune

# Remove unused networks
docker network prune

# Complete cleanup
docker system prune -a --volumes
```

---

### Issue: Cannot Pull Image

**Error:**
```
Error response from daemon: pull access denied for itsddvn/goclaw, repository does not exist or may require 'docker login'
```

**Cause:** Authentication issue or network problem.

**Solution:**

Try pulling with retry:
```bash
docker pull itsddvn/goclaw:v0.4.0-12-g231e112
# May take time, retry if network flaky
```

Login to Docker Hub (if needed):
```bash
docker login
# Enter username and token

docker compose pull
```

Check Docker Hub status:
```bash
# Check if Docker Hub is down
curl -s https://www.dockerstatus.com/ | grep -i status

# Or try alternative registry (if mirrored)
docker pull docker.io/itsddvn/goclaw:v0.4.0-12-g231e112
```

---

## Startup & Health Issues

### Issue: Container Keeps Restarting

**Error:**
```
docker compose ps
# STATUS: Restarting (1) 5s

docker compose logs goclaw --tail=20
# Shows repeated restart attempts
```

**Cause:** Application crashes on startup.

**Solution:**

View logs to find cause:
```bash
docker compose logs goclaw --tail=100 | grep -i error
```

Common causes:

**1. Database not ready**
```bash
# Check PostgreSQL status
docker compose logs postgres | grep -i error

# Wait longer
docker compose down
sleep 5
docker compose up -d
```

**2. Migration failure**
```bash
docker compose logs goclaw | grep -i migration

# Check PostgreSQL connectivity
docker compose exec goclaw nc -zv postgres 5432
```

**3. Invalid environment variables**
```bash
# Check .env file
cat .env | grep GOCLAW

# Validate compose
docker compose config
```

**4. Missing configuration**
```bash
# Ensure required LLM keys are set
grep -E "GOCLAW_.*_API_KEY" .env | grep -v "^#"
```

---

### Issue: Healthcheck Fails

**Error:**
```
docker compose ps
# STATUS: Up (unhealthy)

curl http://localhost/health
# Connection refused or timeout
```

**Cause:** Service not responding to health check.

**Solution:**

Check what's running:
```bash
docker compose ps -a
# Check STATUS column for each service
```

View container logs:
```bash
docker compose logs goclaw --tail=50
docker compose logs postgres --tail=50
```

Wait for service startup (takes ~30s):
```bash
# Database might be slow
docker compose logs postgres | tail -20
# Look for "database system is ready"

# GoClaw might be migrating
docker compose logs goclaw | tail -20
# Look for "ready to serve"
```

Manual health check:
```bash
# Test API directly
curl -v http://localhost/health

# If timeout, container may not be fully started
# Wait and retry
sleep 10
curl http://localhost/health
```

---

## Database Issues

### Issue: PostgreSQL Won't Start

**Error:**
```
docker compose logs postgres | head -30
# Error about data directory or startup
```

**Cause:**
- Corrupted data volume
- Permission issues
- Insufficient disk space

**Note:** PostgreSQL is not exposed externally. It only runs within the Docker network and is only accessible from the goclaw container.

**Solution:**

Reset database (clears all data):
```bash
docker compose down -v  # -v removes volumes
docker compose up -d
# Fresh PostgreSQL init
```

Check volume permissions:
```bash
docker volume inspect goclaw-deploy_pgdata
# Check "Mountpoint" field

# Fix permissions
docker run --rm \
  -v goclaw-deploy_pgdata:/data \
  alpine chmod -R 777 /data
```

---

### Issue: Database Connection Failed

**Error:**
```
docker compose logs goclaw | grep -i "database connection"
# psql: error: could not connect to server
```

**Cause:** PostgreSQL not accepting connections.

**Solution:**

Verify PostgreSQL is healthy:
```bash
docker compose ps
# postgres STATUS should be "healthy"
docker compose logs postgres
```

Check DSN in .env:
```bash
grep GOCLAW_POSTGRES_DSN .env
# Should be: postgres://goclaw:password@postgres:5432/goclaw?sslmode=disable
```

Test connectivity from goclaw container:
```bash
docker compose exec goclaw sh
# Inside container:
nc -zv postgres 5432
# Should output: postgres (5432) open
```

Check database credentials:
```bash
# Verify in .env
grep POSTGRES_PASSWORD .env
grep POSTGRES_USER .env
grep POSTGRES_DB .env
```

---

### Issue: Database Migration Failed

**Error:**
```
docker compose logs goclaw | grep -i migration
# Error applying migration 001_schema.sql
```

**Cause:**
- Migration syntax error
- Incompatible schema change
- Corrupted database state

**Solution:**

View full migration logs:
```bash
docker compose logs goclaw --tail=100 | grep -A 5 -B 5 migration
```

Manually check database:
```bash
docker compose exec postgres psql \
  -U goclaw -d goclaw \
  -c "SELECT version;"
# Confirms database is running
```

Check migration files:
```bash
# In the ./goclaw-core submodule
ls ./goclaw-core/migrations/
# Should contain SQL files (001_, 002_, etc.)

# Verify they're in image
docker compose exec goclaw ls /app/migrations/
```

Reset and retry:
```bash
docker compose down -v
docker compose up -d
# Fresh start, runs all migrations
```

---

## Network & Connectivity Issues

### Issue: Cannot Access Dashboard

**Error:**
```
Browser: localhost - Cannot reach server / Connection refused
```

**Cause:**
- Container not running
- Port mapping issue
- Firewall blocking

**Solution:**

Verify container running:
```bash
docker compose ps
# goclaw should be "Up" and healthy
```

Test port:
```bash
curl http://localhost
# If timeout, port not exposed

# Check if listening
netstat -tlnp | grep ':80 '
# (or: lsof -i :80)
```

Check Docker compose port mapping:
```bash
docker compose ps
# Under "PORTS" column, should see: 0.0.0.0:80->8080/tcp
```

Firewall/VPN issue:
```bash
# Try localhost
curl http://127.0.0.1

# If localhost works but 192.168.*.* doesn't,
# firewall or VPN may be blocking
```

Restart and try:
```bash
docker compose restart
sleep 5
curl http://localhost/health
```

---

### Issue: WebSocket Connection Failed

**Error:**
```
Browser console: WebSocket connection to 'ws://localhost/ws' failed
```

**Cause:** WebSocket proxy misconfigured.

**Solution:**

Check Caddy configuration:
```bash
docker compose exec goclaw cat /tmp/Caddyfile
# Should include a reverse_proxy directive routing /ws to 127.0.0.1:18790
```

Test WebSocket:
```bash
# Install websocat if needed
# websocat ws://localhost/ws
# or use curl
curl -i -N -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  http://localhost/ws
```

Check backend readiness:
```bash
docker compose logs goclaw | tail -20
# Should show: "serving" or "ready"
```

---

### Issue: API Returns 502 Bad Gateway

**Error:**
```
curl http://localhost/v1/...
# 502 Bad Gateway
```

**Cause:** Backend (goclaw:18790) not responding.

**Solution:**

Verify backend is running:
```bash
docker compose exec goclaw sh
# Inside container:
curl http://127.0.0.1:18790/health
# Should respond

exit
```

Check backend logs:
```bash
docker compose logs goclaw --tail=50 | grep -i error
```

Check Caddy logs (Caddy logs to stderr, captured by Docker):
```bash
docker compose logs goclaw | grep -i caddy
```

Restart services:
```bash
docker compose restart
sleep 5
curl http://localhost/v1/health
```

---

## Configuration Issues

### Issue: LLM API Key Not Working

**Error:**
```
Dashboard: "Invalid API key" or "Authentication failed"
```

**Cause:**
- Invalid or expired key
- Wrong key format
- Key not loaded

**Solution:**

Verify key is set:
```bash
grep GOCLAW_ANTHROPIC_API_KEY .env
# Should show: GOCLAW_ANTHROPIC_API_KEY=sk-ant-...
```

Check key format:
```bash
# Anthropic keys start with sk-ant-
# OpenAI keys start with sk-
# Verify against provider's docs
```

Restart to reload:
```bash
docker compose down
docker compose up -d
# .env reloaded on startup
```

Test API directly (if supported):
```bash
# Example: Test Anthropic key
curl https://api.anthropic.com/v1/health \
  -H "x-api-key: $GOCLAW_ANTHROPIC_API_KEY"
# If 401, key is invalid
```

Try different provider:
```bash
# Edit .env, use different provider
GOCLAW_OPENAI_API_KEY=sk-...

docker compose restart
# Switch to OpenAI
```

---

### Issue: Configuration File Not Found

**Error:**
```
docker compose logs goclaw | grep -i "config"
# config.json: no such file or directory
```

**Cause:** Config file missing or path wrong.

**Solution:**

Check default location:
```bash
docker compose exec goclaw ls -la /app/data/config.json
# May not exist on first run
```

Generate config:
```bash
# GoClaw auto-generates on first run
docker compose logs goclaw | grep -i "config"
# Should show creation message

# Wait 30s, check again
sleep 30
docker compose exec goclaw ls -la /app/data/config.json
```

Verify volume mount:
```bash
docker inspect goclaw-deploy-goclaw-1 | grep -A 20 "Mounts"
# Check that /app/data is mounted
```

Manual creation:
```bash
docker compose exec goclaw sh
# Inside container:
touch /app/data/config.json
exit
```

---

### Issue: Environment Variable Not Loaded

**Error:**
```
docker compose logs goclaw | grep "VAR_NAME"
# Variable not used or showing default
```

**Cause:** .env file not loaded or syntax error.

**Solution:**

Verify .env exists:
```bash
ls -la .env
# File should exist and be readable
```

Check .env syntax:
```bash
docker compose config
# If error, shows invalid YAML/env syntax
```

Verify env var is in .env:
```bash
grep "VAR_NAME" .env
# If empty, variable not set
```

Restart to load:
```bash
docker compose down
docker compose up -d
# Reloads .env on startup
```

Check in running container:
```bash
docker compose exec goclaw sh
# Inside:
echo $GOCLAW_HTTP_PORT  # Shows value or empty
env | grep GOCLAW       # Lists all GOCLAW_* vars
```

---

## Performance Issues

### Issue: High Memory Usage

**Error:**
```
docker stats
# goclaw container using 900MB+ of 1GB limit
```

**Cause:**
- Large embeddings/data loaded
- Memory leak in application
- Too many concurrent requests

**Solution:**

Check what's consuming:
```bash
docker stats --no-stream
# See all containers
```

Increase memory limit:
```bash
# Edit docker-compose.yml
deploy:
  resources:
    limits:
      memory: 2G  # Increase from 1G

docker compose up -d
```

Monitor growth:
```bash
docker stats goclaw
# Watch for steady increase (memory leak) vs normal spikes
```

Restart to free memory:
```bash
docker compose restart goclaw
# Clears memory caches
```

---

### Issue: Slow API Response

**Error:**
```
curl http://localhost/v1/...
# Takes > 5 seconds
```

**Cause:**
- LLM API slow
- Database slow
- Network latency
- Container resource constrained

**Solution:**

Check network latency:
```bash
time curl http://localhost/health
# Compare "real" time (total) vs "user"+"sys" (processing)
```

Monitor container resources:
```bash
docker stats goclaw
# Check CPU% and MEM% usage
# If at limits, increase in compose file
```

Check backend logs:
```bash
docker compose logs goclaw | tail -50
# Look for slow queries or LLM API timeouts
```

LLM API response time:
```bash
# May be normal (models take time to respond)
# Test with simple prompt first to isolate issue
```

---

### Issue: Container Uses 100% CPU

**Error:**
```
docker stats
# goclaw CPU% stuck at 100%+
```

**Cause:**
- Infinite loop or busy-wait
- Too many background tasks
- Compilation happening

**Solution:**

Check if it's normal (building):
```bash
docker compose logs goclaw | tail -20
# If building/compiling, CPU spike is normal
```

If stuck:
```bash
docker compose logs goclaw --tail=100 | grep -i error
# Check for issues

docker compose restart goclaw
# Hard restart
```

Check for runaway processes:
```bash
docker compose exec goclaw ps aux
# Look for processes using CPU
```

---

## Build Issues

### Issue: Docker Build Fails

**Error (docker-compose-build.yml):**
```
failed to build image
error building context: ...
```

**Cause:** Build context or Dockerfile problem.

**Solution:**

Check build context:
```bash
# Verify ./goclaw-core submodule exists
ls -la ./goclaw-core/
# If missing, initialize submodule
git submodule update --init --recursive
```

Check Dockerfile:
```bash
ls -la Dockerfile
# Should exist in current directory
```

Check docker buildx:
```bash
docker buildx version
# If command not found, install:
# docker buildx create --use
```

Build with more verbose output:
```bash
docker compose -f docker-compose-build.yml build --verbose
# Shows detailed error messages
```

---

### Issue: Go Build Fails

**Error:**
```
error building context: /src: ...
```

**Cause:** Go source files missing or syntax error.

**Solution:**

Check ./goclaw-core source:
```bash
ls ./goclaw-core/*.go
# Should have main.go and other files
cd ./goclaw-core
git log -1  # Check if repo valid
```
```

Check Go version:
```bash
# Dockerfile expects Go 1.25
cat Dockerfile | grep "golang:"
# If mismatch, may need to update
```

Build errors in code:
```bash
# Check ./goclaw-core for syntax errors
cd ./goclaw-core
go build
# This shows compilation issues
```

---

### Issue: npm/pnpm Build Fails

**Error:**
```
error building context: ui/web build failed
```

**Cause:** Frontend dependencies or code issue.

**Solution:**

Check web source:
```bash
ls -la ./goclaw-core/ui/web/
# Should have: package.json, pnpm-lock.yaml
```

Build locally:
```bash
cd ./goclaw-core/ui/web
pnpm install
pnpm build
# Shows actual error messages
```
```

Check pnpm version:
```bash
# Dockerfile pins pnpm@10.28.2
# May need to align local version
pnpm --version
```

Clear cache:
```bash
docker compose -f docker-compose-build.yml down -v
docker builder prune --all
docker compose -f docker-compose-build.yml build --no-cache
```

---

## Common Solutions

### Nuclear Option: Complete Reset

When all else fails:

```bash
# Stop everything
docker compose down -v  # Removes volumes too!

# Clean up Docker
docker system prune -a --volumes

# Verify clean state
docker image ls | grep goclaw  # Should be empty
docker volume ls | grep goclaw  # Should be empty

# Restart fresh
docker compose pull
docker compose up -d
```

**WARNING:** This deletes all data! Backup first if needed.

### Verify Setup Script

```bash
#!/bin/bash
set -e

echo "Checking prerequisites..."
docker --version || { echo "Docker not found"; exit 1; }
docker compose version || { echo "Docker Compose not found"; exit 1; }

echo "Checking configuration..."
[[ -f .env ]] || { echo ".env missing"; exit 1; }
grep GOCLAW_ANTHROPIC_API_KEY .env || grep GOCLAW_OPENAI_API_KEY .env || \
  { echo "No LLM key configured"; exit 1; }

echo "Validating compose..."
docker compose config > /dev/null || { echo "Invalid compose"; exit 1; }

echo "Starting services..."
docker compose pull
docker compose up -d

echo "Waiting for health..."
for i in {1..60}; do
  curl -s http://localhost/health && \
    { echo "Services healthy!"; exit 0; } || sleep 1
done

echo "Healthcheck timeout"
docker compose logs
exit 1
```

---

## Getting Help

If issues persist:

1. **Check docs:**
   - [Deployment Guide](./deployment-guide.md)
   - [System Architecture](./system-architecture.md)

2. **Review logs:**
   ```bash
   docker compose logs -f --tail=100
   ```

3. **GitHub Issues:**
   - goclaw-deploy: https://github.com/nextlevelbuilder/goclaw-deploy/issues
   - goclaw-core: https://github.com/nextlevelbuilder/goclaw/issues

4. **Debugging:**
   ```bash
   # Shell into container
   docker compose exec goclaw sh

   # Check processes
   ps aux

   # Test services
   curl http://127.0.0.1:18790/health  # Backend
   nc -zv postgres 5432                 # Database

   # View config
   cat /app/data/config.json
   ```
