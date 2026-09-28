#!/usr/bin/env bash
# 6.0.4 (restore): регресс-тесты находок [5]–[9] аудита 6.0.3. Поведенческие, на настоящих функциях:
#  1) [5] _resolve_incremental_chain: безопасная ссылка (hardlink) в дереве стека → rc=0 и ровно одна
#     строка-путь в stdout, WARN виден в stderr; опасный symlink (python) → rc=1, причина — в stderr.
#  2) [5]+[7] execute_restore full на inc-цепочке: доходит до плана; compose в архиве ≠ живому →
#     вопрос конфликта задаётся, «2» → KEEP_INFRA=1, «3» → страховочная копия и .env из архива;
#     одинаковый compose → вопроса нет.
#  3) [8] get_restore_stage_root: bot_version.txt/manifest*.txt не считаются, ERROR — в stderr;
#     legacy files-архив ≤4.21 (bot_version.txt + каталог стека) в files_only доходит до плана.
#  4) [6] импорт globals панели (блок из execute_restore): без .env из архива у ALTER ROLE текущего
#     пользователя (и "в кавычках") убран только PASSWORD, остальные роли/строки байт в байт;
#     .env из архива (INCLUDE_ENV=true, полная замена) → поток без изменений.
#  5) [9] execute_restore .enc: пароль из BACKUP_PASSWORD (с пробелами по краям) — без вопроса (v2 и v1);
#     ввод как есть (IFS=), «pw » при пароле «pw» — успех в первой попытке; неверный — 3 попытки;
#     неподошедший BACKUP_PASSWORD не расходует попытки; v2 rc=2 — ERROR без ввода.
# Разрушительные шаги не достигаются: confirm_restore_target — заглушка «отказ» (после плана).
# Сеть: TG-функции — журналы, curl/wget/aws/rclone — функции-блокираторы и PATH-блокираторы (плюс
# ssh/scp/sftp/sshpass/nc); итоговая проверка «сети не было». rm/shred — только внутри каталога теста.
# LZ_604R_ONLY="1 4" — прогнать только указанные секции (для мутационной проверки).
# Счётчики n_ok/n_err (НЕ PASS=). Пароли фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lz604restore.XXXXXX") || { echo "FAIL: mktemp -d"; exit 1; }
# Windows-TMPDIR вида D:\… рвёт PATH на двоеточии диска — тогда каталог теста в /tmp
if [[ "$T" == *:* ]]; then command rm -rf "$T"; T=$(mktemp -d "/tmp/lz604restore.XXXXXX") || { echo "FAIL: mktemp -d /tmp"; exit 1; }; fi
[[ -n "$T" && "$T" != "/" && -d "$T" ]] || { echo "FAIL: bad test dir '$T'"; exit 1; }

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }
ONLY="${LZ_604R_ONLY:-}"
sec() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; command rm -rf "$T"; exit 1; }
trap 'command rm -rf "$T"' EXIT
LOCK_ACQUIRED="false"

