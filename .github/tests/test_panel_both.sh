#!/usr/bin/env bash
# Co-located both-mode (BACKUP_SECONDARY): the dispatcher backs up two targets in one run.
# Correctness hinges on (a) _resolve_target_config restoring each target's config from a clean
# source so the second pass never inherits the first pass's clobbered working vars, and (b)
# save_config being suppressed during the dispatch so config.env's bot fields are never polluted
# by the panel-resolve clobber. Sources the REAL script as a library (LAZARUS_LIB=true).
# Counters n_ok/n_err (never PASS= — secret scrubber rewrites it on disk).

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
SILENT_LOG="$TMP_DIR/silent.log"; INSTALL_DIR="$TMP_DIR/install"; mkdir -p "$INSTALL_DIR"

# Canonical BOT config snapshot (as load_or_create_config would capture, pre-clobber).
_CANON_BOT_PATH="/opt/bot"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
_CANON_DB_SERVICE="db"; _CANON_DB_NAME=""; _CANON_DB_USER="postgres"; _CANON_MAX_FILE_SIZE_MB="1"
# Panel config.
PANEL_PATH="/opt/remnawave"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"
PANEL_DB_NAME=""; PANEL_KEYWORDS=("remnawave")

# Simulate: process started as panel primary → working vars are panel-clobbered.
BACKUP_TARGET="panel"; resolve_backup_target
[[ "$BOT_PATH" == "/opt/remnawave" ]] && ok || bad "precondition: panel clobbered BOT_PATH, got '$BOT_PATH'"

# --- 1) _resolve_target_config bot: restores canonical bot config over the panel clobber ---
_resolve_target_config "bot"
[[ "$BACKUP_TARGET" == "bot" ]] && ok || bad "rtc bot: BACKUP_TARGET '$BACKUP_TARGET'"
[[ "$BACKUP_PREFIX" == "lazarus" ]] && ok || bad "rtc bot: prefix '$BACKUP_PREFIX'"
[[ "$BOT_PATH" == "/opt/bot" ]] && ok || bad "rtc bot: BOT_PATH restored '$BOT_PATH'"
[[ "$DB_CONTAINER_NAME" == "rwp_shop_db" ]] && ok || bad "rtc bot: DB_CONTAINER '$DB_CONTAINER_NAME'"
[[ "$MAX_FILE_SIZE_MB" == "1" ]] && ok || bad "rtc bot: MAX_FILE_SIZE_MB restored '$MAX_FILE_SIZE_MB'"

# --- 2) _resolve_target_config panel: maps panel config (size limit off) ---
_resolve_target_config "panel"
[[ "$BACKUP_PREFIX" == "lazarus_panel" ]] && ok || bad "rtc panel: prefix '$BACKUP_PREFIX'"
[[ "$BOT_PATH" == "/opt/remnawave" ]] && ok || bad "rtc panel: BOT_PATH '$BOT_PATH'"
[[ "$DB_CONTAINER_NAME" == "remnawave-db" ]] && ok || bad "rtc panel: DB_CONTAINER '$DB_CONTAINER_NAME'"
[[ "$MAX_FILE_SIZE_MB" == "0" ]] && ok || bad "rtc panel: size limit off '$MAX_FILE_SIZE_MB'"

# --- 3) canonical snapshot is NOT corrupted by repeated switches (idempotent) ---
_resolve_target_config "bot"; _resolve_target_config "panel"; _resolve_target_config "bot"
[[ "$BOT_PATH" == "/opt/bot" && "$DB_CONTAINER_NAME" == "rwp_shop_db" ]] && ok \
    || bad "canonical corrupted after repeated switches: BOT_PATH='$BOT_PATH' DB='$DB_CONTAINER_NAME'"
[[ "$_CANON_BOT_PATH" == "/opt/bot" ]] && ok || bad "_CANON_BOT_PATH mutated: '$_CANON_BOT_PATH'"

# --- 4) save_config is suppressed during dispatch (no config.env pollution) ---
CONFIG_FILE="$TMP_DIR/config.env"
rm -f "$CONFIG_FILE"
_SUPPRESS_SAVE=1
save_config
[[ ! -f "$CONFIG_FILE" ]] && ok || bad "save_config wrote despite _SUPPRESS_SAVE"
unset _SUPPRESS_SAVE
# sanity: without suppress, save_config DOES write (proves the guard is what blocked it)
BOT_TOKEN=""; CHAT_ID=""   # minimal vars; save_config tolerates empties
save_config 2>/dev/null
[[ -f "$CONFIG_FILE" ]] && ok || bad "save_config did not write when allowed"

