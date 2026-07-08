#!/usr/bin/env bash
# Remote backup over SSH (_backup_remote_target): the remote dump/tar stream over SSH and are
# compressed+combined LOCALLY into an archive byte-compatible with local backups (same inner names
# db_*.sql.gz / dir_*.tar.gz / bot_version.txt) so restore works unchanged. A mock `ssh` on PATH
# simulates the remote host (no real network/docker). Verifies the produced archive + its contents +
# that _build_target_ssh emits a correct ssh prefix only for transport=ssh.
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

# --- isolate ---
INSTALL_DIR="$TMP_DIR/inst"; BACKUP_DIR="$TMP_DIR/backup"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$TMP_DIR/silent.log"; LOG_FILE="$TMP_DIR/lz.log"
DEBUG_MODE=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
COMPRESSION="gzip"; BACKUP_PASSWORD=""; PG_DUMP_TIMEOUT_SEC=60; TAR_TIMEOUT_SEC=60
REMOTE_STORAGE_TYPE="off"; SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"; DELETE_MODE="time"; RETENTION_DAYS=7
BACKUP_LOG_FILES="false"; BACKUP_TARGET="bot"; BACKUP_PREFIX="lazarus"
BOT_PATH="/remote/opt/bot"; DB_CONTAINER_NAME="rwp_shop_db"; DB_USER="postgres"; DB_NAME=""
# stub lock + delivery (avoid lockfile/network deps)
acquire_lock() { return 0; }; release_lock() { :; }; check_lock_owner() { echo 0; }
upload_to_remote() { return 0; }; send_telegram_document() { return 0; }

# --- mock ssh on PATH: dispatch on the remote-command (last arg) ---
MOCK="$TMP_DIR/bin"; mkdir -p "$MOCK"
SRC="$TMP_DIR/remote_src/bot"; mkdir -p "$SRC"; echo "botfile" > "$SRC/app.conf"; echo "log" > "$SRC/x.log"
cat > "$MOCK/ssh" <<MOCKEOF
#!/usr/bin/env bash
cmd="\${!#}"   # last positional arg = remote command
printf '%s\n' "\$cmd" >> "$TMP_DIR/ssh_cmds.log"
case "\$cmd" in
  true) exit 0 ;;
  *pg_isready*) exit 0 ;;
  *cat*.env*) printf 'POSTGRES_USER=postgres\nPOSTGRES_DB=botdb\n'; exit 0 ;;
  *pg_dumpall*globals*) printf -- '-- roles\nCREATE ROLE postgres;\n'; exit 0 ;;
  *pg_dump*) for i in \$(seq 1 80); do echo "INSERT INTO t VALUES (\$i,'row-\$i-padding');"; done; exit 0 ;;
  *"tar cf -"*) tar cf - -C "$TMP_DIR/remote_src" bot 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/ssh"
TARGET_SSH="ssh -p 22 -o BatchMode=yes user@remotehost"
export PATH="$MOCK:$PATH"

# --- 1) _build_target_ssh: ssh prefix only for transport=ssh ---
# AUDIT v2: _build_target_ssh теперь ВАЛИДИРУЕТ существование ключа + whitelist полей.
_KEYF="$MOCK/k.pem"; : > "$_KEYF"   # реальный (пустой) файл ключа — иначе key-existence guard отвергнет
BOT_TRANSPORT="local"; got=$(_build_target_ssh "bot"); [[ -z "$got" ]] && ok || bad "local transport must yield empty ssh: '$got'"
BOT_TRANSPORT="ssh"; BOT_SSH_HOST="1.2.3.4"; BOT_SSH_PORT="22"; BOT_SSH_USER="root"; BOT_SSH_KEY="$_KEYF"
got=$(_build_target_ssh "bot")
[[ "$got" == *"ssh -p 22"* && "$got" == *"-i $_KEYF"* && "$got" == *"root@1.2.3.4"* && "$got" == *"BatchMode=yes"* ]] && ok || bad "ssh prefix build: '$got'"
# guard: несуществующий ключ → пустой префикс (remote отключён)
BOT_SSH_KEY="/nonexistent-key.pem"; got=$(_build_target_ssh "bot" 2>/dev/null); [[ -z "$got" ]] && ok || bad "missing key must yield empty ssh: '$got'"
# guard: инъекция в host отвергается
BOT_SSH_KEY="$_KEYF"; BOT_SSH_HOST='1.2.3.4 -oProxyCommand=evil'; got=$(_build_target_ssh "bot" 2>/dev/null); [[ -z "$got" ]] && ok || bad "unsafe host must yield empty ssh: '$got'"
BOT_SSH_HOST="1.2.3.4"

