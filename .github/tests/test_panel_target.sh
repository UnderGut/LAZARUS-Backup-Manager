#!/usr/bin/env bash
# Tests for resolve_backup_target() — the bot|panel resolver that maps panel config
# onto the working vars so the hardened create_backup/execute_restore run unchanged.
# Verifies: bot mode = lazarus prefix / no remap; panel mode = lazarus_panel prefix +
# BOT_PATH/DB container/service mirror PANEL_* + DB_NAME override. Counters n_ok/n_err.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
debug_log() { :; }

FUNCS="$TMP_DIR/funcs.sh"
# №20: resolve_backup_target берёт бот-набор из константы — тянем её вместе с функцией.
{
    grep '^BOT_KEYWORDS_DEFAULT=(' "$SCRIPT"
    sed -n '/^resolve_backup_target() {$/,/^}$/p' "$SCRIPT"
} > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# --- bot mode (default) ---
BACKUP_TARGET="bot"; BACKUP_PREFIX=""; BOT_PATH="/opt/bot"; DB_CONTAINER_NAME="rwp_shop_db"
DB_SERVICE_NAME="db"; KEYWORDS=("rwp_shop"); DEFAULT_BOT_PATH="/opt/bot"
DEFAULT_DB_CONTAINER="rwp_shop_db"; BOT_CONTAINER_NAME="rwp_shop"; DEFAULT_BOT_CONTAINER="rwp_shop"
PANEL_PATH="/opt/remnawave"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"
PANEL_DB_NAME=""; PANEL_KEYWORDS=("remnawave"); DB_NAME=""
resolve_backup_target
[[ "$BACKUP_PREFIX" == "lazarus" ]] && ok || bad "bot prefix: '$BACKUP_PREFIX'"
[[ "$BOT_PATH" == "/opt/bot" ]] && ok || bad "bot path unchanged: '$BOT_PATH'"
[[ "$DB_CONTAINER_NAME" == "rwp_shop_db" ]] && ok || bad "bot db unchanged: '$DB_CONTAINER_NAME'"

# --- panel mode ---
BACKUP_TARGET="panel"; BACKUP_PREFIX=""; BOT_PATH="/opt/bot"; DB_CONTAINER_NAME="rwp_shop_db"
DB_SERVICE_NAME="db"; KEYWORDS=("rwp_shop"); DEFAULT_BOT_PATH="/opt/bot"
DEFAULT_DB_CONTAINER="rwp_shop_db"; BOT_CONTAINER_NAME="rwp_shop"; DEFAULT_BOT_CONTAINER="rwp_shop"
PANEL_PATH="/opt/remnawave"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"
PANEL_DB_NAME=""; PANEL_KEYWORDS=("remnawave"); DB_NAME=""
resolve_backup_target
[[ "$BACKUP_PREFIX" == "lazarus_panel" ]] && ok || bad "panel prefix: '$BACKUP_PREFIX'"
[[ "$BOT_PATH" == "/opt/remnawave" ]] && ok || bad "panel path: '$BOT_PATH'"
[[ "$DB_CONTAINER_NAME" == "remnawave-db" ]] && ok || bad "panel db container: '$DB_CONTAINER_NAME'"
[[ "$DB_SERVICE_NAME" == "remnawave-db" ]] && ok || bad "panel db service: '$DB_SERVICE_NAME'"
[[ "$BOT_CONTAINER_NAME" == "remnawave" ]] && ok || bad "panel app container: '$BOT_CONTAINER_NAME'"
[[ "${KEYWORDS[0]}" == "remnawave" ]] && ok || bad "panel keywords: '${KEYWORDS[*]}'"

# --- panel mode with explicit PANEL_DB_NAME override ---
BACKUP_TARGET="panel"; PANEL_DB_NAME="remnawave_custom"; DB_NAME=""
PANEL_KEYWORDS=("remnawave")
resolve_backup_target
[[ "$DB_NAME" == "remnawave_custom" ]] && ok || bad "panel DB_NAME override: '$DB_NAME'"

# --- panel namespace isolation: prefixes do not collide ---
[[ "lazarus_panel_db_X" != lazarus_db_* ]] && ok || bad "namespace collision: lazarus_panel_db matched lazarus_db_*"
[[ "lazarus_panel_full_X" == lazarus_* ]] && ok || bad "size-rotation wildcard should still catch panel"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
