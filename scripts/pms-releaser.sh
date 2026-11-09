#!/bin/bash

# Generate changelog and upload release artifacts
# Combines generate-changelog.sh and release-upload.sh for Docker image usage
# Usage: ./pms-releaser.sh <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch]

set -e
set -o pipefail

# Configuration
FILE_PATH="$1"
VERSION="$2"
PROJECT_NAME="$3"
PACKAGE_NAME="$4"
ARTIFACT_NAME="${5:-$(basename "$FILE_PATH" 2>/dev/null || echo "app")}"
OS="${6:-android}"
ARCH="${7:-universal}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
RELEASE_URL="${RELEASE_URL:-}"

# GitHub Actions environment variables (empty for direct script/Docker usage).
GITHUB_REF_NAME="${GITHUB_REF_NAME:-}"
GITHUB_SHA="${GITHUB_SHA:-}"
GITHUB_REF="${GITHUB_REF:-}"
RELEASE_TAG=""
if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    RELEASE_TAG="${GITHUB_REF#refs/tags/}"
fi

# Function to print usage
print_usage() {
    echo "Usage: $0 <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch]"
    echo ""
    echo "Arguments:"
    echo "  file_path      - Path to the release artifact file"
    echo "  version        - Release version (e.g., v1.0.0)"
    echo "  project_name   - Project name in the release system"
    echo "  package_name   - Package name within the project"
    echo "  artifact_name  - Name of the artifact (default: filename)"
    echo "  os             - Target OS (default: android)"
    echo "  arch           - Target architecture (default: universal)"
    echo ""
    echo "Environment variables:"
    echo "  ACCESS_TOKEN      - Release system access token (required)"
    echo "  RELEASE_URL       - Release system API URL (required)"
    echo "  GITHUB_REF        - GitHub Actions ref (e.g. refs/tags/v1.0.0)"
    echo "  GITHUB_REF_NAME   - GitHub Actions tag or branch name"
    echo "  GITHUB_SHA        - GitHub Actions commit SHA"
    echo ""
    echo "Docker example: docker run --rm -v \$PWD:/workspace pms-releaser:latest ./app.apk v1.0.0 my-project my-package"
}

# Validate inputs
if [ -z "$FILE_PATH" ] || [ -z "$VERSION" ] || [ -z "$PROJECT_NAME" ] || [ -z "$PACKAGE_NAME" ]; then
    print_usage
    exit 1
fi

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found"
    exit 1
fi

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: ACCESS_TOKEN is required"
    exit 1
fi

if [ -z "$RELEASE_URL" ]; then
    echo "Error: RELEASE_URL is required"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "Error: jq or python3 is required to validate the release response as JSON"
    exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pms-releaser.XXXXXX")
cleanup_temp_files() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup_temp_files EXIT

CHANGELOG_FILE="$TMP_DIR/changelog.md"
CHANGELOG_ERROR_FILE="$TMP_DIR/changelog-error.log"
RESPONSE_FILE="$TMP_DIR/release-response.json"
ERROR_FILE="$TMP_DIR/curl-error.log"
HEADER_FILE="$TMP_DIR/release-headers.txt"

validate_json_response() {
    if command -v jq >/dev/null 2>&1; then
        jq -s -e 'length == 1' "$1" >/dev/null 2>&1
    else
        python3 -c 'import json, sys; json.load(sys.stdin)' < "$1" >/dev/null 2>&1
    fi
}

# curl parses its own quoting inside -F, independently of shell quoting.
quote_form_path() {
    local path="$1"
    path="${path//\\/\\\\}"
    path="${path//\"/\\\"}"
    printf '"%s"' "$path"
}
FORM_FILE_PATH=$(quote_form_path "$FILE_PATH")
FORM_CHANGELOG_PATH=$(quote_form_path "$CHANGELOG_FILE")

echo "🚀 Starting release: $VERSION ($FILE_PATH) → $PROJECT_NAME/$PACKAGE_NAME"

# ============================================================================
# CHANGELOG GENERATION SECTION
# ============================================================================

echo ""
echo "📝 Generating changelog..."

# Category indices keep this compatible with Bash 3.2 (macOS).
categorize_commit() {
    case "$1" in
        feat*|feature*) echo 0 ;;
        fix*|bugfix*) echo 1 ;;
        docs*|doc*) echo 2 ;;
        style*|format*) echo 3 ;;
        refactor*) echo 4 ;;
        perf*|performance*) echo 5 ;;
        test*) echo 6 ;;
        build*|ci*|cd*) echo 7 ;;
        chore*) echo 8 ;;
        *) echo 9 ;;
    esac
}

