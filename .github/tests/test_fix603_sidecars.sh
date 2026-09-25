#!/usr/bin/env bash
# 6.0.3 (sidecars): поведенческие регресс-тесты находок 2, 16, 25, 26 (перепроверка 25.09.2026).
#  1) _billing_sidecar_active / _kb_sidecar_active (auto): контейнер ЕСТЬ, но не running → WARN
#     (stdout + LOG_FILE) и _BILL_SKIP_STATE/_KB_SKIP_STATE; «не установлен», bot-цель, false —
#     тишина; remote-ветка хелпера WARN сама не печатает (печатает caller). rc прежние (1/2).
#  2) create_backup (реальный, docker — мок в PATH): архив без billing/KB + маркер «Без infra-billing» /
#     «Без KB» в подписи одиночного режима и в строке цели альбома both (_both_tg_record → flush);
#     running — сайдкар в архиве и без маркера; маркер не затирается строкой size-skip (full).
#  3) _backup_remote_target (ssh — мок в PATH): bot + BOT_KB_BACKUP=true + db_only/full → отказ
#     ДО любых ssh-команд; auto/files_only — как раньше; удалённый бот не печатает WARN про биллинг;
#     удалённая панель: WARN про PANEL_EXTRA_PATHS, billing exited → WARN со state + маркер.
#  4) save_config: temp + rename; сбой cat/дописывания/chmod/mv/огрызок ядра → rc=1, прежний
#     config.env байт в байт, temp убран; брошенный temp мёртвого PID убирается, живого — нет.
#  5) write_password_file: сбой printf/сверки/chmod/mv — прежний файл пароля цел.
#  6) create_backup_dispatch: форс BACKUP_LOG_FILES ask→false и авто-найденное имя billing —
#     транзиентны (проходы видят, после возврата глобал прежний, save_config их не пишет).
#  7) сеть: send_telegram_document/_send_telegram_text — журнал, curl/wget/aws/rclone — PATH-блокираторы;
#     итоговая проверка — ни одного сетевого вызова.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске). Секреты фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d)

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
trap 'rm -rf "$T"' EXIT
# RETURN-trap create_backup ссылается на LOCK_ACQUIRED — глобал нужен и вне функции.
LOCK_ACQUIRED="false"

INSTALL_DIR="$T/inst"; mkdir -p "$INSTALL_DIR"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_PASSWORD_FILE="$INSTALL_DIR/.backup_password"
BACKUP_DIR="$T/backup"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
DEBUG_MODE=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
COMPRESSION="gzip"; BACKUP_PASSWORD=""; PG_DUMP_TIMEOUT_SEC=60; TAR_TIMEOUT_SEC=60
REMOTE_STORAGE_TYPE="off"; SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"; DELETE_MODE="time"; RETENTION_DAYS=7
BOT_TOKEN="000000:fake-token-for-tests"; CHAT_ID="-100000"
BACKUP_LOG_FILES="false"

# Заглушки окружения: лок, гард идентичности, доставка, версии.
acquire_lock() { return 0; }; release_lock() { :; }; check_lock_owner() { echo 0; }
assert_target_identity() { return 0; }; _ensure_encryption_or_confirm() { return 0; }
send_telegram_notification() { :; }; send_telegram_alert() { :; }
upload_to_remote() { return 0; }
get_backup_version() { echo "1.2.3"; }; get_app_version() { echo "1.2.3"; }
get_db_user() { echo "postgres"; }; get_db_name() { echo "appdb"; }
ensure_bot_path() { return 0; }
: > "$T/tg_caption.txt"
send_telegram_document() { printf '%s\n' "$2" >> "$T/tg_caption.txt"; return 0; }
# Текст-сводка альбома (_both_tg_flush при 0 подходящих файлах) — тоже журнал, не sendMessage:
# иначе расширение сценариев both ушло бы в реальный api.telegram.org.
_send_telegram_text() { printf 'TEXT|%s\n' "$1" >> "$T/tg_caption.txt"; return 0; }

