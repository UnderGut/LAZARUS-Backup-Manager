#!/usr/bin/env bash
# Stack identity layer: _container_role (роль по образу+проекту, не имени из конфига),
# discover_stacks (панель/биллинг/бот), assert_target_identity + assert_safe_db_target
# (отказ по чужому стеку при ЛЮБОМ misconfig), billing auto-discover + role-гарды,
# panel_migrate_in (гарды запуска). Мок docker, реальный скрипт как lib. Counters n_ok/n_err.

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

# --- фейковая ФС ---
PANEL_DIR="$TMP_DIR/opt/remnawave"; BOT_DIR="$TMP_DIR/opt/rwp-shop"
mkdir -p "$PANEL_DIR" "$BOT_DIR"
printf 'services:\n  remnawave:\n    image: remnawave/backend:2\n' > "$PANEL_DIR/docker-compose.yml"
printf 'services:\n  rwp_shop:\n    image: rwp_shop:6.6.0.71\n' > "$BOT_DIR/docker-compose.yml"
_panel_root_now() { echo "$PANEL_DIR"; }
timeout() { shift; "$@"; }

# --- мок docker: таблица контейнеров живого сервера ---
mock_meta() { # name → image|dir|svc|status
    case "$1" in
        remnawave)        echo "remnawave/backend:2|$PANEL_DIR|remnawave|running" ;;
        remnawave-db)     echo "postgres:18.4|$PANEL_DIR|remnawave-db|running" ;;
        remnawave-nginx)  echo "nginx:1.31.2|$PANEL_DIR|remnawave-nginx|running" ;;
        infra-billing)    echo "ghcr.io/mishkatik/infra-billing:latest|$PANEL_DIR|infra-billing|running" ;;
        infra-billing-db) echo "postgres:18.4|$PANEL_DIR|infra-billing-db|running" ;;
        rwp_shop)         echo "rwp_shop:6.6.0.71|$BOT_DIR|rwp_shop|running" ;;
        rwp_shop_db)      echo "postgres:18.4|$BOT_DIR|db|running" ;;
        *) return 1 ;;
    esac
}
MOCK_ALL="remnawave remnawave-db remnawave-nginx infra-billing infra-billing-db rwp_shop rwp_shop_db"
docker() {
    local a="$1"; shift
    case "$a" in
        inspect)
            local fmt="" name=""
            if [[ "$1" == "--format" || "$1" == "-f" ]]; then fmt="$2"; name="$3"; else name="$1"; fi
            local meta; meta=$(mock_meta "$name") || return 1
            local img dir svc st; IFS='|' read -r img dir svc st <<<"$meta"
            [[ -z "$fmt" ]] && { echo "{}"; return 0; }
            case "$fmt" in
                *Config.Image*)  echo "$img|$dir|$svc" ;;
                *State.Status*)  echo "$st" ;;
                *working_dir*)   echo "$dir" ;;
                *) echo "" ;;
            esac ;;
        ps)
            local n meta img dir svc st
            for n in $MOCK_ALL; do
                meta=$(mock_meta "$n"); IFS='|' read -r img dir svc st <<<"$meta"
                # покрывает оба формата: '{{.Names}}' и '{{.Names}}|{{.Image}}[|{{.Label ...}}]'
                if [[ "$*" == *"{{.Image}}"* ]]; then echo "$n|$img|$dir"; else echo "$n"; fi
            done ;;
        *) return 0 ;;
    esac
}

# === 1) _container_role: классификация по образу/проекту ===
PANEL_DB_CONTAINER="remnawave-db"
[[ "$(_container_role remnawave)" == "panel-app" ]] && ok || bad "role(remnawave)=$(_container_role remnawave)"
[[ "$(_container_role remnawave-db)" == "panel-db" ]] && ok || bad "role(remnawave-db)=$(_container_role remnawave-db)"
[[ "$(_container_role remnawave-nginx)" == "panel-svc" ]] && ok || bad "role(nginx)=$(_container_role remnawave-nginx)"
[[ "$(_container_role infra-billing)" == "billing-app" ]] && ok || bad "role(billing-app)=$(_container_role infra-billing)"
[[ "$(_container_role infra-billing-db)" == "billing-db" ]] && ok || bad "role(billing-db)=$(_container_role infra-billing-db)"
[[ "$(_container_role rwp_shop_db)" == "external" ]] && ok || bad "role(rwp_shop_db)=$(_container_role rwp_shop_db)"
[[ "$(_container_role no-such)" == "absent" ]] && ok || bad "role(absent)=$(_container_role no-such)"