# --- песочница удаления: только внутри $T; всё остальное — отказ + запись
: > "$T/rm.log"; : > "$T/rm_outside.log"
rm() {
    printf 'RM %s\n' "$*" >> "$T/rm.log"
    local a p
    for a in "$@"; do
        case "$a" in -*) continue ;; esac
        [[ "$a" == /* ]] && p="$a" || p="$PWD/$a"
        case "$p" in
            *"/../"*|*"/..") ;;
            "$T"/*) continue ;;
        esac
        printf 'RM_OUTSIDE %s\n' "$a" >> "$T/rm_outside.log"; return 1
    done
    command rm "$@"
}
shred() {
    printf 'SHRED %s\n' "$*" >> "$T/rm.log"
    local a
    for a in "$@"; do
        case "$a" in -*) continue ;; "$T"/*) continue ;; esac
        printf 'RM_OUTSIDE shred %s\n' "$a" >> "$T/rm_outside.log"; return 1
    done
    command rm -f "$@"
}

# --- сеть: функции-блокираторы + PATH-блокираторы
NETLOG="$T/net.log"; : > "$NETLOG"
curl()   { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
wget()   { printf 'wget %s\n' "$*" >> "$NETLOG"; return 4; }
aws()    { printf 'aws %s\n' "$*" >> "$NETLOG"; return 1; }
rclone() { printf 'rclone %s\n' "$*" >> "$NETLOG"; return 1; }
ssh()    { printf 'ssh %s\n' "$*" >> "$NETLOG"; return 255; }
scp()    { printf 'scp %s\n' "$*" >> "$NETLOG"; return 1; }
nc()     { printf 'nc %s\n' "$*" >> "$NETLOG"; return 1; }
MOCK="$T/bin"; mkdir -p "$MOCK"
for _nb in curl wget aws rclone ssh scp sftp sshpass nc; do
    cat > "$MOCK/$_nb" <<EOF
#!/usr/bin/env bash
echo "BLOCKED $_nb \$*" >> "$NETLOG"
exit 97
EOF
    chmod +x "$MOCK/$_nb"
done
# docker: только локальный мок — `exec -i … psql` пишет поток в MOCK_GL_CAPTURE, остальное rc=0
cat > "$MOCK/docker" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
  exec) if [[ "$2" == "-i" ]]; then cat > "${MOCK_GL_CAPTURE:-/dev/null}"; fi; exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/docker"
export PATH="$MOCK:$PATH"
export MOCK_GL_CAPTURE="$T/gl_capture.sql"

# --- Telegram: только журнал вызовов
TGLOG="$T/tg.log"; : > "$TGLOG"
send_telegram_notification() { :; }
send_telegram_alert()    { printf 'ALERT|%s|%s\n' "$1" "$2" >> "$TGLOG"; return 0; }
send_telegram_document() { printf 'DOC|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_text()    { printf 'TEXT|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_album()   { printf 'ALBUM|%s\n' "$1" >> "$TGLOG"; return 0; }
test_telegram_connection() { return 0; }

# --- окружение restore до плана; confirm_restore_target = «отказ» → дальше плана не идём
debug_log() { :; }
assert_target_identity() { return 0; }
require_rsync() { return 0; }
ensure_bot_path() { return 0; }
assert_safe_bot_path() { return 0; }
PLANLOG="$T/plan.log"
restore_rsync_preview() {
    printf 'PLAN|ROOT=%s|KEEP=%s|ENV=%s|MODE=%s\n' "${1##*/}" "${RESTORE_KEEP_INFRA:-}" "${RESTORE_INCLUDE_ENV:-}" "$MODE" >> "$PLANLOG"
    ( cd "$1" && find . -type f | LC_ALL=C sort ) >> "$PLANLOG"
    return 0
}
confirm_restore_target() { echo "CONFIRM_ASKED" >> "$PLANLOG"; return 1; }
# журнал вызовов расшифровки (пароли фиктивные) + управляемый rc (FAKE_DEC_ALL)
eval "$(declare -f _hmac_envelope_decrypt | sed '1s/^_hmac_envelope_decrypt/_real_hmac_decrypt/')"
FAKE_DEC_ALL=""
_hmac_envelope_decrypt() {
    printf '[%s]\n' "$3" >> "$T/dec_calls"
    [[ -n "$FAKE_DEC_ALL" ]] && return "$FAKE_DEC_ALL"
    _real_hmac_decrypt "$@"
}

INSTALL_DIR="$T/inst"; mkdir -p "$INSTALL_DIR"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_DIR="$T/bk"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
COMPRESSION="gzip"; BACKUP_PASSWORD=""; TARGET_SSH=""; BACKUP_TARGET="bot"
RESTORE_TIMEOUT_SEC=60; RESTORE_INCLUDE_ENV="false"; RESTORE_FORCE="false"
SEND_TO_TELEGRAM="false"; BOT_TOKEN="000000:fake-token-for-tests"; CHAT_ID="-100000"
DB_CONTAINER_NAME="rwp_shop_db"; DB_SERVICE_NAME="db"
RED=""; GREEN=""; YELLOW=""; GRAY=""; BOLD=""; RESET=""; CYAN=""; MAGENTA=""

