#!/bin/bash
# Collect categorized Git commits as Markdown; no release credentials required.
# Usage: collect-changelog.sh <version> [output_file]
set -e
set -o pipefail

VERSION="${1:-}"
OUTPUT_FILE="${2:-}"
if [ -z "$VERSION" ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <version> [output_file]" >&2
    exit 1
fi
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pms-changelog.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

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

# Explicit returns in generate_changelog are required inside this condition.
if ! generate_changelog > "$TMP_DIR/changelog.md"; then
    echo "Error: Failed to generate changelog." >&2
    exit 1
fi
if [ -n "$OUTPUT_FILE" ]; then
    cat "$TMP_DIR/changelog.md" > "$OUTPUT_FILE"
else
    cat "$TMP_DIR/changelog.md"
fi
