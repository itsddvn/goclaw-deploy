---
description: Start the freshly-built goclaw stack in an isolated docker compose project, drive a browser through the first-time setup / login flow with playwright-cli, tear down the stack, and return a structured pass/fail verdict.
argument-hint: (none — invoked from goclaw-upgrade-release workflow)
---

# Browser Smoke Test — goclaw release candidate

You are validating the image that `make build-local` just produced. The image
tag pins are already in `docker-compose.yml`. You must run a throw-away stack
on **non-default ports** in an isolated compose project so you do not touch
the developer's real data, then drive the dashboard through a browser and
decide whether this release candidate is good enough to publish.

You MUST follow `~/.claude/rules/browser.md`:
- Always use the `playwright-cli` skill to drive the browser.
- Save every screenshot to
  `./screenshots/goclaw-upgrade-release/<step>.png` (relative to the repo root)
  — create the directory if it does not exist.

Workflow artifacts dir: `$ARTIFACTS_DIR`
Base branch: `$BASE_BRANCH`
Workflow run ID: `$WORKFLOW_ID`

---

## Fixed test parameters

Use these exact values so every run is reproducible and will not collide with
the user's real compose stack.

| Variable                | Value                              |
|-------------------------|------------------------------------|
| Compose project name    | `goclaw-smoketest`                 |
| HTTP port               | `18080` (host) → `8080` (container) |
| API port                | `18791` (host) → `18790` (container) |
| pgAdmin port            | `15050` (host) → `80` (container)  |
| Dashboard URL           | `http://localhost:18080`           |
| `GOCLAW_GATEWAY_TOKEN`  | generate with `openssl rand -hex 32` |
| `GOCLAW_ENCRYPTION_KEY` | generate with `openssl rand -hex 32` |
| `POSTGRES_PASSWORD`     | `smoketest`                        |

Export these as environment variables before invoking `docker compose` — do
NOT write them into `.env` (that file belongs to the developer).

---

## Steps

### 1. Capture the release tag under test

Read the pinned tag so you can report it in your verdict:

```bash
grep -oE 'image: itsddvn/goclaw:v[^[:space:]]+' docker-compose.yml \
  | head -n1 | sed 's/image: itsddvn\/goclaw://'
```

Store the result as `NEW_VERSION`.

### 2. Bring up the isolated stack

```bash
export GOCLAW_HTTP_PORT=18080
export GOCLAW_API_PORT=18791
export PGADMIN_PORT=15050
export GOCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
export GOCLAW_ENCRYPTION_KEY=$(openssl rand -hex 32)
export POSTGRES_PASSWORD=smoketest

docker compose -p goclaw-smoketest -f docker-compose.yml up -d
```

### 3. Wait for health

Poll the dashboard root until it responds with 2xx/3xx or 90s elapses:

```bash
for i in $(seq 1 45); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/ || true)
  echo "attempt $i: $code"
  case "$code" in
    2*|3*) echo "ready"; break ;;
  esac
  sleep 2
done
```

If it never becomes ready, jump to **Teardown** with `verdict: fail`.
Dump `docker compose -p goclaw-smoketest logs --tail=120 goclaw-stack-core`
into `$ARTIFACTS_DIR/stack.log` before tearing down so the failure is
debuggable.

### 4. Drive the browser (playwright-cli)

Use the `playwright-cli` skill. The dashboard may show either a **first-time
setup wizard** (no users yet — this is expected on a fresh volume) or a
**login page**. Handle both:

1. Navigate to `http://localhost:18080`.
2. Screenshot → `screenshots/goclaw-upgrade-release/01-landing.png`.
3. If a setup / onboarding wizard appears (routes like `/setup`, `/onboarding`,
   or any form asking to create the first admin): fill it in with
   `admin@smoketest.local` / `Smoketest!234` and submit. Screenshot the
   success state → `screenshots/goclaw-upgrade-release/02-setup-done.png`.
4. If a plain login screen appears: try `admin@smoketest.local` /
   `Smoketest!234`; if that fails (no such user), this run is inconclusive —
   record a warning in the summary but continue (a fresh volume should always
   show the wizard).
5. Once inside the dashboard, screenshot →
   `screenshots/goclaw-upgrade-release/03-dashboard.png`.
6. Verify there is **no** browser console error panel and the page is not
   blank / not a JS-error fallback. A healthy dashboard must:
   - Show the goclaw version (should match `NEW_VERSION` if displayed).
   - Render the main navigation (sidebar / top bar).
7. Hit the API endpoint as a secondary check:
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:18080/v1/health \
     || curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:18080/
   ```
   A 2xx/3xx passes. 5xx fails.

Pass criterion: steps 1–7 all succeed.
Fail criterion: ANY of — stack never becomes ready, browser shows a JS error
or blank page, API endpoint returns 5xx, or the UI never escapes the login
screen despite correct credentials.

### 5. Teardown (ALWAYS runs, even on failure)

```bash
docker compose -p goclaw-smoketest -f docker-compose.yml down -v --remove-orphans || true
```

This removes the named project's containers **and** its isolated volumes so
the next run starts clean.

### 6. Return verdict

Reply with **only** a JSON object matching the schema declared on the node:

```json
{
  "verdict": "pass",
  "new_version": "v3.7.1",
  "summary": "Stack came up in 14s. Setup wizard created admin@smoketest.local, dashboard rendered with v3.7.1 in the footer, /v1/health returned 200.",
  "screenshots": [
    "screenshots/goclaw-upgrade-release/01-landing.png",
    "screenshots/goclaw-upgrade-release/02-setup-done.png",
    "screenshots/goclaw-upgrade-release/03-dashboard.png"
  ]
}
```

On failure, set `verdict: "fail"` and explain precisely what broke in
`summary` (at least: where in the flow it failed, the HTTP status, and the
last ~10 lines of the core container log).

Do NOT include prose outside the JSON.
