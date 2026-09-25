#!/usr/bin/env bash
# Регресс-тесты 6.0.3 (security): находки 6, 27, 28 перепроверки 25.09.2026.
#  1) install_script: временные файлы — mktemp в TMPDIR (не предсказуемый /tmp/lazarus_install_tmp),
#     rc curl/wget проверяется, --fail, [[ -s ]], root:root 755, EXIT-trap убирает файлы;
#     на штатном старте — нормализация владельца/прав установленного файла.
#  2) perform_update: атомарная замена (новый inode, открытый старый файл дочитывается старым),
#     755 + root:root, провал не трогает текущую версию.
#  3) мастер AWS CLI: mktemp -d в TMPDIR, --fail, sudo только не под root.
#  4) запасные пути create_backup (_tar_err) и show_skipped_report: вторая попытка mktemp,
#     затем /dev/null — и никакого rm /dev/null.
#  5) check_dependencies: flock обязателен, подсказка apt по именам пакетов (util-linux, coreutils).
#     acquire_lock без flock — явная ERROR «flock не найден», rc=1.
#  6) FTP/WebDAV: креды не в argv (curl -K - со stdin), экранирование \ и ", CR/LF — отказ,
#     все запросы validate (включая GET-fallback и insecure-PROPFIND) и upload идут с авторизацией,
#     debug-вывод без пароля.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске).
# Все креды здесь фиктивные.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d)

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
trap 'command rm -rf "$T"' EXIT
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
send_telegram_notification() { :; }
clear_screen() { :; }
sleep() { :; }
# chown/chmod — записываем вызовы (тест не под root; режимы в Git Bash (noacl) не отражают chmod)
chown() { echo "chown $*" >> "$T/perm.log"; return 0; }
chmod() { echo "chmod $*" >> "$T/perm.log"; command chmod "$@" 2>/dev/null; return 0; }
# rm — страховка песочницы: удаляет только внутри $T, остальное пишет в rm_outside.log и отказывает.
# Регресс кода под тестом (или мутация) не должен стереть ничего в настоящих /tmp, /dev/null и т.п.
rm() {
    echo "RM $*" >> "$T/rm.log"
    local a
    for a in "$@"; do
        case "$a" in -*) ;; "$T"/*) ;; *) echo "RM_OUTSIDE $a" >> "$T/rm_outside.log"; return 1 ;; esac
    done
    command rm "$@"
}

# ============================================================ 1) install_script
IS_BODY=$(declare -f install_script)
P="$IS_BODY"
P=${P//'"$EUID" -ne 0'/'1 -eq 0'}
P=${P//'"$0"'/'"$FAKE0"'}
P=${P//'exec "$INSTALLED_SCRIPT_PATH"'/'exec bash "$INSTALLED_SCRIPT_PATH"'}
# жёстко прописанный /tmp (если вернётся) уводим в «системный» /tmp теста — туда кладёт файлы атакующий
P=${P//'"/tmp/'/'"$FAKE_TMP/'}
P=${P//'[[ -O "$INSTALLED_SCRIPT_PATH" ]]'/'[[ -z "${FAKE_NOT_OWNER:-}" ]]'}
P=${P//'command -v curl'/'command -v "${FAKE_CURL_CMD:-curl}"'}
[[ "$P" != "$IS_BODY" && "$P" == *'FAKE0'* && "$P" == *'exec bash'* ]] && ok || bad "1pre патч install_script применился"
eval "$P"

INSTALL_DIR="$T/opt"; SCRIPT_NAME="lazarus-backup"; SYMLINK_PATH="$T/bin/lazarus"
REMOTE_URL="https://example.invalid/lazarus-backup"
FAKE_TMP="$T/systmp"; FAKE0="/dev/fd/63"
mkdir -p "$INSTALL_DIR/tmp" "$T/bin" "$FAKE_TMP"
export TMPDIR="$INSTALL_DIR/tmp"
INST="$INSTALL_DIR/$SCRIPT_NAME"
install_logrotate() { :; }
ORIGINAL_ARGS=(backup_full --yes)

mk_payload() {  # $1=файл $2=маркер: bash-скрипт ≥10000 байт, пишет маркер со своими аргументами
    { echo '#!/bin/bash'; echo "echo \"\$0 \$*\" > '$2'"; local i; for i in $(seq 1 200); do echo "# padding line $i ................................................"; done; } > "$1"
}
mk_payload "$T/good.sh" "$T/RAN_GOOD"
printf '%s  lazarus-backup\n' "$(sha256sum "$T/good.sh" | awk '{print $1}')" > "$T/good.sha256"
# файлы атакующего: предсозданы по старым фиксированным именам (и в /tmp, и в TMPDIR)
mk_payload "$T/evil.sh" "$T/PWNED"
for _d in "$FAKE_TMP" "$TMPDIR"; do
    cp "$T/evil.sh" "$_d/lazarus_install_tmp"
    printf '%s  lazarus-backup\n' "$(sha256sum "$T/evil.sh" | awk '{print $1}')" > "$_d/lazarus_install_tmp.sha256"
done

INST_MODE=good
curl() {
    echo "CURL $*" >> "$T/curl.log"
    local out="" url="" prev="" a
    for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; [[ "$a" == http* ]] && url="$a"; prev="$a"; done
    echo "OUT $out" >> "$T/curl.log"
    case "$INST_MODE" in
        attack)  return 23 ;;   # protected_regular: curl не может открыть чужой файл
        good)    if [[ "$url" == *.sha256* ]]; then cp "$T/good.sha256" "$out"; else cp "$T/good.sh" "$out"; fi; return 0 ;;
        timeout) [[ "$url" == *.sha256* ]] || cp "$T/good.sh" "$out"; return 28 ;;
        empty)   return 0 ;;
        http404) if [[ " $* " == *" --fail "* ]]; then return 22; fi; echo "404: Not Found" > "$out"; return 0 ;;
        interrupt) [[ "$url" == *.sha256* ]] || { cp "$T/good.sh" "$out"; exit 130; } ;;
    esac
}
wget() {
    echo "WGET $*" >> "$T/curl.log"
    local out="" prev="" a
    for a in "$@"; do [[ "$prev" == "-O" ]] && out="$a"; prev="$a"; done
    cp "$T/good.sh" "$out"; return 4   # сеть оборвалась после частичной записи
}
reset_inst() { rm -f "$INST" "$SYMLINK_PATH" "$T"/RAN_* "$T/PWNED" "$T/curl.log" "$T/perm.log"; }
leftovers() { find "$TMPDIR" "$FAKE_TMP" "$INSTALL_DIR" -maxdepth 1 \( -name 'lazarus_install.*' -o -name 'lazarus_install_sha.*' \) 2>/dev/null | wc -l; }

# 1a–1c: атака — подложенный «скрипт» + совпадающий .sha256, curl rc=23
reset_inst; INST_MODE=attack
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -ne 0 ]] && ok || bad "1a атака: rc!=0 (got $rc)"
[[ ! -e "$T/PWNED" ]] && ok || bad "1b атака: код атакующего НЕ исполнен"
[[ ! -e "$INST" ]] && ok || bad "1c атака: в INSTALL_DIR ничего не установлено"
[[ "$out" == *"Не удалось скачать файл"* ]] && ok || bad "1c2 атака: сообщение о провале загрузки"

# 1d–1l: штатная загрузка
reset_inst; INST_MODE=good
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -eq 0 ]] && ok || bad "1d штатная установка rc=0 (got $rc): $out"
[[ -f "$T/RAN_GOOD" ]] && grep -q 'backup_full --yes' "$T/RAN_GOOD" && ok || bad "1e exec установленного скрипта с ORIGINAL_ARGS"
cmp -s "$INST" "$T/good.sh" && ok || bad "1f установлен именно скачанный файл"
_outs=$(grep '^OUT ' "$T/curl.log" | cut -d' ' -f2-)
_nout=$(grep -c '^OUT ' "$T/curl.log")
_nin=$(grep '^OUT ' "$T/curl.log" | cut -d' ' -f2- | grep -cE "^$TMPDIR/lazarus_install(_sha)?\.[A-Za-z0-9]{6}$")
[[ $_nout -eq 2 && $_nin -eq 2 ]] && ok || bad "1g оба -o — случайные mktemp-имена в TMPDIR (got: $_outs)"
[[ $(grep '^CURL ' "$T/curl.log" | grep -c -- ' --fail ') -eq 2 ]] && ok || bad "1h оба curl с --fail"
grep -qx "chown root:root $INST" "$T/perm.log" && ok || bad "1i chown root:root установленного файла"
grep -qx "chmod 755 $INST" "$T/perm.log" && ok || bad "1j chmod 755 (не +x)"
[[ $(leftovers) -eq 0 ]] && ok || bad "1k временные файлы убраны"
cmp -s "$FAKE_TMP/lazarus_install_tmp" "$T/evil.sh" && ok || bad "1l файлы атакующего не тронуты и не использованы"

# 1m: curl записал «нормальный» файл, но rc=28 (таймаут) → отказ
reset_inst; INST_MODE=timeout
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -ne 0 && ! -e "$INST" ]] && ok || bad "1m rc curl=28 → установка прервана (rc=$rc)"
[[ $(leftovers) -eq 0 ]] && ok || bad "1m2 после отказа временные файлы убраны"

# 1n: curl rc=0, но тело пустое → «Не удалось скачать», а не «неверный файл» (-s, не -f)
reset_inst; INST_MODE=empty
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -ne 0 && "$out" == *"Не удалось скачать файл"* ]] && ok || bad "1n пустая загрузка распознана как провал загрузки (-s): $out"

# 1o: 404 от GitHub: с --fail curl даёт rc=22 → провал загрузки
reset_inst; INST_MODE=http404
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
[[ $rc -ne 0 && "$out" == *"Не удалось скачать файл (rc=22)"* ]] && ok || bad "1o 404 → rc=22 и провал загрузки: $out"

# 1p: wget-ветка — rc проверяется так же
reset_inst; FAKE_CURL_CMD="__no_such_curl__"
out=$( ( install_script ) 2>&1 </dev/null ); rc=$?
unset FAKE_CURL_CMD
[[ $rc -ne 0 && ! -e "$INST" ]] && grep -q '^WGET ' "$T/curl.log" && ok || bad "1p wget rc=4 → установка прервана (rc=$rc)"

# 1q: прерывание посреди загрузки (Ctrl+C → exit 130) — EXIT-trap убирает временные файлы
reset_inst; INST_MODE=interrupt
( trap cleanup_on_exit EXIT; install_script ) >/dev/null 2>&1 </dev/null
[[ $(leftovers) -eq 0 ]] && ok || bad "1q exit посреди загрузки — временные файлы убраны EXIT-trap"

# 1r–1s: штатный старт установленного скрипта — нормализация прав/владельца
reset_inst; cp "$T/good.sh" "$INST"; FAKE0="$INST"
( install_script ) >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 ]] && grep -qx "chmod go-w $INST" "$T/perm.log" && ok || bad "1r штатный старт: chmod go-w установленного файла"
grep -q '^chown' "$T/perm.log" && bad "1r2 свой файл — chown не нужен" || ok
: > "$T/perm.log"; FAKE_NOT_OWNER=1
( install_script ) >/dev/null 2>&1 </dev/null
unset FAKE_NOT_OWNER
grep -qx "chown root:root $INST" "$T/perm.log" && ok || bad "1s чужой владелец → chown root:root"
FAKE0="/dev/fd/63"
[[ $(grep -c '"/tmp/' <<< "$IS_BODY") -eq 0 ]] && ok || bad "1t в install_script нет жёстких \"/tmp/…\" путей"

# ============================================================ 2) perform_update
PU_BODY=$(declare -f perform_update)
P=${PU_BODY//'exec "$SCRIPT_PATH"'/'exec bash "$SCRIPT_PATH"'}
[[ "$P" != "$PU_BODY" ]] && ok || bad "2pre патч perform_update применился"
eval "$P"
INSTALL_DIR="$T/upd"; mkdir -p "$INSTALL_DIR"
SP="$INSTALL_DIR/$SCRIPT_NAME"
mk_payload "$SP" "$T/RAN_OLD"
cp "$SP" "$T/old_copy"
mk_payload "$T/new.sh" "$T/RAN_NEW"
NEW_CONTENT=$(cat "$T/new.sh")
_ino_old=$(stat -c %i "$SP")
: > "$T/perm.log"
exec 9< "$SP"          # «cron-экземпляр bash» держит старый файл открытым
( perform_update "$NEW_CONTENT" ) >/dev/null 2>&1 </dev/null; rc=$?
_seen=$(cat <&9); exec 9<&-
[[ $rc -eq 0 && -f "$T/RAN_NEW" ]] && ok || bad "2a обновление применено и запущено (rc=$rc)"
cmp -s "$SP" "$T/new.sh" && ok || bad "2b содержимое новой версии"
[[ "$(stat -c %i "$SP")" != "$_ino_old" ]] && ok || bad "2c новый inode (rename), не запись поверх"
[[ "$_seen" == "$(cat "$T/old_copy")" ]] && ok || bad "2d открытый старый файл дочитывается старым текстом"
grep -qE "^chmod 755 $INSTALL_DIR/\.$SCRIPT_NAME\.update\.[A-Za-z0-9]{6}$" "$T/perm.log" && ok || bad "2e chmod 755 временного файла в том же каталоге"
grep -qE "^chown root:root $INSTALL_DIR/\.$SCRIPT_NAME\.update\." "$T/perm.log" && ok || bad "2f chown root:root временного файла"
[[ -z "$(find "$INSTALL_DIR" -maxdepth 1 -name ".$SCRIPT_NAME.update.*")" ]] && ok || bad "2g временный файл не остался"
cmp -s "$INSTALL_DIR/$SCRIPT_NAME.backup" "$T/old_copy" && ok || bad "2h резервная копия старой версии"
# провал записи (mktemp не удался) → текущая версия не тронута
cp "$T/old_copy" "$SP"; _ino_old=$(stat -c %i "$SP")
out=$( ( mktemp() { return 1; }; perform_update "$NEW_CONTENT" ) 2>&1 </dev/null ); rc=$?
[[ $rc -eq 1 ]] && cmp -s "$SP" "$T/old_copy" && [[ "$(stat -c %i "$SP")" == "$_ino_old" ]] && ok || bad "2i провал → rc=1, текущая версия не тронута"
[[ "$out" == *"Текущая версия не изменена"* ]] && ok || bad "2j сообщение о нетронутой версии"

# ============================================================ 3) мастер AWS CLI
CR_BODY=$(declare -f configure_remote_storage)
P=${CR_BODY//'"$EUID" -ne 0'/'"${FAKE_EUID:-$EUID}" -ne 0'}
[[ "$P" != "$CR_BODY" ]] && ok || bad "3pre патч configure_remote_storage применился"
eval "$P"
export TMPDIR="$T/awstmp"; mkdir -p "$TMPDIR"
_s3_arch_suffix() { echo x86_64; }
curl() {
    echo "CURL $*" >> "$T/aws.log"
    local out="" prev="" a
    for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
    [[ "$out" == "$TMPDIR/"* ]] || { echo "OUTSIDE $out" >> "$T/aws.log"; return 23; }
    echo "zip" > "$out"
}
unzip() {
    local d="" prev="" a
    for a in "$@"; do [[ "$prev" == "-d" ]] && d="$a"; prev="$a"; done
    [[ "$d" == "$TMPDIR/"* ]] || { echo "UNZIP_OUTSIDE $d" >> "$T/aws.log"; return 1; }
    mkdir -p "$d/aws"; printf '#!/bin/bash\necho "INSTALLER $0 $*" >> "%s"\n' "$T/aws.log" > "$d/aws/install"; command chmod +x "$d/aws/install"
}
sudo() { echo "SUDO $*" >> "$T/aws.log"; "$@"; }
run_aws() { printf '1\nY\n\n\n' | configure_remote_storage >/dev/null 2>&1; }
if command -v aws >/dev/null 2>&1; then
    echo "SKIP: aws установлен — ветка установки AWS CLI не проверяется"
else
    : > "$T/aws.log"; FAKE_EUID=0 run_aws
    grep -qE "^INSTALLER $TMPDIR/lazarus_awscli\.[A-Za-z0-9]{6}/aws/install --update" "$T/aws.log" && ok || bad "3a установщик из mktemp -d в TMPDIR: $(cat "$T/aws.log")"
    grep -q '^SUDO' "$T/aws.log" && bad "3b под root — без sudo" || ok
    grep '^CURL' "$T/aws.log" | grep -q -- '--fail' && ok || bad "3c curl с --fail"
    [[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] && ok || bad "3d рабочий каталог удалён"
    : > "$T/aws.log"; FAKE_EUID=1000 run_aws
    grep -q '^SUDO .*/aws/install --update' "$T/aws.log" && ok || bad "3e не под root — через sudo"
