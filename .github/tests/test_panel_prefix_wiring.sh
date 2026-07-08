#!/usr/bin/env bash
# Panel namespace isolation: the create→list→stats→rotate sites must honour
# $BACKUP_PREFIX so a panel install (lazarus_panel_*) and a bot install (lazarus_*)
# never see or rotate each other's archives. Sources the REAL script as a library
# (LAZARUS_LIB=true) and exercises get_backup_stats + rotate_backups_by_count.
# Counters n_ok/n_err (never PASS= — secret scrubber rewrites it on disk).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# Source the whole script as a library — main loop is gated by LAZARUS_LIB.
export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }

# Neutralise side-effecting globals for an isolated, quiet run.
BACKUP_DIR="$TMP_DIR/backups"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$TMP_DIR/silent.log"
LOG_FILE="$TMP_DIR/lazarus.log"
DEBUG_MODE=false
DRY_RUN=false
IS_INTERACTIVE=false

# Deterministic mtimes (ls -tr orders by time). base epoch + i*60.
_mk() { # _mk <name> <age_index>
    local f="$BACKUP_DIR/$1"
    : > "$f"
    touch -d "@$(( 1700000000 + ${2:-0} * 60 ))" "$f" 2>/dev/null \
        || touch -t "$(date -d "@$(( 1700000000 + ${2:-0} * 60 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null \
        || true
}

# --- fixtures: panel + bot archives side by side ---
_mk "lazarus_panel_full_2026-06-15_01_00_00.tar.gz" 10
_mk "lazarus_panel_full_2026-06-15_02_00_00.tar.gz" 11
_mk "lazarus_panel_db_2026-06-15_01_00_00.tar.gz"   12
_mk "lazarus_panel_files_2026-06-15_01_00_00.tar.gz" 13
_mk "lazarus_panel_files_2026-06-15_02_00_00.tar.zst" 14
_mk "lazarus_panel_files_2026-06-15_03_00_00.tar.gz.enc" 15
# bot decoys (must never be counted/rotated under panel prefix)
_mk "lazarus_full_2026-06-15_01_00_00.tar.gz" 1
_mk "lazarus_full_2026-06-15_02_00_00.tar.gz" 2
_mk "lazarus_full_2026-06-15_03_00_00.tar.gz" 3
_mk "lazarus_full_2026-06-15_04_00_00.tar.gz" 4
_mk "lazarus_full_2026-06-15_05_00_00.tar.gz" 5
_mk "lazarus_db_2026-06-15_01_00_00.tar.gz" 6
_mk "lazarus_db_2026-06-15_02_00_00.tar.gz" 7

# --- 1) get_backup_stats in PANEL mode counts only panel archives ---
BACKUP_PREFIX="lazarus_panel"
get_backup_stats
[[ "$STATS_FULL"  == "2" ]] && ok || bad "panel STATS_FULL=2 expected, got '$STATS_FULL'"
[[ "$STATS_DB"    == "1" ]] && ok || bad "panel STATS_DB=1 expected, got '$STATS_DB'"
[[ "$STATS_FILES" == "3" ]] && ok || bad "panel STATS_FILES=3 expected, got '$STATS_FILES'"

# --- 2) get_backup_stats in BOT mode counts only bot archives (panel ignored) ---
BACKUP_PREFIX="lazarus"
get_backup_stats
[[ "$STATS_FULL"  == "5" ]] && ok || bad "bot STATS_FULL=5 expected, got '$STATS_FULL'"
[[ "$STATS_DB"    == "2" ]] && ok || bad "bot STATS_DB=2 expected, got '$STATS_DB'"
[[ "$STATS_FILES" == "0" ]] && ok || bad "bot STATS_FILES=0 expected, got '$STATS_FILES'"

# --- 3) rotate_backups_by_count on panel prefix deletes ONLY panel files ---
MAX_BACKUPS_COUNT=1
rotate_backups_by_count "lazarus_panel_files" "panel-files" "true" >/dev/null 2>&1
_panel_files_left=$(find "$BACKUP_DIR" -maxdepth 1 -name 'lazarus_panel_files_*' | wc -l | tr -d ' ')
_bot_full_left=$(find "$BACKUP_DIR" -maxdepth 1 -name 'lazarus_full_*' | wc -l | tr -d ' ')
_bot_db_left=$(find "$BACKUP_DIR" -maxdepth 1 -name 'lazarus_db_*' | wc -l | tr -d ' ')
[[ "$_panel_files_left" == "1" ]] && ok || bad "panel files rotated to limit 1, got $_panel_files_left"
[[ "$_bot_full_left" == "5" ]] && ok || bad "bot full untouched by panel rotation, got $_bot_full_left"
[[ "$_bot_db_left" == "2" ]]  && ok || bad "bot db untouched by panel rotation, got $_bot_db_left"

# --- 4) rotate on bot prefix does not touch panel files ---
MAX_BACKUPS_COUNT=1
rotate_backups_by_count "lazarus_full" "bot-full" "true" >/dev/null 2>&1
_bot_full_after=$(find "$BACKUP_DIR" -maxdepth 1 -name 'lazarus_full_*' | wc -l | tr -d ' ')
_panel_full_after=$(find "$BACKUP_DIR" -maxdepth 1 -name 'lazarus_panel_full_*' | wc -l | tr -d ' ')
[[ "$_bot_full_after" == "1" ]] && ok || bad "bot full rotated to limit 1, got $_bot_full_after"
[[ "$_panel_full_after" == "2" ]] && ok || bad "panel full untouched by bot rotation, got $_panel_full_after"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
