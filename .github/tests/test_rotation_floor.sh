#!/usr/bin/env bash
# Tests for rotate_backups_by_size hardening:
#  - never-delete-newest floor (ROT-5): never empties the dir / deletes the only copy
#  - non-numeric MAX_BACKUP_SIZE_MB is treated as disabled (ROT-4/SHELL-1)
#  - orphan-inc cascade when a base full is size-rotated (ROT-1)
# Counters n_ok/n_err (PASS= triggers secret-redaction on disk).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BACKUP_DIR="$TMP_DIR/backup"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$TMP_DIR/silent.log"; : > "$SILENT_LOG"
DRY_RUN="false"
GRAY=""; RESET=""; YELLOW=""; RED=""; GREEN=""; BOLD=""
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export BACKUP_DIR SILENT_LOG DRY_RUN

FUNCS="$TMP_DIR/funcs.sh"
{
    sed -n '/^_mb_to_human() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_delete_orphan_inc_for_full() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^rotate_backups_by_size() {$/,/^}$/p' "$SCRIPT"
} > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

mk() { dd if=/dev/zero of="$BACKUP_DIR/$1" bs=1M count="$2" 2>/dev/null; [[ "${3:-0}" -gt 0 ]] && touch -d "$3 days ago" "$BACKUP_DIR/$1"; }
reset() { rm -f "$BACKUP_DIR"/* 2>/dev/null; }
count_backups() { find "$BACKUP_DIR" -type f -name 'lazarus_*' | wc -l; }

# T1: single backup larger than the limit -> NOT deleted (floor)
reset
mk "lazarus_full_2026-06-01_10_00_00.tar.zst.enc" 3 0
MAX_BACKUP_SIZE_MB="1"
rotate_backups_by_size "true" >/dev/null 2>&1
[[ "$(count_backups)" -eq 1 ]] && ok || bad "T1 single backup was deleted (floor failed), remaining=$(count_backups)"

# T2: 3 backups x 2MB, limit smaller than one -> keep exactly 1 (the newest)
reset
mk "lazarus_full_2026-06-01_10_00_00.tar.zst.enc" 2 5
mk "lazarus_full_2026-06-02_10_00_00.tar.zst.enc" 2 4
mk "lazarus_full_2026-06-03_10_00_00.tar.zst.enc" 2 0
MAX_BACKUP_SIZE_MB="1"
rotate_backups_by_size "true" >/dev/null 2>&1
remaining=$(count_backups)
[[ "$remaining" -eq 1 ]] && ok || bad "T2 expected 1 (newest) kept, got $remaining"
# the survivor must be the newest
[[ -f "$BACKUP_DIR/lazarus_full_2026-06-03_10_00_00.tar.zst.enc" ]] && ok || bad "T2 newest should be the survivor"

# T3: non-numeric limit -> disabled, nothing deleted
reset
mk "lazarus_full_2026-06-01_10_00_00.tar.zst.enc" 3 5
mk "lazarus_full_2026-06-02_10_00_00.tar.zst.enc" 3 0
MAX_BACKUP_SIZE_MB="500MB"
rotate_backups_by_size "true" >/dev/null 2>&1
[[ "$(count_backups)" -eq 2 ]] && ok || bad "T3 non-numeric limit should disable rotation, remaining=$(count_backups)"

# T4: base full deleted by size-rotation cascades its orphan incrementals (ROT-1)
reset
base_ts="2026-06-01_10_00_00"
mk "lazarus_full_${base_ts}__v1.tar.zst.enc" 2 6
mk "lazarus_inc_2026-06-02_10_00_00__base_${base_ts}__v1.tar.zst.enc" 2 5
mk "lazarus_inc_2026-06-03_10_00_00__base_${base_ts}__v1.tar.zst.enc" 2 4
mk "lazarus_full_2026-06-10_10_00_00__v1.tar.zst.enc" 2 0
# limit forces deleting the oldest base full; its 2 incs must be cascaded
MAX_BACKUP_SIZE_MB="3"
rotate_backups_by_size "true" >/dev/null 2>&1
orphans=$(find "$BACKUP_DIR" -name "lazarus_inc_*__base_${base_ts}__*" | wc -l)
[[ "$orphans" -eq 0 ]] && ok || bad "T4 orphan incs not cascaded: $orphans remain"
# newest full still present (floor)
[[ -f "$BACKUP_DIR/lazarus_full_2026-06-10_10_00_00__v1.tar.zst.enc" ]] && ok || bad "T4 newest full should survive"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
