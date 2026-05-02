#!/usr/bin/env bash
# Tests for validate_tar_safety() from lazarus-backup.
# Verifies that:
#   1. Safe archives pass validation.
#   2. Archives with absolute or '..' path components are rejected.
#   3. Archives containing symlinks / hardlinks are rejected.
#
# The function is extracted via sed and sourced into the test shell so the
# real production logic is exercised (no re-implementation drift).

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs required by validate_tar_safety
SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
print_message() { :; }
export SILENT_LOG

# Extract the validate_tar_safety function body and source it
FUNC_FILE="$TMP_DIR/validate_tar_safety.sh"
sed -n '/^validate_tar_safety() {$/,/^}$/p' "$SCRIPT" > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract validate_tar_safety from $SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

assert_pass() {
    local archive="$1"
    local list="$TMP_DIR/list.$RANDOM"
    if ! validate_tar_safety "$archive" "$list"; then
        echo "FAIL: expected $archive to pass validation" >&2
        exit 1
    fi
}

assert_fail() {
    local archive="$1"
    local reason="$2"
    local list="$TMP_DIR/list.$RANDOM"
    if validate_tar_safety "$archive" "$list"; then
        echo "FAIL: expected $archive to FAIL validation ($reason)" >&2
        exit 1
    fi
}

# --- Fixture 1: safe archive ---
SAFE_DIR="$TMP_DIR/safe"
mkdir -p "$SAFE_DIR/inner"
echo "ok" > "$SAFE_DIR/inner/file.txt"
SAFE_TGZ="$TMP_DIR/safe.tgz"
tar -C "$TMP_DIR" -czf "$SAFE_TGZ" safe
assert_pass "$SAFE_TGZ"

# --- Fixture 2: traversal archive (path begins with '../') ---
# Bare 'tar -czf ../evil ...' triggers GNU tar's leading-..-strip on archive
# CREATION, so we use --transform to inject the unsafe prefix into stored names.
EVIL_TGZ="$TMP_DIR/evil.tgz"
tar -C "$TMP_DIR" --transform 's,^safe,../safe,' -czf "$EVIL_TGZ" safe
assert_fail "$EVIL_TGZ" "path traversal '..'"

# --- Fixture 3: absolute path archive ---
ABS_TGZ="$TMP_DIR/abs.tgz"
tar -C "$TMP_DIR" --transform 's,^safe,/etc/safe,' -czf "$ABS_TGZ" safe -P
assert_fail "$ABS_TGZ" "absolute path"

# --- Fixture 4: archive with symlink ---
# Skip on platforms where 'ln -s' silently falls back to a regular file copy
# (e.g. git-bash on Windows without dev-mode/admin). On Linux CI this runs.
SYM_DIR="$TMP_DIR/symdir"
mkdir -p "$SYM_DIR"
echo "ok" > "$SYM_DIR/real.txt"
ln -s real.txt "$SYM_DIR/link.txt" 2>/dev/null || true
if [[ -L "$SYM_DIR/link.txt" ]]; then
    SYM_TGZ="$TMP_DIR/sym.tgz"
    tar -C "$TMP_DIR" -czf "$SYM_TGZ" symdir
    assert_fail "$SYM_TGZ" "symlink present"
    echo "  restore safety: 4 fixtures OK"
else
    echo "  restore safety: 3 fixtures OK (symlink test skipped: no symlink support)"
fi
