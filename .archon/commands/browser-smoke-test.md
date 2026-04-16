---
description: Drive a running goclaw smoke-test stack through a browser login using the gateway token, verify the dashboard renders, then write $ARTIFACTS_DIR/verdict.json with the pass/fail result.
argument-hint: (none — invoked from goclaw-upgrade-release workflow)
---

# Browser Smoke Test — goclaw release candidate

`smoke-up` already started an isolated stack named `goclaw-smoketest` on
`http://localhost:18080` and wrote the env vars it used (including
`GOCLAW_GATEWAY_TOKEN`) to `$ARTIFACTS_DIR/smoke-env.sh`. Don't touch the
compose lifecycle — `smoke-down` handles that.

Your job: **log in with the gateway token and confirm the dashboard loads.**
That's it.

Follow `~/.claude/rules/browser.md`: use the `playwright-cli` skill (already
injected into this node), save screenshots under
`./screenshots/goclaw-upgrade-release/<step>.png`.

## Steps

### 1. Load the gateway token

```bash
source "$ARTIFACTS_DIR/smoke-env.sh"
echo "TOKEN=$GOCLAW_GATEWAY_TOKEN"   # value, not the literal string
```

This token IS the login credential for the dashboard.

### 2. Capture the release tag

```bash
NEW_VERSION=$(grep -oE 'image: itsddvn/goclaw:v[^[:space:]]+' docker-compose.yml \
  | head -n1 | sed 's/image: itsddvn\/goclaw://')
```

### 3. Drive the browser via the playwright-cli skill

Invoke the `playwright-cli` skill via the `Skill` tool. Do this minimum:

1. Navigate to `http://localhost:18080`.
2. Screenshot → `screenshots/goclaw-upgrade-release/01-landing.png`.
3. Find the login input (token / gateway-token / password field — the
   dashboard is token-auth, so there's exactly one input expected) and
   paste the `GOCLAW_GATEWAY_TOKEN` value from step 1. Submit.
4. Screenshot after submit → `screenshots/goclaw-upgrade-release/02-dashboard.png`.
5. Verify the dashboard view is not blank and no JS error overlay is showing.

**Pass** = screenshot 02 shows a real dashboard (navigation/content renders,
no error banner). **Fail** = can't reach landing, token rejected, dashboard
blank, or any 5xx.

### 4. Write the verdict file

Write `$ARTIFACTS_DIR/verdict.json` with the Write tool:

```json
{
  "verdict": "pass",
  "new_version": "v3.7.1",
  "summary": "Logged in with gateway token, dashboard rendered.",
  "screenshots": [
    "screenshots/goclaw-upgrade-release/01-landing.png",
    "screenshots/goclaw-upgrade-release/02-dashboard.png"
  ]
}
```

Rules:
- `verdict`: `"pass"` or `"fail"` (lower-case).
- On fail, put the specific failure (which step, HTTP code, or what the UI
  showed) in `summary`. Include last ~10 lines of core log if relevant:
  `docker compose -p goclaw-smoketest logs --tail=10 goclaw-stack-core`.
- `new_version` always set — use `"unknown"` if you couldn't read it.

Verify:

```bash
jq . "$ARTIFACTS_DIR/verdict.json"
```

### 5. Reply

After writing, reply with one line:

```
verdict=<pass|fail> version=<NEW_VERSION>
```

The downstream `read-verdict` node parses the file — your reply is just a
status line.

### Time budget

Don't spend more than 3 minutes total. If the token flow isn't working and
you've already screenshotted + logged, write a fail verdict and exit.