cnt() { grep -c -- "$1" || true; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
reset_plan() { : > "$PLANLOG"; : > "$T/dec_calls"; }

# --- фикстуры: base full (dir-член с hardlink b.txt → a.txt) и inc поверх него
TS_B="2026-09-01_04_10_00"; TS_I="2026-09-02_04_10_00"; VER="7.1.0.56"
dbdump() { { echo "CREATE TABLE t (id int);"; for i in $(seq 1 40); do echo "INSERT INTO t VALUES ($i);"; done; } | gzip -9 > "$1"; }
mk_full() {   # $1 = ts, $2 = образ в compose, $3 = куда положить (каталог)
    local w="$T/w_full_$1"; command rm -rf "$w"; mkdir -p "$w/src/rwp-shop"
    printf 'services:\n  app:\n    image: bot:%s\n' "$2" > "$w/src/rwp-shop/docker-compose.yml"
    echo "base-a" > "$w/src/rwp-shop/a.txt"
    echo "old" > "$w/src/rwp-shop/old.txt"
    ln "$w/src/rwp-shop/a.txt" "$w/src/rwp-shop/b.txt"
    tar -czf "$w/dir_$1.tar.gz" -C "$w/src" rwp-shop
    echo "$VER" > "$w/bot_version.txt"; dbdump "$w/db_$1.sql.gz"
    # hardlink и во внешнем combine: проверяется каждый из 4 вызовов validate_tar_safety цепочки
    ln "$w/bot_version.txt" "$w/version_link.txt"
    tar -czf "$3/lazarus_full_$1__v$VER.tar.gz" -C "$w" bot_version.txt version_link.txt "db_$1.sql.gz" "dir_$1.tar.gz"
}
mk_inc() {    # $1 = ts, $2 = base ts
    local w="$T/w_inc_$1"; command rm -rf "$w"; mkdir -p "$w/src/rwp-shop"
    echo "inc-c" > "$w/src/rwp-shop/c.txt"
    ln "$w/src/rwp-shop/c.txt" "$w/src/rwp-shop/d.txt"
    tar -czf "$w/bot_files_inc_$1.tar.gz" -C "$w/src" rwp-shop/c.txt rwp-shop/d.txt
    echo "$VER" > "$w/bot_version.txt"; dbdump "$w/db_$1.sql.gz"
    printf '# lazarus manifest v1\n# base=%s\n' "$2" > "$w/manifest.txt"
    printf 'old.txt\n' > "$w/manifest_deletions.txt"
    ln "$w/bot_version.txt" "$w/version_link.txt"
    tar -czf "$BACKUP_DIR/lazarus_inc_$1__base_$2__v$VER.tar.gz" -C "$w" bot_version.txt version_link.txt manifest.txt \
        manifest_deletions.txt "db_$1.sql.gz" "bot_files_inc_$1.tar.gz"
}
mk_full "$TS_B" "1.0" "$BACKUP_DIR"
mk_inc "$TS_I" "$TS_B"
INC="$BACKUP_DIR/lazarus_inc_${TS_I}__base_${TS_B}__v$VER.tar.gz"
for _fx in "$T/w_full_$TS_B/dir_$TS_B.tar.gz" "$BACKUP_DIR/lazarus_full_${TS_B}__v$VER.tar.gz" \
           "$T/w_inc_$TS_I/bot_files_inc_$TS_I.tar.gz" "$INC"; do
    [[ "$(tar -tvzf "$_fx" | grep -c '^[lh]')" -ge 1 ]] && ok || bad "0pre фикстура: в ${_fx##*/} есть ссылка (hardlink)"
done
LIVE="$T/live"; mkdir -p "$LIVE"; BOT_PATH="$LIVE"

# ============================================================ 1) [5] stdout inc-цепочки = только путь
if sec 1; then
mkdir -p "$T/st1"
_resolve_incremental_chain "$INC" "$T/st1" "" > "$T/o1" 2> "$T/e1"; rc=$?
[[ $rc -eq 0 ]] && ok || bad "1a цепочка с безопасной ссылкой → rc=0 (rc=$rc): $(strip < "$T/e1" | tail -n 3)"
[[ "$(wc -l < "$T/o1" | tr -d ' ')" -eq 1 ]] && ok || bad "1b stdout — ровно одна строка: $(cat "$T/o1")"
p1=$(cat "$T/o1")
[[ "$p1" == "$T/st1/"* && -f "$p1" ]] && ok || bad "1c строка stdout — путь к merged внутри stage: '$p1'"
grep -q 'symlink/hardlink' "$T/e1" && ok || bad "1d WARN о ссылке виден оператору (stderr)"
# merged: base + overlay inc, удаление из manifest_deletions применено
if [[ -f "$p1" ]]; then
    mkdir -p "$T/x1"; tar -xzf "$p1" -C "$T/x1" 2>/dev/null
    _inner=$(find "$T/x1" -maxdepth 1 -name 'dir_merged.tar.gz' | head -1)
    _lst=$(tar -tzf "$_inner" 2>/dev/null)
    [[ "$_lst" == *"rwp-shop/c.txt"* && "$_lst" == *"rwp-shop/a.txt"* && "$_lst" != *"old.txt"* ]] \
        && ok || bad "1e merged: base + c.txt из inc, old.txt удалён: $_lst"
fi
# опасный symlink в base → rc=1, конкретная причина — в stderr (раньше терялась в $(...))
PY=$(command -v python3 || command -v python || true)
if [[ -n "$PY" ]]; then
    BK2="$T/bk2"; mkdir -p "$BK2" "$T/w_evil/src/rwp-shop"
    echo "x" > "$T/w_evil/src/rwp-shop/a.txt"
    "$PY" - "$T/w_evil/dir_$TS_B.tar.gz" "$T/w_evil/src" <<'PYEOF'
import sys, tarfile, io
out, src = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as t:
    t.add(src + "/rwp-shop", arcname="rwp-shop")
    ti = tarfile.TarInfo("rwp-shop/evil"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/passwd"
    t.addfile(ti)
PYEOF
    echo "$VER" > "$T/w_evil/bot_version.txt"; dbdump "$T/w_evil/db_$TS_B.sql.gz"
    tar -czf "$BK2/lazarus_full_${TS_B}__v$VER.tar.gz" -C "$T/w_evil" bot_version.txt "db_$TS_B.sql.gz" "dir_$TS_B.tar.gz"
    cp "$INC" "$BK2/"
    mkdir -p "$T/st1b"
    ( BACKUP_DIR="$BK2"; _resolve_incremental_chain "$BK2/${INC##*/}" "$T/st1b" "" > "$T/o1b" 2> "$T/e1b" ); rc=$?
    [[ $rc -eq 1 && ! -s "$T/o1b" ]] && ok || bad "1f опасный symlink → rc=1, stdout пуст (rc=$rc, out=$(cat "$T/o1b"))"
    grep -q 'НЕбезопасный symlink' "$T/e1b" && ok || bad "1g причина отказа (НЕбезопасный symlink) видна в stderr"
else
    echo "  SKIP 1f/1g: нет python для фикстуры опасного symlink"
fi
fi

# ============================================================ 2) [5]+[7] execute_restore full на inc
if sec 2; then
printf 'services:\n  app:\n    image: bot:2.0-fresh-install\n' > "$LIVE/docker-compose.yml"
printf 'LIVE_ENV=1\n' > "$LIVE/.env"
IS_INTERACTIVE=true
# 2a) compose отличается → вопрос; «2» = сохранить текущие compose/.env
reset_plan
out=$(printf 'y\n2\n' | execute_restore full "$INC" 2>&1 | strip); rc=$?
[[ "$out" == *"docker-compose в архиве ОТЛИЧАЕТСЯ"* ]] && ok || bad "2a inc: конфликт-гард задал вопрос (compose отличается): $(tail -n 5 <<< "$out")"
grep -q '^PLAN|ROOT=rwp-shop|KEEP=1|ENV=false|MODE=full$' "$PLANLOG" && ok || bad "2b inc: выбор 2 → KEEP_INFRA=1, план построен: $(head -n 1 "$PLANLOG")"
grep -qx './c.txt' "$PLANLOG" && grep -qx './d.txt' "$PLANLOG" && grep -qx './a.txt' "$PLANLOG" && grep -qx './b.txt' "$PLANLOG" && ! grep -qx './old.txt' "$PLANLOG" \
    && ok || bad "2c план из merged-дерева: a/b из base, c из inc, old.txt удалён: $(cat "$PLANLOG")"
grep -q 'CONFIRM_ASKED' "$PLANLOG" && [[ "$out" != *"Restore-chain failed"* ]] && ok || bad "2d inc-restore дошёл до подтверждения, без «Restore-chain failed»"
# 2e) «3» = точная копия: страховочная копия live compose/.env и .env из архива
reset_plan; command rm -rf "$BACKUP_DIR"/infra_replaced_*
out=$(printf 'y\n3\n' | execute_restore full "$INC" 2>&1 | strip)
_ib=$(find "$BACKUP_DIR" -maxdepth 1 -name 'infra_replaced_*' | head -1)
[[ -n "$_ib" && -f "$_ib/docker-compose.yml" && -f "$_ib/.env" ]] && ok || bad "2e inc: выбор 3 → страховочная копия live compose/.env: '$_ib'"
grep -q '^PLAN|ROOT=rwp-shop|KEEP=0|ENV=true|MODE=full$' "$PLANLOG" && ok || bad "2f inc: выбор 3 → .env из архива (ENV=true): $(head -n 1 "$PLANLOG")"
# 2g) compose совпадает с архивным → вопроса нет (гард не срабатывает ложно)
cp "$T/w_full_$TS_B/src/rwp-shop/docker-compose.yml" "$LIVE/docker-compose.yml"
reset_plan
out=$(printf 'y\n' | execute_restore full "$INC" 2>&1 | strip)
[[ "$out" != *"ОТЛИЧАЕТСЯ"* ]] && grep -q '^PLAN|ROOT=rwp-shop|KEEP=0|ENV=false|MODE=full$' "$PLANLOG" \
    && ok || bad "2g одинаковый compose → без вопроса, KEEP=0: $(head -n 1 "$PLANLOG")"
IS_INTERACTIVE=false
command rm -f "$LIVE/docker-compose.yml" "$LIVE/.env"
fi

# ============================================================ 3) [8] корень stage и legacy files-архив
if sec 3; then
S3="$T/s3"
mkdir -p "$S3/a/rwp-shop"; echo 7 > "$S3/a/bot_version.txt"; echo m > "$S3/a/manifest.txt"; : > "$S3/a/manifest_deletions.txt"
get_restore_stage_root "$S3/a" > "$T/o3" 2> "$T/e3"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/o3")" == "$S3/a/rwp-shop" ]] && ok || bad "3a служебные файлы не считаются → корень rwp-shop (rc=$rc, '$(cat "$T/o3")')"
mkdir -p "$S3/b/one" "$S3/b/two"
get_restore_stage_root "$S3/b" > "$T/o3" 2> "$T/e3"; rc=$?
[[ $rc -eq 1 && ! -s "$T/o3" ]] && ok || bad "3b два каталога → rc=1, stdout пуст (rc=$rc)"
grep -q 'Ожидалась одна корневая папка' "$T/e3" && ok || bad "3c ERROR о корне — в stderr (виден при \$(...))"
mkdir -p "$S3/c/rwp-shop"; echo x > "$S3/c/notes.txt"
get_restore_stage_root "$S3/c" > /dev/null 2>&1 && bad "3d посторонний файл рядом с каталогом по-прежнему отказ" || ok
mkdir -p "$S3/d"; echo 7 > "$S3/d/bot_version.txt"
get_restore_stage_root "$S3/d" > /dev/null 2>&1 && bad "3e только bot_version.txt → отказ (нет каталога)" || ok
# legacy files-архив ≤4.21: tar -czf FINAL -C BACKUP_DIR bot_version.txt -C <parent> <botdir>
L="$T/legacy"; mkdir -p "$L/stage/rwp-shop/data"
echo "$VER" > "$L/bot_version.txt"
printf 'services: {}\n' > "$L/stage/rwp-shop/docker-compose.yml"; echo "d" > "$L/stage/rwp-shop/data/app.json"
tar -czf "$L/lazarus_files_2025-12-01_04_10_00.tar.gz" -C "$L" bot_version.txt -C "$L/stage" rwp-shop
reset_plan
out=$(execute_restore files_only "$L/lazarus_files_2025-12-01_04_10_00.tar.gz" < /dev/null 2>&1 | strip)
grep -q '^PLAN|ROOT=rwp-shop|KEEP=0|ENV=false|MODE=files_only$' "$PLANLOG" && ok || bad "3f legacy files-архив → files_only дошёл до плана: $(tail -n 4 <<< "$out")"
grep -qx './data/app.json' "$PLANLOG" && ! grep -q 'bot_version.txt' "$PLANLOG" && ok || bad "3g источник rsync — каталог стека, без bot_version.txt: $(cat "$PLANLOG")"
fi

