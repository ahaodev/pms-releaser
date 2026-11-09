# Repository instructions

PMS Releaser provides independent Git changelog collection and PMS artifact upload. Usage, parameters, and defaults are documented in [README.md](../README.md); keep those and `action.yml` consistent with the script.

## Files

- `scripts/collect-changelog.sh`: Markdown collection to stdout or a file; no PMS credentials.
- `scripts/pms-publish.sh`: upload an artifact and existing notes; no Git calls.
- `scripts/pms-releaser.sh`: compatibility wrapper; optional eighth argument supplies existing notes.
- `actions/changelog/action.yml`: composite collector, exposes a workspace-relative `changelog_file`.
- `action.yml`: Docker Action wrapper; positional arguments follow the README signature.
- `Dockerfile`: runtime dependencies and exact trusted workspace paths; runs as root for GitHub workspace access.
- `tests/test_changelog.py`: Git-only tests; `test_pms_publish.py`: real HTTP uploads without Git; `test_integration.py`: wrapper/action wiring.
- `.github/workflows/test.yml`: reusable Linux/macOS tests and Linux container checks.
- Tag workflows wait for tests: `github-release.yml` publishes notes and source to GitHub, `docker-publish.yml` publishes GHCR, `release.yml` optionally publishes to PMS when project/package variables exist.

## Behavior to preserve

- Support Bash 3.2; use indexed arrays rather than associative arrays.
- Select the target from the version tag, `GITHUB_SHA`, or `HEAD`. Find the previous tag across all parents, excluding tags on the target itself.
- Complete shallow history from `origin`, or stop publishing. Only missing Git or a non-repository may fall back to minimal notes; expose other Git errors.
- Categorize commit subjects by case-sensitive prefixes; preserve literal characters such as `|`.
- Use `--form-string` for text fields and curl-level quoting for file paths.
- Send credentials in `x-access-token`; never hardcode secrets.
- Require HTTP 2xx, a non-HTML response, and exactly one JSON value. Do not retry the POST; the upload timeout is 600 seconds.
- Keep API fields `drone_tag`, `drone_commit`, `drone_branch` populated from GitHub variables for server compatibility. Do not restore Drone integration.

## Validation

```bash
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m unittest discover -s tests -v
docker build -t pms-releaser:test .
```

Tests require Git, curl, and Python 3; install jq to exercise both JSON backends. For script execution, either jq or Python 3 is sufficient. Docker includes the runtime dependencies.
