#!/usr/bin/env bash
# Tests for compression helpers (gzip vs zstd routing).
# Verifies:
#   1. _compress_current: gzip default, zstd когда установлен
#   2. _compress_current: fallback gzip когда COMPRESSION=zstd но zstd отсутствует
#   3. _compress_ext: "gz" для gzip, "zst" для zstd
#   4. _compress_detect_format: правильная detection по magic bytes
#   5. _decompress_cmd_for: правильный decompressor для формата
#   6. _tar_create_args / _tar_extract_args_for: правильные tar-флаги
#   7. _verify_compressed: integrity check для обоих форматов

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG=/dev/null
INSTALL_DIR="$TMP_DIR/install"
mkdir -p "$INSTALL_DIR"
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export SILENT_LOG INSTALL_DIR

# Extract helpers
FUNC_FILE="$TMP_DIR/compress_helpers.sh"
{
    sed -n '/^_compress_current() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_compress_ext() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_compress_detect_format() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_decompress_cmd_for() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_tar_create_args() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_tar_extract_args_for() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_verify_compressed() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract compression helpers" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# --- Test 1: _compress_current: gzip default ---
COMPRESSION=""
RES=$(_compress_current)
[[ "$RES" == "gzip" ]] || { echo "FAIL [default]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

COMPRESSION="gzip"
RES=$(_compress_current)
[[ "$RES" == "gzip" ]] || { echo "FAIL [gzip explicit]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 2: zstd когда установлен ---
if command -v zstd > /dev/null 2>&1; then
    COMPRESSION="zstd"
    RES=$(_compress_current)
    [[ "$RES" == "zstd" ]] || { echo "FAIL [zstd available]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
fi

# --- Test 3: fallback на gzip когда zstd отсутствует ---
if ! command -v zstd > /dev/null 2>&1; then
    COMPRESSION="zstd"
    RES=$(_compress_current)
    [[ "$RES" == "gzip" ]] || { echo "FAIL [zstd fallback]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
fi

# --- Test 4: _compress_ext ---
COMPRESSION="gzip"
EXT=$(_compress_ext)
[[ "$EXT" == "gz" ]] || { echo "FAIL [ext gz]: got '$EXT'" >&2; FAILS=$((FAILS + 1)); }

if command -v zstd > /dev/null 2>&1; then
    COMPRESSION="zstd"
    EXT=$(_compress_ext)
    [[ "$EXT" == "zst" ]] || { echo "FAIL [ext zst]: got '$EXT'" >&2; FAILS=$((FAILS + 1)); }
fi

# --- Test 5: _compress_detect_format по magic bytes ---
# Создаём gzip файл и проверяем detect
echo "test content" | gzip > "$TMP_DIR/test.gz"
DETECTED=$(_compress_detect_format "$TMP_DIR/test.gz")
[[ "$DETECTED" == "gzip" ]] || { echo "FAIL [detect gzip]: got '$DETECTED'" >&2; FAILS=$((FAILS + 1)); }

if command -v zstd > /dev/null 2>&1; then
    echo "test content" | zstd > "$TMP_DIR/test.zst" 2>/dev/null
    DETECTED=$(_compress_detect_format "$TMP_DIR/test.zst")
    [[ "$DETECTED" == "zstd" ]] || { echo "FAIL [detect zstd]: got '$DETECTED'" >&2; FAILS=$((FAILS + 1)); }
fi

# Unknown format
echo "not compressed" > "$TMP_DIR/test.bin"
DETECTED=$(_compress_detect_format "$TMP_DIR/test.bin")
[[ "$DETECTED" == "unknown" ]] || { echo "FAIL [detect unknown]: got '$DETECTED'" >&2; FAILS=$((FAILS + 1)); }

# Detect через extension (когда magic не помог)
touch "$TMP_DIR/file.tar.zst"
DETECTED=$(_compress_detect_format "$TMP_DIR/file.tar.zst")
[[ "$DETECTED" == "zstd" ]] || { echo "FAIL [detect by ext zst]: got '$DETECTED'" >&2; FAILS=$((FAILS + 1)); }

# Non-existent file
DETECTED=$(_compress_detect_format "$TMP_DIR/nonexistent")
[[ "$DETECTED" == "unknown" ]] || { echo "FAIL [detect missing]: got '$DETECTED'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 6: _decompress_cmd_for ---
RES=$(_decompress_cmd_for "gzip")
[[ "$RES" == "gunzip -c" ]] || { echo "FAIL [decompress gzip]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
RES=$(_decompress_cmd_for "zstd")
[[ "$RES" == "zstd -dc" ]] || { echo "FAIL [decompress zstd]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
RES=$(_decompress_cmd_for "unknown")
[[ "$RES" == "gunzip -c" ]] || { echo "FAIL [decompress fallback]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 7: _tar_extract_args_for ---
RES=$(_tar_extract_args_for "gzip")
[[ "$RES" == "-z" ]] || { echo "FAIL [tar gzip args]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
RES=$(_tar_extract_args_for "zstd")
[[ "$RES" == "--use-compress-program=zstd" ]] || { echo "FAIL [tar zstd args]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 8: _tar_create_args ---
COMPRESSION="gzip"
RES=$(_tar_create_args)
[[ "$RES" == "-z" ]] || { echo "FAIL [tar create gzip]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

if command -v zstd > /dev/null 2>&1; then
    COMPRESSION="zstd"
    RES=$(_tar_create_args)
    [[ "$RES" == "--use-compress-program=zstd" ]] || { echo "FAIL [tar create zstd]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }
fi

# --- Test 9: _verify_compressed (round-trip integrity) ---
# Создаём gzip файл и проверяем verify
echo "valid content" | gzip > "$TMP_DIR/verify.gz"
_verify_compressed "$TMP_DIR/verify.gz" "gzip"
[[ $? -eq 0 ]] || { echo "FAIL [verify gzip OK]" >&2; FAILS=$((FAILS + 1)); }

# Corrupt gzip → должно fail
echo "corrupted" > "$TMP_DIR/bad.gz"
_verify_compressed "$TMP_DIR/bad.gz" "gzip" && { echo "FAIL [verify corrupt should fail]" >&2; FAILS=$((FAILS + 1)); } || true

if command -v zstd > /dev/null 2>&1; then
    echo "zstd content" | zstd > "$TMP_DIR/verify.zst" 2>/dev/null
    _verify_compressed "$TMP_DIR/verify.zst" "zstd"
    [[ $? -eq 0 ]] || { echo "FAIL [verify zstd OK]" >&2; FAILS=$((FAILS + 1)); }
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  compression helpers: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  compression helpers: ~17 fixtures OK (current, ext, detect, decompress, tar args, verify)"