# ============================================================ 4) [6] globals: пароль текущей роли
if sec 4; then
GL_BLK=$(awk '/^        if \[\[ -n "\$GLOBALS_DUMP" && -f "\$GLOBALS_DUMP" && "\$BACKUP_TARGET" == "panel" \]\]; then$/ {f=1} f {print} f && /^        fi$/ {exit}' "$SCRIPT")
[[ "$GL_BLK" == *'"psql-globals"'* && "$GL_BLK" == *'docker exec -i'* ]] && ok || bad "4pre блок импорта globals извлечён из execute_restore"
# многострочная awk-программа не должна давать «}» в первой колонке: инструменты и тесты режут функцию
# по /^}$/ — execute_restore, вырезанная так, обязана загружаться целиком (до хвоста с return 4)
( source <(sed -n '/^execute_restore() {$/,/^}$/p' "$SCRIPT") 2>/dev/null && declare -f execute_restore | grep -q '_sidecar_fail' \
    && declare -f execute_restore | grep -q 'psql-globals' && declare -f execute_restore | grep -q 'return 4' ) \
    && ok || bad "4pre2 execute_restore, вырезанная по /^}\$/, загружается целиком"
eval "_t_globals() {
    local GLOBALS_DUMP=\"\$1\" MODE=\"\$2\" RESTORE_INCLUDE_ENV=\"\$3\" RESTORE_KEEP_INFRA=\"\$4\" ACTUAL_DB_USER=\"\$5\"
    local BACKUP_TARGET=panel DB_CONTAINER_NAME=remnawave-db ACTUAL_DB_NAME=postgres
