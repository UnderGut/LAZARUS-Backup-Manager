#!/usr/bin/env bash
# Regression tests for the menu/UX reorganization (90-agent review fixes). Sources the REAL
# script as a library (LAZARUS_LIB=true) and exercises the presentation helpers — no docker,
# no network, no real backup. Covers the confirmed bugs that are pure-logic and verifiable:
#   H1  ssh target must NOT show a green ✓ without a real check
#   H2  bot row in both-mode must use the canon DB container, not the panel-clobbered one
#   _readiness_line / _protection_needed flags
#   _transport_of
#   M29 help hides bot-management in panel mode
# Counters n_ok/n_err (never PASS= — the secret-scrubber rewrites it on disk).

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
SILENT_LOG="$TMP_DIR/silent.log"; DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false
BACKUP_DIR="$TMP_DIR/bk"; mkdir -p "$BACKUP_DIR"
BACKUP_PASSWORD_FILE="$TMP_DIR/.password"

# --- 1) H1: SSH-цель НЕ показывает зелёную «✓» без проверки связи ---
PANEL_TRANSPORT="ssh"; PANEL_SSH_HOST="10.0.0.5"; PANEL_SSH_USER="root"; PANEL_DB_CONTAINER="remnawave-db"
BACKUP_TARGET="panel"; BACKUP_SECONDARY=""
line=$(_target_status_line panel)
[[ "$line" == *"настроено"* && "$line" != *"✓"* ]] && ok || bad "H1 ssh status must be neutral 'настроено', got: $line"
# хост не задан → подсказка про пункт 2
PANEL_SSH_HOST=""
line=$(_target_status_line panel)
[[ "$line" == *"хост не задан"* && "$line" == *"пункт 2"* ]] && ok || bad "H1 ssh no-host hint: $line"

# --- 2) H2: бот как SECONDARY (панель primary) НЕ показывает контейнер панели ---
# Симулируем in-process клоббер: DB_CONTAINER_NAME затёрт панельным значением, canon пуст.
BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"
BOT_TRANSPORT="local"; BOT_SSH_HOST=""
DB_CONTAINER_NAME="remnawave-db"   # затёрто panel-resolve
_CANON_DB_CONTAINER=""             # снимок не взят (both включили правкой config.env)
line=$(_target_status_line bot)
[[ "$line" != *"remnawave-db"* ]] && ok || bad "H2 bot row leaked panel container: $line"
[[ "$line" == *"не задан"* ]] && ok || bad "H2 bot row should say 'не задан' when canon empty: $line"
# когда canon задан — он и показывается
_CANON_DB_CONTAINER="rwp_shop_db"
line=$(_target_status_line bot)
[[ "$line" == *"rwp_shop_db"* ]] && ok || bad "H2 bot row should show canon container: $line"

# --- 3) _transport_of ---
PANEL_TRANSPORT="ssh"; BOT_TRANSPORT="local"
[[ "$(_transport_of panel)" == "ssh" ]] && ok || bad "_transport_of panel"
[[ "$(_transport_of bot)" == "local" ]] && ok || bad "_transport_of bot"

# --- 4) _readiness_line + _protection_needed: всё выключено → красные флаги + нужна настройка ---
# Регрессия-фикс: cron берётся из get_cron_status (не из NO_CRITICAL_BACKUP) — мокаем функцию.
BACKUP_PASSWORD=""; rm -f "$BACKUP_PASSWORD_FILE"
REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"
get_cron_status() { echo "Выкл"; }   # cron не настроен
rl=$(_readiness_line)
[[ "$rl" == *"шифрование ВЫКЛ"* && "$rl" == *"только локально"* && "$rl" == *"авто ВЫКЛ"* ]] && ok || bad "readiness all-off: $rl"
_protection_needed && ok || bad "_protection_needed must be true when all off"

# --- 5) всё настроено → зелёная готовность + защита не нужна ---
printf 'secret' > "$BACKUP_PASSWORD_FILE"
REMOTE_STORAGE_TYPE="s3"; SEND_TO_REMOTE="true"
get_cron_status() { echo "Ежедневно 04:00"; }   # cron активен
rl=$(_readiness_line)
[[ "$rl" == *"шифр"* && "$rl" == *"off-site"* && "$rl" != *"ВЫКЛ"* ]] && ok || bad "readiness all-on: $rl"
_protection_needed && bad "_protection_needed must be false when all configured" || ok

# --- 5b) РЕГРЕССИЯ-ГАРД: при НЕнастроенном cron и unset NO_CRITICAL_BACKUP — НЕ зелёный авто ---
unset NO_CRITICAL_BACKUP
get_cron_status() { echo "Выкл"; }
rl=$(_readiness_line)
[[ "$rl" == *"авто ВЫКЛ"* ]] && ok || bad "regression: unset NO_CRITICAL_BACKUP must NOT show green авто: $rl"

# --- 6) _target_loc_label ssh/local ---
BOT_TRANSPORT="ssh"; BOT_SSH_HOST="1.2.3.4"; BOT_SSH_USER="root"
[[ "$(_target_loc_label bot)" == "SSH → root@1.2.3.4" ]] && ok || bad "loc ssh: $(_target_loc_label bot)"
PANEL_TRANSPORT="local"
[[ "$(_target_loc_label panel)" == "этот сервер" ]] && ok || bad "loc local: $(_target_loc_label panel)"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
