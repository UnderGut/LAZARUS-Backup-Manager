#!/usr/bin/env bash
# Регресс-тесты 6.0.3(bot): операции бота на смешанном сервере (панель + /opt/rwp-shop из 6 сервисов).
#  1) scan_system_for_bot: БД/инфраструктура/одноразовые `compose run` не становятся «ботом» ни среди
#     живых, ни среди остановленных; панельные исключения работают и для остановленных; проект,
#     известный только по соседям, — кандидат с пустым app (не догадка).
#  2) resolve_bot_runtime: вторая линия — RB_APP из forecast/db перевыводится; запасной выбор
#     через compose ps: сначала живые, потом -a, без oneoff.
#  3) bot_up: статус конкретного контейнера; поднимается ТОЛЬКО его сервис (up -d --no-recreate).
#  4) bot_down: stop ТОЛЬКО сервиса бота, соседи и БД живы; сервис не определён — отказ.
#  5) bot_status: имена из BOT_CONTAINER_NAME/DB_CONTAINER_NAME, печать имён.
#  6) _ask_target_location: резолвер вместо скана с ключами панели; Enter = прежний валидный путь;
#     пустой ввод не затирает канон; панельные имена не попадают в канон.
#  7) menu_backup_target → «2. Бот»: панельный остаток (MAX_FILE_SIZE_MB=0, DB_NAME, remnawave*)
#     не пишется в config.env; «3. Панель + бот» — как раньше.
#  8) load_or_create_config (bot-режим): BOT_CONTAINER_NAME=remnawave на диске лечится на старте.
#  9) compose-проход: 4 имени, -prune каталогов LAZARUS, одиночный кандидат = FOUND_PATH с меткой
#     догадки; detect_bot_installation / check_config_mismatch в неинтерактиве догадку не применяют.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lzbot603.XXXXXX")

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
trap 'rm -rf "$T"' EXIT
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
DEBUG_MODE=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
send_telegram_notification() { :; }
debug_log() { :; }
sleep() { :; }
timeout() { shift; "$@"; }
clear_screen() { :; }
_print_targets_summary() { :; }
_print_projects_note() { :; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

INSTALL_DIR="$T/opt/lazarus-backup"; BACKUP_DIR="$INSTALL_DIR/backup"; mkdir -p "$BACKUP_DIR"
CONFIG_FILE="$INSTALL_DIR/config.env"
PANEL_DIR="$T/opt/remnawave"; BOT_DIR="$T/opt/rwp-shop"
mkdir -p "$PANEL_DIR" "$BOT_DIR" "$T/home" "$T/root"
cat > "$PANEL_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave:
    image: remnawave/backend:2
  remnawave-db:
    image: postgres:18.4
    container_name: 'remnawave-db'
EOF
cat > "$BOT_DIR/docker-compose.yml" <<'EOF'
services:
  rwp_shop:
    image: registry.rwp.rw/jesus/rwp-shop:dev
    container_name: rwp_shop
  db:
    image: postgres:18.4
    container_name: rwp_shop_db
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
EOF

_panel_root_now() { echo "$PANEL_DIR"; }
detect_panel_root() { echo "$PANEL_DIR"; }
PANEL_PATH="$PANEL_DIR"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"; DISC_PANEL_APP=""
# compose-проход сканирует /opt /home /root — уводим в песочницу
FIND_ROOT="$T"
find() { if [[ "$1" == /opt ]]; then shift 3; command find "$FIND_ROOT/opt" "$FIND_ROOT/home" "$FIND_ROOT/root" "$@"; else command find "$@"; fi; }

# ------------------------------------------------------------------ мок docker (состояние в файлах:
# команды бота работают в сабшеллах, изменения up/stop должны переживать их)
DK="$T/dk"; mkdir -p "$DK"
dk_reset() { rm -f "$DK"/*; : > "$T/dk.order"; : > "$T/calls"; }
dk_add() { # name image dir service state [oneoff] [health]; порядок добавления = порядок `docker ps` (новейший первым)
    printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "${6:-False}" "${7:-}" > "$DK/$1"; echo "$1" >> "$T/dk.order"
}
dk_get() { [[ -n "$1" && -f "$DK/$1" ]] || return 1; IFS='|' read -r D_IMG D_DIR D_SVC D_ST D_ONE D_HL < "$DK/$1"; }
dk_set_state() { dk_get "$1" || return 1; printf '%s|%s|%s|%s|%s|%s\n' "$D_IMG" "$D_DIR" "$D_SVC" "$2" "$D_ONE" "$D_HL" > "$DK/$1"; }
dk_state() { dk_get "$1" && echo "$D_ST"; }
dk_fmt() { # подстановка go-template полей для контейнера $2
    local f="$1" n="$2" run="false" upst
    [[ "$D_ST" == "running" ]] && run="true"
    [[ "$D_ST" == "running" ]] && upst="Up 3 days" || upst="Exited (0) 1 hour ago"
    local l_one1='{{.Label "com.docker.compose.oneoff"}}' l_one2='{{ index .Config.Labels "com.docker.compose.oneoff" }}'
    local l_wd1='{{.Label "com.docker.compose.project.working_dir"}}' l_wd2='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
    local l_svc='{{ index .Config.Labels "com.docker.compose.service" }}'
    f="${f//"$l_one1"/$D_ONE}"; f="${f//"$l_one2"/$D_ONE}"
    f="${f//"$l_wd1"/$D_DIR}"; f="${f//"$l_wd2"/$D_DIR}"; f="${f//"$l_svc"/$D_SVC}"
    f="${f//'{{.Names}}'/$n}"; f="${f//'{{.Name}}'/$n}"
    f="${f//'{{.Image}}'/$D_IMG}"; f="${f//'{{.Config.Image}}'/$D_IMG}"
    f="${f//'{{.State.Status}}'/$D_ST}"; f="${f//'{{.State.Running}}'/$run}"; f="${f//'{{.State}}'/$D_ST}"
    f="${f//'{{.State.Health.Status}}'/$D_HL}"; f="${f//'{{.Service}}'/$D_SVC}"; f="${f//'{{.Status}}'/$upst}"
    printf '%s\n' "$f" | sed -E 's/\{\{[^}]*\}\}//g'
}
docker() {
    local a="$1"; shift
    case "$a" in
        container) docker "$@"; return ;;
        info) return 0 ;;
        inspect)
            local fmt="" n=""
            case "$1" in
                --format|-f) fmt="$2"; n="$3" ;;
                --format=*)  fmt="${1#--format=}"; n="$2" ;;
                *) n="$1" ;;
            esac
            dk_get "$n" || return 1
            [[ -z "$fmt" ]] && { echo '[{}]'; return 0; }
            dk_fmt "$fmt" "$n"; return 0 ;;
        ps)
            local all=0 fmt="" n
            while [[ $# -gt 0 ]]; do case "$1" in -a|--all) all=1 ;; --format) fmt="$2"; shift ;; esac; shift; done
            while IFS= read -r n; do
                dk_get "$n" || continue
                [[ $all -eq 0 && "$D_ST" != "running" ]] && continue
                dk_fmt "$fmt" "$n"
            done < "$T/dk.order"
            return 0 ;;
        compose)
            local sub="$1"; shift
            case "$sub" in
                ps)
                    local all=0 fmt="" svc="" n
                    while [[ $# -gt 0 ]]; do case "$1" in -a|--all) all=1 ;; --format) fmt="$2"; shift ;; -*) ;; *) svc="$1" ;; esac; shift; done
                    while IFS= read -r n; do
                        dk_get "$n" || continue
                        _same_path "$D_DIR" "$PWD" || continue
                        [[ $all -eq 0 && "$D_ST" != "running" ]] && continue
                        [[ -n "$svc" && "$D_SVC" != "$svc" ]] && continue
                        dk_fmt "$fmt" "$n"
                    done < "$T/dk.order"
                    return 0 ;;
                up|stop|down|start|restart|pull)
                    echo "compose $sub $*" >> "$T/calls"
                    local svc="" x n
                    for x in "$@"; do [[ "$x" != -* ]] && svc="$x"; done
                    while IFS= read -r n; do
                        dk_get "$n" || continue
                        _same_path "$D_DIR" "$PWD" || continue
                        [[ -n "$svc" && "$D_SVC" != "$svc" ]] && continue
                        [[ "$D_ONE" == "True" ]] && continue   # compose up/stop не трогают одноразовые run
                        case "$sub" in
                            up|start|restart) dk_set_state "$n" running ;;
                            stop) dk_set_state "$n" exited ;;
                            down) rm -f "$DK/$n" ;;
                        esac
                    done < "$T/dk.order"
                    return 0 ;;
            esac
            return 0 ;;
        *) return 0 ;;
    esac
}

# Живой стек как в проде (новейший первым). rwp_shop в состоянии $1.
prod_stack() {
    dk_reset
    dk_add rwp_shop_forecast "registry.rwp.rw/jesus/rwp-shop-forecast:1.1.0" "$BOT_DIR" forecast running False healthy
    dk_add remnawave-subscription-page "remnawave/subscription-page:latest" "$BOT_DIR" remnawave-subscription-page running
    dk_add xray-checker "kutovoys/xray-checker:latest" "$BOT_DIR" xray-checker running
    dk_add rwp_shop_kb_db "pgvector/pgvector:pg18" "$BOT_DIR" kb_db running False healthy
    dk_add rwp_shop_db "postgres:18.4" "$BOT_DIR" db "${2:-running}" False healthy
    dk_add rwp-shop-rwp_shop-run-3f2a "registry.rwp.rw/jesus/rwp-shop:dev" "$BOT_DIR" rwp_shop exited True
    dk_add rwp_shop "registry.rwp.rw/jesus/rwp-shop:dev" "$BOT_DIR" rwp_shop "$1" False healthy
    dk_add remnawave "remnawave/backend:2" "$PANEL_DIR" remnawave running
    dk_add remnawave-db "postgres:18.4" "$PANEL_DIR" remnawave-db running
    dk_add remnawave-migrate-old "remnawave/backend:2" "$PANEL_DIR" migrate exited
}
# Контекст «процесс стартовал с панелью (both)»: рабочие bot-переменные затёрты panel-resolve.
both_ctx() {
    BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"; _BOTRT_FORCED=0
    _CANON_BOT_PATH="$BOT_DIR"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
    _CANON_DB_SERVICE="db"; _CANON_DB_NAME=""; _CANON_DB_USER="postgres"; _CANON_MAX_FILE_SIZE_MB="1"
    PANEL_DB_NAME="panel_db"; MAX_FILE_SIZE_MB="1"; DB_NAME=""; DB_USER="postgres"
    resolve_backup_target
}
BOT_KW="${BOT_KEYWORDS_DEFAULT[*]}"

# ============================================================ 1) scan_system_for_bot
prod_stack exited
KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}"); SCAN_ALLOW_LABEL_FALLBACK=0
scan_system_for_bot
[[ "$FOUND_PATH" == "$BOT_DIR" && "$FOUND_BOT" == "rwp_shop" ]] && ok \
    || bad "1a бот остановлен, соседи живы → rwp_shop, got path='$FOUND_PATH' bot='$FOUND_BOT' all=(${FOUND_BOTS[*]})"
[[ " ${FOUND_BOTS[*]} " != *" rwp_shop_db "* && " ${FOUND_BOTS[*]} " != *"forecast"* && " ${FOUND_BOTS[*]} " != *"-run-"* ]] && ok \
    || bad "1b БД/forecast/-run- не кандидаты: (${FOUND_BOTS[*]})"
[[ "${FOUND_VIA_COMPOSE:-0}" == "0" ]] && ok || bad "1c контейнерная находка — не догадка"

prod_stack running
scan_system_for_bot
[[ "$FOUND_BOT" == "rwp_shop" && ${#FOUND_BOTS[@]} -eq 1 ]] && ok \
    || bad "1d бот жив, forecast новейший → ровно rwp_shop, got (${FOUND_BOTS[*]})"

# остановленный контейнер панели при панельных ключах не становится «ботом»
prod_stack running
KEYWORDS=("${PANEL_KEYWORDS[@]}")
scan_system_for_bot
_hit_panel=0; for _p in "${FOUND_PATHS[@]}"; do _same_path "$_p" "$PANEL_DIR" && _hit_panel=1; done
[[ $_hit_panel -eq 0 && " ${FOUND_BOTS[*]} " != *"remnawave-migrate-old"* ]] && ok \
    || bad "1e exited remnawave-migrate-old (образ backend) исключён в проходе по остановленным: (${FOUND_PATHS[*]}|${FOUND_BOTS[*]})"
KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}")

# контейнер бота удалён, соседи живы: путь известен по соседям — кандидат без app, не догадка
prod_stack running; rm -f "$DK/rwp_shop"
scan_system_for_bot
[[ "$FOUND_PATH" == "$BOT_DIR" && -z "$FOUND_BOT" && "${FOUND_VIA_COMPOSE:-0}" == "0" ]] && ok \
    || bad "1f проект по соседям: path='$FOUND_PATH' bot='$FOUND_BOT' compose_guess=${FOUND_VIA_COMPOSE:-}"

# предикат напрямую
_is_bot_infra_container rwp_shop "registry.rwp.rw/jesus/rwp-shop:dev" False && bad "1g rwp_shop — не инфраструктура" || ok
_is_bot_infra_container dbot "x/dbot:1" && bad "1h 'dbot' без границы слова — не БД" || ok
_is_bot_infra_container shop-pg "postgres:18" && ok || bad "1i образ postgres → инфраструктура"
_is_bot_infra_container rwp_shop_forecast "" && ok || bad "1j forecast по имени → инфраструктура"
_is_bot_infra_container "myproj-app-run-9c1d" "" && ok || bad "1k '-run-' → одноразовый"
_is_bot_infra_container "myproj-app" "" True && ok || bad "1l oneoff=True → одноразовый"

# ============================================================ 2) resolve_bot_runtime
prod_stack exited
both_ctx
KEYWORDS=("${PANEL_KEYWORDS[@]}")
if resolve_bot_runtime; then
    [[ "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" && "$RB_DB" == "rwp_shop_db" ]] && ok \
        || bad "2a both-режим, бот остановлен: path=$RB_PATH app=$RB_APP db=$RB_DB"
else bad "2a resolve должен найти бота"; fi
[[ "${KEYWORDS[*]}" == "${PANEL_KEYWORDS[*]}" ]] && ok || bad "2b KEYWORDS вернулись к панельным: '${KEYWORDS[*]}'"

# вторая линия: RB_APP пришёл из снимка/скана как forecast → перевыводится в rwp_shop (остановлен → -a)
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop_forecast"; DB_CONTAINER_NAME="rwp_shop_db"
resolve_bot_runtime
[[ "$RB_APP" == "rwp_shop" ]] && ok || bad "2c RB_APP=forecast из конфига → rwp_shop, got '$RB_APP'"
BOT_CONTAINER_NAME="rwp_shop_db"
resolve_bot_runtime
[[ "$RB_APP" == "rwp_shop" ]] && ok || bad "2d RB_APP=БД → rwp_shop, got '$RB_APP'"

# кастомные имена: app остановлен, перед ним одноразовый run; живы только БД → app через ps -a без oneoff
P2="$T/opt/myproj"; mkdir -p "$P2"
printf 'services:\n  app:\n    image: acme/shop-app:2\n  postgres:\n    image: postgres:17\n' > "$P2/compose.yml"
dk_reset
dk_add myproj-postgres-1 "postgres:17" "$P2" postgres running
dk_add myproj-app-run-1a2b "acme/shop-app:2" "$P2" app exited True
dk_add myproj-app-1 "acme/shop-app:2" "$P2" app exited
BOT_PATH="$P2"; BOT_CONTAINER_NAME="myproj-postgres-1"; DB_CONTAINER_NAME=""
resolve_bot_runtime
[[ "$RB_PATH" == "$P2" && "$RB_APP" == "myproj-app-1" ]] && ok \
    || bad "2e кастомный стек: app через ps -a без oneoff, got path=$RB_PATH app=$RB_APP db=$RB_DB"
# живой app приоритетнее остановленного
dk_add myproj-app-2 "acme/shop-app:2" "$P2" app running
resolve_bot_runtime
[[ "$RB_APP" == "myproj-app-2" ]] && ok || bad "2f сначала работающие: got '$RB_APP'"

# ============================================================ 3) bot_up
prod_stack exited
both_ctx
out=$( bot_up 2>&1 | strip ); rc=$?
[[ "$out" != *"уже запущен"* ]] && ok || bad "3a бот остановлен, соседи живы — не «уже запущен»: $out"
grep -qx 'compose up -d --no-recreate rwp_shop' "$T/calls" && ok || bad "3b поднят только сервис бота без пересоздания: $(cat "$T/calls")"
[[ $(wc -l < "$T/calls") -eq 1 ]] && ok || bad "3c ровно один compose-вызов: $(cat "$T/calls")"
[[ "$(dk_state rwp_shop)" == "running" && "$out" == *"Бот запущен: rwp_shop"* ]] && ok || bad "3d пост-проверка по контейнеру: $out"

# бот уже работает → ничего не делаем
prod_stack running; both_ctx
out=$( bot_up 2>&1 | strip )
[[ "$out" == *"Бот уже запущен: rwp_shop"* && ! -s "$T/calls" ]] && ok || bad "3e бот жив → «уже запущен», без compose: $out / $(cat "$T/calls")"

# контейнер удалён прежним `compose down`: сервис из compose-файла по имени
prod_stack running; rm -f "$DK/rwp_shop"; both_ctx
out=$( bot_up 2>&1 | strip )
grep -qx 'compose up -d --no-recreate rwp_shop' "$T/calls" && ok || bad "3f контейнера нет → up только сервиса из compose: $(cat "$T/calls") / $out"

# сервис не определить → отказ, весь проект не поднимаем
prod_stack exited
_sv_bind=$(declare -f bind_bot_runtime_or_fail)
bind_bot_runtime_or_fail() { BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="ghost_bot"; DB_CONTAINER_NAME="rwp_shop_db"; return 0; }
out=$( bot_up 2>&1 | strip ); rc=$?
[[ ! -s "$T/calls" && "$out" == *"compose-сервис"* ]] && ok || bad "3g сервис не найден → отказ без compose up: $(cat "$T/calls") / $out"
eval "$_sv_bind"

# _bot_compose_service: container_name ≠ имя сервиса; чужой проект — метке не верим
P3="$T/opt/p3"; mkdir -p "$P3"
cat > "$P3/docker-compose.yml" <<'EOF'
services:
    app:
        image: acme/bot:1
        container_name: "custom_bot"
    db:
        image: postgres:17
EOF
dk_reset
BOT_PATH="$P3"
[[ "$(_bot_compose_service custom_bot)" == "app" ]] && ok || bad "3h контейнера нет: сервис по container_name = app, got '$(_bot_compose_service custom_bot)'"
dk_add alien "acme/bot:1" "$BOT_DIR" app running
_bot_compose_service alien >/dev/null && bad "3i контейнер чужого проекта → сервис не определён" || ok

# ============================================================ 4) bot_down
prod_stack running; both_ctx
out=$( bot_down 2>&1 | strip )
grep -qx 'compose stop rwp_shop' "$T/calls" && ok || bad "4a stop только сервиса бота: $(cat "$T/calls")"
! grep -q 'compose down' "$T/calls" && ok || bad "4b compose down запрещён: $(cat "$T/calls")"
[[ "$(dk_state rwp_shop)" == "exited" ]] && ok || bad "4c бот остановлен"
[[ "$(dk_state remnawave-subscription-page)" == "running" && "$(dk_state rwp_shop_db)" == "running" \
   && "$(dk_state xray-checker)" == "running" && "$(dk_state rwp_shop_kb_db)" == "running" ]] && ok \
    || bad "4d выдача подписок, xray-checker и обе БД живы"
[[ "$out" == *"Бот остановлен: rwp_shop"* ]] && ok || bad "4e сообщение с именем: $out"

# бот уже остановлен, соседи живы → ничего не трогаем
prod_stack exited; both_ctx
out=$( bot_down 2>&1 | strip )
[[ ! -s "$T/calls" && "$out" == *"уже остановлен: rwp_shop"* ]] && ok || bad "4f бот остановлен → без compose: $(cat "$T/calls") / $out"

# сервис не определить → отказ (не down всего проекта)
prod_stack running
dk_add loner "acme/bot:1" "" "" running
bind_bot_runtime_or_fail() { BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="loner"; DB_CONTAINER_NAME="rwp_shop_db"; return 0; }
out=$( bot_down 2>&1 | strip ); rc=$?
[[ ! -s "$T/calls" && $rc -ne 0 && "$out" == *"ERROR"* ]] && ok || bad "4g сервис не определён → отказ rc!=0: rc=$rc $(cat "$T/calls") / $out"
# привязка указала на БД → отказ, БД не останавливаем
bind_bot_runtime_or_fail() { BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop_db"; DB_CONTAINER_NAME="rwp_shop_db"; return 0; }
: > "$T/calls"
out=$( bot_down 2>&1 | strip ); rc=$?
[[ ! -s "$T/calls" && "$(dk_state rwp_shop_db)" == "running" ]] && ok || bad "4h контейнер БД в роли бота → отказ: $(cat "$T/calls") / $out"
eval "$_sv_bind"

# ============================================================ 5) bot_status
prod_stack exited; both_ctx
out=$( bot_status 2>&1 | strip )
_bl=$(printf '%s\n' "$out" | grep 'Контейнер бота:')
_dl=$(printf '%s\n' "$out" | grep 'Контейнер БД:')
[[ "$_bl" == *"○ exited"* && "$_bl" == *"(rwp_shop)"* && "$_bl" != *"Running"* ]] && ok || bad "5a бот остановлен → ○ exited (rwp_shop): '$_bl'"
[[ "$_dl" == *"● Running"* && "$_dl" == *"(rwp_shop_db)"* ]] && ok || bad "5b БД бота: '$_dl'"
prod_stack running exited; both_ctx
out=$( bot_status 2>&1 | strip )
_dl=$(printf '%s\n' "$out" | grep 'Контейнер БД:')
[[ "$_dl" == *"○ exited"* && "$_dl" == *"(rwp_shop_db)"* ]] && ok || bad "5c основная БД остановлена, kb_db жива → ○ exited: '$_dl'"

# ============================================================ 6) _ask_target_location (локальный бот)
ANS=(); SR_CALLS=0
safe_read() {
    SR_CALLS=$(( SR_CALLS + 1 )); [[ $SR_CALLS -gt 40 ]] && return 1
    local _v="${!#}"
    if [[ ${#ANS[@]} -eq 0 ]]; then printf -v "$_v" '%s' ""; return 1; fi
    printf -v "$_v" '%s' "${ANS[0]}"; ANS=("${ANS[@]:1}"); return 0
}
prod_stack running; both_ctx
[[ "${KEYWORDS[*]}" == "${PANEL_KEYWORDS[*]}" && "$BOT_CONTAINER_NAME" == "remnawave" ]] || bad "6-pre panel-resolve затёр bot-переменные"
ANS=(1); SR_CALLS=0
_ask_target_location bot > "$T/out6" 2>&1
[[ "$BOT_PATH" == "$BOT_DIR" && "$_CANON_BOT_PATH" == "$BOT_DIR" ]] && ok || bad "6a бот найден резолвером: BOT_PATH='$BOT_PATH' canon='$_CANON_BOT_PATH'"
[[ "$BOT_CONTAINER_NAME" == "rwp_shop" && "$_CANON_BOT_CONTAINER" == "rwp_shop" && "$_CANON_DB_CONTAINER" == "rwp_shop_db" ]] && ok \
    || bad "6b имена бота: app='$BOT_CONTAINER_NAME' canon_app='$_CANON_BOT_CONTAINER' canon_db='$_CANON_DB_CONTAINER'"
[[ "${KEYWORDS[*]}" == "${PANEL_KEYWORDS[*]}" ]] && ok || bad "6c KEYWORDS вызывателя не тронуты: '${KEYWORDS[*]}'"

# бот не найден: Enter = прежний валидный путь; панельное имя не уходит в канон
CUSTOM="$T/srv/mybot"; mkdir -p "$CUSTOM"; printf 'services:\n  app:\n    image: acme/app:1\n' > "$CUSTOM/docker-compose.yml"
_sv_rbr=$(declare -f resolve_bot_runtime)
resolve_bot_runtime() { return 1; }
both_ctx; _CANON_BOT_PATH="$CUSTOM"
# ответ после Enter обязан уйти в вопрос о БД (без дефолта он стал бы путём)
ANS=(1 "" "custom_db"); SR_CALLS=0
_ask_target_location bot > "$T/out6" 2>&1
[[ "$BOT_PATH" == "$CUSTOM" && "$_CANON_BOT_PATH" == "$CUSTOM" && "$DB_CONTAINER_NAME" == "custom_db" ]] && ok \
    || bad "6d Enter = прежний путь: BOT_PATH='$BOT_PATH' canon='$_CANON_BOT_PATH' db='$DB_CONTAINER_NAME'"
! grep -q 'Укажите путь' "$T/out6" && ok || bad "6d2 валидный прежний путь — без переспроса"
[[ "$_CANON_BOT_CONTAINER" == "rwp_shop" ]] && ok || bad "6e 'remnawave' не перенесён в канон: '$_CANON_BOT_CONTAINER'"
# прежний путь невалиден: Enter → переспрос, затем введённый путь
both_ctx; _CANON_BOT_PATH="$T/nonexistent"
ANS=(1 "" "$CUSTOM" ""); SR_CALLS=0
_ask_target_location bot > "$T/out6" 2>&1
[[ "$BOT_PATH" == "$CUSTOM" ]] && ok || bad "6f пустой ввод без дефолта → переспрос: BOT_PATH='$BOT_PATH'"
grep -q 'Укажите путь' "$T/out6" && ok || bad "6g сообщение о переспросе"
# путь панели отвергается
both_ctx; _CANON_BOT_PATH=""
ANS=(1 "$PANEL_DIR" "$CUSTOM" ""); SR_CALLS=0
_ask_target_location bot > "$T/out6" 2>&1
[[ "$BOT_PATH" == "$CUSTOM" ]] && ok || bad "6h каталог панели отвергнут: BOT_PATH='$BOT_PATH'"
# EOF без дефолта: канон не затирается, рабочий путь = канон (не путь панели)
both_ctx; _CANON_BOT_PATH="$T/kept-bot"
ANS=(1); SR_CALLS=0
_ask_target_location bot > "$T/out6" 2>&1
[[ "$_CANON_BOT_PATH" == "$T/kept-bot" && "$BOT_PATH" == "$T/kept-bot" && $SR_CALLS -lt 40 ]] && ok \
    || bad "6i EOF: canon='$_CANON_BOT_PATH' BOT_PATH='$BOT_PATH' calls=$SR_CALLS"
eval "$_sv_rbr"

# ============================================================ 7) menu_backup_target
cfg() { grep -E "^$1=" "$CONFIG_FILE" | head -1 | cut -d'"' -f2; }
# (а) панель → «2. Бот», бот найден
prod_stack running; both_ctx; BACKUP_SECONDARY=""; rm -f "$CONFIG_FILE"
[[ "$MAX_FILE_SIZE_MB" == "0" && "$DB_NAME" == "panel_db" ]] || bad "7-pre panel-resolve: MAX=$MAX_FILE_SIZE_MB DB_NAME=$DB_NAME"
ANS=(2 1 ""); SR_CALLS=0
menu_backup_target > "$T/out7" 2>&1
! grep -q '^MAX_FILE_SIZE_MB="0"' "$CONFIG_FILE" && ok || bad "7a MAX_FILE_SIZE_MB=0 панели не записан в bot-конфиг"
! grep -q '^DB_NAME="panel_db"' "$CONFIG_FILE" && ok || bad "7b DB_NAME панели не записан"
[[ "$MAX_FILE_SIZE_MB" == "1" && -z "$DB_NAME" ]] && ok || bad "7c в памяти: MAX=$MAX_FILE_SIZE_MB DB_NAME='$DB_NAME'"
[[ "$(cfg BACKUP_TARGET)" == "bot" && "$(cfg BOT_CONTAINER_NAME)" == "rwp_shop" && "$(cfg DB_CONTAINER_NAME)" == "rwp_shop_db" ]] && ok \
    || bad "7d цель/имена: t=$(cfg BACKUP_TARGET) bc=$(cfg BOT_CONTAINER_NAME) dc=$(cfg DB_CONTAINER_NAME)"
# (б) бот не найден, путь вручную: рабочий BOT_CONTAINER_NAME=remnawave не пишется
resolve_bot_runtime() { return 1; }
both_ctx; BACKUP_SECONDARY=""; rm -f "$CONFIG_FILE"
ANS=(2 1 "$BOT_DIR" "" ""); SR_CALLS=0
menu_backup_target > "$T/out7" 2>&1
[[ "$(cfg BOT_CONTAINER_NAME)" == "rwp_shop" && "$(cfg BOT_PATH)" == "$BOT_DIR" ]] && ok \
    || bad "7e ручной путь: bc='$(cfg BOT_CONTAINER_NAME)' bp='$(cfg BOT_PATH)'"
# (в) резолвер не дал БД: панельный remnawave-db не пишется и не попадает в канон
resolve_bot_runtime() { RB_PATH="$BOT_DIR"; RB_APP="rwp_shop"; RB_DB=""; return 0; }
both_ctx; BACKUP_SECONDARY=""; rm -f "$CONFIG_FILE"
ANS=(2 1 ""); SR_CALLS=0
menu_backup_target > "$T/out7" 2>&1
[[ "$(cfg DB_CONTAINER_NAME)" == "rwp_shop_db" && "$_CANON_DB_CONTAINER" == "rwp_shop_db" ]] && ok \
    || bad "7f DB_CONTAINER_NAME: cfg='$(cfg DB_CONTAINER_NAME)' canon='$_CANON_DB_CONTAINER'"
eval "$_sv_rbr"
# (г) «3. Панель + бот» — прежнее поведение (канон, без bot-остатков панели)
prod_stack running; both_ctx; BACKUP_SECONDARY=""; rm -f "$CONFIG_FILE"
ANS=(3 1 "" 1 ""); SR_CALLS=0
menu_backup_target > "$T/out7" 2>&1
[[ "$(cfg BACKUP_TARGET)" == "panel" && "$(cfg BACKUP_SECONDARY)" == "bot" && "$(cfg BOT_CONTAINER_NAME)" == "rwp_shop" && "$(cfg BOT_PATH)" == "$BOT_DIR" ]] && ok \
    || bad "7g обе цели: t=$(cfg BACKUP_TARGET) s=$(cfg BACKUP_SECONDARY) bc=$(cfg BOT_CONTAINER_NAME) bp=$(cfg BOT_PATH)"
! grep -q '^MAX_FILE_SIZE_MB="0"' "$CONFIG_FILE" && ok || bad "7h обе цели: MAX_FILE_SIZE_MB панели не записан"

# ============================================================ 8) load_or_create_config: bot-режим, порча на диске
prod_stack running
IS_INTERACTIVE="false"; AUTO_CONFIRM="false"; BACKUP_PASSWORD=""; BACKUP_PASSWORD_FILE="$INSTALL_DIR/.password"
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; PANEL_DB_NAME=""; IGNORE_MISMATCH="false"
KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}")   # как в свежем процессе (секции 6–7 оставили панельные)
cat > "$CONFIG_FILE" <<EOF
BACKUP_TARGET="bot"
BOT_PATH="$BOT_DIR"
BOT_CONTAINER_NAME="remnawave"
DB_CONTAINER_NAME="rwp_shop_db"
BACKUP_LOG_FILES="false"
EOF
unset _CANON_SNAPSHOT_TAKEN
load_or_create_config > "$T/out8" 2>&1
[[ "$(cfg BOT_CONTAINER_NAME)" != "remnawave" ]] && ok || bad "8a 'remnawave' в bot-режиме вычищен с диска"
[[ "$BOT_CONTAINER_NAME" == "rwp_shop" && "$(cfg BOT_CONTAINER_NAME)" == "rwp_shop" ]] && ok \
    || bad "8b авто-поиск заполнил бота: mem='$BOT_CONTAINER_NAME' cfg='$(cfg BOT_CONTAINER_NAME)'"
AUTO_CONFIRM=true

# ============================================================ 9) compose-проход и догадка
S9="$T/s9"; FIND_ROOT="$S9"
INSTALL_DIR="$S9/opt/lazarus-backup"; BACKUP_DIR="$INSTALL_DIR/backup"
KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}"); SCAN_ALLOW_LABEL_FALLBACK=0
s9_reset() { rm -rf "$S9"; mkdir -p "$S9/opt/mybot" "$S9/home" "$S9/root" "$BACKUP_DIR"; dk_reset; }
for _nm in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    s9_reset
    printf 'services:\n  shop:\n    image: rwp_shop:7.1\n' > "$S9/opt/mybot/$_nm"
    scan_system_for_bot
    [[ "$FOUND_PATH" == "$S9/opt/mybot" && "$FOUND_VIA_COMPOSE" == "1" ]] && ok \
        || bad "9a $_nm → FOUND_PATH='$FOUND_PATH' guess=$FOUND_VIA_COMPOSE"
done
# копии compose в каталогах LAZARUS (tmp, бэкапы) — не кандидаты
s9_reset; rm -rf "$S9/opt/mybot"
mkdir -p "$INSTALL_DIR/tmp/x" "$BACKUP_DIR/y"
printf 'services:\n  shop:\n    image: rwp_shop:7.1\n' > "$INSTALL_DIR/tmp/x/docker-compose.yml"
printf 'services:\n  shop:\n    image: rwp_shop:7.1\n' > "$BACKUP_DIR/y/docker-compose.yml"
scan_system_for_bot
[[ ${#FOUND_PATHS[@]} -eq 0 ]] && ok || bad "9b каталоги LAZARUS исключены: (${FOUND_PATHS[*]})"

# cron: одиночная догадка не применяется
s9_reset
printf 'services:\n  shop:\n    image: rwp_shop:7.1\n    container_name: rwp_shop_new\n' > "$S9/opt/mybot/docker-compose.yml"
IS_INTERACTIVE="false"; AUTO_CONFIRM="false"; BACKUP_TARGET="bot"; BACKUP_SECONDARY=""
BOT_PATH="$T/old-bot"; BOT_CONTAINER_NAME="ghost"; DB_CONTAINER_NAME=""; rm -f "$CONFIG_FILE"
out=$( detect_bot_installation 2>&1 | strip ); rc=$?
detect_bot_installation > /dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$BOT_PATH" == "$T/old-bot" && "$BOT_CONTAINER_NAME" == "ghost" && ! -f "$CONFIG_FILE" ]] && ok \
    || bad "9c cron: одиночная compose-догадка не применена: rc=$rc BOT_PATH=$BOT_PATH bc=$BOT_CONTAINER_NAME"
[[ "$out" == *"compose-файл"* ]] && ok || bad "9d причина названа: $out"
# cron: две догадки — тоже не применяются
mkdir -p "$S9/root/rwp-shop-old"
printf 'services:\n  shop:\n    image: rwp_shop:6.0\n' > "$S9/root/rwp-shop-old/docker-compose.yml"
detect_bot_installation > /dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$BOT_PATH" == "$T/old-bot" && ! -f "$CONFIG_FILE" ]] && ok \
    || bad "9e cron: несколько compose-догадок не применены: rc=$rc BOT_PATH=$BOT_PATH"
rm -rf "$S9/root/rwp-shop-old"
# cron: check_config_mismatch не делает авто-замену на контейнер из compose-файла
IGNORE_MISMATCH="false"
check_config_mismatch > /dev/null 2>&1
[[ "$BOT_CONTAINER_NAME" == "ghost" && "$BOT_PATH" == "$T/old-bot" && ! -f "$CONFIG_FILE" ]] && ok \
    || bad "9f check_config_mismatch: догадка не применена: bc=$BOT_CONTAINER_NAME path=$BOT_PATH"
# интерактив: спрашиваем с пометкой догадки, согласие применяет
IS_INTERACTIVE="true"; AUTO_CONFIRM="false"
out=$( detect_bot_installation 2>&1 <<< "y" | strip )
detect_bot_installation > /dev/null 2>&1 <<< "y"
[[ "$out" == *"compose-файл без контейнеров"* && "$BOT_PATH" == "$S9/opt/mybot" ]] && ok || bad "9g интерактив: вопрос с пометкой, BOT_PATH='$BOT_PATH'"
IS_INTERACTIVE="false"; AUTO_CONFIRM=true
# при живых контейнерах бота cron по-прежнему применяет находку (прод-путь)
s9_reset; prod_stack exited
BOT_PATH=""; BOT_CONTAINER_NAME="ghost"; DB_CONTAINER_NAME=""; rm -f "$CONFIG_FILE"
check_config_mismatch > /dev/null 2>&1
[[ "$BOT_CONTAINER_NAME" == "rwp_shop" && "$BOT_PATH" == "$BOT_DIR" ]] && ok \
    || bad "9h cron: контейнерная находка применяется, и это rwp_shop, а не БД: bc=$BOT_CONTAINER_NAME path=$BOT_PATH"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