# === 2) assert_target_identity: матрица отказов ===
# bot-цель, но БД панели (классический misconfig)
BACKUP_TARGET="bot"; BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="remnawave-db"
assert_target_identity "t" >/dev/null 2>&1 && bad "bot+panel-db must REFUSE" || ok
# bot-цель, но путь = панель (сразу отказ, даже с ботовской БД)
DB_CONTAINER_NAME="rwp_shop_db"; BOT_PATH="$PANEL_DIR"
assert_target_identity "t" >/dev/null 2>&1 && bad "bot+panel-path must REFUSE" || ok
# bot-цель, но app-контейнер панельный
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="remnawave"
assert_target_identity "t" >/dev/null 2>&1 && bad "bot+panel-app must REFUSE" || ok
# bot-цель, но БД = биллинг
BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="infra-billing-db"
assert_target_identity "t" >/dev/null 2>&1 && bad "bot+billing-db must REFUSE" || ok
# корректный бот → ок
DB_CONTAINER_NAME="rwp_shop_db"
assert_target_identity "t" >/dev/null 2>&1 && ok || bad "valid bot must PASS"
# panel-цель, но БД = биллинг (main-db ≠ billing-db!)
BACKUP_TARGET="panel"; BOT_PATH="$PANEL_DIR"; DB_CONTAINER_NAME="infra-billing-db"
assert_target_identity "t" >/dev/null 2>&1 && bad "panel+billing-db must REFUSE" || ok
# panel-цель, но БД бота
DB_CONTAINER_NAME="rwp_shop_db"
assert_target_identity "t" >/dev/null 2>&1 && bad "panel+bot-db must REFUSE" || ok
# panel-цель, путь = каталог БОТА
DB_CONTAINER_NAME="remnawave-db"; BOT_PATH="$BOT_DIR"
assert_target_identity "t" >/dev/null 2>&1 && bad "panel+bot-path must REFUSE" || ok
# корректная панель → ок
BOT_PATH="$PANEL_DIR"
assert_target_identity "t" >/dev/null 2>&1 && ok || bad "valid panel must PASS"
# panel-цель, контейнера ещё нет (fresh server / миграция) → ок
DB_CONTAINER_NAME="not-created-yet"
assert_target_identity "t" >/dev/null 2>&1 && ok || bad "panel+absent must PASS (fresh restore)"

# === 3) assert_safe_db_target: ловит случай, когда working_dir «совпал», но стек чужой ===
# BOT_PATH=панель + DB=remnawave-db при цели bot: старая проверка прошла бы (dir==dir),
# роль-гард обязан отказать.
BACKUP_TARGET="bot"; BOT_PATH="$PANEL_DIR"; DB_CONTAINER_NAME="remnawave-db"
assert_safe_db_target "remnawave-db" "postgres" "postgres" >/dev/null 2>&1 \
    && bad "safe_db_target: bot+remnawave-db (matching dir) must REFUSE" || ok

# === 4) billing: авто-обнаружение + role-гард ===
BACKUP_TARGET="panel"; BOT_PATH="$PANEL_DIR"
# контейнер не настроен → auto-discover по паттерну
PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER=""
_billing_sidecar_active >/dev/null 2>&1
[[ $? -eq 0 && "$PANEL_BILLING_DB_CONTAINER" == "infra-billing-db" ]] && ok \
    || bad "billing auto-discover: got '$PANEL_BILLING_DB_CONTAINER' rc=$?"
# misconfig: главная БД панели в billing-переменной → отказ (auto → rc=1)
PANEL_BILLING_DB_CONTAINER="remnawave-db"
_billing_sidecar_active >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 1 ]] && ok || bad "billing misconfig(auto) must rc=1, got $_rc"
# то же при required → rc=2 (провал бэкапа)
PANEL_BILLING_BACKUP="true"
_billing_sidecar_active >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 2 ]] && ok || bad "billing misconfig(required) must rc=2, got $_rc"
PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"

