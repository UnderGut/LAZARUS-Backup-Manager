#!/usr/bin/env bash
# Tests for _make_live_db_snapshot() — the pre-destruction safety snapshot that
# makes full-restore rollback actually possible (RST-1/CRIT-1 fix).
# Verifies rc semantics: 0=snapshot with real data, 2=empty DB (no rollback value),
# 1=snapshot failed. Counters n_ok/n_err (PASS= triggers secret-redaction).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
BACKUP_DIR="$TMP_DIR/backup"; mkdir -p "$BACKUP_DIR"
PG_DUMP_TIMEOUT_SEC="60"
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export SILENT_LOG BACKUP_DIR PG_DUMP_TIMEOUT_SEC

FUNCS="$TMP_DIR/funcs.sh"
sed -n '/^_make_live_db_snapshot() {$/,/^}$/p' "$SCRIPT" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# Mock the pg_dump|gzip pipe. Last positional arg is the snapshot path.
MODE="real"
_run_pipe_with_timeout() {
    local snap="${*: -1}"
    case "$MODE" in
        real)
            # realistic dump: CREATE TABLE + many COPY rows so gzipped size > 100b floor
            { printf -- '--\n-- PostgreSQL database dump\n--\nCREATE TABLE users (id int, name text, email text);\nCOPY users (id, name, email) FROM stdin;\n'
              for i in $(seq 1 60); do printf '%d\tuser_%d\tuser_%d@example.com\n' "$i" "$i" "$i"; done
              printf '\\.\n'; } | gzip > "$snap"; return 0 ;;
        empty)
            # empty DB: only the standard pg_dump preamble (no CREATE TABLE/COPY/INSERT), padded > 100b gz
            { printf -- '--\n-- PostgreSQL database dump\n--\n'
              for i in $(seq 1 40); do printf 'SET some_guc_%d = off;\n' "$i"; done; } | gzip > "$snap"; return 0 ;;
        tiny)  printf 'x' | gzip > "$snap"; return 0 ;;
        fail)  rm -f "$snap"; return 1 ;;
    esac
}

# T1: real data -> rc 0, path echoed, file exists
MODE="real"
out=$(_make_live_db_snapshot c u d "$BACKUP_DIR"); rc=$?
[[ $rc -eq 0 ]] && ok || bad "T1 rc=$rc (want 0)"
[[ -n "$out" && -f "$out" ]] && ok || bad "T1 path missing: '$out'"

# T2: empty DB (headers only, no CREATE TABLE/COPY) -> rc 2 (no rollback value), path echoed
MODE="empty"
out=$(_make_live_db_snapshot c u d "$BACKUP_DIR"); rc=$?
[[ $rc -eq 2 ]] && ok || bad "T2 rc=$rc (want 2)"
[[ -n "$out" ]] && ok || bad "T2 path should still be echoed"

# T3: pg_dump failed -> rc 1, no path, no file left
MODE="fail"
out=$(_make_live_db_snapshot c u d "$BACKUP_DIR"); rc=$?
[[ $rc -eq 1 ]] && ok || bad "T3 rc=$rc (want 1)"
[[ -z "$out" ]] && ok || bad "T3 should echo no path on failure"

# T4: too-small snapshot (<100 bytes) -> rc 1, file removed
MODE="tiny"
out=$(_make_live_db_snapshot c u d "$BACKUP_DIR"); rc=$?
[[ $rc -eq 1 ]] && ok || bad "T4 rc=$rc (want 1 for <100b)"
[[ -z "$out" ]] && ok || bad "T4 no path for tiny"

# T5: the produced real snapshot round-trips (gunzip-able + contains the table)
MODE="real"
out=$(_make_live_db_snapshot c u d "$BACKUP_DIR")
if gzip -dc "$out" 2>/dev/null | grep -q 'CREATE TABLE users'; then ok; else bad "T5 snapshot not decompressible/complete"; fi

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