# --- мок docker в PATH: реальный create_backup зовёт его и через `timeout`, и из `bash -c`,
# поэтому функция не подходит. Состояние сайдкаров — экспортируемые MOCK_BILL_STATE/MOCK_KB_STATE
# (пусто = контейнера нет).
MOCK="$T/bin"; mkdir -p "$MOCK"
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
        [[ "$*" == *kb* && -n "${MOCK_KB_DUMP_FAIL:-}" ]] && exit 1
        echo "CREATE TABLE t (id int);"; for i in $(seq 1 80); do echo "INSERT INTO t VALUES ($i,'row-$i-padding');"; done ;;
      *"printenv POSTGRES_USER"*) echo "u" ;;
      *"printenv POSTGRES_DB"*) echo "d" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/docker"
# PATH-блокираторы сети: любой curl/wget/aws/rclone (в т.ч. из незаглушённой TG-функции) — журнал и отказ.
: > "$T/net_blocked.log"
for _nb in curl wget aws rclone; do
    cat > "$MOCK/$_nb" <<NBEOF
#!/usr/bin/env bash
echo "BLOCKED $_nb \$*" >> "$T/net_blocked.log"
exit 97
NBEOF
    chmod +x "$MOCK/$_nb"
done
export PATH="$MOCK:$PATH"
export MOCK_BILL_STATE="" MOCK_KB_STATE="" MOCK_KB_DUMP_FAIL=""

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
_last_arc() { find "$BACKUP_DIR" -maxdepth 1 -name "$1" | sort | tail -1; }

# ============================================================ 1) хелперы: WARN только «есть, но не running»
_panel_env
MOCK_BILL_STATE="exited"; : > "$LOG_FILE"
out=$(_billing_sidecar_active ""; echo "rc=$?")
[[ "$out" == *"rc=1"* ]] && ok || bad "1a billing exited(auto) → rc=1 (контракт test_billing_sidecar)"
[[ "$out" == *"infra-billing 'infra-billing-db' не запущен (state=exited)"* ]] && ok || bad "1b billing exited → WARN в stdout: $out"
grep -q "billing sidecar skipped: 'infra-billing-db' state=exited" "$LOG_FILE" && ok || bad "1c billing exited → WARN в LOG_FILE"
_billing_sidecar_active "" >/dev/null; [[ "$_BILL_SKIP_STATE" == "exited" ]] && ok || bad "1d _BILL_SKIP_STATE=exited, got '$_BILL_SKIP_STATE'"
# контейнера нет (панель без биллинга): тишина, state пуст
MOCK_BILL_STATE=""
out=$(_billing_sidecar_active ""; echo "rc=$?")
[[ "$out" == "rc=1" ]] && ok || bad "1e billing absent → rc=1 и БЕЗ вывода: '$out'"
_billing_sidecar_active "" >/dev/null; [[ -z "$_BILL_SKIP_STATE" ]] && ok || bad "1f absent → _BILL_SKIP_STATE пуст"
# bot-цель: тишина + сброс state от прошлого вызова
MOCK_BILL_STATE="exited"; _billing_sidecar_active "" >/dev/null
BACKUP_TARGET="bot"
out=$(_billing_sidecar_active ""; echo "rc=$?")
[[ "$out" == "rc=1" ]] && ok || bad "1g bot-цель → rc=1 без вывода: '$out'"
_billing_sidecar_active "" >/dev/null; [[ -z "$_BILL_SKIP_STATE" ]] && ok || bad "1h bot-цель сбрасывает _BILL_SKIP_STATE (утечка между проходами both)"
_panel_env; PANEL_BILLING_BACKUP="false"
out=$(_billing_sidecar_active ""; echo "rc=$?")
[[ "$out" == "rc=1" ]] && ok || bad "1i PANEL_BILLING_BACKUP=false → тишина: '$out'"
# true + exited: rc=2 (прод-путь ERROR не меняется)
_panel_env; PANEL_BILLING_BACKUP="true"
_billing_sidecar_active "" >/dev/null; [[ $? -eq 2 ]] && ok || bad "1j true+exited → rc=2"
# remote-ветка: WARN печатает caller, хелпер только ставит state
_panel_env
mock_rssh() { case "$1" in *"State.Status}}|{{.Config.Image"*) echo "exited|postgres:17|infra-billing-db" ;; esac; }
timeout() { shift; "$@"; }   # внешний timeout не видит функцию-префикс ssh
out=$(_billing_sidecar_active "mock_rssh"; echo "rc=$?")
[[ "$out" == "rc=1" ]] && ok || bad "1k remote exited → rc=1, хелпер сам не печатает: '$out'"
_billing_sidecar_active "mock_rssh" >/dev/null; [[ "$_BILL_SKIP_STATE" == "exited" ]] && ok || bad "1l remote exited → _BILL_SKIP_STATE=exited"
unset -f timeout
# KB
_bot_env; MOCK_KB_STATE="exited"; : > "$LOG_FILE"
out=$(_kb_sidecar_active; echo "rc=$?")
[[ "$out" == *"rc=1"* && "$out" == *"KB-БД 'rwp_shop_kb_db' не запущена (state=exited)"* ]] && ok || bad "1m KB exited(auto) → rc=1 + WARN: $out"
grep -q "kb sidecar skipped: 'rwp_shop_kb_db' state=exited" "$LOG_FILE" && ok || bad "1n KB exited → WARN в LOG_FILE"
MOCK_KB_STATE=""
out=$(_kb_sidecar_active; echo "rc=$?")
[[ "$out" == "rc=1" ]] && ok || bad "1o KB absent (бот без KB) → тишина: '$out'"
MOCK_KB_STATE="exited"; _kb_sidecar_active >/dev/null; BACKUP_TARGET="panel"; _kb_sidecar_active >/dev/null
[[ -z "$_KB_SKIP_STATE" ]] && ok || bad "1p _KB_SKIP_STATE сбрасывается на каждом вызове"

