#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$SCRIPT_DIR"
CORE_DIR="$DEPLOY_DIR/goclaw-core"
IMAGE="itsddvn/goclaw"
HEALTH_RETRIES=30
HEALTH_INTERVAL=5
COMPOSE_BUILD="docker-compose-build.yml"
COMPOSE_PROD="docker-compose.yml"
COMPOSE_DOKPLOY="docker-compose-dokploy.yml"
LOCKFILE="/tmp/goclaw-release.lock"
COMMAND="${1:-full}"

# ── Auto mode & custom version ──────────────────────────────────────────
AUTO=false
CUSTOM_VERSION=""
for arg in "$@"; do
  if [[ "$arg" == "--auto" ]] || [[ "$arg" == "-auto" ]]; then
    AUTO=true
  elif [[ "$arg" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    CUSTOM_VERSION="$arg"
  fi
done
if [[ "$COMMAND" == "--auto" ]] || [[ "$COMMAND" == "-auto" ]]; then
  COMMAND="${2:-full}"
fi

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}ℹ ${NC}$*"; }
warn()    { echo -e "${YELLOW}⚠ ${NC}$*"; }
error()   { echo -e "${RED}✗ ${NC}$*" >&2; }
success() { echo -e "${GREEN}✓ ${NC}$*"; }

header() {
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  $*${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

confirm() {
  if [[ "$AUTO" == true ]]; then
    info "Auto-confirmed: $1"
    return 0
  fi
  echo ""
  read -r -p "$(echo -e "${YELLOW}? ${NC}$1 [Y/n] ")" answer
  case "${answer:-y}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

health_check() {
  local url=$1
  local retries=${2:-$HEALTH_RETRIES}
  local interval=${3:-$HEALTH_INTERVAL}

  info "Waiting for health check: $url"
  for i in $(seq 1 "$retries"); do
    if curl -sf "$url" > /dev/null 2>&1; then
      success "Health check passed (attempt $i/$retries)"
      return 0
    fi
    echo -n "."
    sleep "$interval"
  done
  echo ""
  error "Health check failed after $retries attempts"
  error "Common causes: DB not ready, port in use (lsof -i :3000), migration failure"
  return 1
}

sed_i() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

escape_sed() {
  printf '%s\n' "$1" | sed 's/[[\.*^$()+?{|]/\\&/g'
}

# ── Lock & cleanup ─────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local pid
    pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      error "Release script already running (PID $pid)"
      error "If stuck, remove: $LOCKFILE"
      exit 1
    else
      warn "Stale lock file found, removing"
      rm -f "$LOCKFILE"
    fi
  fi
  echo $$ > "$LOCKFILE"
}

COMPOSE_RUNNING=""

cleanup() {
  if [[ -n "$COMPOSE_RUNNING" ]]; then
    warn "Cleaning up Docker resources..."
    docker compose -f "$DEPLOY_DIR/$COMPOSE_RUNNING" down -v --remove-orphans 2>/dev/null || true
  fi
  rm -f "$LOCKFILE"
}
trap cleanup EXIT

acquire_lock

# ── Preflight checks ───────────────────────────────────────────────────────
if [[ ! -d "$CORE_DIR" ]]; then
  error "goclaw-core not found at: $CORE_DIR"
  exit 1
fi

if ! git -C "$CORE_DIR" remote get-url upstream > /dev/null 2>&1; then
  error "No 'upstream' remote in goclaw-core. Add it with:"
  error "  git -C $CORE_DIR remote add upstream <upstream-url>"
  exit 1
fi

if ! command -v docker &> /dev/null; then
  error "docker not found"
  exit 1
fi

if ! docker buildx version &> /dev/null; then
  error "docker buildx not available. Ensure Docker >= 20.10"
  exit 1
fi

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: ./release.sh [sync|publish|full] [--auto] [vX.Y.Z]"
  echo ""
  echo "Commands:"
  echo "  sync      Sync upstream, check changes, build & test locally"
  echo "  publish   Tag, build image, push to Docker Hub, smoke test, commit"
  echo "  full      Run everything (default)"
  echo ""
  echo "Flags:"
  echo "  --auto    Non-interactive mode: auto-confirm prompts, keep data on clean, auto-push after commit"
  echo "  vX.Y.Z    Custom version tag (e.g., v2.42.2-fx01) - overrides auto-detection"
  echo ""
  echo "Examples:"
  echo "  ./release.sh full --auto                    # Auto-release with detected version"
  echo "  ./release.sh publish --auto v2.42.2-fx01    # Custom version for hotfix"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# SYNC: fetch upstream → diff → pause → clean → test build
# ═══════════════════════════════════════════════════════════════════════════
do_sync() {
  header "SYNC — Fetch & merge upstream"

  # ── Pull latest from origin & upstream ────────────────────────────────
  info "Fetching origin and upstream..."
  git -C "$CORE_DIR" fetch origin
  git -C "$CORE_DIR" fetch upstream

  info "Pulling latest develop from origin..."
  git -C "$CORE_DIR" checkout develop
  git -C "$CORE_DIR" pull origin develop --no-edit || true

  info "Pulling latest main from origin..."
  git -C "$CORE_DIR" checkout main
  git -C "$CORE_DIR" pull origin main --no-edit || true

  success "Pulled latest from origin"

  # ── Sync upstream/main → fork/main ──────────────────────────────────
  info "Merging upstream/main into main..."
  if ! git -C "$CORE_DIR" merge upstream/main --no-edit; then
    error "Merge conflict on main in $CORE_DIR"
    error ""
    error "Resolution steps:"
    error "  1. cd $CORE_DIR"
    error "  2. Resolve conflicts (git status, edit files)"
    error "  3. git add <resolved-files>"
    error "  4. git merge --continue"
    error "  5. Re-run: ./release.sh sync"
    exit 1
  fi

  success "main synced with upstream"

  # ── Merge fork/main → fork/develop ──────────────────────────────────
  info "Checking out develop..."
  git -C "$CORE_DIR" checkout develop

  info "Merging main into develop..."
  if ! git -C "$CORE_DIR" merge main --no-edit; then
    error "Merge conflict on develop in $CORE_DIR"
    error ""
    error "Resolution steps:"
    error "  1. cd $CORE_DIR"
    error "  2. Resolve conflicts (git status, edit files)"
    error "  3. git add <resolved-files>"
    error "  4. git merge --continue"
    error "  5. Re-run: ./release.sh sync"
    exit 1
  fi

  success "develop synced with main"

  # ── Push fork main & develop to origin ──────────────────────────────
  header "PUSH — Push main & develop to origin"

  info "Pushing main to origin..."
  git -C "$CORE_DIR" push origin main

  info "Pushing develop to origin..."
  git -C "$CORE_DIR" push origin develop

  success "main & develop pushed to origin"

  # ── AUTO-REVIEW ──────────────────────────────────────────────────────
  header "REVIEW — Auto-sync deploy configs from upstream"

  DEPLOY_CONFIGS="nginx.conf"
  SYNCED=0

  for cfg in $DEPLOY_CONFIGS; do
    core_file="$CORE_DIR/$cfg"
    deploy_file="$DEPLOY_DIR/$cfg"

    if [[ ! -f "$core_file" ]]; then
      continue
    fi

    if [[ ! -f "$deploy_file" ]]; then
      warn "$cfg exists in core but not in deploy, skipping"
      continue
    fi

    if ! diff -q "$core_file" "$deploy_file" > /dev/null 2>&1; then
      info "Diff detected in $cfg (core vs deploy):"
      diff --color=auto -u "$deploy_file" "$core_file" || true
      echo ""
      warn "$cfg differs — deploy version kept (review diff above if needed)"
      SYNCED=$((SYNCED + 1))
    fi
  done

  if [[ $SYNCED -eq 0 ]]; then
    success "Deploy configs are in sync with upstream"
  else
    info "$SYNCED config(s) differ between core and deploy (shown above)"
  fi

  # ── CLEAN ─────────────────────────────────────────────────────────────
  header "CLEAN — Prepare environment"

  if [[ "$AUTO" == true ]]; then
    clean_choice=1
    info "Auto-selected: keep data, stop containers only"
  else
    echo ""
    echo -e "  ${CYAN}1)${NC} Rebuild code only — keep DB & volumes intact"
    echo -e "  ${CYAN}2)${NC} Full reset — wipe DB, volumes & rebuild from scratch"
    echo ""
    read -r -p "$(echo -e "${YELLOW}? ${NC}Choose [1/2] (default: 2): ")" clean_choice
    clean_choice="${clean_choice:-2}"
  fi

  case "$clean_choice" in
    1)
      info "Keeping existing data, stopping containers only..."
      docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" down --remove-orphans 2>/dev/null || true
      docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" down --remove-orphans 2>/dev/null || true
      success "Containers stopped (data preserved)"
      ;;
    *)
      info "Stopping and removing containers + volumes..."
      docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" down -v --remove-orphans 2>/dev/null || true
      docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" down -v --remove-orphans 2>/dev/null || true
      success "Cleaned (fresh start)"
      ;;
  esac

  # ── TEST BUILD ────────────────────────────────────────────────────────
  header "TEST — Build from source & health check"

  COMPOSE_RUNNING="$COMPOSE_BUILD"
  info "Building core + all-in-one image..."
  make -C "$DEPLOY_DIR" build-local

  info "Starting with $COMPOSE_BUILD..."
  docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" up -d

  health_check "http://localhost:3000/health" 60 5

  success "Build test passed"

  # Keep containers running for manual inspection
  COMPOSE_RUNNING=""

  # ── PUSH SYNCED CODE ───────────────────────────────────────────────
  header "PUSH — Push synced branches to fork"

  info "Pushing main to origin..."
  if ! git -C "$CORE_DIR" push origin main; then
    warn "Failed to push main — you may need to push manually"
  else
    success "main pushed"
  fi

  info "Pushing develop to origin..."
  if ! git -C "$CORE_DIR" push origin develop; then
    warn "Failed to push develop — you may need to push manually"
  else
    success "develop pushed"
  fi

  echo ""
  success "Sync complete! Containers are still running for inspection."
  info "Dashboard: http://localhost:3000"
  info "Stop with: docker compose -f $COMPOSE_BUILD down -v"
  info "Next: ./release.sh publish"
}

# ═══════════════════════════════════════════════════════════════════════════
# PUBLISH: tag → build+push → update tags → smoke test → commit
# ═══════════════════════════════════════════════════════════════════════════
do_publish() {
  # ── TAG ───────────────────────────────────────────────────────────────
  header "TAG — Get version from upstream"

  if [[ -n "$CUSTOM_VERSION" ]]; then
    VERSION="$CUSTOM_VERSION"
    info "Using custom version: ${CYAN}${VERSION}${NC}"
  else
    # Fetch latest tags from upstream
    git -C "$CORE_DIR" fetch upstream --tags --quiet 2>/dev/null || {
      error "Failed to fetch upstream tags."
      error "Ensure upstream remote exists: git -C $CORE_DIR remote -v"
      exit 1
    }

    VERSION=$(git -C "$CORE_DIR" describe --tags --match "v*" upstream/main 2>/dev/null) || {
      error "Failed to get version from upstream tags."
      error "Ensure upstream has v* tags: git -C $CORE_DIR ls-remote --tags upstream"
      exit 1
    }

    if [[ -z "$VERSION" ]]; then
      error "Empty version string. No tags in repo?"
      exit 1
    fi

    if [[ "$VERSION" == *"dirty"* ]]; then
      error "Working tree is dirty: '$VERSION'"
      error "Commit or stash changes in $CORE_DIR first."
      exit 1
    fi

    info "Detected version: ${CYAN}${VERSION}${NC}"
  fi

  # ── BUILD + PUSH ──────────────────────────────────────────────────────
  header "BUILD — Build & push to Docker Hub"

  confirm "Push ${IMAGE}:${VERSION} to Docker Hub?"

  info "Building and pushing image..."
  if ! VERSION="$VERSION" make -C "$DEPLOY_DIR" push; then
    error "Docker build or push failed"
    error "Check credentials: docker login"
    exit 1
  fi

  info "Verifying pushed image..."
  if ! docker pull "$IMAGE:$VERSION" > /dev/null 2>&1; then
    error "Cannot pull $IMAGE:$VERSION — push may have partially failed"
    exit 1
  fi

  success "Pushed and verified ${IMAGE}:${VERSION}"

  # ── UPDATE TAGS ───────────────────────────────────────────────────────
  header "UPDATE — Write new tag into compose files"

  IMAGE_ESCAPED=$(escape_sed "$IMAGE")

  for f in "$COMPOSE_PROD" "$COMPOSE_DOKPLOY"; do
    filepath="$DEPLOY_DIR/$f"
    if [[ -f "$filepath" ]]; then
      sed_i "s|image: ${IMAGE_ESCAPED}:.*|image: ${IMAGE}:${VERSION}|" "$filepath"
      success "Updated $f → ${VERSION}"
    else
      warn "$f not found, skipping"
    fi
  done

  # ── SMOKE TEST ────────────────────────────────────────────────────────
  header "SMOKE — Pull image & verify"

  COMPOSE_RUNNING="$COMPOSE_PROD"
  info "Starting with pulled image ($COMPOSE_PROD)..."
  docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" up -d

  info "Waiting for goclaw container to be healthy..."
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    STATUS=$(docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" ps goclaw --format '{{.Health}}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "healthy" ]]; then
      success "Smoke test passed (attempt $i/$HEALTH_RETRIES)"
      break
    fi
    if [[ $i -eq $HEALTH_RETRIES ]]; then
      error "Smoke test failed — goclaw container not healthy"
      docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" logs goclaw --tail=20
      exit 1
    fi
    echo -n "."
    sleep "$HEALTH_INTERVAL"
  done

  docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" down -v --remove-orphans
  COMPOSE_RUNNING=""

  success "Smoke test passed"

  # ── COMMIT ────────────────────────────────────────────────────────────
  header "COMMIT — Stage & commit changes"

  info "Files to commit:"
  git -C "$DEPLOY_DIR" diff --name-only
  git -C "$DEPLOY_DIR" diff --staged --name-only

  confirm "Commit release ${VERSION}?"

  cd "$DEPLOY_DIR"
  git add "$COMPOSE_PROD" "$COMPOSE_DOKPLOY"
  git commit -m "release: update image to ${VERSION}"

  success "Committed release ${VERSION}"

  if [[ "$AUTO" == true ]]; then
    info "Auto-pushing to origin main..."
    git push origin main
    success "Pushed to origin main"
  fi

  echo ""
  header "Release ${VERSION} complete!"
  if [[ "$AUTO" != true ]]; then
    info "Next: git push to deploy"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN — Route subcommand
# ═══════════════════════════════════════════════════════════════════════════
case "$COMMAND" in
  sync)
    do_sync
    ;;
  publish)
    do_publish
    ;;
  full)
    do_sync
    do_publish
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    error "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
