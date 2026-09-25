#!/usr/bin/env bash
# 6.0.3: регресс-тесты правок по состязательному ревью объединённых веток (7200974) и стыков веток
# integrity × sidecars × security. Поведенческие, где реально:
#  1) открытый combine (*.part) и сайдкар-дампы globals/billing/KB — sensitive сразу (create_backup
#     db_only/files_only/full, инкремент); после прогона *.part нет, итоговый архив на месте.
#  2) resolve_bot_runtime: remnawave-telegram-shop-bot не отсекается подстрокой 'remnawave' при
#     пустом/панельном/DB BOT_CONTAINER_NAME; панельный контейнер в проекте бота — отсекается;
#     прод-набор (rwp_shop …) не сломан.
#  3) bot_down: restarting/paused — «работает» (compose stop <svc>, paused — сперва unpause); stop не
#     помог → ERROR; exited — «уже остановлен» без вызовов.
#  4) _ask_target_location, ручной путь: Enter на вопрос БД = прежний контейнер (тот же путь), иначе
#     найденный find_db_container_for_path, иначе rwp_shop_db; панельное имя в дефолт не идёт.
#  5) _ask_target_location: working_dir живого бота ≠ путь из конфига → берётся живой (WARN), БД
#     перевыводится для живого каталога.
#  6) install_script, ветка cp: cp упал → exit 1, установленный файл тот же (inode и байты), temp убран;
#     успех → новый inode (mv), новое содержимое, exec с ORIGINAL_ARGS.
#  7) upload_to_remote FTP/WebDAV: HEAD (_curl_with_auth -sI) rc≠0 → REMOTE_UPLOAD_SIZE_UNVERIFIED=true,
#     delete-local копию не удаляет; HEAD без Content-Length / с ним — прежние ветки.
#  8) меню both: счётчик и «Последний» вторичной цели не видят *.part.
#  9) create_backup: verify rc=2 → «непроверенный архив не распространяем», без «битый».
# 10) одиночный _backup_remote_target: «Неполный архив: …» в подписи send_telegram_document.
# 11) локальный full панели: «без PANEL_EXTRA_PATHS» ровно один раз (два пропавших пути; сбой
#     tar-extra; пропавший путь + сбой tar-extra) — в подписи одиночного режима и в метке both.
# 12) restore: rc=2 расшифровки v2 → ERROR «Расшифровка не выполнена», одна попытка; v1 — повтор ввода.
# 13) стык integrity×sidecars: both, пароль, billing exited(auto), verify rc=2 → нет *.part, метка
#     «без infra-billing», в сводке «не проверен» в той же строке, архив сохранён локально.
# 14) стык security×create_backup: mktemp для _tar_err падает (обе попытки) → бэкап создан,
#     rm /dev/null не вызывается.
# Сеть не используется: TG-функции — журналы; curl/wget/aws/rclone — функции-блокираторы и
# PATH-блокираторы (плюс scp/sftp/sshpass/nc), ssh — локальный мок; итоговая проверка «сети не было».
# rm/shred — только внутри каталога теста (иначе отказ и запись в rm_outside.log).
# LZ_REVIEW_ONLY="1 9" — прогнать только указанные секции (для мутационной проверки).
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске). Секреты фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lzrev603.XXXXXX") || { echo "FAIL: mktemp -d"; exit 1; }
# Windows-TMPDIR вида D:\… рвёт PATH на двоеточии диска — тогда каталог теста в /tmp
if [[ "$T" == *:* ]]; then command rm -rf "$T"; T=$(mktemp -d "/tmp/lzrev603.XXXXXX") || { echo "FAIL: mktemp -d /tmp"; exit 1; }; fi
[[ -n "$T" && "$T" != "/" && -d "$T" ]] || { echo "FAIL: bad test dir '$T'"; exit 1; }

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }
ONLY="${LZ_REVIEW_ONLY:-}"
sec() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; command rm -rf "$T"; exit 1; }
trap 'command rm -rf "$T"' EXIT
# RETURN-trap бэкап-функций ссылается на LOCK_ACQUIRED — глобал нужен и вне функции.
LOCK_ACQUIRED="false"

# --- песочница удаления: только внутри $T; всё остальное — отказ + запись (мутация не сотрёт /dev/null и т.п.)
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
    command shred "$@"
}

# --- сеть: функции-блокираторы + PATH-блокираторы (на случай `command curl` и внешних процессов)
NETLOG="$T/net.log"; : > "$NETLOG"
curl()   { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
wget()   { printf 'wget %s\n' "$*" >> "$NETLOG"; return 4; }
aws()    { printf 'aws %s\n' "$*" >> "$NETLOG"; return 1; }
rclone() { printf 'rclone %s\n' "$*" >> "$NETLOG"; return 1; }
MOCK="$T/bin"; mkdir -p "$MOCK"
for _nb in curl wget aws rclone scp sftp sshpass nc; do
    cat > "$MOCK/$_nb" <<EOF
#!/usr/bin/env bash
echo "BLOCKED $_nb \$*" >> "$NETLOG"
exit 97
EOF
    chmod +x "$MOCK/$_nb"
done

# --- Telegram: только журнал вызовов
TGLOG="$T/tg.log"; : > "$TGLOG"
send_telegram_notification() { :; }
send_telegram_alert()    { printf 'ALERT|%s|%s\n' "$1" "$2" >> "$TGLOG"; return 0; }
send_telegram_document() { printf 'DOC|%s\n%s\n' "$1" "$2" >> "$TGLOG"; return 0; }
_send_telegram_text()    { printf 'TEXT|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_album()   { printf 'ALBUM|%s\n' "$1" >> "$TGLOG"; return 0; }
test_telegram_connection() { return 0; }

# --- окружение: лок, гард идентичности, версии; настоящий upload_to_remote — под другим именем (секция 7)
debug_log() { :; }
acquire_lock() { return 0; }; release_lock() { :; }; check_lock_owner() { echo 0; }
assert_target_identity() { return 0; }; _ensure_encryption_or_confirm() { return 0; }
get_backup_version() { echo "1.2.3"; }; get_app_version() { echo "1.2.3"; }
get_db_user() { echo "postgres"; }; get_db_name() { echo "appdb"; }
ensure_bot_path() { return 0; }
eval "$(declare -f upload_to_remote | sed '1s/^upload_to_remote/_real_upload_to_remote/')"
upload_to_remote() { REMOTE_UPLOAD_STATUS_TEXT=""; REMOTE_UPLOAD_SIZE_UNVERIFIED="false"; printf 'UPLOAD|%s\n' "$1" >> "$TGLOG"; return 0; }

INSTALL_DIR="$T/inst"; mkdir -p "$INSTALL_DIR"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_PASSWORD_FILE="$INSTALL_DIR/.backup_password"
BACKUP_DIR="$T/bk"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
COMPRESSION="gzip"; BACKUP_PASSWORD=""; PG_DUMP_TIMEOUT_SEC=60; TAR_TIMEOUT_SEC=60
REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"; SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"
DELETE_MODE="time"; RETENTION_DAYS=7; MAX_BACKUPS_COUNT=50; MAX_BACKUP_SIZE_MB=0
DISK_WARN_PERCENT=101; DISK_CRITICAL_PERCENT=101; DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"
BOT_TOKEN="000000:fake-token-for-tests"; CHAT_ID="-100000"; TG_MESSAGE_THREAD_ID=""
BACKUP_LOG_FILES="false"; MAX_FILE_SIZE_MB=50; EXCLUDE_DIRS=""; _BOTH_TG_DEFER=""
PW="fixture-pass-603r"   # фиктивный пароль

# --- мок docker в PATH (его зовут и через внешний timeout, и из bash -c). Состояние сайдкаров —
# экспортируемые MOCK_BILL_STATE / MOCK_KB_STATE (пусто = контейнера нет).
cat > "$MOCK/docker" <<'MOCKEOF'
#!/usr/bin/env bash
st_of() { case "$1" in *billing*) printf '%s' "${MOCK_BILL_STATE:-}" ;; *kb*) printf '%s' "${MOCK_KB_STATE:-}" ;; *) printf 'running' ;; esac; }
case "$1" in
  info) exit 0 ;;
  container)
    case "$4" in *Running*) echo true ;; *) echo "" ;; esac; exit 0 ;;
  inspect)
    fmt="$3"; name="${!#}"; s=$(st_of "$name")
    case "$fmt" in
      *'{{.Config.Image}}|'*)
        [[ -z "$s" ]] && exit 1
        case "$name" in
          *billing*) echo "postgres:17|/opt/remnawave|infra-billing-db" ;;
          *kb*)      echo "pgvector/pgvector:pg17|/opt/rwp-shop|rwp_shop_kb_db" ;;
          *)         echo "postgres:17||" ;;
        esac ;;
      '{{.Config.Image}}') [[ -z "$s" ]] && exit 1; echo "pgvector/pgvector:pg17" ;;
      '{{.State.Status}}') [[ -z "$s" ]] && exit 1; echo "$s" ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
  exec)
    case "$*" in
      *pg_isready*) exit 0 ;;
      *pg_dumpall*) printf -- '-- roles\nCREATE ROLE postgres;\n' ;;
      *pg_dump*)
        echo "CREATE TABLE t (id int);"; for i in $(seq 1 80); do echo "INSERT INTO t VALUES ($i,'row-$i-padding');"; done ;;
      *"printenv POSTGRES_USER"*) echo "u" ;;
      *"printenv POSTGRES_DB"*) echo "d" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/docker"