# === 5) discover_stacks: все три стека найдены ===
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"; KEYWORDS=(rwp_shop)
find_db_container_for_path() { [[ "$1" == "$BOT_DIR" ]] && echo "rwp_shop_db"; }
discover_stacks
[[ "$DISC_PANEL_APP" == "remnawave" && "$DISC_PANEL_DB" == "remnawave-db" ]] && ok \
    || bad "discover panel: app=$DISC_PANEL_APP db=$DISC_PANEL_DB"
[[ "$DISC_BILLING_APP" == "infra-billing" && "$DISC_BILLING_DB" == "infra-billing-db" ]] && ok \
    || bad "discover billing: app=$DISC_BILLING_APP db=$DISC_BILLING_DB"
[[ "$DISC_BOT_DIR" == "$BOT_DIR" && "$DISC_BOT_APP" == "rwp_shop" ]] && ok \
    || bad "discover bot: dir=$DISC_BOT_DIR app=$DISC_BOT_APP"
[[ "$(_same_path "$DISC_PANEL_DIR" "$PANEL_DIR" && echo y)" == "y" ]] && ok || bad "discover panel dir=$DISC_PANEL_DIR"

# === 6) panel_migrate_in: гарды запуска ===
IS_INTERACTIVE=false
panel_migrate_in --from root@1.2.3.4 >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 2 ]] && ok || bad "migrate non-interactive must rc=2, got $_rc"
IS_INTERACTIVE=true; clear_screen() { :; }
panel_migrate_in --bogus x >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 2 ]] && ok || bad "migrate unknown arg must rc=2, got $_rc"
DRY_RUN=true
panel_migrate_in --from root@1.2.3.4 >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 2 ]] && ok || bad "migrate with --dry-run must rc=2, got $_rc"
DRY_RUN=false

# === 7) ANTI-CYCLE (CRIT): detect_panel_root НЕ доверяет PANEL_PATH без панельного compose ===
# (канонические /opt/... в тест-среде отсутствуют — суть ассерта: БОТ-каталог не эхается НИКОГДА)
PANEL_PATH="$BOT_DIR"           # misconfig: PANEL_PATH указывает на БОТА
got=$(detect_panel_root 2>/dev/null || true)
[[ "$got" != "$BOT_DIR" ]] && ok || bad "ANTI-CYCLE: detect must NOT echo bot-dir PANEL_PATH"
# панельный PANEL_PATH (compose декларирует панель) — принимается
PANEL_PATH="$PANEL_DIR"
got=$(detect_panel_root 2>/dev/null)
[[ "$got" == "$PANEL_DIR" ]] && ok || bad "ANTI-CYCLE: panel-declaring PANEL_PATH must be accepted, got '$got'"

# === 8) ДВОЙНОЙ MISCONFIG (CRIT-сценарий): panel-цель + PANEL_PATH=бот + БД бота → ОТКАЗ ===
# Раньше цикл самоподтверждался и panel-restore уничтожил бы бота. Теперь: detect_panel_root
# отвергает бот-каталог, роль rwp_shop_db = external → отказ в assert_target_identity.
_panel_root_now() { _live_panel_dir 2>/dev/null && return 0; detect_panel_root 2>/dev/null || echo "${PANEL_PATH:-/opt/remnawave}"; }
_LPD_CACHE="-"   # live-панели нет (docker-мок без remnawave/backend labels для ps)
BACKUP_TARGET="panel"; PANEL_PATH="$BOT_DIR"; BOT_PATH="$BOT_DIR"; DB_CONTAINER_NAME="rwp_shop_db"
assert_target_identity "t" >/dev/null 2>&1 && bad "DUAL MISCONFIG must REFUSE (panel→bot dir+db)" || ok
# и в assert_safe_db_target тот же сценарий обязан отказать (db_only-путь)
normalize_path() { readlink -f "$1" 2>/dev/null || echo "$1"; }
assert_safe_db_target "rwp_shop_db" "postgres" "postgres" >/dev/null 2>&1 \
    && bad "DUAL MISCONFIG safe_db_target must REFUSE" || ok
