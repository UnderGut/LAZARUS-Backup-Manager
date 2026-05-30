#!/usr/bin/env bash
# Regression test: ротация ДОЛЖНА видеть .tar.zst (не только .tar.gz).
#
# Root cause disk-full инцидента 2026-05-28: rotate_backups_by_age и
# rotate_backups_by_size искали только -name "lazarus_*.tar.gz" → при
# COMPRESSION=zstd бэкапы (.tar.zst.enc) не ротировались, диск заполнялся.
#
# Этот тест создаёт fixtures всех 4 форматов (gz/zst × plain/enc) и проверяет,
# что обе rotation-функции их находят и удаляют. Страж от повторного дрейфа,
# если кто-то снова добавит формат и забудет обновить glob.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BACKUP_DIR="$TMP_DIR/backup"
mkdir -p "$BACKUP_DIR"
SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"

# Stubs / globals, которые ждут rotation-функции
DRY_RUN="false"
MAX_BACKUPS_COUNT="100"
GRAY=""; RESET=""; YELLOW=""; RED=""; GREEN=""; BOLD=""
print_message() { :; }
log_message() { :; }
debug_log() { :; }
_mb_to_human() { echo "$1 MB"; }
export BACKUP_DIR SILENT_LOG

# Extract rotation-функции + helper из production-скрипта
FUNCS="$TMP_DIR/funcs.sh"
{
    sed -n '/^_delete_orphan_inc_for_full() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^rotate_backups_by_count() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^rotate_backups_by_age() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^rotate_backups_by_size() {$/,/^}$/p' "$SCRIPT"
} > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

# Helper: создать backup-файл нужного размера (МБ) с заданным mtime-возрастом (дни)
mk_backup() {
    local name="$1" size_mb="$2" age_days="$3"
    local path="$BACKUP_DIR/$name"
    dd if=/dev/zero of="$path" bs=1M count="$size_mb" 2>/dev/null
    if [[ "$age_days" -gt 0 ]]; then
        touch -d "$age_days days ago" "$path" 2>/dev/null \
            || touch -t "$(date -d "$age_days days ago" +%Y%m%d%H%M 2>/dev/null)" "$path" 2>/dev/null
    fi
    echo "$path"
}

