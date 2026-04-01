# Code Standards & Conventions

Standards and patterns used throughout the goclaw-deploy repository.

## File Organization

### Naming Conventions

| File Type | Pattern | Example | Notes |
|---|---|---|---|
| Docker | PascalCase, descriptive | Dockerfile, Dockerfile.prod | No extensions |
| Compose | kebab-case-yml | docker-compose.yml, docker-compose-build.yml | Variant names clear |
| Shell | kebab-case.sh | entrypoint.sh, release.sh | Executable bit set |
| Config | lowercase/kebab | Caddyfile.http, .env.example | Standard formats |
| Docs | kebab-case.md | code-standards.md, system-architecture.md | Markdown docs |
| Ignore | dot-prefixed | .gitignore, .dockerignore | Standard patterns |

### Directory Structure

```
goclaw-deploy/
├── Dockerfile                    # Single multi-stage build
├── *.sh                          # Executable scripts
├── docker-compose*.yml           # Three variants (prod, dev, dokploy)
├── Caddyfile.http                # HTTP-only reverse proxy config
├── Caddyfile.https               # Auto HTTPS reverse proxy config
├── Makefile                      # Build targets
├── .env.example                  # Template (not .env)
├── README.md                     # Quick start
├── LICENSE                       # MIT license
└── docs/
    ├── codebase-summary.md       # File-by-file breakdown
    ├── code-standards.md         # This file
    ├── system-architecture.md    # Architecture & data flow
    ├── deployment-guide.md       # Step-by-step for all variants
    ├── project-overview-pdr.md   # Vision, goals, requirements
    └── troubleshooting.md        # FAQs, common issues
```

## Dockerfile Standards

### Pattern: Multi-Stage Build
Structure: compilation → bundling → runtime

```dockerfile
FROM base AS builder
# Heavy toolchains, compilation
# Output to /out or /app/dist

FROM alpine
# Copy only outputs from builders
# Set minimal env, user, healthcheck
```

**Rationale:** Minimize final image size, security (no build tools).

### Pattern: Named Build Contexts
goclaw-core is included as a git submodule at ./goclaw-core, so build contexts can copy files without bloating the Docker context.

```dockerfile
COPY Caddyfile.http Caddyfile.https /app/
```

Build command:
```bash
docker buildx build --build-context deploy=. -f Dockerfile ./goclaw-core
```

### Pattern: Cross-Platform Compilation
Use BUILDPLATFORM/TARGETARCH for multi-arch support.

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.25 AS go-builder
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -o /out/binary .
```

### Pattern: Non-Root User
Always create dedicated user, never run as root.

```dockerfile
RUN addgroup -S goclaw && adduser -S -G goclaw goclaw
USER goclaw
```

### Pattern: Health Checks
Enable Docker to detect service readiness.

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1
```

### Environment Variables in Dockerfile
Set defaults, don't hardcode service logic.

```dockerfile
ENV GOCLAW_PORT=18790 \
    GOCLAW_HOST=0.0.0.0 \
    GOCLAW_CONFIG=/app/config.json
```

**Bad:** ENV APP_MODE=production (should be in compose/runtime)
**Good:** ENV GOCLAW_PORT=18790 (deployment-neutral default)

## Docker Compose Standards

### Pattern: Env File + Environment
Separate concerns: secrets in .env (git-ignored), config in compose.

```yaml
services:
  service:
    env_file:
      - path: .env
        required: false
    environment:
      KEY_FROM_COMPOSE: value
      KEY_FROM_ENV: ${POSTGRES_PASSWORD}
```

### Pattern: Healthchecks for Dependencies
Ensure startup ordering without sleep.

```yaml
depends_on:
  postgres:
    condition: service_healthy
```

### Pattern: Named Volumes for Persistence
Use named volumes (not bind mounts) for production.

```yaml
volumes:
  data-volume:
    # Docker-managed, portable across hosts

# Not:
volumes:
  - ./local/path:/app/data
```

### Pattern: Security Options
Apply standard hardening to all services.

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
tmpfs:
  - /tmp:rw,noexec,nosuid,size=256m
