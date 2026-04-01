# GoClaw Deploy — Project Overview & PDR

## Project Vision

Provide a production-ready, containerized packaging of GoClaw that enables fast deployment across local development, cloud platforms, and PaaS systems. Simplify multi-LLM agent orchestration with a single Docker image bundling backend, frontend, database, and reverse proxy.

## Project Goals

1. **Single-Image Deployment** — Complete GoClaw stack in one Docker image with zero external dependencies except PostgreSQL.
2. **Multi-Environment Support** — Same image works locally, on servers, and managed platforms (Dokploy, etc.).
3. **Zero-Downtime Releases** — Automated sync + build + push + smoke test pipeline with no manual intervention.
4. **Developer Friendly** — Clear compose variants for dev/prod/PaaS, simple env var config, comprehensive docs.
5. **Security by Default** — Non-root containers, capability dropping, tmpfs protections, security headers.

## Target Users

- **Platform Teams** — Deploy GoClaw across infrastructure with minimal ops overhead
- **Developers** — Rapid local testing and iteration using docker-compose
- **DevOps Engineers** — Integrate via automated release.sh pipeline
- **PaaS Users** — One-click deployments on Dokploy, Railway, Render, etc.

## Key Features

### Deployment Flexibility
- **Production** (docker-compose.yml) — Pre-built image from Docker Hub, instant startup
- **Development** (docker-compose-build.yml) — Build from source, test changes locally
- **PaaS** (docker-compose-dokploy.yml) — External network support for managed platforms

### Automated Release Workflow
- Sync upstream (`goclaw-core`) with conflict detection
- Auto-review config changes (Dockerfile, Caddyfile.http)
- Multi-arch build (linux/amd64, linux/arm64)
- Smoke test post-push before marking release complete

### Integrated Backend + Frontend
- Go backend (port 18790 internally, proxied by Caddy)
- React SPA served from Caddy (port 8080 HTTP / 8443 HTTPS)
- WebSocket support for real-time agent updates
- API routing at /v1/

### Database Integration
- PostgreSQL 18 with pgvector extension (vector embeddings)
- Auto-migration on startup (managed mode)
- Persistent named volumes for data
- Healthcheck integration

### Security Hardening
- Non-root user with capability restrictions
- tmpfs protections, resource limits
- Security headers (XSS, clickjacking, referrer policies)
- Configuration via git-ignored .env file

## Requirements

### Functional Requirements

| ID | Requirement | Status |
|---|---|---|
| FR-1 | Build multi-stage Docker image from goclaw-core source | Complete |
| FR-2 | Serve React SPA and API via Caddy reverse proxy | Complete |
| FR-3 | Support PostgreSQL 18 with pgvector in managed mode | Complete |
| FR-4 | Provide three compose variants (prod, dev, dokploy) | Complete |
| FR-5 | Auto-migrate database on container startup | Complete |
| FR-6 | Execute automated release workflow (sync + publish) | Complete |
| FR-7 | Support multi-arch cross-compilation (amd64, arm64) | Complete |
| FR-8 | Expose health check endpoint (/health) | Complete |
| FR-9 | Accept configuration via environment variables | Complete |
| FR-10 | Support LLM provider integration (11+ providers) | Complete (via upstream) |

### Non-Functional Requirements

| ID | Requirement | Target | Status |
|---|---|---|---|
| NFR-1 | Image size | < 1GB (optimized 3-stage) | Complete |
| NFR-2 | Startup time (cold start) | < 30s with healthcheck | Complete |
| NFR-3 | Memory usage | 1GB limit per container | Complete |
| NFR-4 | CPU allocation | 2 vCPU limit per container | Complete |
| NFR-5 | Security: non-root user | goclaw:goclaw, CAP_DROP ALL | Complete |
| NFR-6 | Deployment: zero external deps | Only PostgreSQL external | Complete |
| NFR-7 | Release automation | Fully scripted, no manual steps | Complete |
| NFR-8 | Documentation | README + codebase summary + guides | Complete |

## Success Metrics

### Deployment Reliability
- Production image pull success rate: 100%
- Container healthcheck pass rate: > 99%
- Startup time: < 30s (including DB migration)
- Uptime (running): 99.9%+

### Release Efficiency
- Release workflow execution time: < 15 minutes (including smoke test)
- Manual intervention required: None (fully automated)
- Release frequency: 1+ per week

### User Satisfaction
- Developer setup time: < 5 minutes (copy .env, docker compose up)
- Documentation coverage: All major features, troubleshooting guides
- Platform support: Local, cloud servers, PaaS (Dokploy, etc.)

### Security
- Security vulnerability scans: 0 critical issues
- CVE updates: Applied within 30 days
- Container root processes: 0 (always non-root)

## Architecture Decisions

### Decision: Multi-Stage Docker Build
**Rationale:** Separate compilation toolchains from runtime, minimize image size.
**Impact:** ~500MB final image instead of ~2GB with dependencies.

### Decision: Named Build Context for Deploy Configs
**Rationale:** Avoid including deploy repo in Docker build context; keep separation of concerns.
**Impact:** Dockerfile can reference `./goclaw-core` as build context while importing configs from deploy repo.