# ============================================================ 2) create_backup: архив + маркер в TG
# 2a) panel db_only, billing exited → rc=0, billing_* нет, WARN, маркер в подписи
_panel_env; MOCK_BILL_STATE="exited"; : > "$LOG_FILE"; : > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
arc=$(_last_arc 'lazarus_panel_db_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" ]] && ok || bad "2a panel db_only при остановленном billing (auto) → rc=0 и архив (rc=$rc): $(tail -3 <<<"$out")"
[[ -n "$arc" ]] && ! tar -tzf "$arc" 2>/dev/null | grep -q '^billing_' && ok || bad "2b в архиве нет billing_*"
[[ "$out" == *"не запущен (state=exited)"* ]] && ok || bad "2c WARN про billing в выводе create_backup"
grep -q 'Без infra' "$T/tg_caption.txt" && ok || bad "2d подпись TG одиночного режима содержит «Без infra-billing»: $(cat "$T/tg_caption.txt")"
# 2e) running → billing_* в архиве, маркера нет
MOCK_BILL_STATE="running"; : > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
arc=$(_last_arc 'lazarus_panel_db_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" ]] && tar -tzf "$arc" 2>/dev/null | grep -q '^billing_' && ok || bad "2e billing running → billing_* в архиве (rc=$rc)"
grep -q 'Без infra' "$T/tg_caption.txt" && bad "2f running — маркера быть не должно" || ok
# 2g) панель без биллинга (контейнера нет) → ни WARN, ни маркера
MOCK_BILL_STATE=""; : > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" != *"infra-billing"* ]] && ok || bad "2g панель без биллинга → тишина (rc=$rc)"
grep -q 'Без infra' "$T/tg_caption.txt" && bad "2h без биллинга — маркера быть не должно" || ok
# 2i) true + exited → прод-путь прежний: ERROR и rc≠0
PANEL_BILLING_BACKUP="true"; MOCK_BILL_STATE="exited"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"infra-billing обязателен"* ]] && ok || bad "2i PANEL_BILLING_BACKUP=true + exited → ERROR, rc≠0 (rc=$rc)"
[[ -z "$(_last_arc 'lazarus_panel_db_*')" ]] && ok || bad "2j true + exited → архива нет"
# 2k) both-режим: маркер в строке цели альбома (запись → реальный flush)
_panel_env; MOCK_BILL_STATE="exited"; rm -f "$BACKUP_DIR"/lazarus_*; : > "$T/tg_caption.txt"
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_SIZES=(); _BOTH_TG_BYTES=(); _BOTH_TG_ENC=(); _BOTH_TG_VERIFY=()
_BOTH_TG_REMOTE_OK=(); _BOTH_TG_REMOTE_UNVERIFIED=(); _BOTH_TG_IS_REMOTE=(); _BOTH_TG_VER=(); _BOTH_TG_RSTATUS=(); _BOTH_TG_SKIP=(); _BOTH_TG_SKIPCOUNT=()
_BOTH_TG_DEFER="1"
create_backup "db_only" >/dev/null 2>&1
_BOTH_TG_DEFER=""
[[ "${_BOTH_TG_LABELS[0]:-}" == *"без infra-billing"* ]] && ok || bad "2k both: метка цели с маркером, got '${_BOTH_TG_LABELS[0]:-}'"
SEND_TO_TELEGRAM="true"; TG_SEND_FILE="true"
_both_tg_flush >/dev/null 2>&1
SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"
grep -q 'Remnawave .(.*без infra' "$T/tg_caption.txt" && ok || bad "2l both: подпись альбома содержит «Remnawave (⚠️ без infra-billing)»: $(cat "$T/tg_caption.txt")"
# 2m) бот, KB exited → маркер «Без KB»; второй проход (running) — метка чистая (local, не утекает)
_bot_env; MOCK_KB_STATE="exited"; : > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
arc=$(_last_arc 'lazarus_db_*.tar.gz')
[[ $rc -eq 0 && -n "$arc" ]] && ! tar -tzf "$arc" 2>/dev/null | grep -q '^kb_' && ok || bad "2m бот db_only при остановленной KB → rc=0, kb_* нет (rc=$rc)"
grep -q 'Без KB' "$T/tg_caption.txt" && ok || bad "2n подпись TG содержит «Без KB»"
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_DEFER="1"
create_backup "db_only" >/dev/null 2>&1
MOCK_KB_STATE="running"; create_backup "db_only" >/dev/null 2>&1
_BOTH_TG_DEFER=""
[[ "${_BOTH_TG_LABELS[0]:-}" == *"без KB"* && "${_BOTH_TG_LABELS[1]:-}" == "RWP Shop" ]] && ok || bad "2o both: маркер KB только у своего прохода: '${_BOTH_TG_LABELS[0]:-}' / '${_BOTH_TG_LABELS[1]:-}'"
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=()
# 2p) full бота: маркер KB не затирается строкой size-skip
_bot_env; MOCK_KB_STATE="exited"; MAX_FILE_SIZE_MB=1; EXCLUDE_DIRS=""
head -c 2200000 /dev/zero > "$BOT_PATH/big.bin"; echo "cfg" > "$BOT_PATH/app.conf"
: > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "full" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok || bad "2p бот full → rc=0 (rc=$rc): $(tail -3 <<<"$out")"
grep -q 'Без KB' "$T/tg_caption.txt" && grep -q 'Skip' "$T/tg_caption.txt" && ok || bad "2q full: в подписи и «Без KB», и «Skip» (+=, не =): $(cat "$T/tg_caption.txt")"
rm -f "$BOT_PATH/big.bin"
# 2r) KB запущена, но дамп провалился (auto) → WARN + маркер «Без KB (дамп не удался)»
_bot_env; MOCK_KB_STATE="running"; MOCK_KB_DUMP_FAIL="1"; : > "$T/tg_caption.txt"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(create_backup "db_only" 2>&1); rc=$?
MOCK_KB_DUMP_FAIL=""
[[ $rc -eq 0 && "$out" == *"Дамп KB не удался"* ]] && ok || bad "2r KB-дамп провален (auto) → rc=0 + WARN (rc=$rc)"
grep -q 'Без KB .(дамп не удался' "$T/tg_caption.txt" && ok || bad "2s подпись TG: «Без KB (дамп не удался)»: $(cat "$T/tg_caption.txt")"
MOCK_KB_STATE=""; MOCK_BILL_STATE=""

