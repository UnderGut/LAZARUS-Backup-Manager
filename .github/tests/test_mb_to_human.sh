#!/usr/bin/env bash
# Tests for _mb_to_human — bash-only MB→GB formatter, заменил bc.
# Bug history: production падал с `bc: command not found` на minimal Debian 12
# инсталляциях, где bc не в base пакете → пустой stdout от bc → отображение
# "Размер бэкапов:  GB / 500 MB" (двойной пробел перед GB).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FUNCS="$TMP_DIR/funcs.sh"
sed -n '/^_mb_to_human() {$/,/^}$/p' "$SCRIPT" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

PASS=0
FAIL=0
check() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL: $desc — got '$got', want '$want'"
    fi
}

# === Базовые MB (< 1024) ===
check "$(_mb_to_human 0)"    "0 MB"     "0 MB"
check "$(_mb_to_human 1)"    "1 MB"     "1 MB"
check "$(_mb_to_human 500)"  "500 MB"   "500 MB"
check "$(_mb_to_human 1023)" "1023 MB"  "1023 MB (граница)"

# === GB (≥ 1024) ===
check "$(_mb_to_human 1024)" "1.0 GB"   "1024 MB = 1.0 GB"
# 1280 % 1024 = 256, (256*10+512)/1024 = 3072/1024 = 3 → "1.3 GB" (round half-up)
check "$(_mb_to_human 1280)" "1.3 GB"   "1280 MB = 1.3 GB (round half-up)"
check "$(_mb_to_human 1287)" "1.3 GB"   "1287 MB = 1.3 GB (наш реальный случай: 99 db архивов)"
check "$(_mb_to_human 1536)" "1.5 GB"   "1536 MB = 1.5 GB"
check "$(_mb_to_human 2048)" "2.0 GB"   "2048 MB = 2.0 GB"
check "$(_mb_to_human 10240)" "10.0 GB" "10240 MB = 10.0 GB"
check "$(_mb_to_human 102400)" "100.0 GB" "100 GB"

# === Округление через 10-граница ===
# Edge: дробь округляется в 10 → должна перейти в integer часть
# 1024 + 973 = 1997, 1997 % 1024 = 973, (973*10+512)/1024 = (9730+512)/1024 = 10242/1024 = 10
# → должно быть "2.0 GB", не "1.10 GB"
check "$(_mb_to_human 1997)" "2.0 GB"   "1997 MB округление с переносом в integer"

# === Невалидный ввод ===
check "$(_mb_to_human "")"      "0 MB" "empty input"
check "$(_mb_to_human "abc")"   "0 MB" "non-numeric"
check "$(_mb_to_human "-100")"  "0 MB" "negative (regex не пускает)"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
