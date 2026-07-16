#!/usr/bin/env bash
# Поведение Ctrl+C (_lazarus_int_handler) + инвариант критической секции:
# (1) вне критической секции (меню/промпт/лёгкая операция) — одиночный Ctrl+C = чистый выход 130;
# (2) внутри критической секции (импорт БД при restore) — первый Ctrl+C НЕ выходит (WARN),
#     второй в окне — выходит 130 (защита восстановления от случайного обрыва);
# (3) safe_read сбрасывает _CRITICAL_SECTION в 0 (любой промпт = не критическая секция);
# (4) restore реально ставит _CRITICAL_SECTION=1 вокруг импорта и снимает на выходе.
# Реальный скрипт как lib. Counters n_ok/n_err.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
SILENT_LOG="$TMP_DIR/silent.log"

# === 1) Вне критической секции — одиночный Ctrl+C = выход 130 ===
# Хендлер зовёт exit → ловим в subshell.
_CRITICAL_SECTION=0
out=$( _lazarus_int_handler 2>&1 ); rc=$?
[[ $rc -eq 130 ]] && ok || bad "вне критсекции: ждали exit 130, got rc=$rc"
[[ "$out" == *"Выход."* ]] && ok || bad "вне критсекции: ждали 'Выход.', got '$out'"

# === 2) Внутри критической секции — первый Ctrl+C НЕ выходит, второй выходит ===
# 2a) первый вызов: не должен звать exit (subshell вернёт 0 от последнего printf), печатает WARN.
_CRITICAL_SECTION=1; _INT_FLAG=0; _INT_LAST_TS=0
out=$( _lazarus_int_handler 2>&1 ); rc=$?
[[ $rc -ne 130 ]] && ok || bad "критсекция 1-й Ctrl+C: НЕ должен выходить (rc=$rc)"
[[ "$out" == *"ещё раз"* ]] && ok || bad "критсекция 1-й Ctrl+C: ждали WARN 'ещё раз', got '$out'"
# 2b) состояние после первого (в ТЕКУЩЕМ шелле): _INT_FLAG=1 выставлен.
_CRITICAL_SECTION=1; _INT_FLAG=0; _INT_LAST_TS=0
_lazarus_int_handler >/dev/null 2>&1 || true    # хендлер тут НЕ выходит (flag был 0)
[[ "$_INT_FLAG" == "1" ]] && ok || bad "критсекция: первый Ctrl+C должен взвести _INT_FLAG=1"
# 2c) второй Ctrl+C в окне → exit 130.
out=$( _lazarus_int_handler 2>&1 ); rc=$?
[[ $rc -eq 130 ]] && ok || bad "критсекция 2-й Ctrl+C: ждали exit 130, got rc=$rc"

# === 3) safe_read сбрасывает _CRITICAL_SECTION в 0 ===
# Мок builtin read не получится (builtin), поэтому кормим ввод через here-string на fd0.
_CRITICAL_SECTION=1
safe_read -r _dummy <<< "x"
[[ "$_CRITICAL_SECTION" == "0" ]] && ok || bad "safe_read должен сбросить _CRITICAL_SECTION в 0 (got '$_CRITICAL_SECTION')"

# === 4) Статика: restore ставит флаг вокруг импорта и снимает; хендлер завязан на флаг ===
grep -qE '_CRITICAL_SECTION=1 *#.*импорт' "$SCRIPT" && ok \
    || bad "restore должен ставить _CRITICAL_SECTION=1 перед импортом БД"
grep -qE '_CRITICAL_SECTION=0 *#.*(окно закрыто|импорт)' "$SCRIPT" && ok \
    || bad "restore должен снимать _CRITICAL_SECTION=0 после импорта"
# H1 расширил защищённый коридор restore (down → rsync → volume rm → import) + #3 добавил
# db_only app-stop, поэтому постановок _CRITICAL_SECTION=1 стало больше исходных 3. Проверяем
# нижнюю границу И что каждая постановка перекрыта сбросами (=0 не меньше =1) — иначе флаг
# «залипнет» в 1 после restore и следующий Ctrl+C потребует двойного подтверждения зря.
_sets=$(grep -cE '_CRITICAL_SECTION=1' "$SCRIPT")
_resets=$(grep -cE '_CRITICAL_SECTION=0' "$SCRIPT")
[[ "$_sets" -ge 3 ]] && ok || bad "ждали >=3 постановки _CRITICAL_SECTION=1 (коридор+импорты), нашли $_sets"
[[ "$_resets" -ge "$_sets" ]] && ok || bad "сбросов =0 ($_resets) должно быть не меньше постановок =1 ($_sets) — иначе флаг залипнет"
# хендлер выходит сразу, когда флаг != 1
grep -qE '\[\[ "\$\{_CRITICAL_SECTION:-0\}" != 1 \]\]' "$SCRIPT" && ok \
    || bad "хендлер должен сразу выходить, если _CRITICAL_SECTION != 1"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