fi
unset -f curl unzip sudo
unset FAKE_EUID

# ============================================================ 4) запасные пути временных файлов
# mktemp-заглушка: без аргументов (TMPDIR) — отказ; с шаблоном — успех, если MKT_OK2=1 (файл в $T)
mktemp() {
    echo "MKT $*" >> "$T/mkt.log"
    [[ $# -eq 0 ]] && return 1
    [[ "${MKT_OK2:-}" == 1 ]] || return 1
    local f; f="$T/fb.$RANDOM$RANDOM"; : > "$f"; echo "$f"
}
CB_BODY=$(declare -f create_backup)
L_ASSIGN=$(grep -m1 '_tar_err=$(mktemp' <<< "$CB_BODY")
L_RM=$(grep -m1 'rm -f "$_tar_err"' <<< "$CB_BODY")
[[ -n "$L_ASSIGN" && -n "$L_RM" ]] && ok || bad "4pre строки _tar_err найдены в create_backup"
eval "_t_tar_err() { local _tar_err; $L_ASSIGN
$L_RM
echo \"\$_tar_err\"; }"
: > "$T/mkt.log"; : > "$T/rm.log"; MKT_OK2=1
_te=$(_t_tar_err)
[[ "$_te" == "$T/fb."* ]] && ok || bad "4a create_backup: вторая попытка mktemp (got '$_te')"
grep -qx 'MKT /tmp/lazarus_tar_err.XXXXXX' "$T/mkt.log" && ok || bad "4b вторая попытка — случайный шаблон в /tmp, не .\$\$"
: > "$T/rm.log"; MKT_OK2=0
_te=$(_t_tar_err)
[[ "$_te" == /dev/null ]] && ok || bad "4c обе попытки провалились → /dev/null (got '$_te')"
grep -q '/dev/null' "$T/rm.log" && bad "4d rm /dev/null НЕ вызывается" || ok

BACKUP_DIR="$T/bk"; mkdir -p "$BACKUP_DIR"
printf '12345\t/opt/bot/big.bin\tsize\n' > "$BACKUP_DIR/.last_skipped.txt"
: > "$T/mkt.log"; : > "$T/rm.log"; MKT_OK2=1
out=$(show_skipped_report 2>&1 </dev/null)
[[ "$out" == *"/opt/bot/big.bin"* ]] && ok || bad "4e show_skipped_report: запасной mktemp работает"
grep -qx 'MKT /tmp/lazarus_skipped_view.XXXXXX' "$T/mkt.log" && ok || bad "4f вторая попытка — случайный шаблон в /tmp"
: > "$T/rm.log"; MKT_OK2=0
show_skipped_report >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 ]] && ok || bad "4g без mktemp отчёт не падает"
grep -q '/dev/null' "$T/rm.log" && bad "4h rm /dev/null НЕ вызывается" || ok
unset -f mktemp

