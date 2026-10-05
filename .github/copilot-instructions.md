# Copilot Instructions

## Project Overview

This is a CI/CD release tool distributed as a Docker image (`hao88/pms-releaser`) and a reusable GitHub Action (`ahaodev/pms-releaser`). It automates two things in one step: generating a changelog from git history and uploading a release artifact via HTTP to a PMS release system.

## Architecture

```
Dockerfile                  # Alpine image; installs bash/git/jq/curl, copies script to /usr/local/bin/pms-releaser
scripts/pms-releaser.sh     # Single integrated script — both changelog gen and upload logic live here
action.yml                  # GitHub Action wrapper; passes inputs as positional args to the Docker container
.drone.yml                  # Drone CI pipeline; triggers only on tag events
.github/workflows/release.yml  # GitHub Actions workflow — uses this repo's own action to release itself
```

The Docker `ENTRYPOINT` is `pms-releaser` (not a shell), so arguments passed in `commands:` (Drone) or `args:` (action.yml) go directly to the script.

## Script Signature

```bash
pms-releaser <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch]
```

| Position | Param | Required | Default |
|---|---|---|---|
| $1 | `file_path` | ✅ | — |
| $2 | `version` | ✅ | — |
| $3 | `project_name` | ✅ | — |
| $4 | `package_name` | ✅ | — |
| $5 | `artifact_name` | ❌ | basename of file_path |
| $6 | `os` | ❌ | `android` |
| $7 | `arch` | ❌ | `universal` |

> ⚠️ `README.md` and `CLAUDE.md` show an outdated 5-param signature. The actual script and `action.yml` require `project_name` and `package_name` as params 3 and 4.

## Build & Run

```bash
# Build the image
docker build -t pms-releaser:latest .

# Run directly
docker run --rm -v "$PWD:/workspace" -w /workspace \
  -e ACCESS_TOKEN=$TOKEN -e RELEASE_URL=$URL \
  pms-releaser:latest /workspace/app.apk v1.0.0 my-project my-package

# Run script without Docker (requires bash, git, jq, curl)
chmod +x scripts/pms-releaser.sh
ACCESS_TOKEN=... RELEASE_URL=... ./scripts/pms-releaser.sh ./app.apk v1.0.0 my-project my-package
```

## CI Integration

### GitHub Actions
- Trigger: `push: tags: ['v*']`
- Checkout requires `fetch-depth: 0` for full git history (changelog generation reads all tags)
- Secrets needed: `ACCESS_TOKEN`, `RELEASE_URL`

### Drone CI
- Trigger: `trigger: event: [tag]` — must be restricted to tag events
- Version should be `${DRONE_TAG}`, not `${DRONE_BUILD_NUMBER}`
- Secrets injected via `environment: from_secret:`

## Key Conventions

### Changelog Generation
Commits are categorized by conventional commit prefix (case-insensitive glob match):
- `feat*` / `fix*` / `docs*` / `style*` / `refactor*` / `perf*` / `test*` / `build*|ci*|cd*` / `chore*`
- Anything else falls into "📝 Other Changes"
- If not in a git repo, a minimal fallback changelog is used (non-fatal)

### Upload
- Uses `curl` multipart POST (`-F` fields) to `RELEASE_URL`
- `x-access-token` header carries the token
- Validates HTTP 2xx response **and** checks `Content-Type` is not `text/html` (guards against SPA fallback pages)
- Retries 3 times with 5s delay; 600s max timeout

### Security
- Container runs as non-root user `pms` (uid 1000)
- Secrets must never be hardcoded; always use CI secret injection

### Environment Variable Precedence
The script supports both Drone CI and GitHub Actions env vars. GitHub Actions vars are mapped to Drone-style vars at runtime:
- `GITHUB_REF` (tag ref) → `DRONE_TAG`
- `GITHUB_SHA` → `DRONE_COMMIT`
- `GITHUB_REF_NAME` → `DRONE_BRANCH`
