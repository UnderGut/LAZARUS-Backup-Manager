#!/usr/bin/env bash
# Panel-primary first-run: detect_panel_root() must find a Remnawave install by its
# compose file across canonical layouts, prefer the configured PANEL_PATH, and the
# resolver must flip cleanly between panel and bot. Sources the REAL script as a
# library (LAZARUS_LIB=true). Counters n_ok/n_err (never PASS= — scrubber rewrites it).

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

# --- 1) detect_panel_root finds a dir with docker-compose.yml via PANEL_PATH ---
PANEL_DIR="$TMP_DIR/opt/remnawave"; mkdir -p "$PANEL_DIR"
: > "$PANEL_DIR/docker-compose.yml"
PANEL_PATH="$PANEL_DIR"
got=$(detect_panel_root || true)
[[ "$got" == "$PANEL_DIR" ]] && ok || bad "detect via PANEL_PATH (docker-compose.yml): got '$got'"

# --- 2) compose.yaml / compose.yml variants are recognised ---
PANEL_DIR2="$TMP_DIR/root/remnawave"; mkdir -p "$PANEL_DIR2"
: > "$PANEL_DIR2/compose.yaml"
PANEL_PATH="$PANEL_DIR2"
got=$(detect_panel_root || true)
[[ "$got" == "$PANEL_DIR2" ]] && ok || bad "detect via PANEL_PATH (compose.yaml): got '$got'"

# --- 3) a dir WITHOUT any compose file is NOT returned ---
EMPTY_DIR="$TMP_DIR/empty/remnawave"; mkdir -p "$EMPTY_DIR"
PANEL_PATH="$EMPTY_DIR"
got=$(detect_panel_root || true)
[[ "$got" != "$EMPTY_DIR" ]] && ok || bad "empty dir (no compose) must not be detected: got '$got'"

# --- 4) PANEL_PATH takes precedence over the hardcoded candidates ---
PANEL_PATH="$PANEL_DIR"
got=$(detect_panel_root || true)
[[ "$got" == "$PANEL_DIR" ]] && ok || bad "PANEL_PATH precedence: got '$got'"

# --- 5) resolver flips panel<->bot cleanly (prefix + working vars) ---
PANEL_PATH="$PANEL_DIR"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"
PANEL_DB_NAME=""; PANEL_KEYWORDS=("remnawave"); DB_NAME=""
BACKUP_TARGET="panel"; resolve_backup_target
[[ "$BACKUP_PREFIX" == "lazarus_panel" ]] && ok || bad "panel prefix: '$BACKUP_PREFIX'"
[[ "$BOT_PATH" == "$PANEL_DIR" ]] && ok || bad "panel maps BOT_PATH: '$BOT_PATH'"
[[ "$BOT_CONTAINER_NAME" == "remnawave" ]] && ok || bad "panel app container: '$BOT_CONTAINER_NAME'"
BACKUP_TARGET="bot"; resolve_backup_target
[[ "$BACKUP_PREFIX" == "lazarus" ]] && ok || bad "bot prefix after flip: '$BACKUP_PREFIX'"

# --- 6) bot-branch RESTORES hardcoded constants the panel-branch clobbered (in-process switch).
#        Regression for the wrong-target-backup defect (panel→bot leaking panel DEFAULT_*/KEYWORDS).
# Panel resolve clobbered DEFAULT_*/KEYWORDS to panel values; bot resolve (just run) must restore them.
[[ "$DEFAULT_BOT_PATH" == "/opt/private-remnawave-telegram-shop-bot" ]] && ok || bad "bot restore DEFAULT_BOT_PATH: '$DEFAULT_BOT_PATH'"
[[ "$DEFAULT_BOT_CONTAINER" == "rwp_shop" ]] && ok || bad "bot restore DEFAULT_BOT_CONTAINER: '$DEFAULT_BOT_CONTAINER'"
[[ "$DEFAULT_DB_CONTAINER" == "rwp_shop_db" ]] && ok || bad "bot restore DEFAULT_DB_CONTAINER: '$DEFAULT_DB_CONTAINER'"
[[ "${KEYWORDS[0]}" == "rwp_shop" && " ${KEYWORDS[*]} " == *" shopbot "* ]] && ok || bad "bot restore KEYWORDS: '${KEYWORDS[*]}'"

# --- 7) _target_loc_label: dashboard "where" label is clear for local vs ssh ---
PANEL_TRANSPORT="local"; PANEL_SSH_HOST=""
[[ "$(_target_loc_label panel)" == "этот сервер" ]] && ok || bad "panel local label: '$(_target_loc_label panel)'"
BOT_TRANSPORT="ssh"; BOT_SSH_HOST="203.0.113.59"; BOT_SSH_USER="root"
[[ "$(_target_loc_label bot)" == "SSH → root@203.0.113.59" ]] && ok || bad "bot ssh label: '$(_target_loc_label bot)'"
BOT_SSH_HOST="admin@host"  # already user@host → no dup
[[ "$(_target_loc_label bot)" == "SSH → admin@host" ]] && ok || bad "bot ssh user@host label: '$(_target_loc_label bot)'"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
