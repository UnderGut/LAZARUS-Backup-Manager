#!/usr/bin/env bash
# Tests for HMAC envelope (v2) encrypt/verify/decrypt helpers.
# Verifies:
#   1. Encrypt → decrypt round-trip.
#   2. Tampering detection (flip byte in ciphertext → MAC fails).
#   3. Wrong password detection BEFORE decrypt (gadget protection).
#   4. Backward compat with legacy v1 (Salted__ format).
#   5. _hmac_envelope_verify reports correct format ("v2" / "v1" / "unknown").

# NB: НЕ используем `set -e` потому что мы намеренно вызываем функции, которые
# возвращают non-zero (например MAC mismatch на tampered file). Сами проверяем
# каждый шаг через FAILS counter.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="/dev/null"
TMPDIR="$TMP_DIR"
declare -a SENSITIVE_TMP_PATHS=()
register_sensitive_tmp() { :; }
unregister_sensitive_tmp() { :; }
print_message() { :; }
log_message() { :; }
debug_log() { :; }
export SILENT_LOG TMPDIR

# Skip if openssl not available
if ! command -v openssl >/dev/null 2>&1; then
    echo "  hmac envelope: SKIPPED (no openssl)"
    exit 0
fi

# Skip if openssl doesn't support `-pass fd:N` (старый git-bash openssl на Windows
# или archaic openssl <1.0.2). Проверка через минимальный encrypt с FD heredoc.
_skip_probe_in=$(mktemp); _skip_probe_out=$(mktemp)
echo "probe" > "$_skip_probe_in"
if ! openssl enc -aes-256-cbc -salt -pbkdf2 -iter 1000 \
        -in "$_skip_probe_in" -out "$_skip_probe_out" -pass fd:3 3<<<"probepwd" 2>/dev/null; then
    rm -f "$_skip_probe_in" "$_skip_probe_out"
    echo "  hmac envelope: SKIPPED (openssl не поддерживает -pass fd:N, локально на Windows git-bash)"
    exit 0
fi
rm -f "$_skip_probe_in" "$_skip_probe_out"

# Extract HMAC envelope helpers from main script.
FUNC_FILE="$TMP_DIR/hmac_helpers.sh"
{
    sed -n '/^_to_hex() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_derive_hmac_key() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_hmac_envelope_create() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_hmac_envelope_verify() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_hmac_envelope_decrypt() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract HMAC helpers" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# Подготовка plaintext fixture
PLAIN="$TMP_DIR/plain.txt"
echo "Secret backup payload. v6.4.1.27 + БД dump + files." > "$PLAIN"
PWD='myPa$$word!#& test 12345'

# --- Test 1: encrypt → decrypt round-trip (v2) ---
ENC="$TMP_DIR/enc.v2"
DEC="$TMP_DIR/dec.txt"
if ! _hmac_envelope_create "$PLAIN" "$ENC" "$PWD"; then
    echo "FAIL [encrypt]: _hmac_envelope_create returned non-zero" >&2
    FAILS=$((FAILS + 1))
fi
# Check magic "LAZ2"
MAGIC=$(head -c 4 "$ENC")
if [[ "$MAGIC" != "LAZ2" ]]; then
    echo "FAIL [magic]: expected 'LAZ2', got '$MAGIC'" >&2
    FAILS=$((FAILS + 1))
fi
if ! _hmac_envelope_decrypt "$ENC" "$DEC" "$PWD"; then
    echo "FAIL [decrypt]: _hmac_envelope_decrypt returned non-zero" >&2
    FAILS=$((FAILS + 1))
fi
if ! diff -q "$DEC" "$PLAIN" >/dev/null 2>&1; then
    echo "FAIL [round-trip]: decrypted differs from plaintext" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 2: tampering detection ---
TAMPERED="$TMP_DIR/tampered.v2"
cp "$ENC" "$TAMPERED"
# Flip byte at offset 20 (inside ciphertext, after LAZ2+Salted__)
printf '\xFF' | dd of="$TAMPERED" bs=1 seek=20 count=1 conv=notrunc 2>/dev/null
DEC2="$TMP_DIR/dec_tampered.txt"
if _hmac_envelope_decrypt "$TAMPERED" "$DEC2" "$PWD"; then
    echo "FAIL [tampering]: decrypt of tampered file should fail" >&2
    FAILS=$((FAILS + 1))
fi
rm -f "$DEC2"

# --- Test 3: wrong password (BEFORE decrypt — via MAC) ---
DEC3="$TMP_DIR/dec_wrongpwd.txt"
if _hmac_envelope_decrypt "$ENC" "$DEC3" "WRONG_PASSWORD"; then
    echo "FAIL [wrong pwd]: decrypt with wrong password should fail" >&2
    FAILS=$((FAILS + 1))
fi
# MAC fails before openssl decrypt — so DEC3 shouldn't exist
if [[ -f "$DEC3" ]]; then
    echo "FAIL [wrong pwd gadget]: DEC3 exists — openssl was called despite MAC fail!" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 4: format detection ---
FMT=$(_hmac_envelope_verify "$ENC" "$PWD")
if [[ "$FMT" != "v2" ]]; then
    echo "FAIL [verify format v2]: expected 'v2', got '$FMT'" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 5: backward compat with legacy v1 ---
V1_ENC="$TMP_DIR/legacy.v1"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "$PLAIN" -out "$V1_ENC" -pass fd:3 3<<<"$PWD"
FMT_V1=$(_hmac_envelope_verify "$V1_ENC" "$PWD")
if [[ "$FMT_V1" != "v1" ]]; then
    echo "FAIL [v1 detection]: expected 'v1', got '$FMT_V1'" >&2
    FAILS=$((FAILS + 1))
fi
# Decrypt v1 file
DEC_V1="$TMP_DIR/dec_v1.txt"
if ! _hmac_envelope_decrypt "$V1_ENC" "$DEC_V1" "$PWD"; then
    echo "FAIL [v1 decrypt]: legacy v1 decrypt failed" >&2
    FAILS=$((FAILS + 1))
fi
if ! diff -q "$DEC_V1" "$PLAIN" >/dev/null 2>&1; then
    echo "FAIL [v1 round-trip]: v1 decrypted differs from plaintext" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 6: unknown format ---
UNK="$TMP_DIR/unknown.bin"
echo "not encrypted gibberish" > "$UNK"
FMT_UNK=$(_hmac_envelope_verify "$UNK" "$PWD")
if [[ "$FMT_UNK" != "unknown" ]]; then
    echo "FAIL [unknown detection]: expected 'unknown', got '$FMT_UNK'" >&2
    FAILS=$((FAILS + 1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  hmac envelope: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  hmac envelope: 6 fixtures OK (round-trip, tampering, wrong-pwd, v2 detect, v1 compat, unknown)"