reset_backups() { rm -f "$BACKUP_DIR"/* 2>/dev/null; }

# ============================================================
# Test 1: by_age видит .tar.zst.enc (главный root-cause кейс)
# ============================================================
reset_backups
mk_backup "lazarus_db_2026-05-20_10_00_00__v1.0.0.tar.zst.enc" 1 10 >/dev/null
mk_backup "lazarus_db_2026-05-21_10_00_00__v1.0.0.tar.zst.enc" 1 9  >/dev/null
mk_backup "lazarus_db_2026-05-28_10_00_00__v1.0.0.tar.zst.enc" 1 0  >/dev/null
# RETENTION=3 дня → 2 старых (10,9 дней) должны удалиться, свежий остаться
deleted=$(rotate_backups_by_age "lazarus_db" "DB" "3" "true" | tail -n1)
remaining=$(find "$BACKUP_DIR" -name "lazarus_db_*.tar.zst.enc" | wc -l)
if [[ "$deleted" == "2" && "$remaining" == "1" ]]; then
    pass
else
    fail "by_age zst: deleted=$deleted (want 2), remaining=$remaining (want 1)"
fi

# ============================================================
# Test 2: by_age видит .tar.gz (не сломали старый формат)
# ============================================================
reset_backups
mk_backup "lazarus_db_2026-05-20_10_00_00.tar.gz" 1 10 >/dev/null
mk_backup "lazarus_db_2026-05-28_10_00_00.tar.gz" 1 0  >/dev/null
deleted=$(rotate_backups_by_age "lazarus_db" "DB" "3" "true" | tail -n1)
remaining=$(find "$BACKUP_DIR" -name "lazarus_db_*.tar.gz" | wc -l)
if [[ "$deleted" == "1" && "$remaining" == "1" ]]; then
    pass
else
    fail "by_age gz: deleted=$deleted (want 1), remaining=$remaining (want 1)"
fi

# ============================================================
# Test 3: by_size видит .tar.zst.enc и удаляет до лимита
# ============================================================
reset_backups
# 5 файлов × 2 MB = 10 MB, лимит 5 MB → должно удалить старейшие до ≤5 MB
mk_backup "lazarus_full_2026-05-24_10_00_00.tar.zst.enc" 2 5 >/dev/null
mk_backup "lazarus_full_2026-05-25_10_00_00.tar.zst.enc" 2 4 >/dev/null
mk_backup "lazarus_full_2026-05-26_10_00_00.tar.zst.enc" 2 3 >/dev/null
mk_backup "lazarus_full_2026-05-27_10_00_00.tar.zst.enc" 2 2 >/dev/null
mk_backup "lazarus_full_2026-05-28_10_00_00.tar.zst.enc" 2 1 >/dev/null
MAX_BACKUP_SIZE_MB="5"
rotate_backups_by_size "true" >/dev/null 2>&1
remaining=$(find "$BACKUP_DIR" -name "lazarus_full_*.tar.zst.enc" | wc -l)
total_mb=$(du -sm "$BACKUP_DIR" | awk '{print $1}')
# После ротации должно остаться ≤ 5 MB (т.е. ≤ 2 файла по 2MB + manifest overhead)
if [[ "$remaining" -lt 5 && "$total_mb" -le 6 ]]; then
    pass
else
    fail "by_size zst: remaining=$remaining (want <5), total=${total_mb}MB (want ≤6)"
fi

# ============================================================
# Test 4: by_size НЕ трогает если в пределах лимита (zst)
# ============================================================
reset_backups
mk_backup "lazarus_full_2026-05-28_10_00_00.tar.zst.enc" 1 0 >/dev/null
MAX_BACKUP_SIZE_MB="500"
rotate_backups_by_size "true" >/dev/null 2>&1
remaining=$(find "$BACKUP_DIR" -name "lazarus_full_*.tar.zst.enc" | wc -l)
[[ "$remaining" == "1" ]] && pass || fail "by_size zst within limit: remaining=$remaining (want 1)"

# ============================================================
# Test 5: by_count видит смешанные форматы (gz + zst)
# ============================================================
reset_backups
mk_backup "lazarus_db_2026-05-24_10_00_00.tar.gz"      1 5 >/dev/null
mk_backup "lazarus_db_2026-05-25_10_00_00.tar.gz.enc"  1 4 >/dev/null
mk_backup "lazarus_db_2026-05-26_10_00_00.tar.zst"     1 3 >/dev/null
mk_backup "lazarus_db_2026-05-27_10_00_00.tar.zst.enc" 1 2 >/dev/null
mk_backup "lazarus_db_2026-05-28_10_00_00.tar.zst.enc" 1 1 >/dev/null
MAX_BACKUPS_COUNT="2"
rotate_backups_by_count "lazarus_db" "DB" "true" >/dev/null 2>&1
remaining=$(find "$BACKUP_DIR" -type f -name "lazarus_db_*" | wc -l)
[[ "$remaining" == "2" ]] && pass || fail "by_count mixed: remaining=$remaining (want 2)"

# ============================================================
# Test 6: orphan inc cleanup в by_age (ROT-4) — zst формат
# ============================================================
reset_backups
base_ts="2026-05-20_10_00_00"
mk_backup "lazarus_full_${base_ts}__v1.0.0.tar.zst.enc" 1 10 >/dev/null
mk_backup "lazarus_inc_2026-05-21_10_00_00__base_${base_ts}__v1.0.0.tar.zst.enc" 1 9 >/dev/null
mk_backup "lazarus_inc_2026-05-22_10_00_00__base_${base_ts}__v1.0.0.tar.zst.enc" 1 8 >/dev/null
mk_backup "lazarus_full_2026-05-28_10_00_00__v1.0.0.tar.zst.enc" 1 0 >/dev/null
# RETENTION=3 → старый full (10 дней) удаляется, его 2 inc должны уйти как orphan
rotate_backups_by_age "lazarus_full" "Full" "3" "true" >/dev/null 2>&1
orphans=$(find "$BACKUP_DIR" -name "lazarus_inc_*__base_${base_ts}__*" | wc -l)
[[ "$orphans" == "0" ]] && pass || fail "by_age orphan inc cleanup: $orphans inc остались (want 0)"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
