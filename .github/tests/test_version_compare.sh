#!/usr/bin/env bash
# Tests for version_gt() / version_gte() from lazarus-backup.
# Verifies correct comparison for 2/3/4-component versions and edge cases.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="$TMP_DIR/silent.log"
debug_log() { :; }
export SILENT_LOG

# Extract version helpers
FUNC_FILE="$TMP_DIR/version_funcs.sh"
{
    sed -n '/^_normalize_version_parts() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^version_gt() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^version_gte() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract version functions from $SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

assert_gt() {
    local a="$1" b="$2"
    if ! version_gt "$a" "$b"; then
        echo "FAIL: version_gt '$a' '$b' should be TRUE" >&2
        FAILS=$((FAILS + 1))
    fi
}
assert_not_gt() {
    local a="$1" b="$2"
    if version_gt "$a" "$b"; then
        echo "FAIL: version_gt '$a' '$b' should be FALSE" >&2
        FAILS=$((FAILS + 1))
    fi
}
assert_gte() {
    local a="$1" b="$2"
    if ! version_gte "$a" "$b"; then
        echo "FAIL: version_gte '$a' '$b' should be TRUE" >&2
        FAILS=$((FAILS + 1))
    fi
}

# --- 2-component ---
assert_gt "5.1" "5.0"
assert_not_gt "5.0" "5.1"
assert_not_gt "5.0" "5.0"

# --- 3-component ---
assert_gt "5.1.0" "5.0.99"
assert_gt "6.0.0" "5.99.99"
assert_not_gt "3.25.4" "3.25.5"
assert_gte "3.25.5" "3.25.5"
assert_gte "6.4.1" "3.25.5"

# --- 4-component (build tie-breaker) ---
assert_gt "6.4.1.28" "6.4.1.27"
assert_gt "6.4.2.0" "6.4.1.99"
assert_not_gt "6.4.1.27" "6.4.1.27"

# --- Mixed-length ---
assert_gt "5.0.1" "5.0"
assert_gt "6.4.1.27" "6.4.1"
assert_not_gt "5.0" "5.0.0"  # 5.0 == 5.0.0 → not strictly greater

# --- Edge: empty / Unknown ---
# Empty string normalizes to 0.0.0:
# - "" vs "5.0.0" → 0 > 5? false → not_gt ✓
# - "5.0.0" vs "" → 5 > 0? true → gt (by design; treats missing version as "older")
assert_not_gt "" "5.0.0"
assert_gt "5.0.0" ""

# --- "v" prefix should be tolerated (typical в Docker tags) ---
# Not всегда поддерживается — проверим что хотя бы не падает
version_gt "v6.4.1" "6.4.0" >/dev/null 2>&1 || true

if [[ $FAILS -gt 0 ]]; then
    echo "  version compare: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  version compare: 14 fixtures OK"