# восстановление корректного окружения
PANEL_PATH="$PANEL_DIR"; BOT_PATH="$PANEL_DIR"; DB_CONTAINER_NAME="remnawave-db"
_panel_root_now() { echo "$PANEL_DIR"; }

# === 9) LIVE-КРОСС-ЧЕК: живая панель в другом каталоге → отказ panel-цели ===
_LPD_CACHE="$PANEL_DIR"          # живая панель в PANEL_DIR
BACKUP_TARGET="panel"; BOT_PATH="$TMP_DIR/opt/elsewhere"; mkdir -p "$BOT_PATH"
DB_CONTAINER_NAME="remnawave-db"
assert_target_identity "t" >/dev/null 2>&1 && bad "live cross-check must REFUSE (target != live panel dir)" || ok
BOT_PATH="$PANEL_DIR"
assert_target_identity "t" >/dev/null 2>&1 && ok || bad "live cross-check must PASS when target == live dir"
_LPD_CACHE="-"

# === 10) UNKNOWN = FAIL-CLOSED: docker недоступен → отказ (не absent-pass) ===
_container_role() { echo "unknown"; return 2; }
BACKUP_TARGET="panel"; BOT_PATH="$PANEL_DIR"; DB_CONTAINER_NAME="remnawave-db"
assert_target_identity "t" >/dev/null 2>&1 && bad "role=unknown must REFUSE (panel)" || ok
BACKUP_TARGET="bot"; BOT_PATH="$BOT_DIR"; DB_CONTAINER_NAME="rwp_shop_db"
assert_target_identity "t" >/dev/null 2>&1 && bad "role=unknown must REFUSE (bot)" || ok
source <(sed -n '/^_container_role() {$/,/^}$/p' "$SCRIPT")   # вернуть настоящую

# === 11) BOT WHITELIST: соседняя БД проекта (kb_db) ≠ compose-производная → отказ ===
BACKUP_TARGET="bot"; BOT_PATH="$BOT_DIR"; DB_CONTAINER_NAME="rwp_shop_kb_db"
mock_meta_kb() { echo "pgvector/pgvector:pg17|$BOT_DIR|kb_db|running"; }
_orig_mock_meta=$(declare -f mock_meta)
mock_meta() { if [[ "$1" == "rwp_shop_kb_db" ]]; then mock_meta_kb; else eval "${_orig_mock_meta#*\{}" ; fi; } 2>/dev/null
# проще: подменяем find_db_container_for_path → каноническая БД проекта = rwp_shop_db
find_db_container_for_path() { echo "rwp_shop_db"; }
# роль kb_db: external (pgvector в проекте бота) — блэклист пропустил бы; whitelist обязан отказать
_container_role() { [[ "$1" == "rwp_shop_kb_db" ]] && { echo "external"; return 0; }; echo "external"; }
docker() { case "$1" in ps) echo "rwp_shop_kb_db" ;; inspect) [[ "$2" == "-f" ]] && echo "$BOT_DIR" || return 0 ;; exec) echo "postgres" ;; *) return 0 ;; esac; }
assert_safe_db_target "rwp_shop_kb_db" "postgres" "postgres" >/dev/null 2>&1 \
    && bad "WHITELIST: kb_db (≠ compose-derived rwp_shop_db) must REFUSE" || ok
source <(sed -n '/^_container_role() {$/,/^}$/p' "$SCRIPT")

