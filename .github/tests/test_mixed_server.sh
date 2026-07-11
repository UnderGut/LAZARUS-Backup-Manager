#!/usr/bin/env bash
# Смешанный сервер (бот + панель на одной машине): панель-независимый резолвер реального бота
# (resolve_bot_runtime / bind_bot_runtime_or_fail) + helpers (_same_path/_compose_in/_dir_is_bot/
# _dir_is_panel) + защита config.env от панельной идентичности в bot-полях (save_config heal).
# Sources REAL script as lib (LAZARUS_LIB=true). Counters n_ok/n_err (никогда PASS= — scrubber).

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

# --- фейковая ФС: панель + бот ---
PANEL_DIR="$TMP_DIR/opt/remnawave"; BOT_DIR="$TMP_DIR/opt/rwp-shop"
mkdir -p "$PANEL_DIR" "$BOT_DIR"
cat > "$PANEL_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave:
    image: remnawave/backend:2
  remnawave-db:
    image: postgres:18.4
EOF
cat > "$BOT_DIR/docker-compose.yml" <<'EOF'
services:
  rwp_shop:
    image: rwp_shop:6.6.0.67
  db:
    image: postgres:18.4
EOF

# panel-root всегда указывает на нашу фейковую панель
_panel_root_now() { echo "$PANEL_DIR"; }
# db-контейнер по пути бота — стаб (без docker)
find_db_container_for_path() { [[ "$1" == "$BOT_DIR" ]] && echo "rwp_shop_db"; }
# docker-заглушка (app-fallback не должен дёргать реальный docker)
docker() { return 1; }

# --- 1) _same_path / _compose_in ---
_same_path "$BOT_DIR" "$BOT_DIR/." && ok || bad "_same_path: same dir must match"
_same_path "$BOT_DIR" "$PANEL_DIR" && bad "_same_path: different dirs must NOT match" || ok
cf=$(_compose_in "$BOT_DIR"); [[ "$cf" == "$BOT_DIR/docker-compose.yml" ]] && ok || bad "_compose_in: got '$cf'"
_compose_in "$TMP_DIR/nope" >/dev/null && bad "_compose_in: missing dir must fail" || ok

# --- 2) _dir_is_panel / _dir_is_bot ---
_dir_is_panel "$PANEL_DIR" && ok || bad "_dir_is_panel: panel dir must be panel"
_dir_is_panel "$BOT_DIR" && bad "_dir_is_panel: bot dir must NOT be panel" || ok
_dir_is_bot "$BOT_DIR" && ok || bad "_dir_is_bot: bot dir must be bot"
_dir_is_bot "$PANEL_DIR" && bad "_dir_is_bot: panel dir must NOT be bot" || ok

# --- 3) resolve_bot_runtime: кандидат-1 (текущий BOT_PATH бот-валиден, не панель) ---
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"; KEYWORDS=(rwp_shop)
if resolve_bot_runtime; then
    [[ "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" && "$RB_DB" == "rwp_shop_db" ]] && ok \
        || bad "resolve cand-1: path=$RB_PATH app=$RB_APP db=$RB_DB"
else bad "resolve cand-1: should succeed"; fi

# --- 4) resolve_bot_runtime: BOT_PATH=панель → кандидат-1 отвергнут, скан находит бота ---
BOT_PATH="$PANEL_DIR"; BOT_CONTAINER_NAME="remnawave"; DB_CONTAINER_NAME="remnawave-db"
scan_system_for_bot() { FOUND_PATHS=("$PANEL_DIR" "$BOT_DIR"); FOUND_BOTS=("remnawave" "rwp_shop"); }
if resolve_bot_runtime; then
    [[ "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" ]] && ok \
        || bad "resolve via scan: must skip panel, pick bot — got path=$RB_PATH app=$RB_APP"
else bad "resolve via scan: should succeed"; fi

# --- 5) resolve_bot_runtime: бота нет нигде → rc=1 ---
BOT_PATH="$PANEL_DIR"; BOT_CONTAINER_NAME="remnawave"
scan_system_for_bot() { FOUND_PATHS=("$PANEL_DIR"); FOUND_BOTS=("remnawave"); }
# статические кандидаты (/opt/rwp-shop и т.п.) в тестовой ФС отсутствуют
resolve_bot_runtime && bad "resolve no-bot: must fail (only panel present)" || ok

# --- 6) bind_bot_runtime_or_fail: успех форсит bot-контекст ---
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"
BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"; DB_NAME="postgres"; DB_USER="postgres"
scan_system_for_bot() { FOUND_PATHS=("$BOT_DIR"); FOUND_BOTS=("rwp_shop"); }
if bind_bot_runtime_or_fail "тест"; then
    [[ "$BACKUP_TARGET" == "bot" && "$BOT_PATH" == "$BOT_DIR" && "$BACKUP_PREFIX" == "lazarus" \
       && -z "$DB_NAME" && -z "$DB_USER" && "$BACKUP_SECONDARY" == "" ]] && ok \
        || bad "bind success: target=$BACKUP_TARGET path=$BOT_PATH prefix=$BACKUP_PREFIX dbn='$DB_NAME'"
