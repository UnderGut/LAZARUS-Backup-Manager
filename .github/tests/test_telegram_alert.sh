#!/usr/bin/env bash
# Tests for send_telegram_alert.
# Verifies:
#   1. Severity mapping (CRITICAL/ERROR/WARN/INFO/unknown)
#   2. Body section добавляется если передан
#   3. Actions section добавляется если передан
#   4. <code>X</code> заменяется на `X` после escape
#   5. Hostname + timestamp в footer
#   6. Skip когда SEND_TO_TELEGRAM=false / нет креденшелов

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="/dev/null"
debug_log() { :; }
export SILENT_LOG
CURL_SILENT="-s"
BOT_TOKEN="TEST_TOKEN_123"
CHAT_ID="-100123"
TG_MESSAGE_THREAD_ID=""
SEND_TO_TELEGRAM="true"

# Mock curl — записывает в файл вместо реального запроса.
# Анализируем что-сы было в --data-urlencode text=
CURL_LOG="$TMP_DIR/curl.log"
curl() {
    # Парсим --data-urlencode text="..."
    local _capture_next=""
    for arg in "$@"; do
        if [[ "$_capture_next" == "text" ]]; then
            # arg вида "text=..." — записываем
            echo "${arg#text=}" >> "$CURL_LOG"
            _capture_next=""
            continue
        fi
        if [[ "$arg" == "--data-urlencode" ]]; then
            _capture_next="text"
        fi
    done
}
export -f curl

