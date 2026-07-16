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

# === 5) Пункт «Перенести панель» в ОБОИХ главных меню + режимо-зависимые под-потоки ===
# Статические проверки исходника (главные меню — top-level while-loop, не функции).
# 5a) standard-меню: минимальное простое меню содержит вызов panel_migrate_in (обработчик п.4).
grep -qE '4\)[[:space:]]*panel_migrate_in' "$SCRIPT" && ok \
    || bad "standard menu must dispatch panel_migrate_in on choice 4"
# 5b) expert-меню: case-ветка "8) panel_migrate_in" (после удаления дубля «Что бэкапить» renumber 9→8).
# После вырезания «Обновить бота» пункты сдвинулись: 6=обновления скрипта, 7=перенос.
grep -qE '7\)[[:space:]]*panel_migrate_in' "$SCRIPT" && ok \
    || bad "expert menu must dispatch panel_migrate_in on choice 7"
# 5c) простой бэкап-пункт (п.1) зовёт create_backup_dispatch "full" НАПРЯМУЮ,
#     а не через menu_manual_backup. Проверяем case-ветку "1) create_backup_dispatch \"full\"".
grep -qE '1\)[[:space:]]*create_backup_dispatch[[:space:]]+"full";[[:space:]]*_post_backup_prompt[[:space:]]+"full"' "$SCRIPT" && ok \
    || bad "standard menu choice 1 must call create_backup_dispatch \"full\" directly"
# 5d) L8: menu_automation_simple УДАЛЁН (был мёртвым кодом — standard-меню не имеет пункта
#     «Расписание», планирование идёт через мастер _quickstart_protect; его disable сносил ВСЕ
#     LAZARUS-задачи). Проверяем, что функция удалена и standard-планирование живёт в мастере.
grep -qE 'menu_automation_simple\(\)' "$SCRIPT" && bad "L8: menu_automation_simple должна быть удалена (мёртвый код)" || ok
grep -qE '_quickstart_protect' "$SCRIPT" && ok || bad "standard-планирование должно идти через мастер _quickstart_protect"
# 5e) cleanup_old_backups имеет ветку по UI_MODE (краткий вывод в standard).
if grep -n 'cleanup_old_backups()' "$SCRIPT" >/dev/null; then
    _cl_start=$(grep -n 'cleanup_old_backups()' "$SCRIPT" | head -1 | cut -d: -f1)
    _cl_end=$(( _cl_start + 200 ))
    if sed -n "${_cl_start},${_cl_end}p" "$SCRIPT" | grep -qE 'UI_MODE.*standard'; then ok
    else bad "cleanup_old_backups must branch on UI_MODE==standard"; fi
else
    bad "cleanup_old_backups() not found"
fi

# 5f) L5: Стандартный режим показывает уведомление об обновлении (раньше блок был недостижим
#     из-за 'continue' → новичок не узнавал о новой версии). Ищем строку внутри standard-экрана.
grep -qE 'Доступно обновление: \$\{VERSION\}' "$SCRIPT" && ok \
    || bad "L5: стандартный режим должен показывать «Доступно обновление» при UPDATE_AVAILABLE"

# 5g) Обновление бота ВЫРЕЗАНО из скрипта целиком (решение владельца): ни функций,
#     ни пункта меню, ни рабочего CLI. Команды upgrade дают явный отказ (не молчат).
grep -qE 'SHOW_BOT_UPDATE|auto_update_bot\(\)|^update_bot\(\)|download_bot_release\(\)' "$SCRIPT" \
    && bad "bot-update должен быть вырезан (найдены остатки)" || ok
grep -qE 'Обновление бота удалено из lazarus' "$SCRIPT" && ok \
    || bad "CLI 'bot upgrade' должен давать явный отказ с объяснением"
# Пункт 6 эксперт-меню теперь — «Обновления скрипта» (перенумерация после вырезания).
grep -qE '6\)\s+check_for_updates' "$SCRIPT" && ok || bad "пункт 6 эксперт-меню должен вести в check_for_updates"
grep -qE '7\)\s+panel_migrate_in' "$SCRIPT" && ok || bad "пункт 7 эксперт-меню должен вести в panel_migrate_in"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