# --- 2) remote db_only → valid archive with correct inner layout ---
TARGET_SSH="ssh -p 22 -o BatchMode=yes user@remotehost"
_backup_remote_target "db_only" >/dev/null 2>&1
arc=$(find "$BACKUP_DIR" -name 'lazarus_db_*.tar.gz' | head -1)
[[ -n "$arc" && -f "$arc" ]] && ok || bad "remote db_only produced no archive"
if [[ -n "$arc" ]]; then
    inner=$(tar -tzf "$arc" 2>/dev/null)
    grep -q "bot_version.txt" <<<"$inner" && ok || bad "archive missing bot_version.txt"
    grep -qE "db_.*\.sql\.gz" <<<"$inner" && ok || bad "archive missing db_*.sql.gz: $inner"
    # the inner dump must decompress to the mocked SQL
    tmpx="$TMP_DIR/x"; mkdir -p "$tmpx"; tar -xzf "$arc" -C "$tmpx"
    dbf=$(find "$tmpx" -name 'db_*.sql.gz' | head -1)
    gzip -dc "$dbf" 2>/dev/null | grep -q "INSERT INTO t" && ok || bad "inner dump not the streamed SQL"
fi

# --- 3) remote full → archive with BOTH db + dir, logs excluded ---
rm -f "$BACKUP_DIR"/lazarus_*
_backup_remote_target "full" >/dev/null 2>&1
arcf=$(find "$BACKUP_DIR" -name 'lazarus_full_*.tar.gz' | head -1)
[[ -n "$arcf" && -f "$arcf" ]] && ok || bad "remote full produced no archive"
if [[ -n "$arcf" ]]; then
    innerf=$(tar -tzf "$arcf" 2>/dev/null)
    grep -qE "db_.*\.sql\.gz" <<<"$innerf" && ok || bad "full: missing db"
    grep -qE "dir_.*\.tar\.gz" <<<"$innerf" && ok || bad "full: missing dir tar"
    # extract the dir tar and confirm app.conf present, *.log excluded
    tmpf="$TMP_DIR/xf"; mkdir -p "$tmpf"; tar -xzf "$arcf" -C "$tmpf"
    dirf=$(find "$tmpf" -name 'dir_*.tar.gz' | head -1)
    dirlist=$(tar -tzf "$dirf" 2>/dev/null)
    grep -q "bot/app.conf" <<<"$dirlist" && ok || bad "files tar missing app.conf: $dirlist"
fi
# Real code must PASS the exclude flags in the remote tar command (mock can't honor them).
# Globs are single-quoted to prevent remote glob-expansion.
grep -q -- "--exclude=.git" "$TMP_DIR/ssh_cmds.log" && ok || bad "remote tar missing --exclude=.git"
grep -qF -- "--exclude='*.log'" "$TMP_DIR/ssh_cmds.log" && ok || bad "remote tar missing --exclude='*.log' (logs off)"
grep -qF -- "--exclude='*.tar'" "$TMP_DIR/ssh_cmds.log" && ok || bad "remote tar missing --exclude='*.tar'"

# --- 4) panel remote produces globals sidecar in the archive ---
rm -f "$BACKUP_DIR"/lazarus_panel_*
BACKUP_TARGET="panel"; BACKUP_PREFIX="lazarus_panel"; DB_CONTAINER_NAME="remnawave-db"; BOT_PATH="/remote/opt/remnawave"
_backup_remote_target "db_only" >/dev/null 2>&1
arcp=$(find "$BACKUP_DIR" -name 'lazarus_panel_db_*.tar.gz' | head -1)
[[ -n "$arcp" ]] && tar -tzf "$arcp" 2>/dev/null | grep -qE "globals_.*\.sql\.gz" && ok || bad "panel remote: missing globals sidecar"

# --- 5) INJECTION: _shq must neutralize hostile .env values under a real shell RE-PARSE
#        (the remote ssh shell). A crafted POSTGRES_DB must NOT execute a command. ---
inj_probe="$TMP_DIR/PWNED"
for payload in \
    "mydb'; touch $inj_probe; echo '" \
    "mydb\"; touch $inj_probe; echo \"" \
    "mydb\$(touch $inj_probe)" \
    "mydb\`touch $inj_probe\`" \
    "mydb; touch $inj_probe"; do
    rm -f "$inj_probe"
    esc=$(_shq "$payload")
    # Simulate the remote shell parsing `pg_dump ... <esc>`: the value must come back VERBATIM
    # and no injected `touch` may run.
    out=$(sh -c "printf '%s' $esc" 2>/dev/null)
    [[ "$out" == "$payload" ]] && ok || bad "shq roundtrip altered value: '$out' != '$payload'"
    [[ ! -e "$inj_probe" ]] && ok || bad "INJECTION executed for payload: $payload"
done

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