$GL_BLK
}"
G="$T/g"; mkdir -p "$G"
cat > "$G/globals.sql" <<'SQLEOF'
--
-- PostgreSQL database cluster dump
--
SET default_transaction_read_only = off;
CREATE ROLE app_ro;
ALTER ROLE app_ro WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:ro$x:y';
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:a$b:c';
CREATE ROLE "Admin";
ALTER ROLE "Admin" WITH SUPERUSER LOGIN PASSWORD 'md5abc' VALID UNTIL 'infinity';
ALTER ROLE postgres SET search_path TO public;
GRANT app_ro TO postgres;
SQLEOF
gzip -9c "$G/globals.sql" > "$G/globals_$TS_B.sql.gz"
run_gl() { : > "$MOCK_GL_CAPTURE"; _t_globals "$G/globals_$TS_B.sql.gz" "$@" > "$T/o4" 2>&1; }
line_of() { grep -F -- "$1" "$MOCK_GL_CAPTURE"; }
# 4a) full, .env не из архива → у postgres PASSWORD убран, остальное как есть
run_gl full false 0 postgres; rc=$?
[[ $rc -eq 0 ]] && ok || bad "4a rc импорта globals = 0 (rc=$rc): $(cat "$T/o4")"
[[ "$(line_of 'ALTER ROLE postgres WITH')" == "ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS;" ]] \
    && ok || bad "4b postgres: PASSWORD убран, атрибуты целы: '$(line_of 'ALTER ROLE postgres WITH')'"
