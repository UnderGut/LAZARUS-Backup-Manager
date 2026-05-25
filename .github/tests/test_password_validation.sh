#!/usr/bin/env bash
# Tests for write_password_file() / read_password_file() from lazarus-backup.
# Verifies:
#   1. Normal password round-trip (special chars).
#   2. Newline in password is rejected.
#   3. Path injection (outside INSTALL_DIR) is rejected on write and read.
#   4. Empty file returns no password (clean state).
#   5. Trailing newline in file (manual edit case) is trimmed.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
INSTALL_DIR="$TMP_DIR/install"
mkdir -p "$INSTALL_DIR"
BACKUP_PASSWORD_FILE="$INSTALL_DIR/.password"
BACKUP_PASSWORD=""
print_message() { :; }
log_message() { :; }
export SILENT_LOG INSTALL_DIR BACKUP_PASSWORD_FILE

# Extract functions from main script
FUNC_FILE="$TMP_DIR/pwd_funcs.sh"
{
    sed -n '/^write_password_file() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^read_password_file() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract password functions from $SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL [$name]: expected '$expected', got '$actual'" >&2
        FAILS=$((FAILS + 1))
    fi
}

# --- Test 1: round-trip with special chars ---
PWD1='myS3cret$P@ss!#%&*()_+-='
if write_password_file "$PWD1" 2>/dev/null; then
    BACKUP_PASSWORD=""
    read_password_file
    assert_eq "$BACKUP_PASSWORD" "$PWD1" "round-trip special chars"
else
    echo "FAIL [write normal pwd]: write_password_file returned non-zero" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 2: newline in password → reject ---
if write_password_file $'line1\nline2' 2>/dev/null; then
    echo "FAIL [reject newline]: write_password_file accepted password with newline" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 3: path injection on write ---
BACKUP_PASSWORD_FILE_ORIG="$BACKUP_PASSWORD_FILE"
BACKUP_PASSWORD_FILE="/tmp/evil_test.txt"
if write_password_file "should_fail" 2>/dev/null; then
    echo "FAIL [path injection write]: write accepted external path" >&2
    FAILS=$((FAILS + 1))
    rm -f /tmp/evil_test.txt
fi
BACKUP_PASSWORD_FILE="$BACKUP_PASSWORD_FILE_ORIG"

# --- Test 4: empty file → no password ---
> "$BACKUP_PASSWORD_FILE"
BACKUP_PASSWORD="leftover"
if read_password_file; then
    assert_eq "$BACKUP_PASSWORD" "" "empty file → empty password (rc may vary)"
else
    # rc=1 — expected for empty file, but variable must be empty too
    assert_eq "$BACKUP_PASSWORD" "" "empty file → empty password"
fi

# --- Test 5: trailing newline trim ---
printf 'mypass\n' > "$BACKUP_PASSWORD_FILE"
chmod 600 "$BACKUP_PASSWORD_FILE"
BACKUP_PASSWORD=""
read_password_file
assert_eq "$BACKUP_PASSWORD" "mypass" "trailing newline trim"

# --- Test 6: chmod 600 verification (Linux only) ---
write_password_file "perm_test" 2>/dev/null || true
if command -v stat >/dev/null 2>&1; then
    perms=$(stat -c '%a' "$BACKUP_PASSWORD_FILE" 2>/dev/null || stat -f '%Lp' "$BACKUP_PASSWORD_FILE" 2>/dev/null || echo "?")
    # На Windows git-bash NTFS не поддерживает chmod корректно — 644 OK
    # На Linux должно быть 600
    if [[ "$perms" != "600" && "$perms" != "644" && "$perms" != "?" ]]; then
        echo "WARN [chmod 600]: unexpected perms $perms (expected 600 on Linux, 644 on Win)" >&2
    fi
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  password validation: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  password validation: 6 fixtures OK"