minimal_changelog() {
    printf '## %s\n\n### 🎉 Release\n\n- Release %s\n' "$VERSION" "$VERSION"
}

generate_changelog() {
    local git_error="$TMP_DIR/git-error.log" search_dir
    local shallow target_ref target_commit previous_tag tag category hash msg commits_raw has_previous
    local -a exclude_tags commit_lists category_headers
    exclude_tags=()
    commit_lists=()
    category_headers=("### ✨ New Features" "### 🐛 Bug Fixes" "### 📚 Documentation"
        "### 💄 Style Changes" "### ♻️ Code Refactoring" "### ⚡ Performance Improvements"
        "### 🧪 Tests" "### 🔧 Build System & CI/CD" "### 🔨 Maintenance" "### 📝 Other Changes")

    if ! command -v git >/dev/null 2>&1; then
        echo "Warning: git is unavailable, using minimal changelog" >&2
        minimal_changelog
        return 0
    fi
    if ! LC_ALL=C git rev-parse --git-dir > /dev/null 2>"$git_error"; then
        if grep -q '^fatal: not a git repository' "$git_error"; then
            # A damaged .git entry or an explicitly configured repository is an
            # error, even if Git reports it with the same "not a repository" text.
            search_dir=$(pwd -P) || return 1
            while :; do
                if [ -e "$search_dir/.git" ] || [ -L "$search_dir/.git" ] ||
                    [ -n "${GIT_DIR:-}${GIT_WORK_TREE:-}" ]; then
                    cat "$git_error" >&2
                    return 1
                fi
                [ "$search_dir" = / ] && break
                search_dir=$(dirname "$search_dir") || return 1
            done
            echo "Warning: Not in a git repository, using minimal changelog" >&2
            minimal_changelog
            return 0
        fi
        # Ownership, permissions and repository corruption must not look like success.
        cat "$git_error" >&2
        return 1
    fi

    shallow=$(git rev-parse --is-shallow-repository) || return 1
    if [ "$shallow" = true ]; then
        echo "Shallow repository detected; fetching full history and tags from origin..." >&2
        if ! git fetch --unshallow --tags origin; then
            echo "Error: Cannot complete Git history. Use a full checkout (fetch-depth: 0) before publishing." >&2
            return 1
        fi
        shallow=$(git rev-parse --is-shallow-repository) || return 1
        if [ "$shallow" != false ]; then
            echo "Error: Repository is still shallow; provide a full checkout before publishing." >&2
            return 1
        fi
    fi

    # Resolve an actual release tag first, then the CI commit or HEAD.
    target_ref="refs/tags/$VERSION"
    if ! git rev-parse --verify --quiet "${target_ref}^{commit}" >/dev/null; then
        target_ref="${GITHUB_SHA:-HEAD}"
    fi
    target_commit=$(git rev-parse --verify "${target_ref}^{commit}") || return 1

    # Search all parents, excluding every tag on the target itself. Starting at
    # target^ would discard release tags reachable only through a merge's other parents.
    git tag --points-at "$target_commit" > "$TMP_DIR/target-tags" || return 1
    while IFS= read -r tag; do
        [ -n "$tag" ] && exclude_tags+=("--exclude=$tag")
    done < "$TMP_DIR/target-tags"
    git tag --merged "$target_commit" > "$TMP_DIR/reachable-tags" || return 1
    has_previous=false
    while IFS= read -r tag; do
        if [ -n "$tag" ] && ! grep -Fxq -- "$tag" "$TMP_DIR/target-tags"; then
            has_previous=true
            break
        fi
    done < "$TMP_DIR/reachable-tags"
    previous_tag=""
    if [ "$has_previous" = true ]; then
        previous_tag=$(git describe --tags --abbrev=0 "${exclude_tags[@]}" "$target_commit") || return 1
    fi

    if [ -n "$previous_tag" ]; then
        commits_raw=$(git log --pretty=format:"%h|%s" "refs/tags/$previous_tag..$target_commit" --) || return 1
    else
        commits_raw=$(git log --pretty=format:"%h|%s" "$target_commit" --) || return 1
    fi

    printf '## %s\n\n' "$VERSION"
    if [ -n "$commits_raw" ]; then
        # Hash never contains '|'; read keeps the rest of the subject intact.
        while IFS='|' read -r hash msg; do
            [ -z "$msg" ] && continue
            category=$(categorize_commit "$msg")
            commit_lists[$category]="${commit_lists[$category]}- $msg ($hash)"$'\n'
        done <<< "$commits_raw"
        for category in "${!category_headers[@]}"; do
            if [ -n "${commit_lists[$category]}" ]; then
                printf '%s\n\n%s\n' "${category_headers[$category]}" "${commit_lists[$category]}"
            fi
        done
    else
        printf '### 🎉 Initial Release\n\n- Initial release\n'
    fi
}