# ============================================================ 5) flock: зависимости и acquire_lock
MISSING=""
command() { if [[ "${1:-}" == "-v" && " $MISSING " == *" ${2:-} "* ]]; then return 1; fi; builtin command "$@"; }
docker() { return 0; }
flock() { return 0; }
MISSING="flock"
out=$( ( check_dependencies ) 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && ok || bad "5a без flock check_dependencies = exit 1 (got $rc)"
[[ "$out" == *"Missing dependencies:"*"flock"* ]] && ok || bad "5b flock в списке обязательных: $out"
[[ "$out" == *"apt install util-linux"* ]] && ok || bad "5c подсказка apt install util-linux"
[[ "$out" != *"apt install flock"* ]] && ok || bad "5d нет несуществующего пакета flock в подсказке"
MISSING="realpath sha256sum rsync"
out=$( ( check_dependencies ) 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ok || bad "5e опциональные не валят старт (rc=$rc): $out"
_hint=$(grep -a 'HINT' <<< "$out")
[[ "$_hint" == *"apt install rsync"*"coreutils"* && $(grep -o 'coreutils' <<< "$_hint" | wc -l) -eq 1 ]] && ok || bad "5f realpath+sha256sum → один coreutils: $_hint"
[[ "${_hint#*apt install}" != *"sha256sum"* && "${_hint#*apt install}" != *"realpath"* ]] && ok || bad "5g в apt install нет имён команд вместо пакетов: $_hint"

LOCK_FILE="$T/run/lazarus.lock"
MISSING="flock"
out=$( ( acquire_lock ) 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && ok || bad "5h acquire_lock без flock — rc=1 (got $rc)"
[[ "$out" == *"flock не найден (пакет util-linux)"* ]] && ok || bad "5i явная ERROR «flock не найден»: $out"
grep -q 'flock not installed' "$LOG_FILE" && ok || bad "5j запись в журнал"
MISSING=""; flock() { return 1; }
out=$( ( acquire_lock ) 2>&1 ); rc=$?
[[ $rc -eq 1 && "$out" != *"flock не найден"* ]] && ok || bad "5k занято: rc=1 без сообщения об отсутствии flock"
flock() { return 0; }
( acquire_lock ) >/dev/null 2>&1 && ok || bad "5l flock есть и свободно → rc=0"
unset -f command docker flock

# ============================================================ 6) креды FTP/WebDAV не в argv
PW='S3cr3t"PW\x'          # фиктивный; с " и \ — проверка экранирования
EXP_CFG='user = "u:S3cr3t\"PW\\x"'
CURL_SCEN=""
curl() {
    local a prev="" k=0 line
    line="CALL"; for a in "$@"; do line+=" $a"; [[ "$prev" == "-K" && "$a" == "-" ]] && k=1; prev="$a"; done
    echo "$line" >> "$T/argv.log"
    if [[ $k -eq 1 ]]; then cat >> "$T/cfg.log"; fi
    if [[ " $* " == *" -sI "* ]]; then printf 'Content-Length: %s\r\n' "$FSIZE"; return 0; fi
    case "$CURL_SCEN" in
        ftp_up)  printf '226'; return 0 ;;
        dav_up)  printf '201'; return 0 ;;
        ftp_val) if [[ " $* " == *" --ssl "* ]]; then return 35; fi; return 0 ;;
        dav_val) if [[ " $* " == *" PROPFIND "* && " $* " == *" --insecure "* ]]; then printf '207'; return 0; fi
                 if [[ " $* " == *" PROPFIND "* ]]; then printf '500'; return 0; fi
                 printf '000'; return 7 ;;
    esac
}
reset_net() { : > "$T/argv.log"; : > "$T/cfg.log"; }
calls() { grep -c '^CALL' "$T/argv.log"; }
calls_k() { grep '^CALL' "$T/argv.log" | grep -c -- ' -K - '; }
no_pw() { ! grep -qF 'S3cr3t' "$T/argv.log"; }
cfg_ok() { local n; n=$(grep -c . "$T/cfg.log"); [[ $n -eq $1 && $(grep -cxF "$EXP_CFG" "$T/cfg.log") -eq $1 ]]; }

