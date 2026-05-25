#!/usr/bin/env bash
# Tests for build_skipped_report() from lazarus-backup.
# Verifies that all 6 categories are correctly classified:
#   1. size > MAX_FILE_SIZE_MB
#   2. .git directory
#   3. backups/ directory
#   4. bot image .tar
#   5. log file (rotated + plain) when BACKUP_LOG_FILES != true
#   6. EXCLUDE_DIRS pattern

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export SILENT_LOG

# Extract function
FUNC_FILE="$TMP_DIR/build_skipped.sh"
sed -n '/^build_skipped_report() {$/,/^}$/p' "$SCRIPT" > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract build_skipped_report from $SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

# Создаём fixture-дерево
BOT_DIR="$TMP_DIR/bot"
mkdir -p "$BOT_DIR/uploads" "$BOT_DIR/.git/objects" "$BOT_DIR/logs" \
         "$BOT_DIR/backups" "$BOT_DIR/data" "$BOT_DIR/normal"

# Тестовые файлы (сгенерированы детерминированно):
echo "small" > "$BOT_DIR/main.py"
echo "small" > "$BOT_DIR/normal/config.yaml"
# big.bin > 2 MB
dd if=/dev/zero of="$BOT_DIR/uploads/big.bin" bs=1M count=3 2>/dev/null
# logs
echo "log" > "$BOT_DIR/access.log"
echo "log" > "$BOT_DIR/error.log.1"
echo "log" > "$BOT_DIR/access.log-20260510.gz"
echo "log" > "$BOT_DIR/logs/runtime.log"
# .git
echo "x" > "$BOT_DIR/.git/objects/pack.bin"
# backups/
echo "x" > "$BOT_DIR/backups/old.tar.gz"
# data/ (EXCLUDE_DIRS)
echo "x" > "$BOT_DIR/data/cache.tmp"
# bot image
echo "x" > "$BOT_DIR/private-remnawave-6.4.tar"

# Параметры теста
MAX_FILE_SIZE_MB=2
EXCLUDE_DIRS="data"
BACKUP_LOG_FILES="false"
export MAX_FILE_SIZE_MB EXCLUDE_DIRS BACKUP_LOG_FILES

REPORT="$TMP_DIR/skipped.txt"
COUNT=$(build_skipped_report "$BOT_DIR" "$REPORT")

if [[ ! -s "$REPORT" ]]; then
    echo "FAIL: report empty" >&2
    exit 1
fi

# Проверяем что все 6 категорий присутствуют
EXPECTED_REASONS=(
    "size > MAX_FILE_SIZE_MB=2MB"
    ".git directory"
    "backups/ directory"
    "bot image .tar"
    "log file"
    "EXCLUDE_DIRS: data"
)

FAILS=0
for reason in "${EXPECTED_REASONS[@]}"; do
    if ! grep -qF "$reason" "$REPORT"; then
        echo "FAIL: missing category '$reason' in report" >&2
        echo "--- report content ---" >&2
        cat "$REPORT" >&2
        FAILS=$((FAILS + 1))
    fi
done

# Проверяем что main.py и normal/config.yaml НЕ в отчёте (должны пройти в архив)
if grep -qE 'main\.py|normal/config\.yaml' "$REPORT"; then
    echo "FAIL: legitimate files (main.py, normal/config.yaml) wrongly classified as skipped" >&2
    cat "$REPORT" >&2
    FAILS=$((FAILS + 1))
fi

# Проверяем что COUNT > 0
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 6 ]]; then
    echo "FAIL: expected count ≥ 6, got '$COUNT'" >&2
    FAILS=$((FAILS + 1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  skipped report: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  skipped report: 6 categories + 2 negative cases OK (count=$COUNT)"
