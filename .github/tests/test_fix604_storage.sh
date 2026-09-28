#!/usr/bin/env bash
# 6.0.4 (storage): регресс-тесты правок выгрузки/ротации/TLS/Telegram. Поведенческие:
#  1) _s3_rotate_old: floor — новейший ключ КАЖДОЙ группы (бот/панель × db/files/full/inc), только
#     плоские ключи в S3_PATH. Старый full + свежие db → full на месте; два старых full → удаляется
#     только более старый; вложенные/чужие ключи не трогаются и не считаются floor'ом; DRY_RUN
#     ничего не удаляет. Прогон под текущим awk и (если есть) mawk / gawk --posix.
#  2) CLI backup_*: код выхода = rc диспетчера (0/1/3) при stdin </dev/null, в т.ч. отдельным
#     процессом с EXIT-trap; _post_backup_prompt в non-tty не зовётся.
#  3) upload_to_remote FTP/WebDAV: --insecure только при REMOTE_TLS_INSECURE=true или согласии
#     сессии (выгрузка и HEAD); ftp:// HEAD — с --ssl; TLS-провал (rc 60) → ERROR и статус с
#     подсказкой «повторите настройку хранилища или REMOTE_TLS_INSECURE=true»; не-TLS — без неё.
#  4) validate_remote_connection: WebDAV 401/403 — отказ с понятным сообщением (PROPFIND, GET-fallback,
#     insecure-PROPFIND); FTP(S): TLS-rc → согласие → повтор с --insecure; без согласия ftp:// — plain
#     + WARN; rc 67 — «логин/пароль»; не-TLS провал ftps согласия не спрашивает.
#  5) мастер хранилища: согласие из validate → REMOTE_TLS_INSECURE=true в save_config; без согласия
#     (и при «старом» согласии сессии) → false; отключение хранилища → false.
#  6) save_config/load_config_file: REMOTE_TLS_INSECURE пишется только недефолтным и читается обратно.
#  7) Telegram: все 10 вызовов Bot API через _tg_curl — токена нет в argv, в stdin ровно
#     `url = "https://api.telegram.org/bot<TOKEN>/<метод>"`; метод и поля -F/-d прежние; stdin
#     не используется для данных; экранирование \ и " (плюс разбор настоящим curl на file://);
#     CR/LF в токене → отказ без вызова curl.
# Сеть не используется: curl/wget/aws/rclone — функции-заглушки и PATH-блокираторы (плюс
# scp/sftp/sshpass/nc/ssh), TG-функции — журналы (настоящие — под именами _real_*). rm/shred —
# только внутри каталога теста. LZ_ONLY="1 3" — прогнать только указанные секции.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске). Секреты фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lz604storage.XXXXXX") || { echo "FAIL: mktemp -d"; exit 1; }
# Windows-TMPDIR вида D:\… рвёт PATH на двоеточии диска — тогда каталог теста в /tmp
if [[ "$T" == *:* ]]; then command rm -rf "$T"; T=$(mktemp -d "/tmp/lz604storage.XXXXXX") || { echo "FAIL: mktemp -d /tmp"; exit 1; }; fi
[[ -n "$T" && "$T" != "/" && -d "$T" ]] || { echo "FAIL: bad test dir '$T'"; exit 1; }

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }
ONLY="${LZ_ONLY:-}"
sec() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }

REAL_CURL=$(command -v curl 2>/dev/null || true)   # только для разбора конфига на file:// (секция 7)

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; command rm -rf "$T"; exit 1; }
trap 'command rm -rf "$T"' EXIT
LOCK_ACQUIRED="false"