head -c 3000 /dev/zero > "$T/arc.enc"; FSIZE=3000
SEND_TO_REMOTE=true; IS_INTERACTIVE=false
REMOTE_STORAGE_USER="u"; REMOTE_STORAGE_PASS="$PW"

# 6a–6d: аплоад FTP (upload + HEAD)
reset_net; CURL_SCEN=ftp_up; REMOTE_STORAGE_TYPE=ftp; REMOTE_STORAGE_URL="ftp://h.example/p"
upload_to_remote "$T/arc.enc" >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 ]] && ok || bad "6a FTP upload rc=0 (got $rc)"
no_pw && ok || bad "6b FTP: пароля нет в argv: $(cat "$T/argv.log")"
[[ $(calls) -eq 2 && $(calls_k) -eq 2 ]] && ok || bad "6c FTP: upload и HEAD — оба с -K -"
cfg_ok 2 && ok || bad "6d FTP: конфиг curl = user с экранированием: $(cat "$T/cfg.log")"

# 6e–6g: аплоад WebDAV
reset_net; CURL_SCEN=dav_up; REMOTE_STORAGE_TYPE=webdav; REMOTE_STORAGE_URL="https://dav.example/p"
upload_to_remote "$T/arc.enc" >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 ]] && ok || bad "6e WebDAV upload rc=0 (got $rc)"
no_pw && ok || bad "6f WebDAV: пароля нет в argv"
[[ $(calls) -eq 2 && $(calls_k) -eq 2 ]] && cfg_ok 2 && ok || bad "6g WebDAV: upload и HEAD с -K -, конфиг верный"