else bad "bind success: should bind real bot"; fi

# --- 7) bind refuses when resolved path == panel (defense-in-depth) ---
# Форсим resolve → путь панели, проверяем что bind отвергает (панель не трогаем).
resolve_bot_runtime() { RB_PATH="$PANEL_DIR"; RB_APP="remnawave"; RB_DB="remnawave-db"; return 0; }
BACKUP_TARGET="panel"
bind_bot_runtime_or_fail "опасно" && bad "bind must REFUSE panel path" || ok
[[ "$BACKUP_TARGET" == "panel" ]] && ok || bad "bind refuse must NOT flip target to bot"
unset -f resolve_bot_runtime
# восстанавливаем настоящую функцию из скрипта
source <(sed -n '/^resolve_bot_runtime() {$/,/^}$/p' "$SCRIPT")

# --- 8) bind refuses on panel-only server (no bot) ---
scan_system_for_bot() { FOUND_PATHS=(); FOUND_BOTS=(); }
BOT_PATH="$PANEL_DIR"; BOT_CONTAINER_NAME="remnawave"; BACKUP_TARGET="panel"
bind_bot_runtime_or_fail "апгрейд" && bad "bind must fail with no bot" || ok

# --- 9) save_config НЕ пишет панельную идентичность в bot-поля (heal) ---
CONFIG_FILE="$TMP_DIR/config.env"
BACKUP_TARGET="panel"; BACKUP_SECONDARY=""
# _CANON заражён панелью (симуляция прошлой порчи) — save обязан вычистить
_CANON_BOT_PATH="$PANEL_DIR"; _CANON_BOT_CONTAINER="remnawave"; _CANON_DB_CONTAINER="remnawave-db"
_CANON_DB_NAME=""; _CANON_DB_USER="postgres"; _CANON_MAX_FILE_SIZE_MB="1"
PANEL_DB_CONTAINER="remnawave-db"
save_config
got_bp=$(grep -E '^BOT_PATH=' "$CONFIG_FILE" | cut -d'"' -f2)
got_bc=$(grep -E '^BOT_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
got_dc=$(grep -E '^DB_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
[[ -z "$got_bc" ]] && ok || bad "save heal: BOT_CONTAINER_NAME must be empty, got '$got_bc'"
[[ -z "$got_dc" ]] && ok || bad "save heal: DB_CONTAINER_NAME (panel db) must be empty, got '$got_dc'"
[[ -z "$got_bp" ]] && ok || bad "save heal: BOT_PATH (== panel) must be empty, got '$got_bp'"

# --- 10) save_config пишет РЕАЛЬНЫЙ бот из чистого _CANON ---
_CANON_BOT_PATH="$BOT_DIR"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
save_config
got_bp=$(grep -E '^BOT_PATH=' "$CONFIG_FILE" | cut -d'"' -f2)
got_bc=$(grep -E '^BOT_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
got_dc=$(grep -E '^DB_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
[[ "$got_bp" == "$BOT_DIR" && "$got_bc" == "rwp_shop" && "$got_dc" == "rwp_shop_db" ]] && ok \
    || bad "save real bot: bp='$got_bp' bc='$got_bc' dc='$got_dc'"

# --- 11) _is_panel_container: точные панельные имена да, remnawave-telegram-shop* НЕТ ---
PANEL_DB_CONTAINER="remnawave-db"
_is_panel_container "remnawave" && ok || bad "_is_panel_container: 'remnawave' must be panel"
_is_panel_container "remnawave-db" && ok || bad "_is_panel_container: 'remnawave-db' must be panel"
_is_panel_container "remnawave-telegram-shop" && bad "_is_panel_container: bot 'remnawave-telegram-shop' must NOT be panel" || ok
_is_panel_container "rwp_shop" && bad "_is_panel_container: 'rwp_shop' must NOT be panel" || ok

# --- 12) BACKWARD-COMPAT: bot-only save НЕ занулит легит-бот с именем remnawave-telegram-shop* ---
CONFIG_FILE="$TMP_DIR/config_botonly.env"
BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; _BOTRT_FORCED=0
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="remnawave-telegram-shop"; DB_CONTAINER_NAME="remnawave-telegram-shop-db"; DB_USER="postgres"
save_config
got_bc=$(grep -E '^BOT_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
got_dc=$(grep -E '^DB_CONTAINER_NAME=' "$CONFIG_FILE" | cut -d'"' -f2)
[[ "$got_bc" == "remnawave-telegram-shop" && "$got_dc" == "remnawave-telegram-shop-db" ]] && ok \
    || bad "bot-only save must NOT blank remnawave-telegram-shop*: bc='$got_bc' dc='$got_dc'"

# --- 13) _dir_is_panel НЕ ловит бот, который лишь ссылается на remnawave-db (сеть/depends_on) ---
BOTREF_DIR="$TMP_DIR/opt/bot-ref"; mkdir -p "$BOTREF_DIR"
cat > "$BOTREF_DIR/docker-compose.yml" <<'EOF'
services:
  rwp_shop:
    image: rwp_shop:6.6.0.67
    depends_on: [remnawave-db]
    networks: [remnawave-db_default]
networks:
  remnawave-db_default:
    external: true
EOF
_dir_is_panel "$BOTREF_DIR" && bad "_dir_is_panel: bot referencing remnawave-db must NOT be panel" || ok
_dir_is_bot "$BOTREF_DIR" && ok || bad "_dir_is_bot: bot referencing remnawave-db must be bot"

# --- 14) unbind_bot_runtime восстанавливает both-контекст после форса ---
BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"; _BOTRT_FORCED=0
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"
PANEL_PATH="$PANEL_DIR"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"
scan_system_for_bot() { FOUND_PATHS=("$BOT_DIR"); FOUND_BOTS=("rwp_shop"); }
bind_bot_runtime_or_fail "апгрейд" >/dev/null 2>&1
[[ "$BACKUP_TARGET" == "bot" && "$_BOTRT_FORCED" == "1" ]] && ok || bad "bind must force bot ctx (target=$BACKUP_TARGET forced=$_BOTRT_FORCED)"
# save во время форса пишет ПРЕЖНЮЮ цель (panel+bot), не транзиентный bot-only
CONFIG_FILE="$TMP_DIR/config_forced.env"; _CANON_BOT_PATH="$BOT_DIR"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
save_config
got_t=$(grep -E '^BACKUP_TARGET=' "$CONFIG_FILE" | cut -d'"' -f2)
got_s=$(grep -E '^BACKUP_SECONDARY=' "$CONFIG_FILE" | cut -d'"' -f2)
[[ "$got_t" == "panel" && "$got_s" == "bot" ]] && ok || bad "save during bind must persist PRIOR target: t='$got_t' s='$got_s'"
unbind_bot_runtime
[[ "$BACKUP_TARGET" == "panel" && "$BACKUP_SECONDARY" == "bot" && "$_BOTRT_FORCED" == "0" ]] && ok \
    || bad "unbind must restore both-mode: target=$BACKUP_TARGET sec=$BACKUP_SECONDARY forced=$_BOTRT_FORCED"

# --- 15) _dir_is_panel НЕ ловит depends_on-МАППИНГ remnawave-db (вложенный ключ на своей строке) ---
BOTMAP_DIR="$TMP_DIR/opt/bot-map"; mkdir -p "$BOTMAP_DIR"
cat > "$BOTMAP_DIR/docker-compose.yml" <<'EOF'
services:
  rwp_shop:
    image: rwp_shop:6.6.0.67
    depends_on:
      remnawave-db:
        condition: service_healthy
EOF
_dir_is_panel "$BOTMAP_DIR" && bad "_dir_is_panel: depends_on-mapping remnawave-db must NOT be panel" || ok
_dir_is_bot "$BOTMAP_DIR" && ok || bad "_dir_is_bot: bot with depends_on-mapping must be bot"

# --- 16) _dir_is_panel всё ещё ловит панель по образу на НЕканоническом пути ---
PANEL_ALT="$TMP_DIR/opt/stacks/remnawave"; mkdir -p "$PANEL_ALT"
cat > "$PANEL_ALT/docker-compose.yml" <<'EOF'
services:
  remnawave:
    image: remnawave/backend:2
EOF
_dir_is_panel "$PANEL_ALT" && ok || bad "_dir_is_panel: panel by image at non-canonical path must be panel"

# --- 17) show_bot_startup_logs НЕ льёт compose-логи из каталога панели (panel-only fallback guard) ---
# BOT_PATH указывает на панель, контейнер панельный, реального бота нет → должно уйти в WARN, НЕ в compose logs.
scan_system_for_bot() { FOUND_PATHS=(); FOUND_BOTS=(); }   # бота нет
BOT_CONTAINER_NAME="remnawave"; BOT_PATH="$PANEL_DIR"
logs_out=$(show_bot_startup_logs 5 2>&1)
[[ "$logs_out" == *"не определён"* || "$logs_out" == *"недоступны"* ]] && ok \
    || bad "panel-only 'bot logs' must NOT run compose logs in panel dir: '$logs_out'"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