```

### Pattern: Resource Limits
Prevent runaway containers.

```yaml
deploy:
  resources:
    limits:
      memory: 1G
      cpus: '2.0'
      pids: 200
```

### Compose File Variants
When creating variants, preserve all shared config; only change specific sections.

**docker-compose.yml** (production)
```yaml
services:
  goclaw:
    image: itsddvn/goclaw:TAG  # Pre-built
```

**docker-compose-build.yml** (development)
```yaml
services:
  goclaw:
    build:                       # From source
      context: ./goclaw-core
      dockerfile: ${PWD}/Dockerfile
```

**docker-compose-dokploy.yml** (PaaS)
```yaml
networks:
  dokploy-network:
    external: true
services:
  goclaw:
    networks:
      - dokploy-network
    image: itsddvn/goclaw:TAG   # Same as production
```

## Shell Script Standards

### Shebang & Options
```bash
#!/usr/bin/env bash    # Portable, finds bash in PATH
set -euo pipefail      # Exit on error, undefined vars, pipe failures
```

### Variable Naming
```bash
CONSTANT_VARS            # All caps for constants
local_variables          # Lowercase for locals
$1, $2, ...              # Positional arguments
$@, $*                   # All arguments (use "$@" with quotes)
${VAR:-default}          # Default value
${VAR:?error message}    # Error if unset
```

### Function Pattern
```bash
function_name() {
  local var1="$1"
  local var2="${2:-default}"

  # Error checking
  if [[ ! -d "$var1" ]]; then
    error "Directory not found: $var1"
    return 1
  fi

  # Work
  # Return status (0 for success, non-zero for failure)
}
```

### Error Handling
```bash
error()   { echo -e "${RED}✗ ${NC}$*" >&2; }
warn()    { echo -e "${YELLOW}⚠ ${NC}$*"; }
success() { echo -e "${GREEN}✓ ${NC}$*"; }
info()    { echo -e "${CYAN}ℹ ${NC}$*"; }
```

**Usage:**
```bash
if ! command; then
  error "Command failed"
  exit 1
fi
```

### Cleanup & Traps
```bash
cleanup() {
  # Remove temp files, kill background processes, etc.
  rm -f "$LOCKFILE"
  docker compose down -v 2>/dev/null || true
}
trap cleanup EXIT
```

### Platform-Specific Code
```bash
if [[ "$OSTYPE" == darwin* ]]; then
  # macOS-specific (sed -i '')
  sed -i '' "s/pattern/replacement/" "$file"
else
  # Linux (sed -i)
  sed -i "s/pattern/replacement/" "$file"
fi
```

### Locking for Concurrent Execution
```bash
LOCKFILE="/tmp/myapp.lock"

if [[ -f "$LOCKFILE" ]]; then
  pid=$(cat "$LOCKFILE")
  if kill -0 "$pid" 2>/dev/null; then
    error "Already running (PID $pid)"
    exit 1
  fi
fi
echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT
```

## Makefile Standards

### Pattern: Variable Defaults
```makefile
GOCLAW_DIR ?= ./goclaw-core
IMAGE      ?= itsddvn/goclaw
VERSION    ?= $(shell git describe --tags 2>/dev/null || echo dev)
```

### Pattern: .PHONY Declaration
Always declare phony targets.

```makefile
.PHONY: build build-local push all version clean
```

### Pattern: Comments & Formatting
```makefile
# Build for multi-arch (requires push or registry)
build:
	docker buildx build \
		--platform $(PLATFORMS) \
		-t $(IMAGE):$(VERSION) \
		$(GOCLAW_DIR)

# Build for local platform and load
build-local:
	docker buildx build \
		--platform $(LOCAL_ARCH) \
		--load \
		$(GOCLAW_DIR)