[[ "$(line_of 'ALTER ROLE app_ro')" == "ALTER ROLE app_ro WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256\$4096:ro\$x:y';" ]] \
    && ok || bad "4c app_ro: пароль остался: '$(line_of 'ALTER ROLE app_ro')'"
diff <(grep -v '^ALTER ROLE postgres WITH' "$G/globals.sql") <(grep -v '^ALTER ROLE postgres WITH' "$MOCK_GL_CAPTURE") > /dev/null \
    && [[ "$(wc -l < "$MOCK_GL_CAPTURE")" -eq "$(wc -l < "$G/globals.sql")" ]] \
    && ok || bad "4d прочие строки (в т.ч. ALTER ROLE postgres SET без PASSWORD) — байт в байт"
grep -q "PASSWORD stripped for ALTER ROLE postgres" "$LOG_FILE" && ok || bad "4e след в логе о снятом пароле роли"
# 4f) роль в кавычках ("Admin") — тоже распознаётся; postgres при этом не трогается
run_gl full false 0 Admin
[[ "$(line_of 'ALTER ROLE "Admin"')" == "ALTER ROLE \"Admin\" WITH SUPERUSER LOGIN VALID UNTIL 'infinity';" \
   && "$(line_of 'ALTER ROLE postgres WITH')" == *"PASSWORD 'SCRAM-SHA-256\$4096:a\$b:c';" ]] \
    && ok || bad "4f \"Admin\": пароль убран, VALID UNTIL цел; postgres не тронут: '$(line_of 'ALTER ROLE "Admin"')'"
