#!/bin/bash
# Compatibility entrypoint: collect a changelog unless one was supplied, then publish.
set -e
set -o pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 8 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
    echo "Usage: $0 <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch] [changelog_file]" >&2
    exit 1
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CHANGELOG_FILE="${8:-}"
if [ -z "$CHANGELOG_FILE" ]; then
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pms-releaser.XXXXXX")
    trap 'rm -rf -- "$TMP_DIR"' EXIT
    CHANGELOG_FILE="$TMP_DIR/changelog.md"
    bash "$SCRIPT_DIR/resolve-changelog.sh" "$2" "$CHANGELOG_FILE"
fi
bash "$SCRIPT_DIR/pms-publish.sh" "$1" "$2" "$3" "$4" "$CHANGELOG_FILE" "${5:-}" "${6:-android}" "${7:-universal}"