# === 12) ИМЯ-НЕЗАВИСИМОСТЬ: кастомные имена контейнеров (панель my-panel/pg-main, биллинг fin-db) ===
# Идентификация обязана работать БЕЗ стандартных имён: панель по образу, БД — по compose-сервису
# из DATABASE_URL приложения (authoritative), не по имени.
mock_meta() { # name → image|dir|svc|status  (кастомные имена!)
    case "$1" in
        my-panel)  echo "remnawave/backend:2|$PANEL_DIR|my-panel|running" ;;
        pg-main)   echo "postgres:18.4|$PANEL_DIR|pg-main|running" ;;
        fin-db)    echo "postgres:18.4|$PANEL_DIR|fin-db|running" ;;
        bill-app)  echo "ghcr.io/mishkatik/infra-billing:latest|$PANEL_DIR|bill-app|running" ;;
        shop-core) echo "shop-core:1.0|$BOT_DIR|shop-core|running" ;;
        shop-pg)   echo "postgres:18.4|$BOT_DIR|shop-pg|running" ;;
        *) return 1 ;;
    esac
}
MOCK_ALL="my-panel pg-main fin-db bill-app shop-core shop-pg"
docker() {
    local a="$1"; shift
    case "$a" in
        inspect)
            local fmt="" name=""
            if [[ "$1" == "--format" || "$1" == "-f" ]]; then fmt="$2"; name="$3"; else name="$1"; fi
            local meta; meta=$(mock_meta "$name") || return 1
            local img dir svc st; IFS='|' read -r img dir svc st <<<"$meta"
            [[ -z "$fmt" ]] && { echo "{}"; return 0; }
            case "$fmt" in
                *".Config.Env"*)
                    # DATABASE_URL приложений: панель → pg-main, биллинг → fin-db (пароль в URL —
                    # наружу должен выйти ТОЛЬКО хост)
                    case "$name" in
                        my-panel) echo "DATABASE_URL=postgresql://pguser:S3cr3t@pg-main:5432/postgres" ;;
                        bill-app) echo "DATABASE_URL=postgresql://fin:T0pSecret@fin-db:5432/infra_billing" ;;
                    esac ;;
                *Config.Image*)  echo "$img|$dir|$svc" ;;
                *State.Status*)  echo "$st" ;;
                *working_dir*)   echo "$dir" ;;
                *) echo "" ;;
            esac ;;
        ps)
            local n meta img dir svc st
            for n in $MOCK_ALL; do
                meta=$(mock_meta "$n"); IFS='|' read -r img dir svc st <<<"$meta"
                if [[ "$*" == *"compose.service"* ]]; then echo "$n|$img|$dir|$svc"
                elif [[ "$*" == *"{{.Image}}"* ]]; then echo "$n|$img|$dir"
                else echo "$n"; fi
            done ;;
        info) return 0 ;;
        *) return 0 ;;
    esac
}
# сброс кэшей — новое «железо»
_PANEL_DBSVC_CACHE=""; _BILL_DBSVC_CACHE=""; _LPD_CACHE=""
PANEL_DB_CONTAINER=""   # конфиг пуст — всё должно найтись само
# 12a) _db_host_of_app: только hostname, БЕЗ секретов
got=$(_db_host_of_app my-panel)
[[ "$got" == "pg-main" ]] && ok || bad "_db_host_of_app: got '$got'"
[[ "$got" != *S3cr3t* && "$got" != *pguser* ]] && ok || bad "_db_host_of_app must not leak secrets"
# 12b) сервис-резолверы
[[ "$(_panel_db_service)" == "pg-main" ]] && ok || bad "panel_db_service: $(_panel_db_service)"
[[ "$(_billing_db_service)" == "fin-db" ]] && ok || bad "billing_db_service: $(_billing_db_service)"
# 12c) роли при кастомных именах (fin-db БЕЗ 'billing' в имени!)
[[ "$(_container_role my-panel)" == "panel-app" ]] && ok || bad "role(my-panel)=$(_container_role my-panel)"
[[ "$(_container_role pg-main)" == "panel-db" ]] && ok || bad "role(pg-main)=$(_container_role pg-main)"
[[ "$(_container_role fin-db)" == "billing-db" ]] && ok || bad "role(fin-db)=$(_container_role fin-db) (custom name, no 'billing')"
[[ "$(_container_role shop-pg)" == "external" ]] && ok || bad "role(shop-pg)=$(_container_role shop-pg)"
# 12d) discover_stacks: все стеки найдены при кастомных именах
BOT_PATH="$BOT_DIR"; KEYWORDS=(nomatch); find_db_container_for_path() { echo "shop-pg"; }
discover_stacks
[[ "$DISC_PANEL_APP" == "my-panel" && "$DISC_PANEL_DB" == "pg-main" ]] && ok \
    || bad "discover custom panel: app=$DISC_PANEL_APP db=$DISC_PANEL_DB"
[[ "$DISC_BILLING_APP" == "bill-app" && "$DISC_BILLING_DB" == "fin-db" ]] && ok \
    || bad "discover custom billing: app=$DISC_BILLING_APP db=$DISC_BILLING_DB"