# Explicit returns above are necessary: errexit is disabled inside an if condition.
if generate_changelog > "$CHANGELOG_FILE" 2>"$CHANGELOG_ERROR_FILE"; then
    cat "$CHANGELOG_ERROR_FILE" >&2
    echo "✅ Changelog generated successfully"
else
    echo "Error: Failed to generate changelog; release upload cancelled." >&2
    cat "$CHANGELOG_ERROR_FILE" >&2
    exit 1
fi

echo "📋 Changelog preview:"
echo "---"
head -15 "$CHANGELOG_FILE"
echo "---"
echo ""

# ============================================================================
# RELEASE UPLOAD SECTION
# ============================================================================

echo "📤 Uploading: $ARTIFACT_NAME ($OS/$ARCH) to $RELEASE_URL"

# Test connectivity
if ! curl --connect-timeout 5 --max-time 10 -s -I "$RELEASE_URL" >/dev/null 2>&1; then
    echo "⚠️  Connectivity test failed - continuing anyway"
fi

# Prepare upload with enhanced error handling for Docker environments
echo "📤 Uploading release artifact..."

# The drone_* wire field names are retained for release API compatibility.
# Perform the upload with comprehensive error handling.
# No --retry here: the POST is not idempotent, so a retry after a timeout could create a duplicate release.
if HTTP_CODE=$(curl -X POST "$RELEASE_URL" \
    -H "x-access-token: $ACCESS_TOKEN" \
    -H "User-Agent: PMS-Releaser-Script/1.0" \
    -F "file=@$FORM_FILE_PATH" \
    --form-string "version=$VERSION" \
    --form-string "project_name=$PROJECT_NAME" \
    --form-string "package_name=$PACKAGE_NAME" \
    --form-string "artifact=$ARTIFACT_NAME" \
    --form-string "os=$OS" \
    --form-string "arch=$ARCH" \
    -F "changelog=<$FORM_CHANGELOG_PATH" \
    --form-string "drone_tag=$RELEASE_TAG" \
    --form-string "drone_commit=$GITHUB_SHA" \
    --form-string "drone_branch=$GITHUB_REF_NAME" \
    --connect-timeout 30 \
    --max-time 600 \
    --show-error \
    --fail-with-body \
    --write-out "%{http_code}" \
    --dump-header "$HEADER_FILE" \
    --output "$RESPONSE_FILE" 2>"$ERROR_FILE"); then
    CURL_EXIT=0
else
    CURL_EXIT=$?
fi

echo ""

# Check the response
if [ "$CURL_EXIT" -eq 0 ] && [[ "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    # Verify response is JSON, not an HTML page (e.g. SPA fallback)
    CONTENT_TYPE=$(grep -i "^content-type:" "$HEADER_FILE" 2>/dev/null | tail -1 | tr -d '\r' || true)
    if echo "$CONTENT_TYPE" | grep -qi "text/html"; then
        echo "❌ Upload failed - server returned HTML instead of JSON (HTTP $HTTP_CODE)"
        echo "   This usually means RELEASE_URL is pointing to a frontend page, not the API endpoint."
        echo "   Content-Type: $CONTENT_TYPE"
        echo "   Please check your RELEASE_URL configuration."
        exit 1
    fi

    if ! validate_json_response "$RESPONSE_FILE"; then
        echo "❌ Upload failed - server returned an invalid JSON response (HTTP $HTTP_CODE)"
        cat "$RESPONSE_FILE" 2>/dev/null || echo "No response available"
        exit 1
    fi

    echo "🎉 Release upload successful! (HTTP $HTTP_CODE)"
    echo "📋 Response:"
    if command -v jq >/dev/null 2>&1; then
        cat "$RESPONSE_FILE" | jq . 2>/dev/null || cat "$RESPONSE_FILE"
    else
        cat "$RESPONSE_FILE"
    fi
    echo ""
    echo "✅ Release $VERSION completed!"
    
else
    if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
        echo "❌ Upload failed - Network/Connection error (curl exit: $CURL_EXIT)"
    else
        echo "❌ Upload failed with HTTP code: $HTTP_CODE (curl exit: $CURL_EXIT)"
        cat "$RESPONSE_FILE" 2>/dev/null || echo "No response available"
    fi
    echo "Error details:"
    cat "$ERROR_FILE" 2>/dev/null || echo "No error details available"
    exit 1
fi