# 4g) .env из архива (INCLUDE_ENV=true, полная замена) → поток без изменений
run_gl full true 0 postgres
cmp -s "$G/globals.sql" "$MOCK_GL_CAPTURE" && ok || bad "4g INCLUDE_ENV=true + full → globals без фильтра"
# 4h) INCLUDE_ENV=true, но .env фактически НЕ из архива (db_only / keep-infra) → фильтр
run_gl db_only true 0 postgres
[[ "$(line_of 'ALTER ROLE postgres WITH')" != *PASSWORD* ]] && ok || bad "4h db_only + INCLUDE_ENV=true → пароль postgres убран (.env живой)"
run_gl full true 1 postgres
[[ "$(line_of 'ALTER ROLE postgres WITH')" != *PASSWORD* ]] && ok || bad "4i keep-infra + INCLUDE_ENV=true → пароль postgres убран (.env живой)"
# 4j) db_only без флага (частый случай после свежей установки) → фильтр
run_gl db_only false 0 postgres
[[ "$(line_of 'ALTER ROLE postgres WITH')" != *PASSWORD* && "$(line_of 'ALTER ROLE app_ro')" == *PASSWORD* ]] \
    && ok || bad "4j db_only → у postgres без пароля, у app_ro с паролем"
fi

# ============================================================ 5) [9] пароль restore
if sec 5; then
E="$T/enc"; mkdir -p "$E"
mk_full "2026-09-03_04_10_00" "1.0" "$E"
PLAIN="$E/lazarus_full_2026-09-03_04_10_00__v$VER.tar.gz"
PW_EDGE="  pw5 edge  "       # пароль с пробелами по краям (ручная правка .password)
PW_TRIM="pw5"               # обычный (сохранённый мастером — уже обрезанный)
V2E="$E/edge_full.tar.gz.enc"; V2T="$E/trim_full.tar.gz.enc"; V1E="$E/edge_v1_full.tar.gz.enc"
_hmac_envelope_create "$PLAIN" "$V2E" "$PW_EDGE" > /dev/null 2>&1
_hmac_envelope_create "$PLAIN" "$V2T" "$PW_TRIM" > /dev/null 2>&1
LAZARUS_ENC_PW="$PW_EDGE" openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$PLAIN" -out "$V1E" -pass env:LAZARUS_ENC_PW 2>/dev/null
[[ "$(head -c 4 "$V2E")" == "LAZ2" && "$(head -c 8 "$V1E")" == "Salted__" ]] && ok || bad "5pre v2/v1 архивы созданы"
ncalls() { wc -l < "$T/dec_calls" | tr -d ' '; }
plan_ok() { grep -q '^PLAN|ROOT=rwp-shop|' "$PLANLOG"; }
# 5a) BACKUP_PASSWORD с краями → без вопроса (stdin закрыт), одна расшифровка, план
reset_plan; BACKUP_PASSWORD="$PW_EDGE"
out=$(execute_restore full "$V2E" < /dev/null 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 1 && "$out" == *"Подошёл пароль из конфигурации"* && "$out" != *"Ввод пароля недоступен"* ]] \
    && ok || bad "5a v2: пароль из BACKUP_PASSWORD '  …  ' → без ввода (calls=$(ncalls)): $(tail -n 3 <<< "$out")"
grep -qxF "[$PW_EDGE]" "$T/dec_calls" && ok || bad "5b BACKUP_PASSWORD передан байт в байт (края сохранены)"
# 5c) то же для v1 (rc=0 + gzip -t)
reset_plan
out=$(execute_restore full "$V1E" < /dev/null 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 1 ]] && ok || bad "5c v1: пароль из BACKUP_PASSWORD → без ввода (calls=$(ncalls)): $(tail -n 3 <<< "$out")"
# 5d) fresh-сервер: BACKUP_PASSWORD пуст, ввод «  pw5 edge  » как есть (IFS=) → первая попытка
reset_plan; BACKUP_PASSWORD=""
out=$(printf '%s\n' "$PW_EDGE" | execute_restore full "$V2E" 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 1 ]] && ok || bad "5d ввод с краями сохраняется (IFS= read) → успех с 1 расшифровки (calls=$(ncalls)): $(tail -n 3 <<< "$out")"
# 5e) ввод «pw5 » при пароле «pw5» → успех в ПЕРВОЙ попытке (повтор с обрезанным в той же попытке)
reset_plan
out=$(printf '%s\n' "$PW_TRIM " | execute_restore full "$V2T" 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 2 && "$out" != *"HMAC не совпал"* ]] && ok || bad "5e 'pw5 ' → успех в 1-й попытке (calls=$(ncalls)): $(tail -n 3 <<< "$out")"
[[ "$(sed -n 2p "$T/dec_calls")" == "[$PW_TRIM]" ]] && ok || bad "5f вторая расшифровка — обрезанным вариантом: $(cat "$T/dec_calls")"
# 5g) неверный пароль → 3 попытки и отказ; с краями — по 2 прохода на попытку, попыток всё равно 3
reset_plan
out=$(printf 'bad1\nbad2\nbad3\n' | execute_restore full "$V2T" 2>&1 | strip); rc=$?
[[ $rc -ne 0 && "$(ncalls)" -eq 3 && "$(cnt 'HMAC не совпал' <<< "$out")" -eq 3 && "$out" == *"после 3 попыток"* ]] && ! plan_ok \
    && ok || bad "5g неверный → 3 попытки (calls=$(ncalls)): $(tail -n 2 <<< "$out")"