```

### Pattern: Help Target (Optional)
```makefile
help:
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:' Makefile | sed 's/:.*/ — /' | column -t
```

## Configuration Standards

### .env.example
Template for all environment variables, organized by category.

**Pattern:**
```env
# Category Name
VAR_NAME=                    # Description or empty placeholder
```

**Rules:**
- One variable per line
- Group by feature/provider
- Always git-committed (example, not secrets)
- No default values (users must fill in)
- Comments explain purpose

### Caddyfile
Standards for reverse proxy configuration.

**Pattern:**
```caddyfile
:8080 {
    root * /app/dist
    encode gzip

    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    # API proxy
    handle /v1/* {
        reverse_proxy 127.0.0.1:18790
    }

    # SPA fallback
    try_files {path} /index.html
    file_server
}
```

**Rules:**
- Listen on 8080 (HTTP) / 8443 (HTTPS) — high ports for no-new-privileges
- Add security headers via `header` block
- Use `handle` directives for route-specific proxying
- Use 127.0.0.1 for same-container backends
- Always include SPA fallback with `try_files`
- Use `envsubst` for domain-based HTTPS config

## Process Management Standards

### entrypoint.sh Pattern
Unified container entry point supporting multiple modes.

```bash
case "${1:-serve}" in
    serve)
        # Main service mode
        startup_checks
        background_process_1 &
        pid1=$!
        background_process_2 &
        pid2=$!
        trap shutdown SIGTERM SIGINT
        while kill -0 "$pid1" "$pid2" 2>/dev/null; do sleep 1; done
        ;;
    migrate)
        # One-off migration mode
        exec /app/binary migrate "$@"
        ;;
    *)
        # Pass-through to main binary
        exec /app/binary "$@"
        ;;
esac
```

**Rules:**
- Default mode (no args) is "serve"
- Support one-off utility modes (migrate, onboard, version)
- Use background processes + trap for graceful shutdown
- Use exec for final command (replaces shell process)

## Release Workflow Standards

### release.sh Pattern
Structured, repeatable release pipeline.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Config section (mutable)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Preflight checks (fail fast)
preflight_checks() {
  [[ -d "$CORE_DIR" ]] || { error "Core dir not found"; exit 1; }
  [[ -n "$(git -C "$CORE_DIR" remote -v | grep upstream)" ]] || { error "Upstream remote missing"; exit 1; }
  command -v docker &>/dev/null || { error "Docker not found"; exit 1; }
  docker buildx version &>/dev/null || { error "buildx not found"; exit 1; }
}

# Helper functions (reusable)
health_check() { ... }
cleanup() { ... }
trap cleanup EXIT

# Main workflow phases
do_sync() {
  # Checkout main, fetch upstream, merge upstream/main into fork/main
  # Checkout develop, merge main into develop
  # Auto-review config diffs (Dockerfile, Caddyfile.http)
  # Clean containers, test build
}

do_publish() {
  # Get VERSION from git tags
  # Build multi-arch (linux/amd64)
  # Push to Docker Hub
  # Update docker-compose.yml and docker-compose-dokploy.yml
  # Smoke test, commit
}

# Routing (clear entry point)
case "$COMMAND" in
  sync|publish|full) do_$COMMAND ;;
  *) usage; exit 1 ;;
esac
```

**Rules:**
- Set -euo pipefail (fail on any error)
- Config at top, mutable (SCRIPT_DIR, IMAGE, VERSION)
- Preflight checks early (upstream remote, docker, buildx)
- Trap cleanup EXIT
- Use named functions for phases (do_sync, do_publish)
- Clear routing at end
- Lock file prevents concurrent runs

### Version Detection
Always use git tags from goclaw-core; never hardcode versions.

```bash
VERSION=$(git -C "$CORE_DIR" describe --tags 2>/dev/null) || {
  error "Failed to get version from goclaw-core"
  exit 1
}

# Validate format
[[ -n "$VERSION" ]] || { error "Empty version"; exit 1; }
[[ "$VERSION" != *"dirty"* ]] || { error "Dirty working tree"; exit 1; }
[[ "$VERSION" =~ ^v[0-9] ]] || { error "Invalid version format: $VERSION"; exit 1; }
```

### Lock File Management
Prevent concurrent release runs.

```bash
LOCKFILE="/tmp/goclaw-release.lock"

# Acquire lock
if [[ -f "$LOCKFILE" ]]; then
  pid=$(cat "$LOCKFILE")
  if kill -0 "$pid" 2>/dev/null; then
    error "Already running (PID $pid)"
    exit 1
  fi
fi
echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT
```

## Documentation Standards

### Markdown File Structure
1. **Title** (H1)
2. **Brief intro** (1-2 sentences)
3. **Contents/Navigation** (if long)
4. **Main sections** (H2)
5. **Subsections** (H3)
6. **Code blocks with syntax highlighting**
7. **Tables for structured info**
8. **Links to related docs**

### Inline Code vs Code Blocks
```markdown
# Use backticks for:
Command names: `docker compose up`
Variable names: `GOCLAW_HTTP_PORT`
File paths: `.env.example`

# Use code blocks for:
Configuration examples
Shell commands with output
Multi-line code samples
```

### Cross-References
Link to related docs for navigation.

```markdown
See [System Architecture](./system-architecture.md) for details.
See [Troubleshooting](./troubleshooting.md) for common issues.
```

## Security Standards

### Dockerfile Security
- Non-root user (no root processes)
- CAP_DROP ALL (remove all capabilities)
- no-new-privileges (prevent escalation)
- tmpfs /tmp with noexec (prevent exploit execution)
- Regular base image updates

### Compose Security
- Resource limits (prevent DoS)
- Health checks (detect crashes)
- Security options (no-new-privileges, cap_drop)
- Secret management via .env (git-ignored)

### Shell Script Security
- Quote all variables ("$VAR" not $VAR)
- Use [[ ]] for conditionals (safer than [ ])
- Avoid eval, use arrays instead
- Validate input before use
- Use trap for cleanup

### Configuration Security
- Never commit .env with secrets
- Use git-ignored .env.example as template
- Document required secrets in comments
- Use strong random values for tokens/keys (e.g., `openssl rand -hex 32`)

## Testing & Validation Standards

### Docker Build Validation
```bash
# Build locally
docker buildx build --load -t image:test .

# Run health check
docker run -d --name test-container image:test
sleep 10
docker exec test-container wget -qO- http://localhost:8080/health
docker rm -f test-container
```

### Compose Validation
```bash
# Syntax check
docker compose config

# Dry-run
docker compose up --dry-run

# Real test
docker compose up -d
docker compose ps
docker compose logs
docker compose down -v
```

### Script Validation
```bash
# Syntax check
bash -n script.sh

# Dry-run
bash -x script.sh (shows commands)

# ShellCheck lint
shellcheck script.sh
```

## Change Management

### Breaking Changes
- Bump MAJOR version (semver)
- Document migration steps in CHANGELOG
- Update .env.example with new variables
- Announce in release notes

### Non-Breaking Changes
- Bump MINOR version for features
- Bump PATCH version for fixes
- Automatic migration (entrypoint.sh handles schema updates)

### Release Commits
```bash
git commit -m "release: update image to v0.3.0"
```

Use conventional commits:
- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation
- `chore:` — Maintenance
- `release:` — Version release

## Code Review Checklist

### Dockerfile
- [ ] Multi-stage build (no compile tools in runtime)
- [ ] Named build contexts used correctly
- [ ] Non-root user set (USER goclaw)
- [ ] Healthcheck defined
- [ ] Environment defaults reasonable
- [ ] Security: CAP_DROP, no-new-privileges
- [ ] Image size optimized (< 1GB)

### Docker Compose
- [ ] All three variants consistent (prod, dev, dokploy)
- [ ] Health checks on dependencies
- [ ] Named volumes (not bind mounts)
- [ ] Resource limits set
- [ ] Security options applied
- [ ] .env variables used for secrets
- [ ] Version tags pinned (not latest)

### Shell Scripts
- [ ] Shebang: #!/usr/bin/env bash
- [ ] set -euo pipefail present
- [ ] All variables quoted ("$VAR")
- [ ] Error checking (set -e catches errors)
- [ ] Trap cleanup on EXIT
- [ ] Functions documented
- [ ] Platform-specific code handled

### Documentation
- [ ] Accurate (reflects actual code)
- [ ] Clear examples provided
- [ ] Links to related docs
- [ ] No broken references
- [ ] Troubleshooting section for common issues
- [ ] File paths correct and verified