### Decision: Three Compose Variants
**Rationale:** Support different deployment scenarios without duplicating service definitions.
**Impact:** Single Dockerfile, three compositions for dev/prod/PaaS flexibility.

### Decision: Auto-Migration on Startup
**Rationale:** Zero-downtime deployments; schema migrations run transparently.
**Impact:** Container startup slightly longer, but enables safe image updates.

### Decision: Fully Automated Release Pipeline
**Rationale:** Reduce human error, enable frequent releases, ensure consistency.
**Impact:** release.sh as single source of truth; smoke tests catch breakage before push.

## Technical Constraints

### Upstream Dependency
- **goclaw-core** is included as a git submodule at ./goclaw-core
- Requires main + develop branches
- Must have upstream remote configured
- Uses git tags for versioning

### Docker Requirements
- Docker buildx (multi-arch support)
- Compose v2+ (health checks, additional_contexts)
- ~2GB free disk per build

### Platform Support
- **Linux:** Full support (amd64, arm64)
- **macOS:** Works locally, but M1/M2 (arm64) built images run slower on amd64 targets
- **Windows:** Requires WSL 2 with Docker Desktop

### Build-Time Requirements
- Go 1.25+ (for cross-compilation flags)
- Node 22+ (for pnpm, Vite build)
- Alpine 3.22+ (runtime stability)

## Risk Assessment

### High Risks

**Risk: Upstream Merge Conflicts**
- Impact: Release blocked until manually resolved
- Mitigation: release.sh detects conflicts, provides clear resolution steps

**Risk: Multi-Arch Build Failures**
- Impact: One platform (amd64 or arm64) fails to build
- Mitigation: Local test build on primary arch before publishing

### Medium Risks

**Risk: Database Migration Failure**
- Impact: Container startup fails, service unavailable
- Mitigation: Healthcheck catches issues; smoke tests verify; rollback via image tag

**Risk: Docker Hub Credentials Leak**
- Impact: Unauthorized image pushes
- Mitigation: Use PAT (Personal Access Token) with minimal scope; store in secure secret manager

### Low Risks

**Risk: Compose File Syntax Drift**
- Impact: Deployment fails with parsing error
- Mitigation: release.sh smoke test catches before commit

**Risk: Caddy Config or Process Failure**
- Impact: Reverse proxy unavailable
- Mitigation: Container healthcheck from start-period ensures full readiness

## Acceptance Criteria

### Definition of Done (Per Release)
- [ ] Upstream merge successful (no conflicts)
- [ ] Local test build passes healthcheck (60s timeout)
- [ ] Multi-arch image builds without errors
- [ ] Image pulled and verified from Docker Hub
- [ ] Smoke test with pulled image passes (healthcheck)
- [ ] Compose files updated with new version tag
- [ ] Release committed with message "release: update image to {VERSION}"
- [ ] Documentation reflects changes

### Breaking Changes
None yet. Image API (env vars, ports, paths) stable.

### Migration Path
When breaking changes occur:
- Update .env.example with new variables
- Document in CHANGELOG with migration steps
- Bump major version in semver

## Timeline & Phases

### Phase 1: Foundation (Complete)
- Multi-stage Dockerfile ✓
- Docker Compose setup ✓
- entrypoint.sh lifecycle management ✓
- Caddy reverse proxy ✓

### Phase 2: Automation (Complete)
- release.sh sync workflow ✓
- release.sh publish workflow ✓
- Makefile targets ✓
- Multi-arch support ✓

### Phase 3: Documentation (Complete)
- README.md with quick start ✓
- Codebase summary ✓
- Code standards guide ✓
- System architecture ✓
- Deployment guide ✓
- Troubleshooting FAQ ✓

### Phase 4: Enhancement (Future)
- Helm charts for Kubernetes
- Compose overrides for dev extensions
- CI/CD integration (GitHub Actions auto-release)
- Performance profiling & optimization
- Additional PaaS templates (Railway, Render, Fly.io)

## Operational Runbook

### Starting the Service
```bash
cp .env.example .env
# Edit .env with API keys, passwords
docker compose up -d
curl http://localhost/health
```

### Releasing a New Version
```bash
cd goclaw-deploy
./release.sh full
git push
```

### Rolling Back
```bash
# Edit docker-compose.yml to previous image tag
docker compose pull
docker compose up -d
```

### Monitoring
```bash
docker compose ps
docker compose logs goclaw -f
curl http://localhost/health | jq
```

## Future Roadmap

### Short Term (Q2 2026)
- Add comprehensive integration tests
- GitHub Actions workflow for automated releases
- Terraform modules for cloud deployment

### Medium Term (Q3-Q4 2026)
- Helm charts for Kubernetes
- Observability: Prometheus metrics, OpenTelemetry tracing
- Multi-region deployment patterns

### Long Term (2027+)
- Service mesh integration (Istio)
- Advanced multi-tenancy support
- Auto-scaling orchestration

## Document History

| Date | Version | Author | Changes |
|---|---|---|---|
| 2026-03-01 | 1.0 | Documentation | Initial PDR creation |