# ============================================================ 3) удалённая цель (мок ssh)
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
export MOCK_RBILL=""
_rbot_env() {
    BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; BACKUP_PREFIX="lazarus"; BOT_TRANSPORT="ssh"
    BOT_PATH="/remote/opt/bot"; DB_CONTAINER_NAME="rwp_shop_db"; BOT_KB_DB_CONTAINER="rwp_shop_kb_db"
    TARGET_SSH="ssh -p 21022 -o BatchMode=yes user@remotehost"
}
_rpanel_env() {
    BACKUP_TARGET="panel"; BACKUP_SECONDARY=""; BACKUP_PREFIX="lazarus_panel"; PANEL_TRANSPORT="ssh"
    BOT_PATH="/remote/opt/remnawave"; DB_CONTAINER_NAME="remnawave-db"
    PANEL_BILLING_BACKUP="auto"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"; PANEL_EXTRA_PATHS=""
    TARGET_SSH="ssh -p 21022 -o BatchMode=yes user@remotehost"
}
# 3a) bot + BOT_KB_BACKUP=true + db_only → отказ до любой ssh-команды
_rbot_env; BOT_KB_BACKUP="true"; : > "$T/ssh_cmds.log"; : > "$LOG_FILE"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(_backup_remote_target "db_only" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok || bad "3a remote bot + BOT_KB_BACKUP=true → rc≠0"
[[ "$out" == *"KB-sidecar не поддержан; бэкап прерван"* ]] && ok || bad "3b ERROR про KB-sidecar: $out"
[[ ! -s "$T/ssh_cmds.log" ]] && ok || bad "3c отказ ДО ssh (команды: $(tr '\n' ';' < "$T/ssh_cmds.log"))"
[[ -z "$(_last_arc 'lazarus_db_*')" && ! -e "$BACKUP_DIR/bot_version.txt" ]] && ok || bad "3d ни архива, ни промежуточных файлов"
grep -q 'KB sidecar unsupported over ssh' "$LOG_FILE" && ok || bad "3e отказ в LOG_FILE"
out=$(_backup_remote_target "full" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"KB-sidecar не поддержан"* ]] && ok || bad "3f full тоже отказ"
# files_only при true — KB не при чём, бэкап идёт
out=$(_backup_remote_target "files_only" 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(_last_arc 'lazarus_files_*.tar.gz')" ]] && ok || bad "3g files_only + true → бэкап идёт (rc=$rc)"
# 3h) auto → без шума, архив есть; про биллинг бот не говорит
_rbot_env; BOT_KB_BACKUP="auto"; PANEL_BILLING_BACKUP="auto"; rm -f "$BACKUP_DIR"/lazarus_*
out=$(_backup_remote_target "db_only" 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(_last_arc 'lazarus_db_*.tar.gz')" ]] && ok || bad "3h remote bot auto → архив (rc=$rc)"
[[ "$out" != *"KB"* ]] && ok || bad "3i auto — без шума про KB: $out"
[[ "$out" != *"infra-billing"* ]] && ok || bad "3j удалённый бот не печатает ложный WARN про infra-billing: $out"
# 3k) удалённая панель full + PANEL_EXTRA_PATHS → WARN; без него — тишина
_rpanel_env; PANEL_EXTRA_PATHS="/opt/certwarden/certwarden-data"; MOCK_RBILL=""; rm -f "$BACKUP_DIR"/lazarus_*
out=$(_backup_remote_target "full" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"PANEL_EXTRA_PATHS задан, но панель удалённая"* ]] && ok || bad "3k remote panel full + extra → WARN (rc=$rc): $out"
PANEL_EXTRA_PATHS=""
out=$(_backup_remote_target "full" 2>&1)
[[ "$out" != *"PANEL_EXTRA_PATHS"* ]] && ok || bad "3l без PANEL_EXTRA_PATHS — WARN нет"
out=$(_backup_remote_target "db_only" 2>&1)
[[ "$out" == *"не найден/не запущен — биллинг НЕ входит"* && "$out" != *"state="* ]] && ok || bad "3m remote panel: billing не найден → прежний WARN без state: $out"
# 3n) remote panel, billing exited → WARN со state + маркер в альбоме both
MOCK_RBILL="exited|postgres:17|infra-billing-db"; rm -f "$BACKUP_DIR"/lazarus_*
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_DEFER="1"
out=$(_backup_remote_target "db_only" 2>&1)
_backup_remote_target "db_only" >/dev/null 2>&1
_BOTH_TG_DEFER=""
[[ "$out" == *"(state=exited) — биллинг НЕ входит"* ]] && ok || bad "3n remote billing exited → WARN со state: $out"
[[ "${_BOTH_TG_LABELS[0]:-}" == *"без infra-billing"* ]] && ok || bad "3o remote both: маркер в метке, got '${_BOTH_TG_LABELS[0]:-}'"
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); MOCK_RBILL=""
TARGET_SSH=""; BOT_TRANSPORT="local"; PANEL_TRANSPORT="local"

