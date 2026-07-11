#!/usr/bin/env bash
# UI_MODE (Стандартный/Эксперт режим меню) + интент-экран первого запуска:
# (а) дефолт после source = expert (backward-compat: старые установки без ключа);
# (б) roundtrip save_config → config.env → load_config_file, мусор → expert;
# (в) _firstrun_intent изолированно + select_backup_target_firstrun: выбор 2 зовёт
#     panel_migrate_in, провал → обычный поток, успех → panel+standard без выбора цели.
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

# === 1) Дефолт = expert (совместимость: у существующих установок ключа в конфиге нет) ===
[[ "$UI_MODE" == "expert" ]] && ok || bad "default UI_MODE must be expert, got '$UI_MODE'"

# === 2) Roundtrip: save_config пишет UI_MODE в CORE, load_config_file читает обратно ===
INSTALL_DIR="$TMP_DIR/inst"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; _BOTRT_FORCED=0
UI_MODE="standard"
# shellcheck disable=SC2218  # реальный save_config пришёл из source выше; мок появится позже (§4)
save_config >/dev/null 2>&1
grep -qE '^UI_MODE="standard"$' "$CONFIG_FILE" && ok \
    || bad "save_config must persist UI_MODE=\"standard\" (CORE-секция)"
UI_MODE=""
load_config_file "$CONFIG_FILE"
[[ "$UI_MODE" == "standard" ]] && ok || bad "load must restore standard, got '$UI_MODE'"
# expert тоже персистится (CORE пишется всегда)
UI_MODE="expert"
# shellcheck disable=SC2218  # см. выше — до §4 работает реальный save_config из скрипта
save_config >/dev/null 2>&1
grep -qE '^UI_MODE="expert"$' "$CONFIG_FILE" && ok \
    || bad "save_config must persist UI_MODE=\"expert\""
# Мусорное значение в файле → после load = expert (fail-open в ПОЛНОЕ меню, ничего не скрываем)
printf 'UI_MODE="banana"\n' > "$TMP_DIR/garbage.env"
UI_MODE="standard"
load_config_file "$TMP_DIR/garbage.env"
[[ "$UI_MODE" == "expert" ]] && ok || bad "garbage UI_MODE must load as expert, got '$UI_MODE'"

# === 3) _firstrun_intent изолированно (мок safe_read: последний аргумент = имя переменной) ===
_FEED=(); _FEED_I=0
safe_read() {
    local _v="${!#}"
    printf -v "$_v" '%s' "${_FEED[$_FEED_I]:-}"
    _FEED_I=$(( _FEED_I + 1 ))
    return 0
}
clear_screen() { :; }
sleep() { :; }
send_telegram_notification() { :; }
IS_INTERACTIVE=true

# Enter (пусто) → интент 1 (настроить бэкапы)
_FEED=(""); _FEED_I=0
_firstrun_intent >/dev/null 2>&1
[[ "$_FIRSTRUN_INTENT" == "1" ]] && ok || bad "intent: Enter must mean 1, got '$_FIRSTRUN_INTENT'"
# Мусор → повтор экрана (M21), затем 2 → интент 2 (перенос панели)
_FEED=("9" "2"); _FEED_I=0
_firstrun_intent >/dev/null 2>&1
[[ "$_FIRSTRUN_INTENT" == "2" ]] && ok || bad "intent: garbage then 2 must mean 2, got '$_FIRSTRUN_INTENT'"

# === 4) select_backup_target_firstrun: интент-экран за ручку ===
# Моки окружения: пустой сервер (ни панели, ни бота), тяжёлые шаги заглушены.
detect_panel_root() { return 1; }
resolve_bot_runtime() { return 1; }
discover_stacks() { DISC_PANEL_DB=""; DISC_PANEL_DB_SVC=""; }
_ask_target_location() { :; }
timeout() { shift; "$@"; }
docker() { return 1; }
save_config() { echo "SAVE_CALLED"; }
_quickstart_protect() { echo "QUICKSTART_CALLED"; }

# 4a) Выбор 2 + panel_migrate_in ПРОВАЛЕН (rc=1) → сообщение и обычный поток настройки
panel_migrate_in() { echo "MIGRATE_CALLED"; return 1; }
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; UI_MODE="expert"
_FEED=("2" "1"); _FEED_I=0   # интент=2, затем цель=1 (панель) в обычном потоке
select_backup_target_firstrun > "$TMP_DIR/out_fail.txt" 2>&1; _rc=$?
[[ $_rc -eq 0 ]] && ok || bad "firstrun after failed migrate must not crash, rc=$_rc"
grep -q "MIGRATE_CALLED" "$TMP_DIR/out_fail.txt" && ok \
    || bad "choice 2 must call panel_migrate_in"
grep -q "Перенос не выполнен" "$TMP_DIR/out_fail.txt" && ok \
    || bad "failed migrate must announce fallback to normal setup"
[[ "$BACKUP_TARGET" == "panel" ]] && ok || bad "normal flow after fallback: target '$BACKUP_TARGET'"
[[ "$UI_MODE" == "standard" ]] && ok || bad "first run must set UI_MODE=standard, got '$UI_MODE'"
grep -q "QUICKSTART_CALLED" "$TMP_DIR/out_fail.txt" && ok \
    || bad "firstrun must end with _quickstart_protect"

# 4b) Выбор 2 + panel_migrate_in УСПЕШЕН (rc=0) → panel+standard, выбор цели ПРОПУЩЕН
panel_migrate_in() { echo "MIGRATE_CALLED"; return 0; }
BACKUP_TARGET="bot"; BACKUP_SECONDARY="bot"; UI_MODE="expert"
_FEED=("2"); _FEED_I=0
select_backup_target_firstrun > "$TMP_DIR/out_ok.txt" 2>&1; _rc=$?
[[ $_rc -eq 0 ]] && ok || bad "successful migrate path must rc=0, got $_rc"
grep -q "MIGRATE_CALLED" "$TMP_DIR/out_ok.txt" && ok || bad "success path must call migrate"
[[ "$BACKUP_TARGET" == "panel" && -z "$BACKUP_SECONDARY" ]] && ok \
    || bad "success path must set panel-only target: '$BACKUP_TARGET'+'$BACKUP_SECONDARY'"
[[ "$UI_MODE" == "standard" ]] && ok || bad "success path must set standard, got '$UI_MODE'"
grep -q "Первичная настройка" "$TMP_DIR/out_ok.txt" \
    && bad "success path must SKIP target selection screen" || ok
grep -q "QUICKSTART_CALLED" "$TMP_DIR/out_ok.txt" && ok \
    || bad "success path must go straight to _quickstart_protect"

# 4c) Интент 1 (Enter) → panel_migrate_in НЕ вызывается, обычный поток
panel_migrate_in() { echo "MIGRATE_CALLED"; return 0; }
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; UI_MODE="expert"
_FEED=("" "1"); _FEED_I=0    # интент=Enter(1), затем цель=1 (панель)
select_backup_target_firstrun > "$TMP_DIR/out_int1.txt" 2>&1; _rc=$?
[[ $_rc -eq 0 ]] && ok || bad "intent 1 flow must rc=0, got $_rc"
grep -q "MIGRATE_CALLED" "$TMP_DIR/out_int1.txt" \
    && bad "intent 1 must NOT call panel_migrate_in" || ok
grep -q "Первичная настройка" "$TMP_DIR/out_int1.txt" && ok \
    || bad "intent 1 must show target selection screen"
[[ "$UI_MODE" == "standard" ]] && ok || bad "intent 1 flow must set standard, got '$UI_MODE'"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
