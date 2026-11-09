#!/bin/bash

# Upload an artifact and an existing Markdown changelog to PMS; no Git access required.

set -e
set -o pipefail

# Configuration
FILE_PATH="${1:-}"
VERSION="${2:-}"
PROJECT_NAME="${3:-}"
PACKAGE_NAME="${4:-}"
CHANGELOG_FILE="${5:-}"
ARTIFACT_NAME="${6:-$(basename "$FILE_PATH" 2>/dev/null || echo "app")}"
OS="${7:-android}"
ARCH="${8:-universal}"
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

print_usage() {
    echo "Usage: $0 <file_path> <version> <project_name> <package_name> <changelog_file> [artifact_name] [os] [arch]" >&2
}

# Validate inputs
if [ -z "$FILE_PATH" ] || [ -z "$VERSION" ] || [ -z "$PROJECT_NAME" ] || [ -z "$PACKAGE_NAME" ] || [ -z "$CHANGELOG_FILE" ] || [ "$#" -gt 8 ]; then
    print_usage
    exit 1
fi

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found"
    exit 1
fi

if [ ! -f "$CHANGELOG_FILE" ] || [ ! -r "$CHANGELOG_FILE" ]; then
    echo "Error: Changelog file '$CHANGELOG_FILE' is not readable" >&2
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

echo "📋 Changelog preview:"
head -15 "$CHANGELOG_FILE"

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