# ============================================================ 4) save_config: temp + атомарный rename
_panel_env; BACKUP_SECONDARY="bot"; REMOTE_STORAGE_TYPE="s3"; S3_BUCKET="fake-bucket"; S3_SECRET_KEY="fake-secret-key"
_CANON_BOT_PATH="/opt/rwp-shop"; _CANON_BOT_CONTAINER="rwp_shop"; _CANON_DB_CONTAINER="rwp_shop_db"
rm -f "$CONFIG_FILE"
save_config >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && -s "$CONFIG_FILE" ]] && ok || bad "4a штатный save_config rc=0 (rc=$rc)"
grep -q '^BACKUP_TARGET="panel"$' "$CONFIG_FILE" && grep -q '^BACKUP_SECONDARY="bot"$' "$CONFIG_FILE" \
    && grep -q '^S3_BUCKET="fake-bucket"$' "$CONFIG_FILE" && ok || bad "4b ядро и хвост записаны"
[[ -z "$(ls "$INSTALL_DIR" | grep 'config.env.tmp')" ]] && ok || bad "4c temp не остаётся после успеха"
cp "$CONFIG_FILE" "$T/good.env"
# значение, которое изменили бы в памяти: при сбое на диске обязано остаться прежнее
BOT_TOKEN="111111:changed-fake-token"
_expect_kept() {   # $1 — метка сценария
    local _rc=$2 _o=$3
    [[ $_rc -ne 0 ]] && ok || bad "$1: rc≠0 при сбое записи"
    cmp -s "$CONFIG_FILE" "$T/good.env" && ok || bad "$1: прежний config.env байт в байт"
    [[ -z "$(ls "$INSTALL_DIR" | grep 'config.env.tmp')" ]] && ok || bad "$1: temp убран"
    [[ "$_o" == *"config.env НЕ сохранён"* ]] && ok || bad "$1: ERROR «config.env НЕ сохранён»: $_o"
}
cat() { return 1; }
out=$(save_config 2>&1); rc=$?
unset -f cat
_expect_kept "4d сбой heredoc (ENOSPC)" "$rc" "$out"
# ядро записано целиком, но cat вернул ошибку (ENOSPC/EIO на close) — rc записи обязан учитываться
cat() { command cat; return 1; }
out=$(save_config 2>&1); rc=$?
unset -f cat
_expect_kept "4d2 полная запись, но rc cat≠0" "$rc" "$out"
# огрызок: cat «успешен», но ядро записано не до конца
cat() { command cat | head -c 60; }
out=$(save_config 2>&1); rc=$?
unset -f cat
_expect_kept "4e огрызок ядра (sanity BACKUP_PASSWORD_FILE=)" "$rc" "$out"
printf() { if [[ "$1" == '%s' && "${2:-}" == *'S3_BUCKET='* ]]; then return 1; fi; builtin printf "$@"; }
out=$(save_config 2>&1); rc=$?
unset -f printf
_expect_kept "4f сбой дописывания хвоста" "$rc" "$out"
chmod() { return 1; }
out=$(save_config 2>&1); rc=$?
unset -f chmod
_expect_kept "4g сбой chmod" "$rc" "$out"
mv() { return 1; }
out=$(save_config 2>&1); rc=$?
unset -f mv
_expect_kept "4h сбой rename" "$rc" "$out"
# брошенный temp мёртвого процесса убирается, живого — нет, чужие имена — не трогаем
sleep 60 & _alive=$!
_dead=999999; while kill -0 "$_dead" 2>/dev/null; do _dead=$(( _dead - 1 )); done
echo "x" > "$CONFIG_FILE.tmp.$_dead"; echo "x" > "$CONFIG_FILE.tmp.$_alive"; echo "x" > "$CONFIG_FILE.tmp.keep"
save_config >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$CONFIG_FILE.tmp.$_dead" ]] && ok || bad "4i temp мёртвого PID убран"
[[ -e "$CONFIG_FILE.tmp.$_alive" ]] && ok || bad "4j temp живого PID (параллельный writer) не тронут"
[[ -e "$CONFIG_FILE.tmp.keep" ]] && ok || bad "4k не-PID хвост вне точного шаблона не тронут"
kill "$_alive" 2>/dev/null; wait "$_alive" 2>/dev/null
rm -f "$CONFIG_FILE".tmp.*
grep -q '^BOT_TOKEN="111111:changed-fake-token"$' "$CONFIG_FILE" && ok || bad "4l после успешного save — новое значение"
# roundtrip: load_config_file в чистых дефолтах читает то, что записано
( BACKUP_TARGET="bot"; BACKUP_SECONDARY=""; REMOTE_STORAGE_TYPE="off"; BOT_TOKEN=""
  load_config_file "$CONFIG_FILE" >/dev/null 2>&1
  [[ "$BACKUP_TARGET|$BACKUP_SECONDARY|$REMOTE_STORAGE_TYPE|$BOT_TOKEN" == "panel|bot|s3|111111:changed-fake-token" ]] ) \
    && ok || bad "4m roundtrip save→load"
