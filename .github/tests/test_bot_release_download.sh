#!/usr/bin/env bash
# Tests for download_bot_release() + version/license arg classification
# (lazarus bot upgrade <VERSION>).
# NB: счётчики называются n_ok/n_err (не PASS/FAIL) — иначе строка "PASS=..."
# попадает под маскировку секретов и ломает файл на диске.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
BOT_PATH="$TMP_DIR/bot"
mkdir -p "$BOT_PATH"
BOT_RELEASE_URL_BASE="https://s3.rwp.rw/releases"
print_message() { :; }
debug_log() { :; }
export SILENT_LOG BOT_PATH BOT_RELEASE_URL_BASE

FUNCS="$TMP_DIR/funcs.sh"
sed -n '/^download_bot_release() {$/,/^}$/p' "$SCRIPT" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

n_ok=0
n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# Mock curl: захватывает -o <out> и URL. URL пишем в файл (T1 зовёт функцию
# в $()-subshell, переменная не дожила бы до родителя). Содержимое — по режиму.
MOCK_CURL_MODE="valid"
URL_FILE="$TMP_DIR/_url"
curl() {
    local out=""
    local args=("$@")
    local i
    for ((i=0; i<${#args[@]}; i++)); do
        [[ "${args[i]}" == "-o" ]] && out="${args[i+1]}"
        [[ "${args[i]}" == http* ]] && echo "${args[i]}" > "$URL_FILE"
    done
    case "$MOCK_CURL_MODE" in
        netfail) return 22 ;;
        small)   echo "404 Not Found" > "$out"; return 0 ;;
        garbage) head -c 2200000 /dev/urandom > "$out" 2>/dev/null; return 0 ;;
        valid)
            local big="$TMP_DIR/_payload"
            dd if=/dev/zero of="$big" bs=1M count=2 2>/dev/null
            tar -cf "$out" -C "$TMP_DIR" "$(basename "$big")" 2>/dev/null
            return 0 ;;
    esac
}
wget() { return 1; }

# T1: успешная загрузка валидного релиза
MOCK_CURL_MODE="valid"
if out=$(download_bot_release "6.5.19" 2>/dev/null); then
    [[ "$out" == "$BOT_PATH/rwp_shop_6.5.19.tar" ]] && ok || bad "T1 out path: '$out'"
else
    bad "T1: должна быть успешной загрузка valid tar"
fi

# T2: URL построен правильно
_url="$(cat "$URL_FILE" 2>/dev/null)"
[[ "$_url" == "https://s3.rwp.rw/releases/6.5.19/rwp_shop_6.5.19.tar" ]] \
    && ok || bad "T2 URL: '$_url'"

# T3: curl fail (404) → rc!=0, файла нет
MOCK_CURL_MODE="netfail"
if download_bot_release "6.5.20" >/dev/null 2>&1; then
    bad "T3: должна провалиться при curl rc=22"
else
    [[ ! -f "$BOT_PATH/rwp_shop_6.5.20.tar" ]] && ok || bad "T3: tar не должен остаться"
fi

# T4: маленький файл (404-страница) → отвергнут
MOCK_CURL_MODE="small"
if download_bot_release "6.5.21" >/dev/null 2>&1; then
    bad "T4: маленький файл должен быть отвергнут"
else
    [[ ! -f "$BOT_PATH/rwp_shop_6.5.21.tar" ]] && ok || bad "T4: cleanup"
fi

# T5: большой, но не tar → отвергнут
MOCK_CURL_MODE="garbage"
if download_bot_release "6.5.22" >/dev/null 2>&1; then
    bad "T5: не-tar должен быть отвергнут"
else
    [[ ! -f "$BOT_PATH/rwp_shop_6.5.22.tar" ]] && ok || bad "T5: cleanup"
fi

# T6: некорректная/пустая версия → отвергнута до curl
MOCK_CURL_MODE="valid"
download_bot_release "not-a-version" >/dev/null 2>&1 && bad "T6: кривая версия" || ok
download_bot_release "" >/dev/null 2>&1 && bad "T6b: пустая версия" || ok

# T7: классификация version vs license (логика arg-парсинга auto_update_bot)
classify() {
    local r="other"
    if [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then r="version"
    elif [[ "$1" =~ ^[0-9a-f]{64}$ ]]; then r="license"; fi
    echo "$r"
}
[[ "$(classify 6.5.19)" == "version" ]] && ok || bad "T7 6.5.19"
[[ "$(classify 6.5.19.27)" == "version" ]] && ok || bad "T7 4-part"
KEY64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
[[ "$(classify "$KEY64")" == "license" ]] && ok || bad "T7 64hex"
[[ "$(classify "cd")" == "other" ]] && ok || bad "T7 cd"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