# мок ssh: ничего никуда не подключает — исполняет «удалённые» команды локально по шаблонам
cat > "$MOCK/ssh" <<MOCKEOF
#!/usr/bin/env bash
cmd="\${!#}"
printf '%s\n' "\$cmd" >> "$T/ssh_cmds.log"
case "\$cmd" in
  true) exit 0 ;;
  *pg_isready*) exit 0 ;;
  *"State.Status}}|{{.Config.Image"*) [[ -n "\${MOCK_RBILL:-}" ]] && echo "\$MOCK_RBILL"; exit 0 ;;
  *"docker ps -a"*) exit 0 ;;
  *pg_dumpall*globals*) printf -- '-- roles\nCREATE ROLE postgres;\n'; exit 0 ;;
  *pg_dump*) for i in \$(seq 1 80); do echo "INSERT INTO t VALUES (\$i,'row-\$i-padding');"; done; exit 0 ;;
  *"tar cf -"*) tar cf - -C "$T/remote_src" bot 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/ssh"
mkdir -p "$T/remote_src/bot"; echo "botfile" > "$T/remote_src/bot/app.conf"
export PATH="$MOCK:$PATH"
export MOCK_BILL_STATE="" MOCK_KB_STATE="" MOCK_RBILL=""

# verify rc=2 (I/O / нет места): копия настоящей функции + обёртка для verify-вызовов
# (FAKE_VRC) и для всех вызовов restore-цикла (FAKE_DEC_ALL, журнал вызовов).
eval "$(declare -f _hmac_envelope_decrypt | sed '1s/^_hmac_envelope_decrypt/_real_hmac_decrypt/')"
FAKE_VRC=0; FAKE_DEC_ALL=""
_hmac_envelope_decrypt() {
    if [[ -n "$FAKE_DEC_ALL" ]]; then printf '%s\n' "$2" >> "$T/dec_calls"; return "$FAKE_DEC_ALL"; fi
    if [[ "$FAKE_VRC" -ne 0 && ( "$2" == *lazarus_verify* || "$2" == *lazarus_rverify* || "$2" == *lazarus_incverify* ) ]]; then return "$FAKE_VRC"; fi
    _real_hmac_decrypt "$@"
}