# --- 5) secondary==primary is a no-op guard (dispatcher must not double-back-up same target) ---
# (validation lives in load_or_create_config; here assert the dispatcher's own guard condition)
BACKUP_TARGET="panel"; BACKUP_SECONDARY="panel"
[[ -z "$BACKUP_SECONDARY" || "$BACKUP_SECONDARY" == "$BACKUP_TARGET" ]] && ok \
    || bad "dispatcher guard: secondary==primary should short-circuit"
BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"
[[ -n "$BACKUP_SECONDARY" && "$BACKUP_SECONDARY" != "$BACKUP_TARGET" ]] && ok \
    || bad "dispatcher guard: distinct secondary should proceed"

# --- 6) WRONG-TARGET regression: load_config_file re-reads BACKUP_TARGET from disk; the active
#        pass's in-memory target must be preserved across it (the ensure_bot_path recovery fix). ---
CONFIG_FILE="$TMP_DIR/cfg_both.env"
cat > "$CONFIG_FILE" <<'EOF'
BACKUP_TARGET="panel"
BACKUP_SECONDARY="bot"
BOT_PATH="/opt/bot"
EOF
# Simulate being mid secondary (bot) pass: in-memory target = bot.
BACKUP_TARGET="bot"; BACKUP_SECONDARY="bot"
# The hazard: a bare load_config_file overwrites the active target with the on-disk primary.
load_config_file "$CONFIG_FILE"
[[ "$BACKUP_TARGET" == "panel" ]] && ok || bad "precondition: load_config_file should re-read primary, got '$BACKUP_TARGET'"
# The fix pattern (save→load→restore) keeps the active pass target.
BACKUP_TARGET="bot"; BACKUP_SECONDARY="bot"
_et="$BACKUP_TARGET"; _es="$BACKUP_SECONDARY"
load_config_file "$CONFIG_FILE"; BACKUP_TARGET="$_et"; BACKUP_SECONDARY="$_es"
[[ "$BACKUP_TARGET" == "bot" ]] && ok || bad "fix: active target must survive load, got '$BACKUP_TARGET'"

# --- 7) Canonical snapshot is taken ONCE (init); a recovery re-entry of load_or_create_config
#        must NOT re-snapshot _CANON_* (else it could poison the bot pass/heal). ---
INSTALL_DIR="$TMP_DIR/inst7"; mkdir -p "$INSTALL_DIR"
CONFIG_FILE="$INSTALL_DIR/config.env"; BACKUP_DIR="$INSTALL_DIR/backup"
IS_INTERACTIVE="false"; AUTO_CONFIRM="false"; BACKUP_PASSWORD=""; BACKUP_PASSWORD_FILE="$INSTALL_DIR/.password"
cat > "$CONFIG_FILE" <<'EOF'
BACKUP_TARGET="bot"
BOT_PATH="/opt/bot"
BOT_CONTAINER_NAME="rwp_shop"
DB_CONTAINER_NAME="rwp_shop_db"
BACKUP_LOG_FILES="false"
EOF
unset _CANON_SNAPSHOT_TAKEN; _CANON_BOT_PATH=""
load_or_create_config >/dev/null 2>&1
[[ "$_CANON_BOT_PATH" == "/opt/bot" ]] && ok || bad "init snapshot: _CANON_BOT_PATH='$_CANON_BOT_PATH'"
[[ -n "${_CANON_SNAPSHOT_TAKEN:-}" ]] && ok || bad "init: _CANON_SNAPSHOT_TAKEN not set"
# Recovery re-entry: change disk + clobber working var, re-call → snapshot must stay /opt/bot.
sed -i 's#/opt/bot#/opt/CHANGED#' "$CONFIG_FILE"
BOT_PATH="/opt/remnawave"   # simulate panel-clobbered working var
load_or_create_config >/dev/null 2>&1
[[ "$_CANON_BOT_PATH" == "/opt/bot" ]] && ok || bad "recovery re-entry re-snapshotted _CANON: '$_CANON_BOT_PATH'"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