# 12e) _is_panel_container ловит кастомное имя панельной БД (динамическая роль)
_is_panel_container "pg-main" && ok || bad "_is_panel_container(pg-main custom) must be panel"
_is_panel_container "shop-pg" && bad "_is_panel_container(shop-pg) must NOT be panel" || ok
# 12f) бот-fallback по проектам: БЕЗ флага (cron) — пусто (чужой проект не авто-применяется);
# С флагом (интерактивный выбор) — проект с БД найден и помечен догадкой
FOUND_PATHS=(); FOUND_BOTS=(); FOUND_PATH=""; FOUND_BOT=""; FOUND_DB=""
SCAN_ALLOW_LABEL_FALLBACK=0
scan_system_for_bot
[[ ${#FOUND_PATHS[@]} -eq 0 ]] && ok || bad "cron scan must NOT use label-fallback: '${FOUND_PATHS[0]:-}'"
SCAN_ALLOW_LABEL_FALLBACK=1
scan_system_for_bot
[[ "${FOUND_PATHS[0]:-}" == "$BOT_DIR" && "$FOUND_VIA_FALLBACK" == "1" ]] && ok \
    || bad "interactive label-fallback must find bot project: '${FOUND_PATHS[0]:-}' (fb=$FOUND_VIA_FALLBACK)"
SCAN_ALLOW_LABEL_FALLBACK=0

# === 13) Парольный SSH-режим (sshpass -e) — _build_target_ssh ===
# (а) SSH_PASSWORD_MODE=1: префикс начинается с sshpass -e, БЕЗ BatchMode, с PubkeyAuthentication=no
BOT_TRANSPORT="ssh"; BOT_SSH_HOST="203.0.113.7"; BOT_SSH_PORT="21022"; BOT_SSH_USER="root"; BOT_SSH_KEY=""
SSH_PASSWORD_MODE=1
got=$(_build_target_ssh bot)
[[ "$got" == "sshpass -e ssh -p 21022 "* ]] && ok || bad "pw-mode: prefix must start with 'sshpass -e ssh -p 21022': '$got'"
[[ "$got" != *"BatchMode"* ]] && ok || bad "pw-mode: BatchMode must be ABSENT: '$got'"
[[ "$got" == *"PubkeyAuthentication=no"* ]] && ok || bad "pw-mode: PubkeyAuthentication=no missing: '$got'"
# (б) SSH_PASSWORD_MODE=0: как раньше — BatchMode=yes, без sshpass
SSH_PASSWORD_MODE=0
got=$(_build_target_ssh bot)
[[ "$got" == ssh* && "$got" == *"BatchMode=yes"* && "$got" != *sshpass* ]] && ok \
    || bad "key-mode: must be plain ssh with BatchMode=yes, no sshpass: '$got'"
BOT_TRANSPORT="local"; BOT_SSH_HOST=""

# === 14) Щадящий save_config: дефолтный advanced-ключ НЕ пишется, недефолтный — пишется и грузится ===
INSTALL_DIR="$TMP_DIR/inst"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; _BOTRT_FORCED=0
PG_DUMP_TIMEOUT_SEC="3600"
save_config >/dev/null 2>&1
grep -qE '^PG_DUMP_TIMEOUT_SEC=' "$CONFIG_FILE" \
    && bad "sparse-save: default PG_DUMP_TIMEOUT_SEC must be ABSENT from config" || ok
PG_DUMP_TIMEOUT_SEC="123"
save_config >/dev/null 2>&1
grep -qE '^PG_DUMP_TIMEOUT_SEC="123"$' "$CONFIG_FILE" && ok \
    || bad "sparse-save: non-default PG_DUMP_TIMEOUT_SEC must be written"
PG_DUMP_TIMEOUT_SEC=""
load_config_file "$CONFIG_FILE"
[[ "$PG_DUMP_TIMEOUT_SEC" == "123" ]] && ok \
    || bad "sparse-save: PG_DUMP_TIMEOUT_SEC must load back, got '$PG_DUMP_TIMEOUT_SEC'"
PG_DUMP_TIMEOUT_SEC="3600"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
