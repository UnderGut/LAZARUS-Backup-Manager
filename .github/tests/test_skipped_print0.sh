#!/usr/bin/env bash
# Tests for build_skipped_report защита от tab/newline в filenames.
# Verifies:
#   1. Файл с newline в имени корректно парсится (не ломает строку)
#   2. Файл с tab в имени корректно парсится
#   3. Контрольные символы в output_file заменяются на <NL>/<TAB>
#   4. Количество строк в output_file == количеству скипнутых файлов
#      (один файл — одна строка, даже если в имени newline)

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Skip если нет GNU find -printf
if ! find /dev/null -printf '' 2>/dev/null; then
    echo "  skipped print0: SKIPPED (no GNU find -printf)"
    exit 0
fi

# Stubs
SILENT_LOG="/dev/null"
debug_log() { :; }
print_message() { :; }
log_message() { :; }
export SILENT_LOG
EXCLUDE_DIRS=""
MAX_FILE_SIZE_MB=1
BACKUP_LOG_FILES="false"

# Extract helpers
FUNC_FILE="$TMP_DIR/funcs.sh"
{
    sed -n '/^_split_exclude_dirs() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^build_skipped_report() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# Setup fake bot_path с проблемными файлами
BOT_PATH="$TMP_DIR/bot"
mkdir -p "$BOT_PATH"
# 1) Normal large file (> 1MB)
dd if=/dev/zero of="$BOT_PATH/large_normal.bin" bs=1M count=2 2>/dev/null
# 2) Large file with tab in name (test 2)
dd if=/dev/zero of="$BOT_PATH/large"$'\t'"with_tab.bin" bs=1M count=2 2>/dev/null
# 3) Large file with newline in name (test 1 — main scenario)
NL_FILE="$BOT_PATH/large"$'\n'"with_newline.bin"
dd if=/dev/zero of="$NL_FILE" bs=1M count=2 2>/dev/null
# 4) Small file (не должен попасть в skipped)
dd if=/dev/zero of="$BOT_PATH/small.txt" bs=1024 count=1 2>/dev/null

OUTPUT="$TMP_DIR/skipped.txt"
build_skipped_report "$BOT_PATH" "$OUTPUT" > /dev/null

# Test 4: количество строк в output == количество скипнутых файлов
ACTUAL_LINES=$(wc -l < "$OUTPUT")
if [[ $ACTUAL_LINES -ne 3 ]]; then
    echo "FAIL [line count]: expected 3 large files, got $ACTUAL_LINES lines" >&2
    FAILS=$((FAILS + 1))
    echo "--- output content ---" >&2
    cat -A "$OUTPUT" >&2
fi

# Test 1+3: ни одна строка не должна содержать сырой newline в filename
# (он должен быть заменён на <NL>)
if grep -P '\t.*\n.*\t' "$OUTPUT" 2>/dev/null; then
    echo "FAIL [newline]: raw newline detected inside filename field" >&2
    FAILS=$((FAILS + 1))
fi

# Проверим что <NL> маркер появился
if ! grep -q "<NL>" "$OUTPUT"; then
    echo "FAIL [NL marker]: <NL> not found in output (expected from newline in name)" >&2
    FAILS=$((FAILS + 1))
fi

# Test 2: <TAB> маркер
if ! grep -q "<TAB>" "$OUTPUT"; then
    echo "FAIL [TAB marker]: <TAB> not found in output (expected from tab in name)" >&2
    FAILS=$((FAILS + 1))
fi

# Verify: все 3 large files имеют reason "size > MAX_FILE_SIZE_MB..."
SIZE_REASONS=$(grep -c "size > MAX_FILE_SIZE_MB" "$OUTPUT" || true)
if [[ $SIZE_REASONS -ne 3 ]]; then
    echo "FAIL [size reason]: expected 3, got $SIZE_REASONS" >&2
    FAILS=$((FAILS + 1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  skipped print0: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  skipped print0: 4 fixtures OK (line count, no raw newline, NL marker, TAB marker, size reason)"
