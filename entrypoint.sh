#!/bin/sh
set -e

# ── Fix volume ownership (root context only) ──
# Docker named volumes may initialize as root-owned.
# Ensure goclaw user owns all writable directories.
# These are deploy-specific (workspace teams, caddy data, skills-store home).
if [ "$(id -u)" = "0" ]; then
  # Workspace volume — create teams dir if missing.
  # This mount is initialized from image contents owned by `goclaw`. The container
  # drops DAC override, so root may be unable to write here even during startup.
  if [ ! -d /app/workspace/teams ]; then
    su-exec goclaw mkdir -p /app/workspace/teams 2>/dev/null || mkdir -p /app/workspace/teams 2>/dev/null || true
  fi

  # Check if goclaw can write, if not use chmod g+w
  if ! su-exec goclaw test -w /app/workspace/teams 2>/dev/null; then
    echo "Note: Fixing permissions for /app/workspace/teams"
    chmod -R g+w /app/workspace/teams 2>/dev/null || true
    chmod g+s /app/workspace/teams 2>/dev/null || true  # SetGID for new files
  fi

  # Ensure readable/executable by all
  chmod 755 /app/workspace 2>/dev/null || true

  # Data volume — goclaw owns root and direct children (except .runtime)
  chown goclaw:goclaw /app/data || echo "Warning: data chown failed (may already be correct)"
  find /app/data -maxdepth 1 ! -name .runtime ! -name data -exec chown goclaw:goclaw {} \; 2>/dev/null || true
  chown -R goclaw:goclaw /app/data/skills 2>/dev/null || true

  # Agent workspace directory
  chown -R goclaw:goclaw /app/.goclaw 2>/dev/null || true

  # Skills-store home — binary writes to /home/goclaw/.goclaw/skills-store/
  mkdir -p /home/goclaw/.goclaw && chown -R goclaw:goclaw /home/goclaw

  # Caddy data volume — certificates persist here
  chown goclaw:goclaw /data 2>/dev/null || true
fi

# ── Helpers ──
run_as_goclaw() {
  if command -v su-exec >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    su-exec goclaw "$@"
  else
    "$@"
  fi
}

process_is_running() {
  [ -n "$1" ] && [ -d "/proc/$1" ]
}

terminate_pid() {
  pid="$1"
  kill "$pid" 2>/dev/null || true
  if command -v su-exec >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    su-exec goclaw kill "$pid" 2>/dev/null || true
  fi
}

shutdown() {
    terminate_pid "$GOCLAW_PID"
    terminate_pid "$CADDY_PID"
    wait "$GOCLAW_PID" "$CADDY_PID" 2>/dev/null
    exit 0
}

# ── Main ──
case "${1:-serve}" in
    serve)
        # Set Caddy site address based on GOCLAW_DOMAIN
        if [ -n "$GOCLAW_DOMAIN" ]; then
            export CADDY_SITE_ADDRESS="$GOCLAW_DOMAIN"
        else
            export CADDY_SITE_ADDRESS=":8080"
        fi

        # Start goclaw via core entrypoint in a subshell.
        # Core handles all shared init (runtime dirs, env, pkg-helper, claude creds,
        # db upgrade) then exec's into goclaw — replacing the subshell, not this script.
        (/app/docker-entrypoint.sh serve) &
        GOCLAW_PID=$!

        # Start Caddy as goclaw user (high ports, no special capabilities needed).
        # Launch it directly so $! is the real long-lived process, not a wrapper shell.
        if command -v su-exec >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
            su-exec goclaw caddy run --config /app/Caddyfile --adapter caddyfile &
        else
            caddy run --config /app/Caddyfile --adapter caddyfile &
        fi
        CADDY_PID=$!

        trap shutdown SIGTERM SIGINT

        # Under cap-drop/no-new-privileges, root may lack permission to signal
        # same-container processes after they switch to the goclaw UID. Track liveness
        # by /proc presence instead of kill -0 so startup doesn't kill healthy children.
        while process_is_running "$GOCLAW_PID" && process_is_running "$CADDY_PID"; do
            sleep 1
        done
        shutdown
        ;;
    *)
        # All other commands: delegate to core entrypoint (handles init + exec)
        exec /app/docker-entrypoint.sh "$@"
        ;;
esac
