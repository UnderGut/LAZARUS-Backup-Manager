#!/usr/bin/env bash
# Regression tests for the senior-audit fixes (financial-critical). Sources the REAL script as a
# library (LAZARUS_LIB=true). Covers: size-rotation per-namespace floor (must never delete the
# newest backup of the OTHER target in both-mode) and the ssh-empty-host backup guard (must NOT
# silently fall back to a local backup of the wrong target). Counters n_ok/n_err.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
SILENT_LOG="$TMP_DIR/silent.log"; LOG_FILE="$TMP_DIR/lz.log"; DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false

# --- 1) size-rotation per-namespace floor (both-mode): newest of EACH target survives ---
BACKUP_DIR="$TMP_DIR/bk"; mkdir -p "$BACKUP_DIR"; MAX_BACKUP_SIZE_MB=1
_mk() { head -c 450000 /dev/zero > "$BACKUP_DIR/$1" 2>/dev/null; touch -d "@$(( 1700000000 + $2*60 ))" "$BACKUP_DIR/$1"; }
# bot: 3 (oldest..newest), panel: 2 (oldest..newest) — total ~2.25MB > 1MB limit
_mk "lazarus_full_2026-06-15_01_00_00.tar.gz" 1
_mk "lazarus_full_2026-06-15_02_00_00.tar.gz" 2
_mk "lazarus_full_2026-06-15_03_00_00.tar.gz" 5   # newest BOT
_mk "lazarus_panel_db_2026-06-15_01_00_00.tar.gz" 3
_mk "lazarus_panel_db_2026-06-15_02_00_00.tar.gz" 6   # newest PANEL
rotate_backups_by_size "true" >/dev/null 2>&1
[[ -f "$BACKUP_DIR/lazarus_full_2026-06-15_03_00_00.tar.gz" ]] && ok || bad "size-rotation deleted newest BOT backup (floor broken)"
[[ -f "$BACKUP_DIR/lazarus_panel_db_2026-06-15_02_00_00.tar.gz" ]] && ok || bad "size-rotation deleted newest PANEL backup (cross-namespace delete!)"
# at least one old file got deleted (rotation actually ran)
_remaining=$(find "$BACKUP_DIR" -name 'lazarus_*' | wc -l | tr -d ' ')
[[ "$_remaining" -lt 5 ]] && ok || bad "size-rotation deleted nothing (expected some old removed), remaining=$_remaining"

# --- 2) ssh-empty-host guard: transport=ssh but no host must NOT do a local backup ---
# stub the two sinks to record which (if any) ran
_LOCAL_RAN=0; _REMOTE_RAN=0
create_backup() { _LOCAL_RAN=1; return 0; }
_backup_remote_target() { _REMOTE_RAN=1; return 0; }
BACKUP_TARGET="bot"; BOT_TRANSPORT="ssh"; PANEL_TRANSPORT="local"; TARGET_SSH=""
_backup_active_target "db_only" >/dev/null 2>&1; _rc=$?
[[ "$_rc" -ne 0 ]] && ok || bad "ssh-empty-host: _backup_active_target should fail, rc=$_rc"
[[ "$_LOCAL_RAN" -eq 0 ]] && ok || bad "ssh-empty-host: must NOT run local create_backup"
[[ "$_REMOTE_RAN" -eq 0 ]] && ok || bad "ssh-empty-host: must NOT run remote (no host)"
# sanity: local transport still routes to local create_backup
_LOCAL_RAN=0; BOT_TRANSPORT="local"; TARGET_SSH=""
_backup_active_target "db_only" >/dev/null 2>&1
[[ "$_LOCAL_RAN" -eq 1 ]] && ok || bad "local transport should route to create_backup"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
