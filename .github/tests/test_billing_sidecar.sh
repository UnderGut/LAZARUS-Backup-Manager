#!/usr/bin/env bash
# Infra-billing sidecar: гейт _billing_sidecar_active (auto/true/false, panel-only, remote),
# авто-discovery кредов _billing_db_creds (printenv из контейнера, дефолты образа postgres),
# строка в _print_targets_summary и glob-детект billing_*.sql.* на restore.
# Sources the REAL script as a library (LAZARUS_LIB=true). Counters n_ok/n_err (никогда PASS=).

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
SILENT_LOG="$TMP_DIR/silent.log"; DEBUG_MODE=false; IS_INTERACTIVE=false

# Стабы: timeout прозрачно вызывает остальное КАК ФУНКЦИЮ (иначе external timeout не видит
# bash-функцию docker); docker эмулирует inspect/exec printenv.
timeout() { shift; "$@"; }
_MOCK_STATE="running"; _MOCK_USER="infra"; _MOCK_DB="infra_billing"
docker() {
    case "$*" in
        "inspect --format {{.State.Status}} "*) echo "$_MOCK_STATE"; [[ -n "$_MOCK_STATE" ]] ;;
        *"printenv POSTGRES_USER"*) [[ -n "$_MOCK_USER" ]] && echo "$_MOCK_USER" ;;
        *"printenv POSTGRES_DB"*)   [[ -n "$_MOCK_DB" ]] && echo "$_MOCK_DB" ;;
        inspect*) return 0 ;;
        *) return 0 ;;
    esac
}

# --- 1) Гейт: bot-цель / выкл / пустой контейнер → rc=1 ---
BACKUP_TARGET="bot"; PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"
_billing_sidecar_active; [[ $? -eq 1 ]] && ok || bad "bot target must be rc=1"
BACKUP_TARGET="panel"; PANEL_BILLING_BACKUP="false"
_billing_sidecar_active; [[ $? -eq 1 ]] && ok || bad "PANEL_BILLING_BACKUP=false must be rc=1"
PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER=""
_billing_sidecar_active; [[ $? -eq 1 ]] && ok || bad "empty container must be rc=1"

# --- 2) Гейт: auto+running → 0; auto+stopped → 1; true+stopped → 2 (провал бэкапа) ---
PANEL_BILLING_DB_CONTAINER="infra-billing-db"; _MOCK_STATE="running"
_billing_sidecar_active; [[ $? -eq 0 ]] && ok || bad "auto+running must be rc=0"
_MOCK_STATE="exited"
_billing_sidecar_active; [[ $? -eq 1 ]] && ok || bad "auto+stopped must be rc=1 (silent skip)"
PANEL_BILLING_BACKUP="true"
_billing_sidecar_active; [[ $? -eq 2 ]] && ok || bad "required+stopped must be rc=2 (fail backup)"
PANEL_BILLING_BACKUP="auto"; _MOCK_STATE="running"

# --- 3) Креды: printenv из контейнера; пусто → дефолты postgres-образа ---
creds=$(_billing_db_creds)
[[ "$creds" == "infra infra_billing" ]] && ok || bad "creds discovery: '$creds'"
_MOCK_USER=""; _MOCK_DB=""
creds=$(_billing_db_creds)
[[ "$creds" == "postgres postgres" ]] && ok || bad "creds defaults: '$creds'"
_MOCK_USER="infra"; _MOCK_DB="infra_billing"

# --- 4) Remote-вариант: команды идут через ssh-префикс, не через локальный docker ---
# Счётчик через файл: вызовы происходят в subshell'ах ($(...)), переменная бы потерялась.
: > "$TMP_DIR/ssh_calls"
mock_ssh() {
    echo x >> "$TMP_DIR/ssh_calls"
    case "$1" in
        *"inspect --format"*) echo "running" ;;
        *"printenv POSTGRES_USER"*) echo "remoteuser" ;;
        *"printenv POSTGRES_DB"*)   echo "remotedb" ;;
    esac
}
_billing_sidecar_active "mock_ssh"; [[ $? -eq 0 ]] && ok || bad "remote active via ssh"
creds=$(_billing_db_creds "mock_ssh")
[[ "$creds" == "remoteuser remotedb" ]] && ok || bad "remote creds: '$creds'"
[[ "$(wc -l < "$TMP_DIR/ssh_calls" | tr -d ' ')" -ge 3 ]] && ok || bad "ssh prefix must be used (calls=$(wc -l < "$TMP_DIR/ssh_calls"))"

# --- 5) Сводка целей показывает billing-строку (panel + локально + running) ---
PANEL_TRANSPORT="local"; PANEL_SSH_HOST=""; PANEL_DB_CONTAINER="remnawave-db"
BOT_TRANSPORT="local"; BACKUP_SECONDARY=""
_MOCK_STATE="running"
out=$(_print_targets_summary)
[[ "$out" == *"infra-billing"* ]] && ok || bad "targets summary must mention infra-billing: $out"
PANEL_BILLING_BACKUP="false"
out=$(_print_targets_summary)
[[ "$out" != *"infra-billing"* ]] && ok || bad "summary must NOT mention billing when off"
PANEL_BILLING_BACKUP="auto"

# --- 6) Restore-детект: glob billing_*.sql.* находит sidecar в распакованном архиве ---
mkdir -p "$TMP_DIR/x"
: > "$TMP_DIR/x/db_2026-06-23_01_00_00.sql.gz"
: > "$TMP_DIR/x/billing_2026-06-23_01_00_00.sql.gz"
found=$(find "$TMP_DIR/x" \( -name "billing_*.sql.gz" -o -name "billing_*.sql.zst" \) | head -1)
[[ -n "$found" ]] && ok || bad "restore glob must find billing sidecar"
# и НЕ путает его с основным дампом
main=$(find "$TMP_DIR/x" \( -name "db_*.sql.gz" -o -name "db_*.sql.zst" \) | head -1)
[[ "$main" == *"/db_"* ]] && ok || bad "main dump glob must not match billing"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