# _SUPPRESS_SAVE: по-прежнему rc=0 и файл не трогается
cp "$CONFIG_FILE" "$T/good.env"; BOT_TOKEN="222222:other-fake"
( _SUPPRESS_SAVE=1; save_config >/dev/null 2>&1 ) && cmp -s "$CONFIG_FILE" "$T/good.env" && ok || bad "4n _SUPPRESS_SAVE: rc=0, файл не тронут"

# ============================================================ 5) write_password_file: прежний файл цел
printf '%s' 'old-fake-pass' > "$BACKUP_PASSWORD_FILE"
write_password_file 'new-fake-pass' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(command cat "$BACKUP_PASSWORD_FILE")" == 'new-fake-pass' ]] && ok || bad "5a штатная смена пароля"
[[ -z "$(ls -a "$INSTALL_DIR" | grep 'backup_password.tmp')" ]] && ok || bad "5b temp пароля не остаётся"
_pw_kept() {
    [[ $2 -ne 0 ]] && ok || bad "$1: rc≠0"
    [[ "$(command cat "$BACKUP_PASSWORD_FILE" 2>/dev/null)" == 'new-fake-pass' ]] && ok || bad "$1: прежний файл пароля цел"
    [[ -z "$(ls -a "$INSTALL_DIR" | grep 'backup_password.tmp')" ]] && ok || bad "$1: temp пароля убран"
}
printf() { if [[ "$1" == '%s' && "${2:-}" == 'x-fake-pass' ]]; then return 1; fi; builtin printf "$@"; }
write_password_file 'x-fake-pass' >/dev/null 2>&1; rc=$?
unset -f printf
_pw_kept "5c сбой printf (ENOSPC)" "$rc"
cat() { echo "garbled"; }
write_password_file 'x-fake-pass' >/dev/null 2>&1; rc=$?
unset -f cat
_pw_kept "5d частичная запись (сверка)" "$rc"
chmod() { return 1; }
write_password_file 'x-fake-pass' >/dev/null 2>&1; rc=$?
unset -f chmod
_pw_kept "5e сбой chmod" "$rc"
mv() { return 1; }
write_password_file 'x-fake-pass' >/dev/null 2>&1; rc=$?
unset -f mv
_pw_kept "5f сбой rename" "$rc"

