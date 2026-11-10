#!/bin/bash
# Resolve release notes without modifying the source changelog.
set -e
set -o pipefail
VERSION="${1:-}"
OUTPUT="${2:-}"
[ -n "$VERSION" ] && [ -n "$OUTPUT" ] && [ "$#" -eq 2 ] || { echo "Usage: $0 <version> <output_file>" >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pms-notes.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT
if [ -e CHANGELOG.md ] || [ -L CHANGELOG.md ]; then
    [ -f CHANGELOG.md ] && [ -r CHANGELOG.md ] || { echo "Error: CHANGELOG.md is not readable" >&2; exit 1; }
    if awk -v version="$VERSION" '
        function normalized(s) { sub(/^v/, "", s); return s }
        /^##[ \t]+/ {
            active=0
            title=$0; sub(/^##[ \t]+/, "", title)
            split(title, parts, /[ \t]+/); token=parts[1]
            sub(/^\[/, "", token); sub(/\]$/, "", token)
            if (normalized(token)==normalized(version)) { count++; active=1 }
        }
        active {
            if ($0 ~ /^[ \t]*\[[^]]+\]:/) next
            print
            if ($0 !~ /^##[ \t]+/ && $0 !~ /^[ \t]*$/) body=1
        }
        END { if (count==0) exit 3; if (count!=1 || !body) exit 4 }
    ' CHANGELOG.md > "$TMP_DIR/notes"; then
        echo "Using CHANGELOG.md section for $VERSION" >&2
        cat "$TMP_DIR/notes" > "$OUTPUT"
        exit 0
    else
        status=$?
        [ "$status" -eq 3 ] || { echo "Error: Invalid or empty CHANGELOG.md section for $VERSION" >&2; exit 1; }
        echo "No CHANGELOG.md section for $VERSION; collecting Git commits" >&2
    fi
else
    echo "CHANGELOG.md absent; collecting Git commits" >&2
fi
bash "$SCRIPT_DIR/collect-changelog.sh" "$VERSION" "$OUTPUT"