_panel_env() {
    BACKUP_TARGET="panel"; BACKUP_SECONDARY=""; BACKUP_PREFIX="lazarus_panel"; TARGET_SSH=""
    DB_CONTAINER_NAME="remnawave-db"; BOT_CONTAINER_NAME="remnawave"; BOT_PATH="$T/panel"; mkdir -p "$BOT_PATH"
    PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"
    PANEL_TRANSPORT="local"; BOT_TRANSPORT="local"; PANEL_EXTRA_PATHS=""
}
_bot_env() {
    BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; BACKUP_PREFIX="lazarus"; TARGET_SSH=""
    DB_CONTAINER_NAME="rwp_shop_db"; BOT_CONTAINER_NAME="rwp_shop"; BOT_PATH="$T/bot/rwp-shop"; mkdir -p "$BOT_PATH"
    BOT_KB_BACKUP="auto"; BOT_KB_DB_CONTAINER="rwp_shop_kb_db"; PANEL_DB_CONTAINER="remnawave-db"
    PANEL_BILLING_DB_CONTAINER="infra-billing-db"; BOT_TRANSPORT="local"; PANEL_TRANSPORT="local"
}
_rpanel_env() {
    BACKUP_TARGET="panel"; BACKUP_SECONDARY=""; BACKUP_PREFIX="lazarus_panel"; PANEL_TRANSPORT="ssh"
    BOT_PATH="/remote/opt/remnawave"; DB_CONTAINER_NAME="remnawave-db"
    PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"; PANEL_EXTRA_PATHS=""
    TARGET_SSH="ssh -p 21022 -o BatchMode=yes user@remotehost"
}
_last_arc() { find "$BACKUP_DIR" -maxdepth 1 -name "$1" | sort | tail -1; }
n_arch() { find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" | wc -l | tr -d ' '; }
reset_bk() { rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"; : > "$TGLOG"; : > "$LOG_FILE"; SENSITIVE_TMP_PATHS=(); }
both_reset() {
    _BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_SIZES=(); _BOTH_TG_BYTES=(); _BOTH_TG_ENC=(); _BOTH_TG_VERIFY=()
    _BOTH_TG_REMOTE_OK=(); _BOTH_TG_REMOTE_UNVERIFIED=(); _BOTH_TG_IS_REMOTE=(); _BOTH_TG_VER=(); _BOTH_TG_RSTATUS=()
    _BOTH_TG_SKIP=(); _BOTH_TG_SKIPCOUNT=(); _BOTH_TG_TYPE=""
}
# has_sens <glob>: есть ли в SENSITIVE_TMP_PATHS путь под шаблон
has_sens() { local p; for p in "${SENSITIVE_TMP_PATHS[@]}"; do [[ "$p" == $1 ]] && return 0; done; return 1; }
cnt() { grep -o -- "$1" | wc -l | tr -d ' '; }

# ============================================================ 1) *.part и сайдкар-дампы — sensitive сразу
if sec 1; then
# 1a) панель db_only с паролем, billing запущен: .part, globals, billing
_panel_env; MOCK_BILL_STATE="running"; BACKUP_PASSWORD="$PW"; reset_bk
create_backup "db_only" > "$T/o1" 2>&1; rc=$?
enc=$(_last_arc 'lazarus_panel_db_*.tar.gz.enc')
[[ $rc -eq 0 && -n "$enc" ]] && ok || bad "1a panel db_only с паролем → rc=0 и .enc (rc=$rc): $(grep -E 'ERROR|WARN' "$T/o1" | head -3)"
[[ "$(n_arch '*.part')" -eq 0 && "$(n_arch 'lazarus_panel_db_*.tar.gz')" -eq 0 ]] && ok || bad "1b после прогона нет ни *.part, ни открытого архива: $(ls "$BACKUP_DIR")"
[[ -n "$enc" ]] && has_sens "${enc%.enc}.part" && ok || bad "1c открытый combine (\${FILE_FINAL}.part) в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
has_sens "$BACKUP_DIR/globals_*" && ok || bad "1d globals-дамп (роли/хеши) в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
has_sens "$BACKUP_DIR/billing_*" && ok || bad "1e billing-дамп в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
grep -q '^UPLOAD|' "$TGLOG" && ok || bad "1f валидный архив доходит до выгрузки"
# 1g) бот db_only с паролем, KB запущена: .part + KB
_bot_env; MOCK_KB_STATE="running"; BACKUP_PASSWORD="$PW"; reset_bk
create_backup "db_only" > "$T/o1" 2>&1; rc=$?
enc=$(_last_arc 'lazarus_db_*.tar.gz.enc')
[[ $rc -eq 0 && -n "$enc" && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "1g бот db_only с паролем → rc=0, .enc есть, *.part нет (rc=$rc): $(ls "$BACKUP_DIR")"
[[ -n "$enc" ]] && has_sens "${enc%.enc}.part" && ok || bad "1h бот: .part в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
has_sens "$BACKUP_DIR/kb_*" && ok || bad "1i KB-дамп в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
# 1j) files_only и full без пароля: .part тоже регистрируется
_bot_env; MOCK_KB_STATE=""; BACKUP_PASSWORD=""; echo "cfg" > "$BOT_PATH/app.conf"
reset_bk
create_backup "files_only" > "$T/o1" 2>&1; rc=$?
arc=$(_last_arc 'lazarus_files_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "1j files_only → rc=0, архив есть, *.part нет (rc=$rc): $(ls "$BACKUP_DIR")"
[[ -n "$arc" ]] && has_sens "$arc.part" && ok || bad "1k files_only: .part в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
reset_bk
create_backup "full" > "$T/o1" 2>&1; rc=$?
arc=$(_last_arc 'lazarus_full_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "1l full → rc=0, архив есть, *.part нет (rc=$rc): $(ls "$BACKUP_DIR")"
[[ -n "$arc" ]] && has_sens "$arc.part" && ok || bad "1m full: .part в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
# 1n) инкремент: _inc_part регистрируется, после прогона .part нет
BASE_TS="2026-09-01_04_10_00"
_bot_env; BACKUP_PASSWORD=""; DB_CONTAINER_NAME=""; reset_bk
echo "a" > "$BOT_PATH/app.txt"
rm -rf "$T/basestage"; mkdir -p "$T/basestage"
_manifest_generate "$BOT_PATH" "$T/basestage/manifest.txt" >/dev/null 2>&1
echo "7.1" > "$T/basestage/bot_version.txt"
tar -czf "$BACKUP_DIR/lazarus_full_${BASE_TS}.tar.gz" -C "$T/basestage" manifest.txt bot_version.txt
touch -d '-1 hour' "$BACKUP_DIR/lazarus_full_${BASE_TS}.tar.gz"
echo "changed $RANDOM" >> "$BOT_PATH/app.txt"; sleep 1
create_incremental_backup > "$T/o1" 2>&1; rc=$?
inc=$(_last_arc 'lazarus_inc_*.tar.gz')
[[ $rc -eq 0 && -n "$inc" && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "1n inc → rc=0, архив есть, *.part нет (rc=$rc): $(grep -E 'ERROR' "$T/o1" | head -2) $(ls "$BACKUP_DIR")"
[[ -n "$inc" ]] && has_sens "$inc.part" && ok || bad "1o inc: _inc_part в SENSITIVE_TMP_PATHS: ${SENSITIVE_TMP_PATHS[*]}"
BACKUP_PASSWORD=""; MOCK_BILL_STATE=""; MOCK_KB_STATE=""
fi

# ============================================================ 9) verify rc=2: текст без «битый»
if sec 9; then
_bot_env; MOCK_KB_STATE=""; BACKUP_PASSWORD="$PW"; FAKE_VRC=2; reset_bk
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok || bad "9a verify rc=2 → create_backup rc≠0"
[[ "$out" == *"непроверенный архив не распространяем"* ]] && ok || bad "9b verify rc=2 → «непроверенный архив не распространяем»: $(grep -F 'Загрузка/отправка' <<< "$out")"
[[ "$out" != *"битый не распространяем"* ]] && ok || bad "9c verify rc=2 → без «битый не распространяем»"
grep -q 'Upload+TG skipped: verify not performed' "$LOG_FILE" && ok || bad "9d в логе «verify not performed»"
! grep -q '^UPLOAD|' "$TGLOG" && [[ "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "9e непроверенный: не выгружен, сохранён локально"
FAKE_VRC=1; reset_bk
out=$(create_backup "db_only" 2>&1)
[[ "$out" == *"битый не распространяем"* && "$out" != *"непроверенный архив"* ]] && ok || bad "9f verify rc=1 → прежнее «битый не распространяем»"
FAKE_VRC=0; BACKUP_PASSWORD=""
fi

# ============================================================ 10) одиночная удалённая цель: маркер в подписи
if sec 10; then
_rpanel_env; MOCK_RBILL="exited|postgres:17|infra-billing-db"; BACKUP_PASSWORD=""; _BOTH_TG_DEFER=""; reset_bk
out=$(_backup_remote_target "db_only" 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(_last_arc 'lazarus_panel_db_*.tar.gz')" ]] && ok || bad "10a удалённая панель db_only (billing exited) → rc=0 и архив (rc=$rc): $(grep -E 'ERROR' <<< "$out" | head -2)"
grep -q '#remote_backup (панель)' "$TGLOG" && ok || bad "10b одиночная подпись удалённого бэкапа отправлена: $(cat "$TGLOG")"
grep -q 'Неполный архив: без infra-billing' "$TGLOG" && ok || bad "10c в подписи «Неполный архив: без infra-billing»: $(cat "$TGLOG")"
MOCK_RBILL=""; reset_bk
_backup_remote_target "db_only" > /dev/null 2>&1
grep -q '#remote_backup' "$TGLOG" && ! grep -q 'Неполный архив' "$TGLOG" && ok || bad "10d billing нет — подпись без маркера: $(cat "$TGLOG")"
TARGET_SSH=""; PANEL_TRANSPORT="local"; MOCK_RBILL=""
fi

# ============================================================ 11) без PANEL_EXTRA_PATHS — ровно один маркер
if sec 11; then
_panel_env; MOCK_BILL_STATE=""; BACKUP_PASSWORD=""; echo "cfg" > "$BOT_PATH/panel.conf"
# 11a) два пропавших пути, одиночный режим
PANEL_EXTRA_PATHS="$T/nope-a,$T/nope-b"; reset_bk
out=$(create_backup "full" 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(_last_arc 'lazarus_panel_full_*.tar.gz')" ]] && ok || bad "11a panel full с пропавшими путями → rc=0 и архив (rc=$rc): $(grep -E 'ERROR' <<< "$out" | head -2)"
[[ "$(cnt 'путь не найден' <<< "$out")" -eq 2 ]] && ok || bad "11b WARN на каждый пропавший путь (2)"
[[ "$(cnt 'Без PANEL' < "$TGLOG")" -eq 1 ]] && ok || bad "11c подпись одиночного режима: «Без PANEL_EXTRA_PATHS» ровно 1 раз, got $(cnt 'Без PANEL' < "$TGLOG"): $(cat "$TGLOG")"
# 11d) то же в both: метка цели альбома — один маркер
both_reset; _BOTH_TG_DEFER="1"; reset_bk
create_backup "full" > /dev/null 2>&1
_BOTH_TG_DEFER=""
[[ "$(cnt 'без PANEL_EXTRA_PATHS' <<< "${_BOTH_TG_LABELS[0]:-}")" -eq 1 ]] && ok || bad "11d both: в метке «без PANEL_EXTRA_PATHS» ровно 1 раз: '${_BOTH_TG_LABELS[0]:-}'"
both_reset
# 11e) путь есть, но tar-extra упал (TAR_TIMEOUT_SEC=0 → tar зовётся напрямую, функция видна)
mkdir -p "$T/extra-dir"; echo "x" > "$T/extra-dir/f"
TAR_TIMEOUT_SEC=0
tar() { if [[ " $* " == *" -C / "* && " $* " == *"/extra_"* ]]; then echo "tar: simulated failure" >&2; return 2; fi; command tar "$@"; }
PANEL_EXTRA_PATHS="$T/extra-dir"; reset_bk
out=$(create_backup "full" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"extra-sidecar не создан"* ]] && ok || bad "11e сбой tar-extra → WARN, бэкап идёт (rc=$rc)"
[[ "$(cnt 'Без PANEL' < "$TGLOG")" -eq 1 ]] && ok || bad "11f сбой tar-extra: маркер ровно 1 раз, got $(cnt 'Без PANEL' < "$TGLOG")"
# 11g) пропавший путь + сбой tar-extra: маркер всё равно один
PANEL_EXTRA_PATHS="$T/nope-a,$T/extra-dir"; reset_bk
out=$(create_backup "full" 2>&1); rc=$?
[[ $rc -eq 0 && "$(cnt 'Без PANEL' < "$TGLOG")" -eq 1 ]] && ok || bad "11g пропавший путь + сбой tar-extra: маркер ровно 1 раз (rc=$rc), got $(cnt 'Без PANEL' < "$TGLOG")"
unset -f tar
TAR_TIMEOUT_SEC=60; PANEL_EXTRA_PATHS=""
fi

# ============================================================ 13) стык integrity × sidecars (both)
if sec 13; then
_panel_env; MOCK_BILL_STATE="exited"; PANEL_BILLING_BACKUP="auto"; BACKUP_PASSWORD="$PW"; FAKE_VRC=2; reset_bk
both_reset; _BOTH_TG_DEFER="1"; DELETE_LOCAL_AFTER_REMOTE_UPLOAD="any"
create_backup "db_only" > "$T/o13" 2>&1; rc=$?
_BOTH_TG_DEFER=""
enc=$(_last_arc 'lazarus_panel_db_*.tar.gz.enc')
[[ $rc -ne 0 && -n "$enc" ]] && ok || bad "13a both + пароль + verify rc=2 → rc≠0, .enc есть (rc=$rc): $(ls "$BACKUP_DIR")"
[[ "$(n_arch '*.part')" -eq 0 && "$(n_arch 'lazarus_panel_db_*.tar.gz')" -eq 0 ]] && ok || bad "13b ни *.part, ни открытого архива: $(ls "$BACKUP_DIR")"
grep -q 'не запущен (state=exited)' "$T/o13" && ok || bad "13c WARN про остановленный infra-billing"
[[ "${_BOTH_TG_LABELS[0]:-}" == *"без infra-billing"* ]] && ok || bad "13d метка цели с «без infra-billing»: '${_BOTH_TG_LABELS[0]:-}'"
[[ "${_BOTH_TG_VERIFY[0]:-}" == "unverified" ]] && ok || bad "13e статус прохода unverified: '${_BOTH_TG_VERIFY[0]:-}'"
SEND_TO_TELEGRAM="true"; TG_SEND_FILE="true"; : > "$TGLOG"
_both_tg_flush > "$T/o13f" 2>&1
SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"
grep -q '^TEXT|' "$TGLOG" && ! grep -qE '^(DOC|ALBUM)\|' "$TGLOG" && ok || bad "13f непроверенный архив не уходит файлом — только текст-сводка: $(cat "$TGLOG")"
grep -qE 'без infra.*не проверен' "$TGLOG" && ok || bad "13g в сводке маркер и «не проверен» в строке цели: $(cat "$TGLOG")"
[[ -n "$enc" && -f "$enc" ]] && ok || bad "13h непроверенный архив сохранён локально после flush (DELETE_LOCAL=any)"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"; FAKE_VRC=0; BACKUP_PASSWORD=""; MOCK_BILL_STATE=""; both_reset
fi

# ============================================================ 14) стык security × create_backup: _tar_err=/dev/null
if sec 14; then
_bot_env; MOCK_KB_STATE=""; BACKUP_PASSWORD=""; FAKE_VRC=0; echo "cfg" > "$BOT_PATH/app.conf"; reset_bk
: > "$T/rm.log"; : > "$T/mkt.log"
# обе попытки mktemp в create_backup (TMPDIR и /tmp/lazarus_tar_err.XXXXXX) падают; прочие — настоящие
mktemp() {
    if [[ "${FUNCNAME[1]:-}" == "create_backup" ]]; then printf 'MKT %s\n' "$*" >> "$T/mkt.log"; return 1; fi
    command mktemp "$@"
}
create_backup "full" > "$T/o14" 2>&1; rc=$?
unset -f mktemp
arc=$(_last_arc 'lazarus_full_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" ]] && ok || bad "14a mktemp для _tar_err недоступен → бэкап всё равно создан (rc=$rc): $(grep -E 'ERROR' "$T/o14" | head -2)"
[[ "$(grep -c '^MKT' "$T/mkt.log")" -eq 2 ]] && grep -q 'lazarus_tar_err' "$T/mkt.log" && ok || bad "14b прошли обе попытки mktemp (→ /dev/null): $(cat "$T/mkt.log")"
! grep -q '/dev/null' "$T/rm.log" && ok || bad "14c rm /dev/null НЕ вызывается: $(grep '/dev/null' "$T/rm.log")"
[[ "$(n_arch '*.part')" -eq 0 ]] && ok || bad "14d *.part не осталось"
fi

# ============================================================ 7) FTP/WebDAV: HEAD rc≠0 → размер не подтверждён
if sec 7; then
_sv_cwa=$(declare -f _curl_with_auth)
HEAD_MODE="fail"; HEAD_LEN=0
_curl_with_auth() {   # $1 user, $2 pass, дальше аргументы curl
    shift 2
    printf 'CWA %s\n' "$*" >> "$T/cwa.log"
    if [[ " $* " == *" -T "* ]]; then [[ "$REMOTE_STORAGE_TYPE" == "ftp" ]] && echo 226 || echo 201; return 0; fi
    if [[ " $* " == *" -sI "* ]]; then
        case "$HEAD_MODE" in
            fail)  return 7 ;;
            nolen) printf 'HTTP/1.1 200 OK\r\n'; return 0 ;;
            len)   printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n' "$HEAD_LEN"; return 0 ;;
        esac
    fi
    return 1
}
reset_bk
F7="$BACKUP_DIR/lazarus_db_2026-09-05_04_10_00.tar.gz.enc"; head -c 3000 /dev/urandom > "$F7"; SZ7=$(stat -c%s "$F7")
SEND_TO_REMOTE="true"; REMOTE_STORAGE_USER="fake-user"; REMOTE_STORAGE_PASS="fake-pass-7"
for _rt in ftp webdav; do
    REMOTE_STORAGE_TYPE="$_rt"
    if [[ "$_rt" == ftp ]]; then REMOTE_STORAGE_URL="ftp://store.example.invalid/bk"; else REMOTE_STORAGE_URL="https://dav.example.invalid/bk"; fi
    HEAD_MODE="fail"; : > "$T/cwa.log"; REMOTE_UPLOAD_SIZE_UNVERIFIED="false"
    _real_upload_to_remote "$F7" > "$T/o7" 2>&1; rc=$?
    [[ $rc -eq 0 ]] && ok || bad "7a $_rt: загрузка прошла, HEAD rc=7 → rc=0 (got $rc): $(cat "$T/o7")"
    grep -q -- ' -sI ' "$T/cwa.log" && ok || bad "7b $_rt: HEAD-проверка через _curl_with_auth -sI"
    [[ "$REMOTE_UPLOAD_SIZE_UNVERIFIED" == "true" ]] && ok || bad "7c $_rt: HEAD rc≠0 → REMOTE_UPLOAD_SIZE_UNVERIFIED=true, got '$REMOTE_UPLOAD_SIZE_UNVERIFIED'"
    [[ "$REMOTE_UPLOAD_STATUS_TEXT" == *"размер НЕ проверен"* ]] && grep -q 'HEAD rc=7' "$T/o7" && ok || bad "7d $_rt: статус «размер НЕ проверен» и WARN с rc: '$REMOTE_UPLOAD_STATUS_TEXT'"
    # следствие: delete-local (remote_only) при неподтверждённом размере локальную копию НЕ удаляет
    DELETE_LOCAL_AFTER_REMOTE_UPLOAD="remote_only"; : > "$LOG_FILE"
    _delete_local_after_send "${F7##*/}" "true" "false" "true" "$REMOTE_UPLOAD_SIZE_UNVERIFIED" > /dev/null 2>&1
    DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"
    [[ -f "$F7" ]] && ok || bad "7e $_rt: размер не подтверждён → локальная копия сохранена"
    [[ -f "$F7" ]] || { head -c 3000 /dev/urandom > "$F7"; SZ7=$(stat -c%s "$F7"); }
    grep -q 'verify/size not confirmed' "$LOG_FILE" && ok || bad "7f $_rt: в логе «verify/size not confirmed»"
    # контроль: HEAD успешен без Content-Length → «verify skipped», размер не «не подтверждён»
    HEAD_MODE="nolen"; _real_upload_to_remote "$F7" > "$T/o7" 2>&1; rc=$?
    [[ $rc -eq 0 && "$REMOTE_UPLOAD_SIZE_UNVERIFIED" == "false" && "$REMOTE_UPLOAD_STATUS_TEXT" == *"verify skipped"* ]] && ok || bad "7g $_rt: HEAD ok без Content-Length → verify skipped (rc=$rc, '$REMOTE_UPLOAD_SIZE_UNVERIFIED', '$REMOTE_UPLOAD_STATUS_TEXT')"
    HEAD_MODE="len"; HEAD_LEN="$SZ7"; _real_upload_to_remote "$F7" > "$T/o7" 2>&1; rc=$?
    [[ $rc -eq 0 && "$REMOTE_UPLOAD_STATUS_TEXT" == *"OK (verified)"* ]] && ok || bad "7h $_rt: размер совпал → verified (rc=$rc, '$REMOTE_UPLOAD_STATUS_TEXT')"
    HEAD_LEN=$(( SZ7 - 1 )); _real_upload_to_remote "$F7" > "$T/o7" 2>&1; rc=$?
    [[ $rc -ne 0 && "$REMOTE_UPLOAD_STATUS_TEXT" == *"размер не совпал"* ]] && ok || bad "7i $_rt: размер не совпал → rc≠0 (rc=$rc)"
done
eval "$_sv_cwa"
SEND_TO_REMOTE="false"; REMOTE_STORAGE_TYPE="off"; REMOTE_STORAGE_URL=""; REMOTE_STORAGE_USER=""; REMOTE_STORAGE_PASS=""
fi

# ============================================================ 6) install_script, ветка cp
if sec 6; then
IS_BODY=$(declare -f install_script)
P="$IS_BODY"
P=${P//'"$EUID" -ne 0'/'1 -eq 0'}
P=${P//'"$0"'/'"$FAKE0"'}
P=${P//'exec "$INSTALLED_SCRIPT_PATH"'/'exec bash "$INSTALLED_SCRIPT_PATH"'}
P=${P//'[[ -O "$INSTALLED_SCRIPT_PATH" ]]'/'true'}
[[ "$P" != "$IS_BODY" && "$P" == *'FAKE0'* && "$P" == *'exec bash'* ]] && ok || bad "6pre патч install_script применился"
eval "$P"
_sv_inst=("$INSTALL_DIR" "${SCRIPT_NAME:-}" "${SYMLINK_PATH:-}")
INSTALL_DIR="$T/inst6"; SCRIPT_NAME="lazarus-backup"; SYMLINK_PATH="$T/bin6/lazarus"
mkdir -p "$INSTALL_DIR" "$T/bin6"
INST="$INSTALL_DIR/$SCRIPT_NAME"
install_logrotate() { :; }
chown() { printf 'chown %s\n' "$*" >> "$T/perm.log"; return 0; }
ORIGINAL_ARGS=(backup_full --yes)
mk_script() {   # $1 файл, $2 метка, $3 маркер; первая строка после shebang — длинный комментарий
    { echo '#!/bin/bash'; echo "# $2 ........................................................................"; echo "echo \"$2 \$*\" > '$3'"; } > "$1"
}
mk_script "$INST" OLD "$T/RAN_OLD"; cp "$INST" "$T/inst_before"; ino0=$(stat -c %i "$INST")
mk_script "$T/new.sh" NEW "$T/RAN_NEW"; FAKE0="$T/new.sh"
leftovers6() { find "$INSTALL_DIR" -maxdepth 1 -name '.lazarus-backup.install.*' | wc -l | tr -d ' '; }
# 6a) cp упал посреди записи (ENOSPC): огрызок в цель + rc=1
cp() {
    local dst="${!#}" src="${@: -2:1}"
    if [[ "$dst" == "$INSTALL_DIR/"* ]]; then head -c 16 "$src" > "$dst"; return 1; fi
    command cp "$@"
}
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
unset -f cp
[[ $rc -eq 1 ]] && ok || bad "6a cp упал → exit 1 (got $rc): $out"
cmp -s "$INST" "$T/inst_before" && ok || bad "6b установленный файл байт в байт прежний"
[[ "$(stat -c %i "$INST")" == "$ino0" ]] && ok || bad "6c установленный файл — тот же inode"
[[ "$(leftovers6)" -eq 0 ]] && ok || bad "6d временный .lazarus-backup.install.* удалён"
[[ "$out" == *"Не удалось установить"* ]] && ok || bad "6e ERROR «Не удалось установить»: $out"
[[ ! -e "$T/RAN_NEW" && ! -e "$T/RAN_OLD" ]] && ok || bad "6f после провала ничего не исполнено"
# 6g) успех: атомарный mv — новый inode, новое содержимое, exec с ORIGINAL_ARGS
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -eq 0 ]] && ok || bad "6g успешная установка rc=0 (got $rc): $out"
cmp -s "$INST" "$T/new.sh" && ok || bad "6h установлено новое содержимое"
[[ "$(stat -c %i "$INST")" != "$ino0" ]] && ok || bad "6i новый inode (mv, не cp поверх исполняемого cron'ом файла)"
[[ "$(leftovers6)" -eq 0 ]] && ok || bad "6j временный файл не остался"
grep -q 'NEW backup_full --yes' "$T/RAN_NEW" 2>/dev/null && ok || bad "6k exec новой версии с ORIGINAL_ARGS"
unset -f chown
INSTALL_DIR="${_sv_inst[0]}"; SCRIPT_NAME="${_sv_inst[1]}"; SYMLINK_PATH="${_sv_inst[2]}"
fi

# ============================================================ 8) меню both: *.part вторичной цели не бэкапы
if sec 8; then
L_N=$(grep -m1 -F '_sec_n=$(find "$BACKUP_DIR"' "$SCRIPT" | sed 's/^[[:space:]]*//')
L_LAST=$(grep -m1 -F '_sec_last_f=$(find "$BACKUP_DIR"' "$SCRIPT" | sed 's/^[[:space:]]*//')
[[ -n "$L_N" && -n "$L_LAST" ]] && ok || bad "8pre строки счётчика/последнего вторичной цели найдены"
mkf() { echo "x" > "$BACKUP_DIR/$1"; touch -d "$2" "$BACKUP_DIR/$1"; }
reset_bk
mkf "lazarus_full_2026-09-01_04_10_00__v1.2.3.tar.gz.enc" '-3 hours'
mkf "lazarus_db_2026-09-02_04_10_00.tar.zst" '-2 hours'
mkf "lazarus_db_2026-09-03_04_10_00__v1.2.3.tar.gz.enc.part" '-10 minutes'
mkf "lazarus_files_2026-09-03_04_10_00.tar.gz.part" '-5 minutes'
mkf "lazarus_panel_full_2026-09-03_04_10_00.tar.gz" '-1 minutes'   # чужой namespace
_sec_prefix="lazarus"; _sec_n=""; _sec_last_f=""
eval "$L_N"
[[ "$_sec_n" == "2" ]] && ok || bad "8a счётчик вторичной цели без *.part = 2, got '$_sec_n'"
eval "$L_LAST"
[[ "$_sec_last_f" == "$BACKUP_DIR/lazarus_db_2026-09-02_04_10_00.tar.zst" ]] && ok || bad "8b «Последний» — штатный архив, не свежий .part: '$_sec_last_f'"
reset_bk
mkf "lazarus_panel_db_2026-09-03_04_10_00.tar.gz.part" '-1 minutes'
_sec_prefix="lazarus_panel"; eval "$L_N"
[[ "$_sec_n" == "0" ]] && ok || bad "8c только .part → 0 бэкапов, got '$_sec_n'"
_sec_last_f=""; eval "$L_LAST"
[[ -z "$_sec_last_f" ]] && ok || bad "8d только .part → «Последний» пуст: '$_sec_last_f'"
fi

# ============================================================ 12) restore: rc=2 расшифровки
if sec 12; then
ER_START=$(grep -n '^execute_restore() {' "$SCRIPT" | cut -d: -f1)
ER_END=$(awk -v s="$ER_START" 'NR>s && /^}/ {print NR; exit}' "$SCRIPT")
DEC_BLK=$(sed -n "${ER_START},${ER_END}p" "$SCRIPT" | awk '/^[[:space:]]*local _archive_format[[:space:]]*$/ {f=1} f {print} f && /WORK_FILE="\$DECRYPTED_FILE"/ {exit}')
[[ "$DEC_BLK" == *'_hmac_envelope_decrypt "$FILE" "$DECRYPTED_FILE" "$decrypt_pass"'* && "$DEC_BLK" == *'WORK_FILE="$DECRYPTED_FILE"'* ]] \
    && ok || bad "12pre цикл расшифровки извлечён из execute_restore"
eval "_t_restore_dec() {
    local FILE=\"\$1\" TMP_DIR=\"\$2\" WORK_FILE=\"\" _verified_pass=\"\" _archive_magic4=\"\" _archive_magic8=\"\"
$DEC_BLK
    echo \"DEC_DONE ok=\$_dec_ok\"
}"
R12="$T/r12"; mkdir -p "$R12"
head -c 5000 /dev/urandom > "$R12/plain.bin"; tar -czf "$R12/a.tar.gz" -C "$R12" plain.bin
_hmac_envelope_create "$R12/a.tar.gz" "$R12/v2.tar.gz.enc" "$PW" >/dev/null 2>&1
printf 'Salted__' > "$R12/v1.tar.gz.enc"; head -c 512 /dev/urandom >> "$R12/v1.tar.gz.enc"
[[ "$(head -c 4 "$R12/v2.tar.gz.enc")" == "LAZ2" ]] && ok || bad "12pre2 v2-архив создан"
# 12a) v2, rc=2 → ERROR «не выполнена», одна попытка, без «MAC прошёл»
mkdir -p "$R12/tmp"; FAKE_DEC_ALL=2; : > "$T/dec_calls"; : > "$LOG_FILE"
out=$(printf 'p1\np2\np3\n' | _t_restore_dec "$R12/v2.tar.gz.enc" "$R12/tmp" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" != *"DEC_DONE"* ]] && ok || bad "12a v2 rc=2 → отказ (rc=$rc)"
[[ "$out" == *"Расшифровка не выполнена"* ]] && ok || bad "12b v2 rc=2 → ERROR «Расшифровка не выполнена»: $out"
[[ "$(wc -l < "$T/dec_calls" | tr -d ' ')" -eq 1 ]] && ok || bad "12c v2 rc=2 → ровно одна попытка, got $(wc -l < "$T/dec_calls")"
[[ "$out" != *"MAC прошёл"* ]] && ok || bad "12d без ложного «MAC прошёл»"
grep -q 'restore decrypt rc=2' "$LOG_FILE" && ok || bad "12e в логе «restore decrypt rc=2»"
# 12f) v1, rc=2 → прежний повтор ввода (3 попытки, «Неверный пароль или повреждённый файл»)
mkdir -p "$R12/tmp"; : > "$T/dec_calls"
out=$(printf 'p1\np2\np3\n' | _t_restore_dec "$R12/v1.tar.gz.enc" "$R12/tmp" 2>&1); rc=$?
[[ "$(wc -l < "$T/dec_calls" | tr -d ' ')" -eq 3 ]] && ok || bad "12f v1 rc=2 → повтор ввода (3 попытки), got $(wc -l < "$T/dec_calls")"
[[ "$(cnt 'Неверный пароль или повреждённый файл' <<< "$out")" -eq 3 && "$out" != *"Расшифровка не выполнена"* ]] && ok || bad "12g v1 rc=2 → WARN «Неверный пароль…» на каждой попытке: $out"
# 12h) v2, rc=1 (MAC) — по-прежнему повтор ввода
mkdir -p "$R12/tmp"; : > "$T/dec_calls"; FAKE_DEC_ALL=1
out=$(printf 'p1\np2\np3\n' | _t_restore_dec "$R12/v2.tar.gz.enc" "$R12/tmp" 2>&1)
[[ "$(wc -l < "$T/dec_calls" | tr -d ' ')" -eq 3 && "$out" == *"HMAC не совпал"* ]] && ok || bad "12h v2 rc=1 → 3 попытки с «HMAC не совпал»"
# 12i) контроль извлечения: верный пароль, настоящий decrypt → успех
mkdir -p "$R12/tmp"; FAKE_DEC_ALL=""
out=$(printf '%s\n' "$PW" | _t_restore_dec "$R12/v2.tar.gz.enc" "$R12/tmp" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"DEC_DONE ok=true"* ]] && cmp -s "$R12/tmp/decrypted.tar.gz" "$R12/a.tar.gz" && ok || bad "12i верный пароль → расшифровано (rc=$rc): $out"
FAKE_DEC_ALL=""
fi

# ============================================================ 2–5) бот: docker-мок (функция) и песочница /opt
if sec 2 || sec 3 || sec 4 || sec 5; then
sleep() { :; }
timeout() { shift; "$@"; }
clear_screen() { :; }; _print_targets_summary() { :; }; _print_projects_note() { :; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
B="$T/b"
INSTALL_DIR="$B/opt/lazarus-backup"; BACKUP_DIR="$INSTALL_DIR/backup"; mkdir -p "$BACKUP_DIR"
CONFIG_FILE="$INSTALL_DIR/config.env"
PANEL_DIR="$B/opt/remnawave"; BOT_DIR="$B/opt/rwp-shop"; RW_DIR="$B/opt/remnawave-telegram-shop"
mkdir -p "$PANEL_DIR" "$BOT_DIR" "$RW_DIR" "$B/home" "$B/root"
cat > "$PANEL_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave:
    image: remnawave/backend:2
  remnawave-db:
    image: postgres:18.4
    container_name: 'remnawave-db'
EOF
cat > "$BOT_DIR/docker-compose.yml" <<'EOF'
services:
  rwp_shop:
    image: registry.rwp.rw/jesus/rwp-shop:dev
    container_name: rwp_shop
  db:
    image: postgres:18.4
    container_name: rwp_shop_db
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
EOF
cat > "$RW_DIR/docker-compose.yml" <<'EOF'
services:
  bot:
    image: ghcr.io/jolymmiles/remnawave-telegram-shop-bot:latest
    container_name: remnawave-telegram-shop-bot
  db:
    image: postgres:17
    container_name: remnawave-telegram-shop-db
EOF
_panel_root_now() { echo "$PANEL_DIR"; }
detect_panel_root() { echo "$PANEL_DIR"; }
PANEL_PATH="$PANEL_DIR"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_DB_SERVICE="remnawave-db"; DISC_PANEL_APP=""; DISC_PANEL_DB=""
FIND_ROOT="$B"
find() { if [[ "$1" == /opt ]]; then shift 3; command find "$FIND_ROOT/opt" "$FIND_ROOT/home" "$FIND_ROOT/root" "$@"; else command find "$@"; fi; }

# docker-мок: состояние контейнеров в файлах (команды бота идут в сабшеллах)
DK="$T/dk"; mkdir -p "$DK"; MOCK_STOP_STUCK=""
dk_reset() { rm -f "$DK"/*; : > "$T/dk.order"; : > "$T/calls"; }
dk_add() { # name image dir service state [oneoff] [health]; порядок добавления = порядок `docker ps`
    printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "${6:-False}" "${7:-}" > "$DK/$1"; echo "$1" >> "$T/dk.order"
}
dk_get() { [[ -n "$1" && -f "$DK/$1" ]] || return 1; IFS='|' read -r D_IMG D_DIR D_SVC D_ST D_ONE D_HL < "$DK/$1"; }
dk_set_state() { dk_get "$1" || return 1; printf '%s|%s|%s|%s|%s|%s\n' "$D_IMG" "$D_DIR" "$D_SVC" "$2" "$D_ONE" "$D_HL" > "$DK/$1"; }
dk_state() { dk_get "$1" && echo "$D_ST"; }
dk_fmt() {
    local f="$1" n="$2" run="false" upst
    [[ "$D_ST" == "running" ]] && run="true"
    [[ "$D_ST" == "running" ]] && upst="Up 3 days" || upst="Exited (0) 1 hour ago"
    local l_one1='{{.Label "com.docker.compose.oneoff"}}' l_one2='{{ index .Config.Labels "com.docker.compose.oneoff" }}'
    local l_wd1='{{.Label "com.docker.compose.project.working_dir"}}' l_wd2='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
    local l_svc='{{ index .Config.Labels "com.docker.compose.service" }}'
    f="${f//"$l_one1"/$D_ONE}"; f="${f//"$l_one2"/$D_ONE}"
    f="${f//"$l_wd1"/$D_DIR}"; f="${f//"$l_wd2"/$D_DIR}"; f="${f//"$l_svc"/$D_SVC}"
    f="${f//'{{.Names}}'/$n}"; f="${f//'{{.Name}}'/$n}"
    f="${f//'{{.Image}}'/$D_IMG}"; f="${f//'{{.Config.Image}}'/$D_IMG}"
    f="${f//'{{.State.Status}}'/$D_ST}"; f="${f//'{{.State.Running}}'/$run}"; f="${f//'{{.State}}'/$D_ST}"
    f="${f//'{{.State.Health.Status}}'/$D_HL}"; f="${f//'{{.Service}}'/$D_SVC}"; f="${f//'{{.Status}}'/$upst}"
    printf '%s\n' "$f" | sed -E 's/\{\{[^}]*\}\}//g'
}
docker() {
    local a="$1"; shift
    case "$a" in
        container) docker "$@"; return ;;
        info) return 0 ;;
        unpause) echo "unpause $*" >> "$T/calls"; dk_get "$1" && dk_set_state "$1" running; return 0 ;;
        inspect)
            local fmt="" n=""
            case "$1" in
                --format|-f) fmt="$2"; n="$3" ;;
                --format=*)  fmt="${1#--format=}"; n="$2" ;;
                *) n="$1" ;;
            esac
            dk_get "$n" || return 1
            [[ -z "$fmt" ]] && { echo '[{}]'; return 0; }
            dk_fmt "$fmt" "$n"; return 0 ;;
        ps)
            local all=0 fmt="" n
            while [[ $# -gt 0 ]]; do case "$1" in -a|--all) all=1 ;; --format) fmt="$2"; shift ;; esac; shift; done
            while IFS= read -r n; do
                dk_get "$n" || continue
                [[ $all -eq 0 && "$D_ST" != "running" ]] && continue
                dk_fmt "$fmt" "$n"
            done < "$T/dk.order"
            return 0 ;;
        compose)
            local sub="$1"; shift
            case "$sub" in
                ps)
                    local all=0 fmt="" svc="" n
                    while [[ $# -gt 0 ]]; do case "$1" in -a|--all) all=1 ;; --format) fmt="$2"; shift ;; -*) ;; *) svc="$1" ;; esac; shift; done
                    while IFS= read -r n; do
                        dk_get "$n" || continue
                        _same_path "$D_DIR" "$PWD" || continue
                        [[ $all -eq 0 && "$D_ST" != "running" ]] && continue
                        [[ -n "$svc" && "$D_SVC" != "$svc" ]] && continue
                        dk_fmt "$fmt" "$n"
                    done < "$T/dk.order"
                    return 0 ;;
                up|stop|down|start|restart|pull)
                    echo "compose $sub $*" >> "$T/calls"
                    local svc="" x n
                    for x in "$@"; do [[ "$x" != -* ]] && svc="$x"; done
                    while IFS= read -r n; do
                        dk_get "$n" || continue
                        _same_path "$D_DIR" "$PWD" || continue
                        [[ -n "$svc" && "$D_SVC" != "$svc" ]] && continue
                        [[ "$D_ONE" == "True" ]] && continue
                        case "$sub" in
                            up|start|restart) dk_set_state "$n" running ;;
                            stop) [[ -n "$MOCK_STOP_STUCK" ]] || dk_set_state "$n" exited ;;   # STUCK: restart: always снова поднимает
                            down) rm -f "$DK/$n" ;;
                        esac
                    done < "$T/dk.order"
                    return 0 ;;
            esac
            return 0 ;;
        *) return 0 ;;
    esac
}
# Живой прод-стек (новейший первым). rwp_shop в состоянии $1.
prod_stack() {
    dk_reset
    dk_add rwp_shop_forecast "registry.rwp.rw/jesus/rwp-shop-forecast:1.1.0" "$BOT_DIR" forecast running False healthy
    dk_add remnawave-subscription-page "remnawave/subscription-page:latest" "$BOT_DIR" remnawave-subscription-page running
    dk_add xray-checker "kutovoys/xray-checker:latest" "$BOT_DIR" xray-checker running
    dk_add rwp_shop_kb_db "pgvector/pgvector:pg18" "$BOT_DIR" kb_db running False healthy
    dk_add rwp_shop_db "postgres:18.4" "$BOT_DIR" db running False healthy
    dk_add rwp-shop-rwp_shop-run-3f2a "registry.rwp.rw/jesus/rwp-shop:dev" "$BOT_DIR" rwp_shop exited True
    dk_add rwp_shop "registry.rwp.rw/jesus/rwp-shop:dev" "$BOT_DIR" rwp_shop "$1" False healthy
    dk_add remnawave "remnawave/backend:2" "$PANEL_DIR" remnawave running
    dk_add remnawave-db "postgres:18.4" "$PANEL_DIR" remnawave-db running
}
# Публичный бот remnawave-telegram-shop (имена контейнеров содержат 'remnawave'). $1 — состояние бота.
rw_stack() {
    dk_reset
    dk_add remnawave-telegram-shop-db "postgres:17" "$RW_DIR" db running
    dk_add remnawave-telegram-shop-bot "ghcr.io/jolymmiles/remnawave-telegram-shop-bot:latest" "$RW_DIR" bot "${1:-running}"
    dk_add remnawave "remnawave/backend:2" "$PANEL_DIR" remnawave running
    dk_add remnawave-db "postgres:18.4" "$PANEL_DIR" remnawave-db running
}
# «процесс стартовал с панелью (both)»: рабочие bot-переменные затёрты panel-resolve
both_ctx() {
    BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"; _BOTRT_FORCED=0
    _CANON_BOT_PATH="$BOT_DIR"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
    _CANON_DB_SERVICE="db"; _CANON_DB_NAME=""; _CANON_DB_USER="postgres"; _CANON_MAX_FILE_SIZE_MB="1"
    PANEL_DB_NAME="panel_db"; MAX_FILE_SIZE_MB="1"; DB_NAME=""; DB_USER="postgres"
    resolve_backup_target
}
bot_ctx() { BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; _BOTRT_FORCED=0; KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}"); }
ANS=(); SR_CALLS=0; : > "$T/prompts"
safe_read() {
    SR_CALLS=$(( SR_CALLS + 1 )); [[ $SR_CALLS -gt 40 ]] && return 1
    printf '%s\n' "${@: -2:1}" >> "$T/prompts"
    local _v="${!#}"
    if [[ ${#ANS[@]} -eq 0 ]]; then printf -v "$_v" '%s' ""; return 1; fi
    printf -v "$_v" '%s' "${ANS[0]}"; ANS=("${ANS[@]:1}"); return 0
}
fi

# ============================================================ 2) resolve_bot_runtime: публичный бот remnawave-telegram-shop
if sec 2; then
rw_stack running; bot_ctx
for _bcn in "" "remnawave" "remnawave-telegram-shop-db"; do
    BOT_PATH="$RW_DIR"; BOT_CONTAINER_NAME="$_bcn"; DB_CONTAINER_NAME=""
    if resolve_bot_runtime; then
        [[ "$RB_PATH" == "$RW_DIR" && "$RB_APP" == "remnawave-telegram-shop-bot" && "$RB_DB" == "remnawave-telegram-shop-db" ]] && ok \
            || bad "2a BOT_CONTAINER_NAME='$_bcn' → remnawave-telegram-shop-bot, got path=$RB_PATH app=$RB_APP db=$RB_DB"
    else bad "2a BOT_CONTAINER_NAME='$_bcn': resolve_bot_runtime не нашёл бота"; fi
done
# бот остановлен (цикл после неудачного апдейта) — берётся через ps -a
rw_stack exited; BOT_PATH="$RW_DIR"; BOT_CONTAINER_NAME="remnawave"; DB_CONTAINER_NAME=""
resolve_bot_runtime; [[ "$RB_APP" == "remnawave-telegram-shop-bot" ]] && ok || bad "2b остановленный remnawave-telegram-shop-bot → он же, got '$RB_APP'"
# панельный контейнер (обнаруженный под кастомным именем) в проекте бота — отсекается точным _is_panel_container
dk_reset
dk_add shop-panel-app "acme/panel-app:1" "$RW_DIR" panel-app running
dk_add remnawave-telegram-shop-db "postgres:17" "$RW_DIR" db running
dk_add remnawave-telegram-shop-bot "ghcr.io/jolymmiles/remnawave-telegram-shop-bot:latest" "$RW_DIR" bot running
DISC_PANEL_APP="shop-panel-app"; BOT_PATH="$RW_DIR"; BOT_CONTAINER_NAME=""; DB_CONTAINER_NAME=""
resolve_bot_runtime; [[ "$RB_APP" == "remnawave-telegram-shop-bot" ]] && ok || bad "2c панельный контейнер в проекте бота не выбран ботом, got '$RB_APP'"
DISC_PANEL_APP=""
# прод-набор rwp_shop не сломан
for _st in running exited; do
    for _bcn in "" "remnawave" "rwp_shop_db"; do
        prod_stack "$_st"; bot_ctx; BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="$_bcn"; DB_CONTAINER_NAME=""
        resolve_bot_runtime
        [[ "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" && "$RB_DB" == "rwp_shop_db" ]] && ok \
            || bad "2d прод ($_st, BOT_CONTAINER_NAME='$_bcn') → rwp_shop/rwp_shop_db, got app=$RB_APP db=$RB_DB"
    done
done
prod_stack exited; both_ctx; KEYWORDS=("${PANEL_KEYWORDS[@]}")
resolve_bot_runtime
[[ "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" ]] && ok || bad "2e both-режим (панель первична): скан → rwp_shop, got path=$RB_PATH app=$RB_APP"
fi

# ============================================================ 3) bot_down: restarting / paused / exited
if sec 3; then
for _st in restarting paused; do
    prod_stack "$_st"; both_ctx
    out=$( bot_down 2>&1 ); rc=$?; out=$(strip <<< "$out")
    [[ $rc -eq 0 && "$out" == *"Бот остановлен: rwp_shop"* && "$out" != *"уже остановлен"* ]] && ok || bad "3a $_st → бот останавливается (rc=$rc): $out"
    grep -qx 'compose stop rwp_shop' "$T/calls" && [[ "$(grep -c '^compose' "$T/calls")" -eq 1 ]] && ok || bad "3b $_st → ровно compose stop rwp_shop: $(cat "$T/calls")"
    [[ "$(dk_state rwp_shop)" == "exited" ]] && ok || bad "3c $_st → контейнер остановлен, got $(dk_state rwp_shop)"
    [[ "$(dk_state rwp_shop_db)" == "running" && "$(dk_state remnawave-subscription-page)" == "running" ]] && ok || bad "3d $_st → БД и выдача подписок живы"
done
prod_stack paused; both_ctx; ( bot_down ) > /dev/null 2>&1
[[ "$(sed -n 1p "$T/calls")" == "unpause rwp_shop" && "$(sed -n 2p "$T/calls")" == "compose stop rwp_shop" ]] && ok || bad "3e paused: сперва unpause, затем stop: $(cat "$T/calls")"
prod_stack restarting; both_ctx; ( bot_down ) > /dev/null 2>&1
! grep -q '^unpause' "$T/calls" && ok || bad "3f restarting: unpause не зовётся"
# stop не помог (restart: always снова поднимает) → ERROR, rc≠0
prod_stack restarting; both_ctx; MOCK_STOP_STUCK=1
out=$( bot_down 2>&1 ); rc=$?; MOCK_STOP_STUCK=""
[[ $rc -ne 0 && "$out" == *"всё ещё работает"* ]] && ok || bad "3g после stop всё ещё restarting → ERROR rc≠0 (rc=$rc): $(strip <<< "$out")"
prod_stack exited; both_ctx
out=$( bot_down 2>&1 | strip )
[[ ! -s "$T/calls" && "$out" == *"уже остановлен: rwp_shop (exited)"* ]] && ok || bad "3h exited → «уже остановлен», без вызовов: $(cat "$T/calls") / $out"
fi

# ============================================================ 4) _ask_target_location: ручной путь, Enter на вопрос БД
if sec 4; then
_sv_rbr=$(declare -f resolve_bot_runtime)
resolve_bot_runtime() { return 1; }
CUSTOM="$B/srv/mybot"; OTHER="$B/srv/otherbot"; BARE="$B/srv/barebot"
for _d in "$CUSTOM" "$OTHER" "$BARE"; do
    mkdir -p "$_d"; printf 'services:\n  app:\n    image: acme/app:1\n  db:\n    image: postgres:17\n' > "$_d/docker-compose.yml"
done
# 4a) тот же путь, Enter → прежний контейнер БД
dk_reset; both_ctx; _CANON_BOT_PATH="$CUSTOM"; _CANON_DB_CONTAINER="mybot_db_prev"; : > "$T/prompts"
ANS=(1 "" ""); SR_CALLS=0
_ask_target_location bot > "$T/out4" 2>&1
[[ "$BOT_PATH" == "$CUSTOM" && "$DB_CONTAINER_NAME" == "mybot_db_prev" ]] && ok || bad "4a тот же путь + Enter → прежний контейнер БД: BOT_PATH='$BOT_PATH' db='$DB_CONTAINER_NAME'"
grep -qF '(Enter = mybot_db_prev)' "$T/prompts" && ok || bad "4b подсказка «Enter = mybot_db_prev»: $(tail -2 "$T/prompts")"
[[ "$_CANON_DB_CONTAINER" == "mybot_db_prev" ]] && ok || bad "4c канон БД не заменён на rwp_shop_db: '$_CANON_DB_CONTAINER'"
# 4d) тот же путь, но канон — панельное имя: в дефолт идёт найденный в каталоге
dk_reset; dk_add mybot-db-1 "postgres:17" "$CUSTOM" db running
both_ctx; _CANON_BOT_PATH="$CUSTOM"; _CANON_DB_CONTAINER="remnawave-db"
ANS=(1 "" ""); SR_CALLS=0
_ask_target_location bot > "$T/out4" 2>&1
[[ "$DB_CONTAINER_NAME" == "mybot-db-1" ]] && ok || bad "4d канон панельный → найденный mybot-db-1, got '$DB_CONTAINER_NAME'"
# 4e) другой путь → найденный find_db_container_for_path
dk_reset; dk_add otherbot-db-1 "postgres:17" "$OTHER" db running
both_ctx; _CANON_BOT_PATH="$CUSTOM"; _CANON_DB_CONTAINER="mybot_db_prev"; : > "$T/prompts"
ANS=(1 "$OTHER" ""); SR_CALLS=0
_ask_target_location bot > "$T/out4" 2>&1
[[ "$BOT_PATH" == "$OTHER" && "$DB_CONTAINER_NAME" == "otherbot-db-1" ]] && ok || bad "4e другой путь + Enter → найденный otherbot-db-1: BOT_PATH='$BOT_PATH' db='$DB_CONTAINER_NAME'"
grep -qF '(Enter = otherbot-db-1)' "$T/prompts" && ok || bad "4f подсказка «Enter = otherbot-db-1»"
# 4g) другой путь без найденной БД → rwp_shop_db (а не прежний чужой)
dk_reset; both_ctx; _CANON_BOT_PATH="$CUSTOM"; _CANON_DB_CONTAINER="mybot_db_prev"
ANS=(1 "$BARE" ""); SR_CALLS=0
_ask_target_location bot > "$T/out4" 2>&1
[[ "$BOT_PATH" == "$BARE" && "$DB_CONTAINER_NAME" == "rwp_shop_db" ]] && ok || bad "4g другой путь без БД → rwp_shop_db, got '$DB_CONTAINER_NAME'"
# 4h) явный ввод побеждает дефолт
dk_reset; both_ctx; _CANON_BOT_PATH="$CUSTOM"; _CANON_DB_CONTAINER="mybot_db_prev"
ANS=(1 "" "typed_db"); SR_CALLS=0
_ask_target_location bot > "$T/out4" 2>&1
[[ "$DB_CONTAINER_NAME" == "typed_db" ]] && ok || bad "4h явный ввод → typed_db, got '$DB_CONTAINER_NAME'"
eval "$_sv_rbr"
fi

# ============================================================ 5) _ask_target_location: путь живого бота
if sec 5; then
OLD="$B/opt/rwp-shop-old"; mkdir -p "$OLD"; cp "$BOT_DIR/docker-compose.yml" "$OLD/"
prod_stack running; bot_ctx
BOT_PATH="$OLD"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="old_db"
_CANON_BOT_PATH="$OLD"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="old_db"
ANS=(1); SR_CALLS=0
_ask_target_location bot > "$T/out5" 2>&1
[[ "$BOT_PATH" == "$BOT_DIR" && "$_CANON_BOT_PATH" == "$BOT_DIR" ]] && ok || bad "5a путь живого бота вместо устаревшего: BOT_PATH='$BOT_PATH' canon='$_CANON_BOT_PATH'"
[[ "$DB_CONTAINER_NAME" == "rwp_shop_db" ]] && ok || bad "5b БД перевыведена для живого каталога, got '$DB_CONTAINER_NAME'"
grep -qF "работает из $BOT_DIR" "$T/out5" && grep -qF 'берём путь живого' "$T/out5" && ok || bad "5c WARN о расхождении: $(strip < "$T/out5")"
# контроль: путь из конфига = живой → без WARN
prod_stack running; bot_ctx
BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"; _CANON_BOT_PATH="$BOT_DIR"
ANS=(1); SR_CALLS=0
_ask_target_location bot > "$T/out5" 2>&1
[[ "$BOT_PATH" == "$BOT_DIR" ]] && ! grep -qF 'берём путь живого' "$T/out5" && ok || bad "5d путь совпал с живым → без WARN"
fi

# ============================================================ итог: сеть и песочница удаления
[[ ! -s "$NETLOG" ]] && ok || bad "Z1 ни одного сетевого вызова (curl/wget/aws/rclone/scp…): $(head -3 "$NETLOG")"
[[ ! -s "$T/rm_outside.log" ]] && ok || bad "Z2 rm/shred вне каталога теста не вызывались: $(head -3 "$T/rm_outside.log")"

echo "---"
echo "review603: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