reset_plan
out=$(printf ' bad1 \n bad2 \n bad3 \n' | execute_restore full "$V2T" 2>&1 | strip)
[[ "$(ncalls)" -eq 6 && "$(cnt 'HMAC не совпал' <<< "$out")" -eq 3 && "$out" == *"после 3 попыток"* ]] \
    && ok || bad "5h неверный с краями → 3 попытки по 2 прохода (calls=$(ncalls))"
# 5i) только пробелы — как пустой: попытка не засчитана
reset_plan
out=$(printf '   \n%s\n' "$PW_TRIM" | execute_restore full "$V2T" 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 1 && "$out" == *"попытка не засчитана"* && "$out" != *"HMAC не совпал"* ]] \
    && ok || bad "5i ввод из пробелов не засчитан как попытка (calls=$(ncalls))"
# 5j) BACKUP_PASSWORD не подошёл → обычный ввод, попытки не расходуются (3-я введённая — верная)
reset_plan; BACKUP_PASSWORD="other-config-pass"
out=$(printf 'bad1\nbad2\n%s\n' "$PW_TRIM" | execute_restore full "$V2T" 2>&1 | strip)
plan_ok && [[ "$(ncalls)" -eq 4 && "$out" == *"к этому архиву не подошёл"* && "$(cnt 'HMAC не совпал' <<< "$out")" -eq 2 ]] \
    && ok || bad "5j неподошедший BACKUP_PASSWORD не съел попытку (calls=$(ncalls)): $(tail -n 3 <<< "$out")"
# 5k) EOF после неподошедшего BACKUP_PASSWORD → прежний выход «ввод недоступен»
reset_plan
out=$(execute_restore full "$V2T" < /dev/null 2>&1 | strip); rc=$?
[[ $rc -eq 1 && "$out" == *"Ввод пароля недоступен"* ]] && ! plan_ok && ok || bad "5k EOF → rc=1 «Ввод пароля недоступен» (rc=$rc)"
# 5l) v2 rc=2 на пароле из конфигурации → ERROR «не выполнена», без ввода и без повторов
reset_plan; FAKE_DEC_ALL=2
out=$(printf 'x1\nx2\nx3\n' | execute_restore full "$V2T" 2>&1 | strip); rc=$?
[[ $rc -eq 1 && "$(ncalls)" -eq 1 && "$out" == *"Расшифровка не выполнена"* && "$out" != *"после 3 попыток"* ]] \
    && ok || bad "5l v2 rc=2 (BACKUP_PASSWORD) → одна попытка, ERROR (calls=$(ncalls)): $(tail -n 2 <<< "$out")"
FAKE_DEC_ALL=""; BACKUP_PASSWORD=""
# 5m) расшифрованные временные файлы restore не остаются (TMP_DIR убран на всех путях)
[[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'lazarus_restore.*' 2>/dev/null)" ]] && ok || bad "5m temp-каталоги restore убраны: $(ls "$TMPDIR")"
fi

# ============================================================ итог: сеть и удаления вне песочницы
[[ ! -s "$NETLOG" ]] && ok || bad "сеть не использовалась: $(head -n 3 "$NETLOG")"
[[ ! -s "$T/rm_outside.log" ]] && ok || bad "rm/shred вне каталога теста: $(head -n 3 "$T/rm_outside.log")"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
