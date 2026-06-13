#!/usr/bin/env bash
# Tests for config persistence safety:
#  - env_escape neutralizes CR/LF (CFG-1: a newline in a value would split into a fake
#    second key=value line on reload, corrupting config/credentials)
#  - env_escape / parse_env_value round-trip for backslash + quote
#  - load_config_file honors the documented DB_NAME override (CFG-2)
# Counters n_ok/n_err (PASS= triggers secret-redaction on disk).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SILENT_LOG="$TMP_DIR/silent.log"; : > "$SILENT_LOG"
debug_log() { :; }
export SILENT_LOG

FUNCS="$TMP_DIR/funcs.sh"
{
    sed -n '/^env_escape() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^trim_ws() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^parse_env_value() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^load_config_file() {$/,/^}$/p' "$SCRIPT"
} > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# T1: env_escape strips embedded newline (no second-line injection on reload)
got=$(env_escape $'val1\nINJECTED=evil')
[[ "$got" == "val1INJECTED=evil" ]] && ok || bad "T1 newline not stripped: '$got'"

# T2: env_escape strips CR
got=$(env_escape $'a\rb')
[[ "$got" == "ab" ]] && ok || bad "T2 CR not stripped: '$got'"

# T3: env_escape escapes backslash and quote (round-trippable)
got=$(env_escape 'a\b"c')
[[ "$got" == 'a\\b\"c' ]] && ok || bad "T3 escape: '$got'"

# T4: load_config_file reads DB_NAME (the documented override)
cfg="$TMP_DIR/config.env"
DB_NAME=""; DB_USER=""
cat > "$cfg" <<'EOF'
DB_USER="myuser"
DB_NAME="mydb"
EOF
load_config_file "$cfg"
[[ "$DB_NAME" == "mydb" ]] && ok || bad "T4 DB_NAME not loaded: '$DB_NAME'"
[[ "$DB_USER" == "myuser" ]] && ok || bad "T4 DB_USER: '$DB_USER'"

# T5: a value that was escaped survives a config write+read round-trip
#     (write escaped value into config, load it back, expect the original)
orig='p@ss"w\rd'   # contains quote + backslash (no newline)
esc=$(env_escape "$orig")
printf 'BACKUP_PASSWORD="%s"\n' "$esc" > "$cfg"
BACKUP_PASSWORD=""
load_config_file "$cfg"
[[ "$BACKUP_PASSWORD" == "$orig" ]] && ok || bad "T5 round-trip: got '$BACKUP_PASSWORD' want '$orig'"

# T6: a newline-bearing value cannot inject a second key on reload
DB_USER="safe"
evil=$(env_escape $'x\nDB_USER=pwned')
printf 'BACKUP_TOKEN="%s"\n' "$evil" > "$cfg"
load_config_file "$cfg"
[[ "$DB_USER" == "safe" ]] && ok || bad "T6 injection: DB_USER overwritten to '$DB_USER'"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