# Extract functions
FUNC_FILE="$TMP_DIR/funcs.sh"
{
    sed -n '/^escape_markdown_v2() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^send_telegram_alert() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract send_telegram_alert" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# --- Test 1: CRITICAL severity → 🔴🔴🔴 + CRITICAL label + #critical ---
: > "$CURL_LOG"
send_telegram_alert "CRITICAL" "Test critical" "body text" ""
LAST=$(cat "$CURL_LOG")
grep -q "🔴🔴🔴" <<< "$LAST" || { echo "FAIL [crit emoji]: no 🔴🔴🔴 in output" >&2; FAILS=$((FAILS + 1)); }
grep -q "CRITICAL" <<< "$LAST" || { echo "FAIL [crit label]: no CRITICAL" >&2; FAILS=$((FAILS + 1)); }
grep -q "#critical" <<< "$LAST" || { echo "FAIL [crit hashtag]: no #critical" >&2; FAILS=$((FAILS + 1)); }
grep -q "━" <<< "$LAST" || { echo "FAIL [crit separator]: no ━━━ line" >&2; FAILS=$((FAILS + 1)); }

# --- Test 2: ERROR severity → ❌ + ERROR label + #error ---
: > "$CURL_LOG"
send_telegram_alert "ERROR" "Test error" "errbody" ""
LAST=$(cat "$CURL_LOG")
grep -q "❌" <<< "$LAST" || { echo "FAIL [err emoji]" >&2; FAILS=$((FAILS + 1)); }
grep -q "ERROR" <<< "$LAST" || { echo "FAIL [err label]" >&2; FAILS=$((FAILS + 1)); }

# --- Test 3: WARN ---
: > "$CURL_LOG"
send_telegram_alert "WARN" "Test warn" "warn body" ""
LAST=$(cat "$CURL_LOG")
grep -q "⚠️" <<< "$LAST" || { echo "FAIL [warn emoji]" >&2; FAILS=$((FAILS + 1)); }
grep -q "WARNING" <<< "$LAST" || { echo "FAIL [warn label]" >&2; FAILS=$((FAILS + 1)); }
grep -q "#warning" <<< "$LAST" || { echo "FAIL [warn hashtag]" >&2; FAILS=$((FAILS + 1)); }
# WARN не должен иметь separator (только CRITICAL)
grep -q "━" <<< "$LAST" && { echo "FAIL [warn separator]: should NOT have ━ line" >&2; FAILS=$((FAILS + 1)); }

# --- Test 4: INFO ---
: > "$CURL_LOG"
send_telegram_alert "INFO" "Test info" "" ""
LAST=$(cat "$CURL_LOG")
grep -q "ℹ️" <<< "$LAST" || { echo "FAIL [info emoji]" >&2; FAILS=$((FAILS + 1)); }
grep -q "INFO" <<< "$LAST" || { echo "FAIL [info label]" >&2; FAILS=$((FAILS + 1)); }

# --- Test 5: Body + Actions присутствуют ---
: > "$CURL_LOG"
send_telegram_alert "CRITICAL" "Title" "body text here" "do something
do another"
LAST=$(cat "$CURL_LOG")
grep -q "body text here" <<< "$LAST" || { echo "FAIL [body present]" >&2; FAILS=$((FAILS + 1)); }
grep -q "do something" <<< "$LAST" || { echo "FAIL [actions line 1]" >&2; FAILS=$((FAILS + 1)); }
grep -q "do another" <<< "$LAST" || { echo "FAIL [actions line 2]" >&2; FAILS=$((FAILS + 1)); }
grep -q "Что делать" <<< "$LAST" || { echo "FAIL [actions label]" >&2; FAILS=$((FAILS + 1)); }

# --- Test 6: <code>X</code> → `X` после escape ---
: > "$CURL_LOG"
send_telegram_alert "INFO" "Code test" "Use <code>lazarus cleanup</code> command" "Run <code>df -h</code>"
LAST=$(cat "$CURL_LOG")
# В output должны быть backtick'и вместо <code>
if grep -q "<code>" <<< "$LAST"; then
    echo "FAIL [code not replaced]: <code> still present" >&2
    FAILS=$((FAILS + 1))
fi
grep -q '`lazarus cleanup`' <<< "$LAST" || { echo "FAIL [code body backticks]" >&2; FAILS=$((FAILS + 1)); }
grep -q '`df \\-h`' <<< "$LAST" || grep -q '`df -h`' <<< "$LAST" || { echo "FAIL [code actions backticks]" >&2; FAILS=$((FAILS + 1)); }

# --- Test 7: Skip если SEND_TO_TELEGRAM=false ---
: > "$CURL_LOG"
SEND_TO_TELEGRAM="false"
send_telegram_alert "CRITICAL" "Should not send" "x" ""
if [[ -s "$CURL_LOG" ]]; then
    echo "FAIL [skip disabled]: curl was called despite SEND_TO_TELEGRAM=false" >&2
    FAILS=$((FAILS + 1))
fi
SEND_TO_TELEGRAM="true"

# --- Test 8: Skip если нет BOT_TOKEN ---
: > "$CURL_LOG"
BOT_TOKEN_BAK="$BOT_TOKEN"
BOT_TOKEN=""
send_telegram_alert "ERROR" "Should not send" "x" ""
if [[ -s "$CURL_LOG" ]]; then
    echo "FAIL [skip no token]: curl was called despite empty BOT_TOKEN" >&2
    FAILS=$((FAILS + 1))
fi
BOT_TOKEN="$BOT_TOKEN_BAK"

# --- Test 9: hostname + timestamp в footer, hashtags в самом начале ---
: > "$CURL_LOG"
send_telegram_alert "INFO" "Footer test" "" ""
LAST=$(cat "$CURL_LOG")
grep -q "🖥" <<< "$LAST" || { echo "FAIL [host emoji]" >&2; FAILS=$((FAILS + 1)); }
grep -q "🕐" <<< "$LAST" || { echo "FAIL [clock emoji]" >&2; FAILS=$((FAILS + 1)); }
# timestamp в формате DD.MM HH:MM:SS — должна быть хотя бы пара цифр-точка-цифр
grep -qE "[0-9]+\\\.[0-9]+" <<< "$LAST" || { echo "FAIL [timestamp format]" >&2; FAILS=$((FAILS + 1)); }
# Hashtag должен быть в первой строке (не в footer)
FIRST_LINE=$(head -1 <<< "$LAST")
if ! grep -q "#info" <<< "$FIRST_LINE"; then
    echo "FAIL [hashtag in first line]: got first line: '$FIRST_LINE'" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 10: special chars в title escape'ятся ---
: > "$CURL_LOG"
send_telegram_alert "WARN" "Test (with) special.chars!" "body" ""
LAST=$(cat "$CURL_LOG")
# MarkdownV2 escape — точка/скобки/восклицательный должны быть с \
grep -q '\\(' <<< "$LAST" || { echo "FAIL [escape parens]" >&2; FAILS=$((FAILS + 1)); }
grep -q '\\.' <<< "$LAST" || { echo "FAIL [escape dot]" >&2; FAILS=$((FAILS + 1)); }

if [[ $FAILS -gt 0 ]]; then
    echo "  telegram alert: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  telegram alert: 10 fixtures OK (severities x4, body+actions, code-replace, skip x2, footer, escape)"
