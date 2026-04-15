---
description: Publish a validated goclaw release — push the multi-arch image to Docker Hub, commit the bumped submodule + compose files with the repo's conventional commit style, create a matching git tag, and push commit + tag to origin.
argument-hint: (none — invoked from goclaw-upgrade-release workflow)
---

# Publish Release — goclaw-deploy

The smoke test already passed. You are the last step before this release is
live. Do each action deliberately, check the result, and abort the moment
anything unexpected happens. Do NOT use `git push --force`, do NOT use
`--no-verify`, and do NOT amend previous commits.

Workflow artifacts dir: `$ARTIFACTS_DIR`
Base branch: `$BASE_BRANCH`
Workflow run ID: `$WORKFLOW_ID`

---

## 1. Re-derive the version under release

The workflow already bumped the pin. Read it back so commit/tag text matches:

```bash
NEW_VERSION=$(grep -oE 'image: itsddvn/goclaw:v[^[:space:]]+' docker-compose.yml \
  | head -n1 | sed 's/image: itsddvn\/goclaw://')
echo "NEW_VERSION=$NEW_VERSION"
```

If `NEW_VERSION` is empty or does not match `v[0-9]+\.[0-9]+\.[0-9]+`, ABORT
and report the problem.

## 2. Confirm the expected files are staged changes

`make update` should have touched these files and the submodule pointer:

- `goclaw-core` (submodule pointer)
- `docker-compose.yml`
- `docker-compose-dokploy.yml` (if present)

```bash
git status --porcelain
```

Expected: ONLY the files listed above appear. If anything else is dirty,
ABORT — it means someone else modified the tree mid-run.

## 3. Push the multi-arch image

This is the point of no return for the registry. Run:

```bash
make push 2>&1 | tail -n 80
```

`make push` builds for `linux/amd64,linux/arm64` and pushes both
`itsddvn/goclaw:$NEW_VERSION` and `itsddvn/goclaw:latest`, plus the
`$NEW_VERSION-core` tag. If it exits non-zero, ABORT — do not commit or tag.

Verify the image is actually on Docker Hub before continuing:

```bash
docker buildx imagetools inspect "itsddvn/goclaw:$NEW_VERSION" \
  | head -n 20
```

A successful inspect (showing the manifest list) proves the push worked.

## 4. Commit the bumps

Match the repo's existing style exactly (see `git log --oneline -10`):

```
chore: upgrade goclaw-core to <NEW_VERSION>
```

Stage **only** the bumped files by name — never use `git add -A`:

```bash
git add goclaw-core docker-compose.yml
[ -f docker-compose-dokploy.yml ] && git add docker-compose-dokploy.yml

git commit -m "chore: upgrade goclaw-core to $NEW_VERSION"
```

Capture the commit SHA:

```bash
COMMIT_SHA=$(git rev-parse HEAD)
```

## 5. Tag the release

The deploy repo tags match the goclaw-core version verbatim (e.g. `v3.7.1`).
Abort if the tag already exists locally OR on origin.

```bash
if git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then
  echo "ABORT: local tag $NEW_VERSION already exists"; exit 1
fi
git fetch --tags --quiet
if git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then
  echo "ABORT: tag $NEW_VERSION was fetched from origin"; exit 1
fi

git tag -a "$NEW_VERSION" -m "Release $NEW_VERSION"
```

## 6. Push commit + tag to origin

```bash
git push origin HEAD:"$BASE_BRANCH"
git push origin "$NEW_VERSION"
```

If either push is rejected (non-fast-forward, permission, etc.) — DO NOT
force. Report the error and stop. The local commit + tag stay in place so
the developer can decide what to do.

## 7. Final summary

Print a short markdown summary to stdout so the downstream `report` node can
use it:

```
## Publish summary

- Version: <NEW_VERSION>
- Image: itsddvn/goclaw:<NEW_VERSION> (multi-arch, pushed)
- Commit: <COMMIT_SHA> on <BASE_BRANCH>
- Tag: <NEW_VERSION> (pushed)
- Timestamp (UTC): <date -u +%FT%TZ>
```

On any abort, print exactly what failed, what state the repo is in, and what
the human needs to do next. Do NOT attempt automatic rollback — registry
pushes are not reversible, and a human needs to decide next steps.