# --- песочница удаления: только внутри $T
: > "$T/rm_outside.log"
rm() {
    local a p
    for a in "$@"; do
        case "$a" in -*) continue ;; esac
        [[ "$a" == /* ]] && p="$a" || p="$PWD/$a"
        case "$p" in *"/../"*|*"/..") ;; "$T"/*) continue ;; esac
        printf 'RM_OUTSIDE %s\n' "$a" >> "$T/rm_outside.log"; return 1
    done
    command rm "$@"
}
shred() {
    local a
    for a in "$@"; do
        case "$a" in -*) continue ;; "$T"/*) continue ;; esac
        printf 'RM_OUTSIDE shred %s\n' "$a" >> "$T/rm_outside.log"; return 1
    done
    command shred "$@"
}

# --- сеть: функции-блокираторы + PATH-блокираторы
NETLOG="$T/net.log"; : > "$NETLOG"
curl()   { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
wget()   { printf 'wget %s\n' "$*" >> "$NETLOG"; return 4; }
aws()    { printf 'aws %s\n' "$*" >> "$NETLOG"; return 1; }
rclone() { printf 'rclone %s\n' "$*" >> "$NETLOG"; return 1; }
MOCK="$T/bin"; mkdir -p "$MOCK"
for _nb in curl wget aws rclone scp sftp sshpass nc ssh; do
    printf '#!/usr/bin/env bash\necho "BLOCKED %s $*" >> "%s"\nexit 97\n' "$_nb" "$NETLOG" > "$MOCK/$_nb"
    chmod +x "$MOCK/$_nb"
done
export PATH="$MOCK:$PATH"

# --- Telegram: настоящие функции — под _real_*, под штатными именами — журналы
for _fn in send_telegram_document send_telegram_alert _send_telegram_text _send_telegram_album test_telegram_connection; do
    eval "$(declare -f "$_fn" | sed "1s/^$_fn/_real_$_fn/")"
done
TGLOG="$T/tg.log"; : > "$TGLOG"
send_telegram_notification() { :; }
send_telegram_alert()    { printf 'ALERT|%s|%s\n' "$1" "$2" >> "$TGLOG"; return 0; }
send_telegram_document() { printf 'DOC|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_text()    { printf 'TEXT|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_album()   { printf 'ALBUM|%s\n' "$1" >> "$TGLOG"; return 0; }
test_telegram_connection() { return 0; }

debug_log() { :; }
sleep() { :; }            # ретраи выгрузки не ждут
clear_screen() { :; }
INSTALL_DIR="$T/inst"; mkdir -p "$INSTALL_DIR"; CONFIG_FILE="$INSTALL_DIR/config.env"
BACKUP_PASSWORD_FILE="$INSTALL_DIR/.backup_password"
BACKUP_DIR="$T/bk"; mkdir -p "$BACKUP_DIR"
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"; CURL_SILENT="-s"
BOT_TOKEN="000000:fake-token-for-tests"; CHAT_ID="-100000"; TG_MESSAGE_THREAD_ID=""
REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"; REMOTE_TLS_INSECURE="false"; _REMOTE_TLS_INSECURE_SESSION=""

# ============================================================ 1) S3-ротация: floor по группе
if sec 1; then
iso() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%S.000Z; }
_s3_aws_run() {
    case "$1 $2" in
        "s3api list-objects-v2") cat "$T/bucket.lst" ;;
        "s3api delete-object")
            local a prev="" k=""
            for a in "$@"; do [[ "$prev" == "--key" ]] && k="$a"; prev="$a"; done
            printf '%s\n' "$k" >> "$T/deleted.log" ;;
        *) printf 'S3 %s\n' "$*" >> "$NETLOG"; return 1 ;;
    esac
}
put() { printf '%s\t%s\n' "$1" "$(iso "$2")" >> "$T/bucket.lst"; }
del_set() { LC_ALL=C sort "$T/deleted.log" 2>/dev/null | tr '\n' ' '; }
REMOTE_STORAGE_TYPE="s3"; S3_BUCKET="bk"; S3_PATH="lazarus/prod"; S3_ENDPOINT=""; S3_REGION="auto"
P="lazarus/prod"

rot_scenarios() {   # $1 — метка прогона (awk-вариант)
    local L="$1"
    # 1a–1c: прод-сценарий — full не создавался 5 суток, свежие db каждые 30 мин
    : > "$T/bucket.lst"; : > "$T/deleted.log"
    put "$P/lazarus_full_A.tar.gz.enc" 120;        put "$P/lazarus_panel_full_A.tar.gz.enc" 121
    put "$P/lazarus_db_OLD.tar.gz.enc" 150;        put "$P/lazarus_panel_db_OLD.tar.gz.enc" 151
    put "$P/lazarus_db_NEW.tar.gz.enc" 1;          put "$P/lazarus_panel_db_NEW.tar.gz.enc" 1
    DRY_RUN=false; _s3_rotate_old 4 > "$T/o1" 2>&1; rc=$?
    [[ $rc -eq 0 ]] && ok || bad "1a[$L] rc=0 (got $rc)"
    [[ "$(del_set)" == "$P/lazarus_db_OLD.tar.gz.enc $P/lazarus_panel_db_OLD.tar.gz.enc " ]] && ok \
        || bad "1b[$L] удалены только старые db, оба full (floor своей группы) на месте: '$(del_set)'"
    grep -q 'удалено 2 архив' "$T/o1" && ok || bad "1c[$L] итог ротации: $(cat "$T/o1")"

    # 1d: два старых full + свежий db → удаляется только более старый full (бот и панель раздельно)
    : > "$T/bucket.lst"; : > "$T/deleted.log"
    put "$P/lazarus_full_B1.tar.zst.enc" 120;      put "$P/lazarus_full_B0.tar.zst.enc" 144
    put "$P/lazarus_panel_full_B1.tar.gz" 130;     put "$P/lazarus_panel_full_B0.tar.gz" 170
    put "$P/lazarus_db_NEW.tar.gz.enc" 1
    _s3_rotate_old 4 > "$T/o1" 2>&1
    [[ "$(del_set)" == "$P/lazarus_full_B0.tar.zst.enc $P/lazarus_panel_full_B0.tar.gz " ]] && ok \
        || bad "1d[$L] два старых full → удалён только более старый в каждом семействе: '$(del_set)'"

    # 1e–1f: скоуп — чужой префикс, вложенный ключ, не-наши имена; floor только по плоским ключам
    : > "$T/bucket.lst"; : > "$T/deleted.log"
    put "other/lazarus_full_X.tar.gz" 400                # вне S3_PATH (стаб отдаёт и его)
    put "$P/sub/lazarus_full_NESTED.tar.gz" 1            # вложенный СВЕЖИЙ — не floor для плоских
    put "$P/sub/lazarus_db_NESTED_OLD.tar.gz" 400
    put "$P/lazarus_full_dir/lazarus_full_Z.tar.gz" 1   # подкаталог «под наше имя» — тоже не floor
    put "$P/notes.txt" 400;  put "$P/lazarus_foo_1.tar.gz" 400;  put "${P}x/lazarus_db_Y.tar.gz" 400
    put "$P/lazarus_full_C1.tar.gz" 150;           put "$P/lazarus_full_C0.tar.gz" 200
    put "$P/lazarus_inc_I1__base_x__v1.tar.gz" 100; put "$P/lazarus_inc_I0__base_x__v1.tar.gz" 110
    put "$P/lazarus_files_F0.tar.gz" 300           # единственный files — floor
    _s3_rotate_old 4 > "$T/o1" 2>&1
    [[ "$(del_set)" == "$P/lazarus_full_C0.tar.gz $P/lazarus_inc_I0__base_x__v1.tar.gz " ]] && ok \
        || bad "1e[$L] удалены только старший full и старший inc: '$(del_set)'"
    grep -qE 'other/|/sub/|notes\.txt|lazarus_foo_|prodx/|lazarus_full_dir/' "$T/deleted.log" && bad "1f[$L] тронут чужой/вложенный ключ: '$(del_set)'" || ok

    # 1g: DRY_RUN — только показ, delete-object не вызывается
    : > "$T/deleted.log"; DRY_RUN=true
    _s3_rotate_old 4 > "$T/o1" 2>&1
    DRY_RUN=false
    [[ ! -s "$T/deleted.log" ]] && grep -q 'DRY-RUN\] удалил бы: lazarus/prod/lazarus_full_C0' "$T/o1" \
        && ! grep -q 'lazarus_full_C1' "$T/o1" && ok || bad "1g[$L] DRY_RUN: показ без удаления: $(cat "$T/o1")"

    # 1h: S3_PATH пуст (корень бакета) — floor по группе работает и без префикса
    S3_PATH=""; : > "$T/bucket.lst"; : > "$T/deleted.log"
    put "lazarus_full_R1.tar.gz" 120; put "lazarus_full_R0.tar.gz" 150; put "lazarus_db_NEW.tar.gz" 1
    put "sub/lazarus_full_S.tar.gz" 500; put "foreign.bin" 500
    _s3_rotate_old 4 > "$T/o1" 2>&1
    [[ "$(del_set)" == "lazarus_full_R0.tar.gz " ]] && ok || bad "1h[$L] корень бакета: удалён только старший full: '$(del_set)'"
    S3_PATH="lazarus/prod"
}
rot_scenarios "awk"
if command -v mawk >/dev/null 2>&1; then
    awk() { command mawk "$@"; }; rot_scenarios "mawk"; unset -f awk
else
    echo "SKIP: mawk нет — прогон под mawk пропущен (в CI Ubuntu awk=mawk)"
fi
if command -v gawk >/dev/null 2>&1; then
    awk() { command gawk --posix "$@"; }; rot_scenarios "gawk-posix"; unset -f awk
    # эмуляция mawk на gawk: index(s, "") = 0 (у gawk — 1). Программа — первый аргумент-не-опция.
    awk() {
        local a=() x skip=0 done_prog=0
        for x in "$@"; do
            if [[ $skip -eq 1 ]]; then a+=("$x"); skip=0; continue; fi
            case "$x" in
                -v|-F|-f) a+=("$x"); skip=1 ;;
                -*) a+=("$x") ;;
                *)  if [[ $done_prog -eq 0 ]]; then
                        a+=('function _mx_index(s, t) { return (t == "") ? 0 : index(s, t) } '"${x//index(/_mx_index(}")
                        done_prog=1
                    else a+=("$x"); fi ;;
            esac
        done
        command gawk --posix "${a[@]}"
    }
    rot_scenarios "mawk-emu"; unset -f awk
fi
unset -f _s3_aws_run
REMOTE_STORAGE_TYPE="off"; S3_BUCKET=""
fi

# ============================================================ 2) CLI: код выхода = rc диспетчера
if sec 2; then
CASE_BLOCK=$(sed -n '/^case "\$1" in$/,/^esac$/p' "$SCRIPT")
[[ "$CASE_BLOCK" == *"backup_db)"* ]] && ok || bad "2a главный case найден в скрипте"
: > "$T/cli.log"
create_backup_dispatch()    { printf 'DISPATCH %s\n' "$1" >> "$T/cli.log"; return "$FAKE_RC"; }
create_incremental_backup() { printf 'INC\n' >> "$T/cli.log"; return "$FAKE_RC"; }
_v2_migration_sentinel()    { :; }
_post_backup_prompt()       { printf 'PROMPT\n' >> "$T/cli.log"; return 0; }
for _cmd in "backup_full" "backup_db" "backup_files" "backup_inc" "backup_incremental" \
            "backup create" "backup db" "backup files" "backup inc"; do
    for FAKE_RC in 0 1 3; do
        # shellcheck disable=SC2086
        ( set -- $_cmd; IS_INTERACTIVE=false; eval "$CASE_BLOCK" ) </dev/null > /dev/null 2>&1; rc=$?
        [[ $rc -eq $FAKE_RC ]] && ok || bad "2b '$_cmd' диспетчер rc=$FAKE_RC → exit $FAKE_RC (got $rc)"
    done
done
! grep -q PROMPT "$T/cli.log" && ok || bad "2c non-interactive: _post_backup_prompt не вызывается"
# интерактив: промпт показан, но код выхода — всё равно rc бэкапа
: > "$T/cli.log"; FAKE_RC=1
( set -- backup_db; IS_INTERACTIVE=true; eval "$CASE_BLOCK" ) </dev/null > /dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q PROMPT "$T/cli.log" && ok || bad "2d interactive: промпт и exit=rc бэкапа (rc=$rc)"

# 2e–2g: отдельный процесс bash (EXIT-trap cleanup_on_exit установлен при source), stdin </dev/null
cat > "$T/runner.sh" <<EOF
#!/usr/bin/env bash
export LAZARUS_LIB=true
source "$SCRIPT" >/dev/null 2>&1
export PATH="$MOCK:\$PATH"
INSTALL_DIR="$T/inst"; BACKUP_DIR="$T/bk"; LOG_FILE="$T/lazarus.log"; SILENT_LOG="$T/silent.log"
create_backup_dispatch()    { echo "DISPATCH \$1" >> "$T/proc.log"; return "\$FAKE_RC"; }
create_incremental_backup() { echo "INC" >> "$T/proc.log"; return "\$FAKE_RC"; }
_v2_migration_sentinel()    { :; }
_post_backup_prompt()       { echo "PROMPT" >> "$T/proc.log"; }
eval "\$(sed -n '/^case "\\\$1" in\$/,/^esac\$/p' "$SCRIPT")"
EOF
: > "$T/proc.log"
FAKE_RC=0 bash "$T/runner.sh" backup_db </dev/null >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok || bad "2e процесс: backup_db успешен → exit 0 (got $rc)"
FAKE_RC=1 bash "$T/runner.sh" backup_full </dev/null >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok || bad "2f процесс: backup_full провален → exit 1 (got $rc)"
FAKE_RC=0 bash "$T/runner.sh" backup inc </dev/null >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^DISPATCH db_only$' "$T/proc.log" && grep -q '^DISPATCH full$' "$T/proc.log" \
    && grep -q '^INC$' "$T/proc.log" && ! grep -q PROMPT "$T/proc.log" && ok \
    || bad "2g процесс: backup inc → exit 0, диспетчеры вызваны, промпта нет (rc=$rc): $(cat "$T/proc.log")"
unset -f create_backup_dispatch create_incremental_backup _v2_migration_sentinel _post_backup_prompt
fi

# ============================================================ 3) выгрузка FTP/WebDAV: TLS
if sec 3; then
# curl-заглушка выгрузки: -T → UP_RC/UP_CODE, -sI → Content-Length (HEAD); журнал argv
curl() {
    local a prev="" k=0 line="CALL"
    for a in "$@"; do line+=" $a"; [[ "$prev" == "-K" && "$a" == "-" ]] && k=1; prev="$a"; done
    echo "$line" >> "$T/up_argv.log"
    [[ $k -eq 1 ]] && cat > /dev/null
    if [[ " $* " == *" -sI "* ]]; then printf 'Content-Length: %s\r\n' "$FSIZE"; return 0; fi
    if [[ " $* " == *" -T "* ]]; then
        if [[ "$UP_RC" -ne 0 ]]; then printf '000'; return "$UP_RC"; fi
        printf '%s' "$UP_CODE"; return 0
    fi
    return 1
}
head -c 3000 /dev/zero > "$T/arc.enc"; FSIZE=3000
SEND_TO_REMOTE="true"; REMOTE_STORAGE_USER="u"; REMOTE_STORAGE_PASS="fake-pass-604"
up() {   # $1 type, $2 url → rc; журнал $T/up_argv.log, вывод $T/o3
    : > "$T/up_argv.log"; REMOTE_STORAGE_TYPE="$1"; REMOTE_STORAGE_URL="$2"
    upload_to_remote "$T/arc.enc" > "$T/o3" 2>&1 </dev/null
}
n_ins() { grep -c -- ' --insecure' "$T/up_argv.log"; }
n_calls() { grep -c '^CALL' "$T/up_argv.log"; }

# 3a–3c: по умолчанию — строгая проверка во всех трёх схемах (выгрузка + HEAD)
UP_RC=0; REMOTE_TLS_INSECURE="false"; _REMOTE_TLS_INSECURE_SESSION=""
UP_CODE=201; up webdav "https://dav.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(n_calls) -eq 2 && $(n_ins) -eq 0 ]] && ok || bad "3a WebDAV https: без --insecure (rc=$rc): $(cat "$T/up_argv.log")"
UP_CODE=226; up ftp "ftps://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(n_ins) -eq 0 && $(grep -c -- '--ssl-reqd' "$T/up_argv.log") -eq 2 ]] && ok || bad "3b FTPS: --ssl-reqd без --insecure: $(cat "$T/up_argv.log")"
UP_CODE=226; up ftp "ftp://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(n_ins) -eq 0 && $(grep -c -- ' --ssl ' "$T/up_argv.log") -eq 2 ]] && ok || bad "3c ftp://: --ssl в выгрузке и HEAD, без --insecure: $(cat "$T/up_argv.log")"

# 3d–3e: согласие — сохранённое (REMOTE_TLS_INSECURE=true) или сессии → --insecure в выгрузке и HEAD
REMOTE_TLS_INSECURE="true"
for _u in "webdav|https://dav.example.invalid/bk|201" "ftp|ftps://ftp.example.invalid/bk|226" "ftp|ftp://ftp.example.invalid/bk|226"; do
    IFS='|' read -r _ty _url UP_CODE <<< "$_u"
    up "$_ty" "$_url"; rc=$?
    [[ $rc -eq 0 && $(n_ins) -eq 2 ]] && ok || bad "3d REMOTE_TLS_INSECURE=true $_url: --insecure в выгрузке и HEAD (rc=$rc): $(cat "$T/up_argv.log")"
done
REMOTE_TLS_INSECURE="false"; _REMOTE_TLS_INSECURE_SESSION="1"
UP_CODE=201; up webdav "https://dav.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(n_ins) -eq 2 ]] && ok || bad "3e согласие сессии: --insecure (rc=$rc)"
_REMOTE_TLS_INSECURE_SESSION=""
# 3f: http:// — --insecure не нужен и при согласии
REMOTE_TLS_INSECURE="true"; UP_CODE=201; up webdav "http://dav.example.invalid/bk"
[[ $(n_ins) -eq 0 ]] && ok || bad "3f http:// без --insecure"
REMOTE_TLS_INSECURE="false"

# 3g–3j: TLS-провал (curl rc=60) при строгой проверке → понятный ERROR + статус с подсказкой
: > "$LOG_FILE"; UP_RC=60
up webdav "https://dav.example.invalid/bk"; rc=$?
[[ $rc -ne 0 && $(n_ins) -eq 0 && $(n_calls) -eq 3 ]] && ok || bad "3g TLS rc=60: провал, 3 попытки, молчаливого --insecure нет (rc=$rc, calls=$(n_calls))"
[[ "$REMOTE_UPLOAD_STATUS_TEXT" == *"TLS"* && "$REMOTE_UPLOAD_STATUS_TEXT" == *"повторите настройку хранилища"* && "$REMOTE_UPLOAD_STATUS_TEXT" == *"REMOTE_TLS_INSECURE=true"* ]] \
    && ok || bad "3h статус с подсказкой: '$REMOTE_UPLOAD_STATUS_TEXT'"
grep -q 'TLS-сертификат сервера не прошёл проверку (curl rc=60)' "$T/o3" && grep -q 'REMOTE_TLS_INSECURE=true' "$T/o3" \
    && grep -q 'TLS verification failed (curl rc=60)' "$LOG_FILE" && ok || bad "3i ERROR и журнал о TLS: $(cat "$T/o3")"
UP_RC=35; up ftp "ftps://ftp.example.invalid/bk"
[[ "$REMOTE_UPLOAD_STATUS_TEXT" == *"FTP: ошибка TLS-сертификата"* ]] && ok || bad "3j FTPS rc=35 → TLS-статус: '$REMOTE_UPLOAD_STATUS_TEXT'"
# 3k: не-TLS провал (rc 7) — прежний статус «Ошибка», без TLS-подсказки
UP_RC=7; up webdav "https://dav.example.invalid/bk"; rc=$?
[[ $rc -ne 0 && "$REMOTE_UPLOAD_STATUS_TEXT" == *"WebDAV: Ошибка"* && "$REMOTE_UPLOAD_STATUS_TEXT" != *"TLS"* ]] && ok \
    || bad "3k сеть rc=7 → обычная ошибка: '$REMOTE_UPLOAD_STATUS_TEXT'"
# 3l: TLS-провал уже при согласии — подсказку про REMOTE_TLS_INSECURE не даём (она не поможет)
REMOTE_TLS_INSECURE="true"; UP_RC=35; up webdav "https://dav.example.invalid/bk"
[[ "$REMOTE_UPLOAD_STATUS_TEXT" == *"WebDAV: Ошибка"* ]] && ok || bad "3l insecure уже включён → обычная ошибка: '$REMOTE_UPLOAD_STATUS_TEXT'"
REMOTE_TLS_INSECURE="false"; UP_RC=0
unset -f curl
curl() { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
SEND_TO_REMOTE="false"; REMOTE_STORAGE_TYPE="off"; REMOTE_STORAGE_URL=""
fi

# ============================================================ 4) validate_remote_connection
if sec 4; then
# очередь ответов "код:rc" (файл-счётчик: curl зовётся и из $(…))
curl() {
    local a prev="" k=0 line="CALL" i r
    for a in "$@"; do line+=" $a"; [[ "$prev" == "-K" && "$a" == "-" ]] && k=1; prev="$a"; done
    echo "$line" >> "$T/v_argv.log"
    [[ $k -eq 1 ]] && cat > /dev/null
    i=$(<"$T/qi"); echo $(( i + 1 )) > "$T/qi"
    r="${Q[$i]:-000:7}"
    printf '%s' "${r%%:*}"; return "${r##*:}"
}
vc() {   # $1 type $2 url → rc; вывод $T/o4
    : > "$T/v_argv.log"; echo 0 > "$T/qi"; : > "$T/ask.log"; _REMOTE_TLS_INSECURE_SESSION=""
    validate_remote_connection "$1" "$2" "u" "fake-pass-604" > "$T/o4" 2>&1 </dev/null
}
v_calls() { grep -c '^CALL' "$T/v_argv.log"; }
_remote_allow_insecure_tls() { echo ASKED >> "$T/ask.log"; _REMOTE_TLS_INSECURE_SESSION=1; return 0; }
DAV="https://dav.example.invalid/bk"

Q=("401:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 1 && $(v_calls) -eq 1 ]] && grep -q 'HTTP 401' "$T/o4" && ok || bad "4a PROPFIND 401 → отказ сразу (rc=$rc, calls=$(v_calls)): $(cat "$T/o4")"
Q=("500:0" "401:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 1 && $(v_calls) -eq 2 ]] && grep -q 'неверный логин или пароль' "$T/o4" && ok || bad "4b GET-fallback 401 → НЕ успех (rc=$rc): $(cat "$T/o4")"
Q=("403:0" "403:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'HTTP 403' "$T/o4" && ok || bad "4c GET-fallback 403 → отказ с сообщением (rc=$rc): $(cat "$T/o4")"
Q=("500:0" "000:60" "401:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 1 && $(v_calls) -eq 3 ]] && grep -q 'HTTP 401' "$T/o4" && tail -1 "$T/v_argv.log" | grep -q -- '--insecure' && ok \
    || bad "4d insecure-PROPFIND 401 → НЕ успех (rc=$rc, calls=$(v_calls)): $(cat "$T/o4")"
Q=("500:0" "000:60" "207:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 0 && "$_REMOTE_TLS_INSECURE_SESSION" == "1" ]] && ok || bad "4e контроль: insecure-PROPFIND 207 → успех (rc=$rc)"
Q=("207:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 0 && $(v_calls) -eq 1 ]] && ok || bad "4f контроль: PROPFIND 207 → успех"
Q=("500:0" "200:0"); vc webdav "$DAV"; rc=$?
[[ $rc -eq 0 ]] && ok || bad "4g контроль: GET 200 → успех"

# FTP(S)
Q=(":60" ":0"); vc ftp "ftps://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(v_calls) -eq 2 && -s "$T/ask.log" ]] && tail -1 "$T/v_argv.log" | grep -q -- '--ssl-reqd --insecure' && ok \
    || bad "4h FTPS rc=60 → согласие → повтор с --insecure (rc=$rc): $(cat "$T/v_argv.log")"
Q=(":60" ":0"); vc ftp "ftp://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(v_calls) -eq 2 && -s "$T/ask.log" ]] && tail -1 "$T/v_argv.log" | grep -q -- '--ssl --insecure' && ok \
    || bad "4i ftp:// rc=60 → согласие → повтор --ssl --insecure (rc=$rc): $(cat "$T/v_argv.log")"
Q=(":7"); vc ftp "ftps://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 1 && $(v_calls) -eq 1 && ! -s "$T/ask.log" ]] && ok || bad "4j FTPS rc=7 (не TLS) → согласие не спрашивается (rc=$rc, ask=$(cat "$T/ask.log"))"
Q=(":67" ":67"); vc ftp "ftp://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'отклонил логин/пароль' "$T/o4" && ok || bad "4k FTP rc=67 → «логин/пароль» (rc=$rc): $(cat "$T/o4")"
# без согласия (настоящая функция: non-tty → нет) — ftp:// уходит в plain, но с WARN про TLS
unset -f _remote_allow_insecure_tls
eval "$(sed -n '/^_remote_allow_insecure_tls() {$/,/^}$/p' "$SCRIPT")"
Q=(":60" ":0"); vc ftp "ftp://ftp.example.invalid/bk"; rc=$?
[[ $rc -eq 0 && $(v_calls) -eq 2 ]] && ! tail -1 "$T/v_argv.log" | grep -q -- '--ssl' \
    && grep -q 'TLS-сертификат сервера не прошёл проверку' "$T/o4" && [[ -z "$_REMOTE_TLS_INSECURE_SESSION" ]] && ok \
    || bad "4l ftp:// без согласия: plain-повтор + WARN о TLS (rc=$rc): $(cat "$T/o4")"
unset -f curl
curl() { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
fi

# ============================================================ 5) мастер: согласие → REMOTE_TLS_INSECURE
if sec 5; then
_sv_save=$(declare -f save_config); _sv_val=$(declare -f validate_remote_connection)
save_config() { printf 'SAVE type=%s insecure=%s\n' "$REMOTE_STORAGE_TYPE" "$REMOTE_TLS_INSECURE" >> "$T/save.log"; }
wiz() { : > "$T/save.log"; configure_remote_storage < "$T/ans" > "$T/o5" 2>&1; }
printf '2\nhttps://dav.example.invalid\nbk\nu\nfake-pass-604\n' > "$T/ans"
validate_remote_connection() { _REMOTE_TLS_INSECURE_SESSION=1; return 0; }   # пользователь сказал «да»
REMOTE_STORAGE_TYPE="off"; REMOTE_TLS_INSECURE="false"; wiz
grep -qx 'SAVE type=webdav insecure=true' "$T/save.log" && ok || bad "5a согласие в validate → сохранено REMOTE_TLS_INSECURE=true: $(cat "$T/save.log")"
validate_remote_connection() { return 0; }                                  # сертификат валиден
REMOTE_TLS_INSECURE="true"; _REMOTE_TLS_INSECURE_SESSION=1; wiz            # «старое» согласие сессии
grep -qx 'SAVE type=webdav insecure=false' "$T/save.log" && ok || bad "5b без согласия (старое сброшено) → false: $(cat "$T/save.log")"
# провал validate + «сохранить всё равно»: согласие дано → true
printf '2\nhttps://dav.example.invalid\nbk\nu\nfake-pass-604\ny\n' > "$T/ans"
validate_remote_connection() { _REMOTE_TLS_INSECURE_SESSION=1; return 1; }
REMOTE_TLS_INSECURE="false"; wiz
grep -qx 'SAVE type=webdav insecure=true' "$T/save.log" && ok || bad "5c force-save после согласия → true: $(cat "$T/save.log")"
# отключение хранилища → false
printf '9\n' > "$T/ans"; REMOTE_STORAGE_TYPE="webdav"; REMOTE_TLS_INSECURE="true"; wiz
grep -qx 'SAVE type=off insecure=false' "$T/save.log" && ok || bad "5d отключение → false: $(cat "$T/save.log")"
eval "$_sv_save"; eval "$_sv_val"
REMOTE_STORAGE_TYPE="off"; REMOTE_TLS_INSECURE="false"; _REMOTE_TLS_INSECURE_SESSION=""
fi

# ============================================================ 6) save_config / load: REMOTE_TLS_INSECURE
if sec 6; then
REMOTE_TLS_INSECURE="true"; save_config > /dev/null 2>&1
grep -qx 'REMOTE_TLS_INSECURE="true"' "$CONFIG_FILE" && ok || bad "6a true → строка в config.env"
REMOTE_TLS_INSECURE="false"; load_config_file "$CONFIG_FILE"
[[ "$REMOTE_TLS_INSECURE" == "true" ]] && ok || bad "6b load возвращает true, got '$REMOTE_TLS_INSECURE'"
REMOTE_TLS_INSECURE="false"; save_config > /dev/null 2>&1
! grep -q '^REMOTE_TLS_INSECURE=' "$CONFIG_FILE" && grep -q '^BACKUP_PASSWORD_FILE=' "$CONFIG_FILE" && ok || bad "6c дефолт false в config.env не пишется"
fi

# ============================================================ 7) Telegram: токен не в argv
if sec 7; then
TOKEN_A="123456:AAFakeTokenFor604"
curl() {
    local a prev="" k=0 line="CALL" w=""
    for a in "$@"; do line+=" $a"; [[ "$prev" == "-K" && "$a" == "-" ]] && k=1; [[ "$prev" == "-w" ]] && w="$a"; prev="$a"; done
    echo "$line" >> "$T/tg_argv.log"; echo "$line" >> "$T/tg_all_argv.log"
    if [[ $k -eq 1 ]]; then cat >> "$T/tg_cfg.log"; else echo "NO-K" >> "$T/tg_cfg.log"; fi
    tail -1 "$T/tg_cfg.log" >> "$T/tg_all_cfg.log"
    case "$w" in
        '%{http_code}')    printf '%s' "$TG_CODE" ;;
        *'%{http_code}')   printf '{"ok":true,"result":[]}\n%s' "$TG_CODE" ;;
        *)                 printf '{"ok":true,"result":{"username":"lz604bot"}}' ;;
    esac
    return 0
}
tg_reset() { : > "$T/tg_argv.log"; : > "$T/tg_cfg.log"; }
cfg_is() { grep -cxF "url = \"https://api.telegram.org/bot${TOKEN_A}/$1\"" "$T/tg_cfg.log"; }
argv_has() { grep -qF -- "$1" "$T/tg_argv.log"; }
BOT_TOKEN="$TOKEN_A"; CHAT_ID="-100604"; SEND_TO_TELEGRAM="true"; TG_CODE=200
printf 'x' > "$T/d1.tar.gz"; printf 'y' > "$T/d2.tar.gz"

tg_reset; _real_send_telegram_alert "ERROR" "T604" "body" "" > /dev/null 2>&1
[[ $(cfg_is sendMessage) -eq 1 ]] && argv_has ' -K - ' && argv_has '-X POST' && argv_has 'chat_id=-100604' \
    && argv_has 'parse_mode=MarkdownV2' && argv_has '--data-urlencode' && ok || bad "7a alert: sendMessage через конфиг, поля прежние: $(cat "$T/tg_argv.log") | $(cat "$T/tg_cfg.log")"

tg_reset; _real__send_telegram_text "txt" > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && $(cfg_is sendMessage) -eq 1 ]] && argv_has '--max-time 120' && ok || bad "7b text: rc=$rc cfg=$(cat "$T/tg_cfg.log")"

tg_reset; _real__send_telegram_album "cap" "$T/d1.tar.gz" "$T/d2.tar.gz" > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && $(cfg_is sendMediaGroup) -eq 1 ]] && argv_has "-F doc0=@$T/d1.tar.gz" && argv_has "-F doc1=@$T/d2.tar.gz" \
    && argv_has '-F chat_id=-100604' && argv_has '-F media=[' && ok || bad "7c album: rc=$rc $(cat "$T/tg_argv.log")"

TG_SEND_FILE="true"
tg_reset; _real_send_telegram_document "$T/d1.tar.gz" "cap" > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && $(cfg_is sendDocument) -eq 1 ]] && argv_has "-F document=@$T/d1.tar.gz" && argv_has '-F parse_mode=MarkdownV2' \
    && argv_has '-F caption=' && ok || bad "7d document: rc=$rc $(cat "$T/tg_argv.log")"
TG_SEND_FILE="false"
tg_reset; _real_send_telegram_document "$T/d1.tar.gz" "cap" > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && $(cfg_is sendMessage) -eq 1 ]] && ok || bad "7e document, TG_SEND_FILE=false → sendMessage: rc=$rc"
# fallback >50MB (файл «вырос» между pre-flight и отказом API): sendDocument 413 → sendMessage
TG_SEND_FILE="true"; echo 0 > "$T/statn"
stat() { local n; n=$(<"$T/statn"); echo $(( n + 1 )) > "$T/statn"; [[ $n -eq 0 ]] && echo 100 || echo 60000000; }
tg_reset; TG_CODE=413; _real_send_telegram_document "$T/d1.tar.gz" "cap" > /dev/null 2>&1; rc=$?
unset -f stat; TG_CODE=200; TG_SEND_FILE="false"
[[ $rc -eq 2 && $(cfg_is sendDocument) -eq 1 && $(cfg_is sendMessage) -eq 1 ]] && ok || bad "7f fallback >50MB: rc=$rc cfg=$(cat "$T/tg_cfg.log")"

tg_reset; _real_test_telegram_connection > /dev/null 2>&1 </dev/null
[[ $(cfg_is getMe) -eq 1 && $(cfg_is sendMessage) -eq 1 ]] && argv_has 'text=' && ok || bad "7g test connection: getMe + sendMessage: $(cat "$T/tg_cfg.log")"

tg_reset; emoji_command probe 111 222 > /dev/null 2>&1
grep -qF "url = \"https://api.telegram.org/bot${TOKEN_A}/getCustomEmojiStickers?custom_emoji_ids=" "$T/tg_cfg.log" && ok || bad "7h emoji probe: $(cat "$T/tg_cfg.log")"
tg_reset; emoji_command scan 5 > /dev/null 2>&1
grep -qF "url = \"https://api.telegram.org/bot${TOKEN_A}/getUpdates?limit=5&allowed_updates=" "$T/tg_cfg.log" && ok || bad "7i emoji scan: $(cat "$T/tg_cfg.log")"

# все вызовы секции (накопительные журналы): токена в argv нет, stdin не для данных, всегда -K -
[[ $(grep -c '^CALL' "$T/tg_all_argv.log") -ge 11 ]] && ok || bad "7j0 накоплено вызовов: $(grep -c '^CALL' "$T/tg_all_argv.log")"
grep -qF "$TOKEN_A" "$T/tg_all_argv.log" && bad "7j токен в argv: $(grep -F "$TOKEN_A" "$T/tg_all_argv.log" | head -2)" || ok
! grep -qE '@-( |$)|<-( |$)| -T -( |$)' "$T/tg_all_argv.log" && ok || bad "7k данные не через stdin (@-/-T -)"
! grep -q 'NO-K' "$T/tg_all_cfg.log" && ok || bad "7l каждый вызов с -K -"
# статически: в скрипте не осталось api.telegram.org/bot$… в argv (все 10 мест через _tg_curl)
[[ $(grep -E 'api\.telegram\.org/bot\$' "$SCRIPT" | grep -vcF 'local _u="https://api.telegram.org/bot${BOT_TOKEN}/${_m}"') -eq 0 \
   && $(grep -cE '_tg_curl (sendMessage|sendDocument|sendMediaGroup|getMe|"get)' "$SCRIPT") -ge 10 ]] \
    && ok || bad "7m все вызовы Bot API через _tg_curl"

# 7n: экранирование \ и " в строке конфига + разбор настоящим curl (file://, без сети)
tg_reset; BOT_TOKEN='12"3\x'; _tg_curl getMe -s > /dev/null 2>&1
grep -qxF 'url = "https://api.telegram.org/bot12\"3\\x/getMe"' "$T/tg_cfg.log" && ok || bad "7n экранирование: $(cat "$T/tg_cfg.log")"
if [[ -n "$REAL_CURL" ]] && "$REAL_CURL" --help all 2>/dev/null | grep -q -- '--libcurl'; then
    sed 's#https://api.telegram.org#file:///lz604-nonexistent#' "$T/tg_cfg.log" > "$T/real.cfg"
    "$REAL_CURL" -K "$T/real.cfg" --libcurl "$T/lc.c" -s -o /dev/null >/dev/null 2>&1
    grep -qF 'CURLOPT_URL, "file:///lz604-nonexistent/bot12\"3\\x/getMe"' "$T/lc.c" 2>/dev/null && ok \
        || bad "7o настоящий curl: URL = …/bot12\"3\\x/getMe: $(grep CURLOPT_URL "$T/lc.c" 2>/dev/null)"
else
    echo "SKIP: curl без --libcurl — разбор конфига настоящим curl пропущен"
fi
# 7p: CR/LF в токене — отказ, curl не вызывается
tg_reset; BOT_TOKEN=$'123\nurl = "http://evil.invalid/"'; _tg_curl getMe -s > /dev/null 2>&1; rc=$?
[[ $rc -eq 2 && ! -s "$T/tg_argv.log" ]] && ok || bad "7p CR/LF в токене → rc=2 без curl (rc=$rc)"
BOT_TOKEN="000000:fake-token-for-tests"; SEND_TO_TELEGRAM="false"
unset -f curl
curl() { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
fi

# ============================================================ итог: сеть и песочница удаления
[[ ! -s "$NETLOG" ]] && ok || bad "Z1 ни одного сетевого вызова: $(head -3 "$NETLOG")"
[[ ! -s "$T/rm_outside.log" ]] && ok || bad "Z2 rm/shred вне каталога теста не вызывались: $(head -3 "$T/rm_outside.log")"

echo "---"
echo "fix604-storage: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
