#!/usr/bin/env bash
# «Каждые N минут» — общая безопасная логика интервала (_cron_every_n_min) + проводка
# в мастере [3/4] и в главном меню расписаний (setup_cron_task п.5).
# Проверяем: границы 1..59, нормализацию ведущих нулей (10#), отказ на мусоре с очисткой
# выходных переменных, round-trip через get_cron_status, и что оба UI-пути зовут хелпер.
# Реальный скрипт как lib (LAZARUS_LIB=true). Counters n_ok/n_err.

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
SILENT_LOG="$TMP_DIR/silent.log"; DEBUG_MODE=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true

# helper: прогон _cron_every_n_min с ожидаемым rc + spec
chk() { # $1=вход $2=ожид.rc $3=ожид.spec("" если rc!=0)
    _cron_every_n_min "$1"; local _rc=$?
    if [[ "$_rc" -ne "$2" ]]; then bad "_cron_every_n_min('$1') rc=$_rc, ждали $2"; return; fi
    if [[ "$_rc" -eq 0 ]]; then
        [[ "$_CRON_MIN_SPEC" == "$3" ]] && ok || bad "_cron_every_n_min('$1') spec='$_CRON_MIN_SPEC', ждали '$3'"
    else
        # на отказе выходные переменные ОБЯЗАНЫ быть пусты (иначе сталое значение утечёт в cron)
        [[ -z "$_CRON_MIN_SPEC" && -z "$_CRON_MIN_N" ]] && ok \
            || bad "_cron_every_n_min('$1') при отказе не очистил spec/N ('$_CRON_MIN_SPEC'/'$_CRON_MIN_N')"
    fi
}

# === 1) Валидные интервалы ===
chk "5"  0 "*/5 * * * *"
chk "1"  0 "*/1 * * * *"
chk "59" 0 "*/59 * * * *"

# === 2) Нормализация ведущих нулей: '08' → 8 (не октальный сбой, не '*/08') ===
_cron_every_n_min "08"; [[ $? -eq 0 && "$_CRON_MIN_N" == "8"  && "$_CRON_MIN_SPEC" == "*/8 * * * *" ]] \
    && ok || bad "'08' должно нормализоваться в 8 (N='$_CRON_MIN_N' spec='$_CRON_MIN_SPEC')"
_cron_every_n_min "09"; [[ $? -eq 0 && "$_CRON_MIN_N" == "9" ]] \
    && ok || bad "'09' должно нормализоваться в 9 (N='$_CRON_MIN_N')"
_cron_every_n_min "030"; [[ $? -eq 0 && "$_CRON_MIN_N" == "30" && "$_CRON_MIN_SPEC" == "*/30 * * * *" ]] \
    && ok || bad "'030' должно нормализоваться в 30 (N='$_CRON_MIN_N')"

# === 3) Границы и мусор — отказ (rc=1) ===
chk "0"    1 ""
chk "60"   1 ""
chk "61"   1 ""
chk "1440" 1 ""
chk "99999999999999999999" 1 ""   # L7: 20 цифр — без cap длины 10# переполнял int64 → wrap в 1..59
chk ""     1 ""
chk "abc"  1 ""
chk "5x"   1 ""
chk "5.5"  1 ""
chk "-3"   1 ""
chk "5 "   1 ""     # пробел → regex не матчит → отказ (безопасно)
chk " 5"   1 ""

# === 4) Round-trip: get_cron_status читает записанный */N обратно как «Каждые N мин» ===
crontab() { printf '%s\n' "*/7 * * * * /opt/lazarus-backup/lazarus-backup backup_full >> /var/log/lazarus_backup.log 2>&1 # LAZARUS-JOB-FULL"; }
[[ "$(get_cron_status full)" == "Каждые 7 мин" ]] && ok \
    || bad "get_cron_status должен читать '*/7' как 'Каждые 7 мин', получил '$(get_cron_status full)'"
unset -f crontab

# === 5) Статическая проводка UI: оба пути зовут единый хелпер, мастер предлагает п.3 ===
grep -qE '_cron_every_n_min\(\)' "$SCRIPT" && ok || bad "хелпер _cron_every_n_min должен быть определён"
# мастер [3/4]: пункт интервала (после UX-редизайна — «3. Свой интервал в минутах») + ветка 3)
grep -qE '3\. Свой интервал в минутах' "$SCRIPT" && ok || bad "мастер должен предлагать '3. Свой интервал в минутах'"
# ровно ДВА вызова хелпера (мастер + setup_cron_task п.5), не считая определения —
# точный счёт (=2) ловит потерю одной проводки, которую >=2 пропустил бы (замечание ревью).
_calls=$(grep -cE '_cron_every_n_min "' "$SCRIPT")
[[ "$_calls" -eq 2 ]] && ok || bad "ждали ровно 2 вызова _cron_every_n_min (мастер+меню), нашли $_calls"
# нет реликта старой невалидированной инлайн-проверки в меню
grep -qE '\[ "\$interval" -gt 0 \]' "$SCRIPT" \
    && bad "старая инлайн-валидация интервала должна быть удалена (перешла в _cron_every_n_min)" || ok

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