# 6h–6j: validate FTP с --debug: TLS-попытка провалена, повтор без TLS — оба с авторизацией
reset_net; CURL_SCEN=ftp_val; DEBUG_MODE=true
_dbg=$(validate_remote_connection ftp "ftp://h.example/p" u "$PW" 2>&1 </dev/null); rc=$?
DEBUG_MODE=false
[[ $rc -eq 0 ]] && ok || bad "6h validate FTP rc=0 (got $rc)"
[[ $(calls) -eq 2 && $(calls_k) -eq 2 ]] && no_pw && cfg_ok 2 && ok || bad "6i validate FTP: оба запроса с -K -, пароля нет в argv"
[[ "$_dbg" != *"S3cr3t"* && "$_dbg" == *"Running: curl"* ]] && ok || bad "6j debug-вывод без пароля"

# 6k–6l: validate WebDAV: PROPFIND 500 → GET-fallback 000 → insecure-PROPFIND 207 — все три с авторизацией
reset_net; CURL_SCEN=dav_val
_remote_allow_insecure_tls() { return 0; }
validate_remote_connection webdav "https://dav.example/p" u "$PW" >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 ]] && ok || bad "6k validate WebDAV через insecure-PROPFIND rc=0 (got $rc)"
[[ $(calls) -eq 3 && $(calls_k) -eq 3 ]] && no_pw && cfg_ok 3 && ok || bad "6l PROPFIND, GET-fallback и insecure-PROPFIND — все с -K -: $(cat "$T/argv.log")"