# ============================================================ 6) create_backup_dispatch: транзиентные форсы
# Реальный диспетчер; проходы и flush заглушены (сами проходы проверены выше).
( _seen=""
  _backup_active_target() {
      [[ -z "$PANEL_BILLING_DB_CONTAINER" ]] && PANEL_BILLING_DB_CONTAINER="found-billing-db"   # как авто-поиск хелпера
      _seen+="$BACKUP_TARGET:$BACKUP_LOG_FILES:$PANEL_BILLING_DB_CONTAINER;"; return 0; }
  _both_tg_flush() { :; }
  _resolve_target_config() { BACKUP_TARGET="$1"; }
  _panel_env; BACKUP_SECONDARY="bot"; BACKUP_LOG_FILES="ask"; PANEL_BILLING_DB_CONTAINER=""
  create_backup_dispatch "full" >/dev/null 2>&1
  [[ "$_seen" == "panel:false:found-billing-db;bot:false:found-billing-db;" ]] || { echo "SUB-FAIL 6a проходы видели: '$_seen'"; exit 1; }
  [[ "$BACKUP_LOG_FILES" == "ask" ]] || { echo "SUB-FAIL 6b после диспетчера BACKUP_LOG_FILES='$BACKUP_LOG_FILES' (ожидалось ask)"; exit 1; }
  [[ -z "$PANEL_BILLING_DB_CONTAINER" ]] || { echo "SUB-FAIL 6c после диспетчера PANEL_BILLING_DB_CONTAINER='$PANEL_BILLING_DB_CONTAINER'"; exit 1; }
  rm -f "$CONFIG_FILE"; save_config >/dev/null 2>&1
  grep -q '^BACKUP_LOG_FILES=' "$CONFIG_FILE" && { echo "SUB-FAIL 6d save_config записал BACKUP_LOG_FILES"; exit 1; }
  grep -q 'found-billing-db' "$CONFIG_FILE" && { echo "SUB-FAIL 6e save_config записал авто-найденное имя billing"; exit 1; }
  # одиночная цель: авто-найденное имя тоже не оседает
  _seen=""; BACKUP_SECONDARY=""
  create_backup_dispatch "db_only" >/dev/null 2>&1
  [[ "$_seen" == "panel:ask:found-billing-db;" && -z "$PANEL_BILLING_DB_CONTAINER" ]] || { echo "SUB-FAIL 6f single: '$_seen' / '$PANEL_BILLING_DB_CONTAINER'"; exit 1; }
  # контроль: явные значения не меняются
  _seen=""; BACKUP_SECONDARY="bot"; BACKUP_LOG_FILES="true"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"
  create_backup_dispatch "full" >/dev/null 2>&1
  [[ "$_seen" == "panel:true:infra-billing-db;bot:true:infra-billing-db;" && "$BACKUP_LOG_FILES" == "true" ]] || { echo "SUB-FAIL 6g контроль true: '$_seen'"; exit 1; }
  exit 0
) && ok || bad "6 create_backup_dispatch: форсы транзиентны"

[[ ! -s "$T/net_blocked.log" ]] && ok || bad "7 ни одного сетевого вызова: $(head -3 "$T/net_blocked.log")"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
