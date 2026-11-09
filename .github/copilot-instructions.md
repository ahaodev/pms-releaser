# Repository instructions

PMS Releaser generates a Git changelog and uploads artifacts to a PMS HTTP API. Usage, parameters, and defaults are documented in [README.md](../README.md); keep those and `action.yml` consistent with the script.

## Files

- `scripts/pms-releaser.sh`: changelog generation and multipart upload; Docker entrypoint is `pms-releaser`.
- `action.yml`: Docker Action wrapper; positional arguments follow the README signature.
- `Dockerfile`: runtime dependencies and exact trusted workspace paths; runs as root for GitHub workspace access.
- `tests/`: temporary Git fixtures and real curl requests to a local HTTP server.
- `.github/workflows/test.yml`: reusable Linux/macOS tests and Linux container checks.
- `.github/workflows/{release,docker-publish}.yml`: publish on `v*` tags after tests pass; source releases use `uses: ./`.

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
bash -n scripts/pms-releaser.sh
python3 -m unittest discover -s tests -v
docker build -t pms-releaser:test .
```

Tests require Git, curl, and Python 3; install jq to exercise both JSON backends. For script execution, either jq or Python 3 is sufficient. Docker includes the runtime dependencies.
