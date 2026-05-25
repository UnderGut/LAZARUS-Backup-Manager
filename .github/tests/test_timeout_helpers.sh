#!/usr/bin/env bash
# Tests for _run_with_timeout / _run_pipe_with_timeout.
# Verifies:
#   1. Команда укладывается в лимит → rc=0
#   2. Команда превышает лимит → rc=124 + log
#   3. timeout=0 → команда без лимита (даже если бы должна была убиться)
#   4. Pipe-вариант: первое звено падает → pipefail catches
#   5. Pipe-вариант: timeout срабатывает на висящий sleep
#   6. Команда возвращает non-zero сама → rc прокидывается напрямую

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Skip если timeout не установлен (старые BSD, macOS без coreutils)
if ! command -v timeout >/dev/null 2>&1; then
    echo "  timeout helpers: SKIPPED (no GNU timeout)"
    exit 0
fi

# Stubs
SILENT_LOG="/dev/null"
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export SILENT_LOG

# Extract helpers
FUNC_FILE="$TMP_DIR/timeout_helpers.sh"
{
    sed -n '/^_run_with_timeout() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_run_pipe_with_timeout() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract timeout helpers" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# --- Test 1: команда укладывается в лимит → rc=0 ---
_run_with_timeout 5 "fast-true" /bin/true
RC=$?
[[ $RC -eq 0 ]] || { echo "FAIL [fast]: expected rc=0, got $RC" >&2; FAILS=$((FAILS + 1)); }

# --- Test 2: команда превышает лимит → rc=124 ---
START=$(date +%s)
_run_with_timeout 1 "slow-sleep" sleep 10
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
if [[ $RC -ne 124 && $RC -ne 137 ]]; then
    echo "FAIL [timeout]: expected rc=124/137, got $RC" >&2
    FAILS=$((FAILS + 1))
fi
# Sanity: не должно занять > 32 сек (1s + 30s kill-after, но обычно < 2s)
if [[ $ELAPSED -gt 32 ]]; then
    echo "FAIL [timeout elapsed]: took ${ELAPSED}s, expected < 32" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 3: timeout=0 → без лимита ---
START=$(date +%s)
_run_with_timeout 0 "no-limit" sleep 1
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
[[ $RC -eq 0 ]] || { echo "FAIL [no-limit rc]: got $RC" >&2; FAILS=$((FAILS + 1)); }
[[ $ELAPSED -ge 1 ]] || { echo "FAIL [no-limit elapsed]: only ${ELAPSED}s" >&2; FAILS=$((FAILS + 1)); }

# --- Test 4: команда возвращает non-zero (НЕ timeout) → rc прокинут ---
_run_with_timeout 10 "false-cmd" /bin/false
RC=$?
[[ $RC -eq 1 ]] || { echo "FAIL [non-zero]: expected rc=1, got $RC" >&2; FAILS=$((FAILS + 1)); }

# --- Test 5: pipe — первое звено падает (pipefail catches) ---
_run_pipe_with_timeout 5 "pipe-fail" '/bin/false | cat'
RC=$?
[[ $RC -eq 1 ]] || { echo "FAIL [pipe-fail]: expected rc=1, got $RC" >&2; FAILS=$((FAILS + 1)); }

# --- Test 6: pipe — успешный ---
OUT=$(mktemp)
_run_pipe_with_timeout 5 "pipe-ok" 'echo hello | tr a-z A-Z > "$1"' "$OUT"
RC=$?
[[ $RC -eq 0 ]] || { echo "FAIL [pipe-ok rc]: got $RC" >&2; FAILS=$((FAILS + 1)); }
PIPE_RESULT=$(cat "$OUT")
[[ "$PIPE_RESULT" == "HELLO" ]] || { echo "FAIL [pipe-ok result]: got '$PIPE_RESULT'" >&2; FAILS=$((FAILS + 1)); }
rm -f "$OUT"

# --- Test 7: pipe — sleep в pipe killed by timeout ---
START=$(date +%s)
_run_pipe_with_timeout 1 "pipe-timeout" 'sleep 10 | cat'
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
if [[ $RC -ne 124 && $RC -ne 137 ]]; then
    echo "FAIL [pipe-timeout rc]: expected 124/137, got $RC" >&2
    FAILS=$((FAILS + 1))
fi
if [[ $ELAPSED -gt 32 ]]; then
    echo "FAIL [pipe-timeout elapsed]: took ${ELAPSED}s" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 8: pipe с args через $1 $2 ---
_run_pipe_with_timeout 5 "pipe-args" 'echo "$1-$2" > "$3"' "foo" "bar" "$TMP_DIR/args.out"
RC=$?
[[ $RC -eq 0 ]] || { echo "FAIL [pipe-args rc]: $RC" >&2; FAILS=$((FAILS + 1)); }
ARGS_OUT=$(cat "$TMP_DIR/args.out" 2>/dev/null)
[[ "$ARGS_OUT" == "foo-bar" ]] || { echo "FAIL [pipe-args content]: '$ARGS_OUT'" >&2; FAILS=$((FAILS + 1)); }

if [[ $FAILS -gt 0 ]]; then
    echo "  timeout helpers: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  timeout helpers: 8 fixtures OK (fast, timeout, no-limit, non-zero, pipe x4)"