# 6m: пустой user — без -K, stdin не читается (как раньше)
reset_net; CURL_SCEN=ftp_up; REMOTE_STORAGE_TYPE=ftp; REMOTE_STORAGE_URL="ftp://h.example/p"; REMOTE_STORAGE_USER=""
upload_to_remote "$T/arc.enc" >/dev/null 2>&1 </dev/null; rc=$?
[[ $rc -eq 0 && $(calls) -eq 2 && $(calls_k) -eq 0 ]] && ok || bad "6m без логина — curl без -K"

# 6n–6q: CR/LF в пароле — явный отказ, curl не вызывается
reset_net; REMOTE_STORAGE_USER="u"; REMOTE_STORAGE_PASS=$'bad\npw'
out=$(upload_to_remote "$T/arc.enc" 2>&1 </dev/null); rc=$?
[[ $rc -ne 0 && $(calls) -eq 0 ]] && ok || bad "6n upload: CR/LF → отказ без запросов"
[[ "$out" == *"перевод строки"* ]] && ok || bad "6o upload: ERROR о переводе строки"
# CR — через переменную: Git Bash вырезает литеральный CR из текста $(…), $'…\r…' внутри не дошёл бы
_pw_cr=$'bad\rpw'; _pw_lf=$'x\ny'
out=$(validate_remote_connection webdav "https://dav.example/p" u "$_pw_cr" 2>&1 </dev/null); rc=$?
[[ $rc -ne 0 && $(calls) -eq 0 && "$out" == *"перевод строки"* ]] && ok || bad "6p validate: CR → отказ с ERROR"
reset_net
out=$( _curl_with_auth u "$_pw_lf" -s "ftp://h.example/" 2>&1 </dev/null ); rc=$?
[[ $rc -ne 0 && $(calls) -eq 0 ]] && ok || bad "6q _curl_with_auth сам отклоняет CR/LF"
unset -f curl _remote_allow_insecure_tls

# 6r: настоящий curl понимает экранированный конфиг так же, как --user (CURLOPT_USERPWD через --libcurl)
if command -v curl >/dev/null 2>&1 && curl --help all 2>/dev/null | grep -q -- '--libcurl'; then
    : > "$T/empty.txt"
    _curl_with_auth u "$PW" -s --libcurl "$T/lc.c" -o /dev/null "file://$T/empty.txt" >/dev/null 2>&1 </dev/null
    grep -qF 'CURLOPT_USERPWD, "u:S3cr3t\"PW\\x"' "$T/lc.c" 2>/dev/null && ok || bad "6r libcurl: USERPWD = u:S3cr3t\"PW\\x: $(grep USERPWD "$T/lc.c" 2>/dev/null)"
else
    echo "SKIP: curl без --libcurl — проверка разбора конфига пропущена"
fi

[[ ! -s "$T/rm_outside.log" ]] && ok || bad "7 ни одного rm вне песочницы: $(cat "$T/rm_outside.log")"

echo "fix603-security: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]]
