#!/usr/bin/env bash
# 6.0.4(config): регресс-тесты правок группы config по аудиту 6.0.3 (находки [9], [10], [11]).
#  1) write_password_file: .password — симлинк (сейф секретов) → пишем в ЦЕЛЬ ссылки: ссылка остаётся
#     ссылкой, в цели новый пароль, temp рядом с целью (rename в одном каталоге), брошенные temp
#     убираются и у цели, и у ссылки (там их оставляла 6.0.3), живой чужой temp не трогаем; сбой mv —
#     цель со старым паролем цела; висячая ссылка — файл создаётся в цели; обычный файл — как раньше.
#     ФС без симлинков — явный SKIP.
#  2) read_password_file: пробел/таб/перенос по краям или BOM в начале → WARN в stderr и в лог, пароль
#     НЕ меняется (им зашифрованы архивы); обычный пароль, хвостовой \n / \r\n, пробелы внутри — без WARN.
#  3) find_db_container_for_path и поиск БД в scan_system_for_bot: панель и infra-billing отсекаются по
#     роли, а не по подстроке 'remnawave_' — БД bedolaga (remnawave_bot_db) находится (сервис postgres и
#     кастомный сервис по образу), прод-набор rwp-shop → rwp_shop_db (не kb), каталог панели не отдаёт
#     remnawave-db / infra-billing-db / кастомное имя БД панели.
#  4) BOT_KEYWORDS_DEFAULT: + remnawave_bot (bedolaga находится сканом), прежние ключи на месте,
#     _is_bot_infra_container отсекает remnawave_bot_db / remnawave_bot_redis; resolve_bot_runtime на
#     прод-наборе и на bedolaga.
# Сеть не используется: TG-функции — заглушки; curl/wget/aws/rclone/ssh/scp/nc — функции-блокираторы и
# PATH-блокираторы; итоговая проверка «сети не было». rm/shred — только внутри каталога теста.
# docker — функция-мок (состояние в файлах каталога теста), timeout — сквозной (иначе внешний timeout
# не увидит функцию docker).
# LZ604C_ONLY="1 3" — прогнать только указанные секции (для мутационной проверки).
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске). Пароли фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lz604config.XXXXXX") || { echo "FAIL: mktemp -d"; exit 1; }
# Windows-TMPDIR вида D:\… рвёт PATH на двоеточии диска — тогда каталог теста в /tmp
if [[ "$T" == *:* ]]; then command rm -rf "$T"; T=$(mktemp -d "/tmp/lz604config.XXXXXX") || { echo "FAIL: mktemp -d /tmp"; exit 1; }; fi
[[ -n "$T" && "$T" != "/" && -d "$T" ]] || { echo "FAIL: bad test dir '$T'"; exit 1; }

n_ok=0; n_err=0; n_skip=0
ok()   { n_ok=$(( n_ok + 1 )); }
bad()  { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }
skip() { echo "SKIP: $1"; n_skip=$(( n_skip + 1 )); }
ONLY="${LZ604C_ONLY:-}"
sec() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; command rm -rf "$T"; exit 1; }
trap 'cd / && command rm -rf "$T"' EXIT

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
    command shred "$@"
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
for _nb in curl wget aws rclone ssh scp sftp sshpass nc docker; do
    cat > "$MOCK/$_nb" <<EOF
#!/usr/bin/env bash
echo "BLOCKED $_nb \$*" >> "$NETLOG"
exit 97
EOF
    chmod +x "$MOCK/$_nb"
done
export PATH="$MOCK:$PATH"

# --- Telegram: только журнал
TGLOG="$T/tg.log"; : > "$TGLOG"
send_telegram_notification() { :; }
send_telegram_alert()    { printf 'ALERT|%s\n' "$*" >> "$TGLOG"; return 0; }
send_telegram_document() { printf 'DOC|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_text()    { printf 'TEXT|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_album()   { printf 'ALBUM|%s\n' "$1" >> "$TGLOG"; return 0; }

debug_log() { :; }
sleep() { :; }
timeout() { shift; "$@"; }
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
DEBUG_MODE=false; IS_INTERACTIVE=false; AUTO_CONFIRM=true
INSTALL_DIR="$T/inst"; mkdir -p "$INSTALL_DIR"
# рабочий каталог — внутри теста: относительный путь (мутация, пустая переменная) не уйдёт наружу
cd "$T" || { echo "FAIL: cd $T"; exit 1; }
IS_WIN=false; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=true ;; esac

# перечень вызовов mv (источник → цель) для проверки «temp рядом с целью»
: > "$T/mv.log"
mv() { printf '%s\n' "$*" >> "$T/mv.log"; command mv "$@"; }

# ============================================================ 1) write_password_file: симлинк → цель
if sec 1; then
VAULT="$T/vault"; mkdir -p "$VAULT"
printf '%s' 'OLD-fake-pw-604' > "$VAULT/pw"; chmod 600 "$VAULT/pw"
LINK="$INSTALL_DIR/.password"
MSYS=winsymlinks:nativestrict ln -s "$VAULT/pw" "$LINK" 2> "$T/ln.err"
if [[ ! -L "$LINK" ]]; then
    skip "1 ФС/окружение без симлинков ($(head -1 "$T/ln.err")) — проверки симлинка не выполнены"
    command rm -f "$LINK"
else
    BACKUP_PASSWORD_FILE="$LINK"
    # брошенные temp: у цели (мёртвый PID), у ссылки (оставила 6.0.3); temp живого чужого процесса
    # (фоновый sleep теста; PPID не годится — под нативным родителем Windows он 1) — оставить
    command sleep 120 & LIVE_PID=$!
    printf 'stale1' > "$VAULT/pw.tmp.99999991"
    printf 'stale2' > "$LINK.tmp.99999992"
    printf 'live'   > "$VAULT/pw.tmp.$LIVE_PID"
    : > "$T/mv.log"
    write_password_file 'NEW-fake-pw-604' > "$T/out1" 2>&1; rc=$?
    [[ $rc -eq 0 ]] && ok || bad "1a write через симлинк rc=$rc: $(strip < "$T/out1")"
    [[ -L "$LINK" ]] && ok || bad "1b .password остался симлинком (заменён обычным файлом)"
    [[ "$(cat "$VAULT/pw")" == 'NEW-fake-pw-604' ]] && ok || bad "1c в цели ссылки новый пароль, got '$(cat "$VAULT/pw")'"
    [[ "$(readlink "$LINK")" == "$VAULT/pw" ]] && ok || bad "1d ссылка указывает туда же: '$(readlink "$LINK")'"
    BACKUP_PASSWORD=""; read_password_file 2>/dev/null
    [[ "$BACKUP_PASSWORD" == 'NEW-fake-pw-604' ]] && ok || bad "1e read через ссылку → новый пароль, got '$BACKUP_PASSWORD'"
    # rename в одном каталоге: источник mv — temp в каталоге ЦЕЛИ, приёмник — сама цель
    _mvl=$(grep -F '.tmp.' "$T/mv.log" | tail -1)
    [[ "$_mvl" == "-f $VAULT/pw.tmp."*" $VAULT/pw" ]] && ok || bad "1f temp рядом с целью и mv в цель: '$_mvl'"
    [[ ! -e "$VAULT/pw.tmp.99999991" ]] && ok || bad "1g брошенный temp у цели убран"
    [[ ! -e "$LINK.tmp.99999992" ]] && ok || bad "1h брошенный temp у ссылки (6.0.3) убран"
    [[ -e "$VAULT/pw.tmp.$LIVE_PID" ]] && ok || bad "1i temp живого процесса не тронут"
    kill "$LIVE_PID" 2> /dev/null; wait "$LIVE_PID" 2> /dev/null
    command rm -f "$VAULT/pw.tmp.$LIVE_PID"
    _left=$(ls -A "$VAULT" "$INSTALL_DIR" | grep -c '\.tmp\.' )
    [[ "$_left" -eq 0 ]] && ok || bad "1j своих temp не осталось: $(ls -A "$VAULT" "$INSTALL_DIR")"
    _wl=$(strip < "$T/out1" | grep -F 'Права на')
    if [[ "$IS_WIN" == true ]]; then
        skip "1k права 600 у цели — NTFS в Git Bash не хранит режим (проверка на Linux CI)"
        # режим NTFS ≠ 600 → WARN есть всегда; он обязан показывать права ЦЕЛИ (у ссылки было бы 777)
        [[ -z "$_wl" || "$_wl" == *"Права на $VAULT/pw: $(stat -c '%a' "$VAULT/pw") "* ]] && ok || bad "1l WARN о правах — про цель: '$_wl'"
    else
        [[ "$(stat -c '%a' "$VAULT/pw")" == "600" ]] && ok || bad "1k права цели 600, got $(stat -c '%a' "$VAULT/pw")"
        [[ -z "$_wl" ]] && ok || bad "1l нет WARN о правах (stat цели, не ссылки): '$_wl'"
    fi
    # сбой mv: цель со СТАРЫМ паролем цела, ссылка цела, temp убран
    mv() { printf '%s\n' "$*" >> "$T/mv.log"; return 1; }
    write_password_file 'FAIL-fake-pw-604' > "$T/out1m" 2>&1; rc=$?
    mv() { printf '%s\n' "$*" >> "$T/mv.log"; command mv "$@"; }
    [[ $rc -eq 1 ]] && ok || bad "1m сбой mv → rc=1, got $rc"
    [[ -L "$LINK" && "$(cat "$VAULT/pw")" == 'NEW-fake-pw-604' ]] && ok || bad "1n сбой mv: ссылка и прежний пароль в цели целы, got '$(cat "$VAULT/pw")'"
    [[ "$(ls -A "$VAULT" | grep -c '\.tmp\.')" -eq 0 ]] && ok || bad "1o сбой mv: temp у цели убран: $(ls -A "$VAULT")"
    command rm -f "$LINK"
    # висячая ссылка с существующим каталогом цели: файл создаётся в цели, ссылка остаётся
    LINK2="$INSTALL_DIR/.password_dangling"
    MSYS=winsymlinks:native ln -s "$VAULT/newpw" "$LINK2" 2>/dev/null
    if [[ -L "$LINK2" && ! -e "$VAULT/newpw" ]]; then
        BACKUP_PASSWORD_FILE="$LINK2"
        write_password_file 'DANG-fake-pw-604' > "$T/out1d" 2>&1; rc=$?
        [[ $rc -eq 0 && -L "$LINK2" && "$(cat "$VAULT/newpw" 2>/dev/null)" == 'DANG-fake-pw-604' ]] && ok \
            || bad "1p висячая ссылка → файл в цели: rc=$rc link=$([[ -L "$LINK2" ]] && echo y) target='$(cat "$VAULT/newpw" 2>/dev/null)'"
    else
        skip "1p висячий симлинк не создаётся в этом окружении (Windows nativestrict/native)"
    fi
    command rm -f "$LINK2"
    # ссылка не разрешается (нет каталога цели): WARN и прежнее поведение — обычный файл с новым паролем
    LINK3="$INSTALL_DIR/.password_nodir"
    MSYS=winsymlinks:native ln -s "$T/nodir/pw" "$LINK3" 2>/dev/null
    if [[ -L "$LINK3" ]] && ! readlink -f "$LINK3" > /dev/null 2>&1; then
        BACKUP_PASSWORD_FILE="$LINK3"
        write_password_file 'NODIR-fake-pw-604' > "$T/out1n" 2>&1; rc=$?
        [[ $rc -eq 0 && -f "$LINK3" && ! -L "$LINK3" && "$(cat "$LINK3")" == 'NODIR-fake-pw-604' ]] && ok \
            || bad "1v неразрешимая ссылка → обычный файл с новым паролем: rc=$rc $(strip < "$T/out1n")"
        grep -qF 'не разрешается' "$T/out1n" && ok || bad "1w неразрешимая ссылка — WARN вслух: $(strip < "$T/out1n")"
        [[ ! -e "$T/nodir" ]] && ok || bad "1x каталог цели не создаётся"
    else
        skip "1v неразрешимый симлинк не создаётся в этом окружении"
    fi
    command rm -f "$LINK3"
fi
# обычный файл — как раньше: обычный файл, новый пароль, 600
REG="$INSTALL_DIR/.password_reg"; printf '%s' 'A-fake' > "$REG"
BACKUP_PASSWORD_FILE="$REG"
write_password_file 'B-fake-pw-604' > "$T/out1r" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$REG" && ! -L "$REG" && "$(cat "$REG")" == 'B-fake-pw-604' ]] && ok || bad "1q обычный файл: rc=$rc content='$(cat "$REG")'"
if [[ "$IS_WIN" != true ]]; then
    [[ "$(stat -c '%a' "$REG")" == "600" ]] && ok || bad "1r обычный файл 600, got $(stat -c '%a' "$REG")"
fi
[[ "$(ls -A "$INSTALL_DIR" | grep -c '\.tmp\.')" -eq 0 ]] && ok || bad "1s обычный файл: temp не остался"
# путь пароля — каталог: отказ, внутрь каталога ничего не кладётся (раньше mv клал temp внутрь и rc=0)
PWDIR="$INSTALL_DIR/pwdir"; mkdir -p "$PWDIR"; BACKUP_PASSWORD_FILE="$PWDIR"
write_password_file 'DIR-fake-pw-604' > "$T/out1dir" 2>&1; rc=$?
[[ $rc -eq 1 && -z "$(ls -A "$PWDIR")" ]] && ok || bad "1y путь-каталог → отказ, каталог пуст: rc=$rc $(ls -A "$PWDIR")"
[[ "$(ls -A "$INSTALL_DIR" | grep -c '\.tmp\.')" -eq 0 ]] && ok || bad "1z путь-каталог: temp не остался"
# путь-гард по-прежнему по литеральному пути
BACKUP_PASSWORD_FILE="$T/outside/.password"
write_password_file 'X-fake' > /dev/null 2>&1 && bad "1t путь вне INSTALL_DIR должен отклоняться" || ok
[[ ! -e "$T/outside/.password" ]] && ok || bad "1u вне INSTALL_DIR ничего не записано"
fi

# ============================================================ 2) read_password_file: края и BOM → WARN
if sec 2; then
PF="$INSTALL_DIR/.password_edge"; BACKUP_PASSWORD_FILE="$PF"
# rp_case <содержимое-printf> → $RP_RC, $RP_OUT (stdout), $RP_ERR (stderr)
rp_case() {
    printf "$1" > "$PF"
    BACKUP_PASSWORD=""; : > "$LOG_FILE"
    read_password_file > "$T/rp.out" 2> "$T/rp.err"; RP_RC=$?
    RP_OUT=$(strip < "$T/rp.out"); RP_ERR=$(strip < "$T/rp.err")
}
rp_case '  sp-fake-pw  '
[[ $RP_RC -eq 0 && "$BACKUP_PASSWORD" == '  sp-fake-pw  ' ]] && ok || bad "2a пробелы по краям: пароль как есть, rc=$RP_RC got '$BACKUP_PASSWORD'"
[[ "$RP_ERR" == *WARN*"по краям"* ]] && ok || bad "2b WARN о краях в stderr: '$RP_ERR'"
[[ -z "$RP_OUT" ]] && ok || bad "2c stdout пуст (вызов бывает внутри \$(...)): '$RP_OUT'"
grep -q '\[WARN\].*whitespace or BOM' "$LOG_FILE" && ok || bad "2d WARN в логе: $(cat "$LOG_FILE")"
! grep -qF 'sp-fake-pw' "$LOG_FILE" "$T/rp.err" && ok || bad "2e сам пароль не печатается и не логируется"
rp_case '\ttab-fake-pw'
[[ $RP_RC -eq 0 && "$BACKUP_PASSWORD" == $'\ttab-fake-pw' && "$RP_ERR" == *WARN* ]] && ok || bad "2f таб в начале → WARN, пароль как есть: '$RP_ERR'"
rp_case 'tail-fake-pw \n'
[[ "$BACKUP_PASSWORD" == 'tail-fake-pw ' && "$RP_ERR" == *WARN* ]] && ok || bad "2g пробел перед хвостовым \\n → WARN: '$RP_ERR' pw='$BACKUP_PASSWORD'"
rp_case '\xef\xbb\xbfbom-fake-pw'
[[ $RP_RC -eq 0 && "$BACKUP_PASSWORD" == $'\xef\xbb\xbf''bom-fake-pw' ]] && ok || bad "2h BOM: пароль как есть"
[[ "$RP_ERR" == *WARN*BOM* ]] && ok || bad "2i WARN о BOM: '$RP_ERR'"
# хвостовые \n срезает уже $(cat) — в пароль они не попадают ни при бэкапе, ни при вводе: WARN не нужен
rp_case 'dbl-fake-pw\n\n'
[[ "$BACKUP_PASSWORD" == 'dbl-fake-pw' && -z "$RP_ERR" ]] && ok || bad "2j несколько \\n в хвосте срезаются без WARN: '$RP_ERR' pw='$BACKUP_PASSWORD'"
# контроли: без WARN
rp_case 'plain-fake-pw-604'
[[ $RP_RC -eq 0 && "$BACKUP_PASSWORD" == 'plain-fake-pw-604' && -z "$RP_ERR" && -z "$RP_OUT" ]] && ok || bad "2k обычный пароль без WARN: '$RP_ERR$RP_OUT'"
rp_case 'nl-fake-pw\n'
[[ "$BACKUP_PASSWORD" == 'nl-fake-pw' && -z "$RP_ERR" ]] && ok || bad "2l хвостовой \\n (echo >) срезается без WARN: '$RP_ERR'"
rp_case 'crlf-fake-pw\r\n'
[[ "$BACKUP_PASSWORD" == 'crlf-fake-pw' && -z "$RP_ERR" ]] && ok || bad "2m \\r\\n срезается без WARN: '$RP_ERR'"
rp_case 'in ner fake pw'
[[ "$BACKUP_PASSWORD" == 'in ner fake pw' && -z "$RP_ERR" ]] && ok || bad "2n пробелы внутри — без WARN: '$RP_ERR'"
! grep -q '\[WARN\]' "$LOG_FILE" && ok || bad "2o контроль: WARN в лог не пишется"
fi

# ============================================================ мок docker (секции 3–4)
PANEL_DIR="$T/opt/remnawave"; BOT_DIR="$T/opt/rwp-shop"; BEDO_DIR="$T/opt/remnawave-bedolaga-telegram-bot"
mkdir -p "$PANEL_DIR" "$BOT_DIR" "$BEDO_DIR" "$T/home" "$T/root"
cat > "$PANEL_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave:
    image: remnawave/backend:2
  remnawave-db:
    image: postgres:17
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
EOF
cat > "$BEDO_DIR/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:15-alpine
    container_name: remnawave_bot_db
  redis:
    image: redis:7-alpine
    container_name: remnawave_bot_redis
  bot:
    image: fr1ngg/remnawave-bedolaga-telegram-bot:latest
    container_name: remnawave_bot
EOF
_panel_root_now() { echo "$PANEL_DIR"; }
detect_panel_root() { echo "$PANEL_DIR"; }
PANEL_PATH="$PANEL_DIR"; PANEL_DB_CONTAINER="remnawave-db"; DISC_PANEL_APP=""; DISC_PANEL_DB=""
FIND_ROOT="$T"
find() { if [[ "$1" == /opt ]]; then shift 3; command find "$FIND_ROOT/opt" "$FIND_ROOT/home" "$FIND_ROOT/root" "$@"; else command find "$@"; fi; }

DK="$T/dk"; mkdir -p "$DK"
dk_reset() { command rm -f "$DK"/*; : > "$T/dk.order"; _PANEL_DBSVC_CACHE=""; _BILL_DBSVC_CACHE=""; _LPD_CACHE=""; }
dk_add() { # name image dir service [state] [env]; порядок = порядок `docker ps` (новейший первым)
    printf '%s|%s|%s|%s|False\n' "$2" "$3" "$4" "${5:-running}" > "$DK/$1"; echo "$1" >> "$T/dk.order"
    [[ -n "${6:-}" ]] && printf '%s\n' "$6" > "$DK/$1.env"
    return 0
}
dk_get() { [[ -n "$1" && -f "$DK/$1" ]] || return 1; IFS='|' read -r D_IMG D_DIR D_SVC D_ST D_ONE < "$DK/$1"; }
dk_fmt() {
    local f="$1" n="$2" run="false"
    [[ "$D_ST" == "running" ]] && run="true"
    local l_one1='{{.Label "com.docker.compose.oneoff"}}' l_one2='{{ index .Config.Labels "com.docker.compose.oneoff" }}'
    local l_wd1='{{.Label "com.docker.compose.project.working_dir"}}' l_wd2='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
    local l_svc='{{ index .Config.Labels "com.docker.compose.service" }}'
    f="${f//"$l_one1"/$D_ONE}"; f="${f//"$l_one2"/$D_ONE}"
    f="${f//"$l_wd1"/$D_DIR}"; f="${f//"$l_wd2"/$D_DIR}"; f="${f//"$l_svc"/$D_SVC}"
    f="${f//'{{.Names}}'/$n}"; f="${f//'{{.Name}}'/$n}"
    f="${f//'{{.Image}}'/$D_IMG}"; f="${f//'{{.Config.Image}}'/$D_IMG}"
    f="${f//'{{.State.Status}}'/$D_ST}"; f="${f//'{{.State.Running}}'/$run}"; f="${f//'{{.State}}'/$D_ST}"
    printf '%s\n' "$f" | sed -E 's/\{\{[^}]*\}\}//g'
}
docker() {
    local a="$1"; shift
    printf '%s %s\n' "$a" "$*" >> "$T/dk.calls"
    case "$a" in
        container) docker "$@"; return ;;
        info) return 0 ;;
        inspect)
            local fmt="" n=""
            case "$1" in
                --format|-f) fmt="$2"; n="$3" ;;
                --format=*)  fmt="${1#--format=}"; n="$2" ;;
                *) n="$1" ;;
            esac
            dk_get "$n" || return 1
            if [[ "$fmt" == *'range .Config.Env'* ]]; then [[ -f "$DK/$n.env" ]] && cat "$DK/$n.env"; return 0; fi
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
            if [[ "$sub" == ps ]]; then
                local all=0 fmt="" svc="" n
                while [[ $# -gt 0 ]]; do case "$1" in -a|--all) all=1 ;; --format) fmt="$2"; shift ;; -*) ;; *) svc="$1" ;; esac; shift; done
                while IFS= read -r n; do
                    dk_get "$n" || continue
                    _same_path "$D_DIR" "$PWD" || continue
                    [[ $all -eq 0 && "$D_ST" != "running" ]] && continue
                    [[ -n "$svc" && "$D_SVC" != "$svc" ]] && continue
                    dk_fmt "$fmt" "$n"
                done < "$T/dk.order"
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}
# Панель как в проде: backend + БД + redis + infra-billing (+ его БД) в каталоге панели.
panel_stack() {
    dk_add remnawave "remnawave/backend:2" "$PANEL_DIR" remnawave running "DATABASE_URL=postgresql://u:fake@remnawave-db:5432/postgres"
    dk_add remnawave-db "postgres:17" "$PANEL_DIR" remnawave-db
    dk_add remnawave-redis "valkey/valkey:8" "$PANEL_DIR" remnawave-redis
    dk_add infra-billing "mishkatik/infra-billing:latest" "$PANEL_DIR" infra-billing running "DATABASE_URL=postgresql://u:fake@infra-billing-db:5432/billing"
    dk_add infra-billing-db "postgres:17" "$PANEL_DIR" infra-billing-db
}
# Бот как в проде (/opt/rwp-shop, 6 сервисов; kb_db — pgvector, новее основной БД).
rwp_stack() {
    dk_add rwp_shop_forecast "registry.rwp.rw/jesus/rwp-shop-forecast:1.1.0" "$BOT_DIR" forecast
    dk_add remnawave-subscription-page "remnawave/subscription-page:latest" "$BOT_DIR" remnawave-subscription-page
    dk_add xray-checker "kutovoys/xray-checker:latest" "$BOT_DIR" xray-checker
    dk_add rwp_shop_kb_db "pgvector/pgvector:pg18" "$BOT_DIR" kb_db
    dk_add rwp_shop_db "postgres:18.4" "$BOT_DIR" db
    dk_add rwp_shop "registry.rwp.rw/jesus/rwp-shop:dev" "$BOT_DIR" rwp_shop
}
# bedolaga: сервис БД postgres (или кастомный $1, образ $2), контейнеры с подчёркиванием remnawave_bot*.
bedo_stack() {
    dk_add remnawave_bot_redis "redis:7-alpine" "$BEDO_DIR" redis
    dk_add remnawave_bot_db "${2:-postgres:15-alpine}" "$BEDO_DIR" "${1:-postgres}"
    dk_add remnawave_bot "fr1ngg/remnawave-bedolaga-telegram-bot:latest" "$BEDO_DIR" bot
}
scan_bot() { KEYWORDS=("${BOT_KEYWORDS_DEFAULT[@]}"); SCAN_ALLOW_LABEL_FALLBACK=0; scan_system_for_bot > /dev/null 2>&1; }

# ============================================================ 3) поиск БД бота: по роли, не по подстроке
if sec 3; then
dk_reset; panel_stack; bedo_stack
_r=$(find_db_container_for_path "$BEDO_DIR" 2> /dev/null); rc=$?
[[ $rc -eq 0 && "$_r" == "remnawave_bot_db" ]] && ok || bad "3a bedolaga (сервис postgres) → remnawave_bot_db, rc=$rc got '$_r'"
# образ вне regex шага 2 (pgvector) — найти может только шаг 1 (по имени сервиса)
dk_reset; panel_stack; bedo_stack postgres "pgvector/pgvector:pg16"
_r=$(find_db_container_for_path "$BEDO_DIR" 2> /dev/null); rc=$?
[[ $rc -eq 0 && "$_r" == "remnawave_bot_db" ]] && ok || bad "3a2 bedolaga, только шаг сервиса → remnawave_bot_db, rc=$rc got '$_r'"
dk_reset; panel_stack; bedo_stack pg
_r=$(find_db_container_for_path "$BEDO_DIR" 2> /dev/null); rc=$?
[[ $rc -eq 0 && "$_r" == "remnawave_bot_db" ]] && ok || bad "3b bedolaga (кастомный сервис, шаг по образу) → remnawave_bot_db, rc=$rc got '$_r'"
dk_reset; panel_stack; rwp_stack
_r=$(find_db_container_for_path "$BOT_DIR" 2> /dev/null); rc=$?
[[ $rc -eq 0 && "$_r" == "rwp_shop_db" ]] && ok || bad "3c прод rwp-shop → rwp_shop_db (не kb), rc=$rc got '$_r'"
# каталог панели: ни БД панели, ни БД биллинга (шаг по образу раньше отдавал infra-billing-db)
dk_reset; panel_stack; rwp_stack
_r=$(find_db_container_for_path "$PANEL_DIR" 2> /dev/null); rc=$?
[[ "$_r" != "remnawave-db" && "$_r" != "infra-billing-db" && -z "$_r" && $rc -eq 1 ]] && ok || bad "3d каталог панели → пусто (не remnawave-db/infra-billing-db), rc=$rc got '$_r'"
# кастомное имя БД панели (сервис db, проект панели) — роль panel-db, не отдаётся
dk_reset; dk_add pg-panel "postgres:17" "$PANEL_DIR" db
dk_add remnawave "remnawave/backend:2" "$PANEL_DIR" remnawave running "DATABASE_URL=postgresql://u:fake@db:5432/postgres"
_r=$(find_db_container_for_path "$PANEL_DIR" 2> /dev/null); rc=$?
[[ -z "$_r" && $rc -eq 1 ]] && ok || bad "3e кастомная БД панели (pg-panel, сервис db) не отдаётся боту, got '$_r'"
# scan_system_for_bot: тот же фильтр в поиске БД (шаг сервиса и шаг по образу)
dk_reset; panel_stack; bedo_stack
scan_bot
[[ "$FOUND_PATH" == "$BEDO_DIR" && "$FOUND_BOT" == "remnawave_bot" ]] && ok || bad "3f скан bedolaga: path='$FOUND_PATH' bot='$FOUND_BOT'"
[[ "$FOUND_DB" == "remnawave_bot_db" ]] && ok || bad "3g скан bedolaga: FOUND_DB='$FOUND_DB'"
dk_reset; panel_stack; bedo_stack postgres "pgvector/pgvector:pg16"
scan_bot
[[ "$FOUND_DB" == "remnawave_bot_db" ]] && ok || bad "3g2 скан bedolaga, только шаг сервиса: FOUND_DB='$FOUND_DB'"
dk_reset; panel_stack; bedo_stack pg
scan_bot
[[ "$FOUND_DB" == "remnawave_bot_db" ]] && ok || bad "3h скан bedolaga, кастомный сервис БД (шаг по образу): FOUND_DB='$FOUND_DB'"
dk_reset; panel_stack; rwp_stack
scan_bot
[[ "$FOUND_PATH" == "$BOT_DIR" && "$FOUND_BOT" == "rwp_shop" && "$FOUND_DB" == "rwp_shop_db" ]] && ok \
    || bad "3i скан прод-набора: path='$FOUND_PATH' bot='$FOUND_BOT' db='$FOUND_DB'"
# предикат напрямую: панель/биллинг — чужие, БД ботов — свои
dk_reset; panel_stack; rwp_stack; bedo_stack
for _c in remnawave-db infra-billing-db remnawave; do
    _is_foreign_stack_db "$_c" && ok || bad "3j $_c должен считаться чужим (панель/биллинг)"
done
for _c in rwp_shop_db remnawave_bot_db rwp_shop_kb_db; do
    _is_foreign_stack_db "$_c" && bad "3k $_c — не панель, не должен отсекаться" || ok
done
fi

# ============================================================ 4) ключ bedolaga и прод-путь резолвера
if sec 4; then
_kw=" ${BOT_KEYWORDS_DEFAULT[*]} "
[[ "$_kw" == *" remnawave_bot "* ]] && ok || bad "4a remnawave_bot в BOT_KEYWORDS_DEFAULT: '$_kw'"
[[ "$_kw" != *bedolaga* ]] && ok || bad "4b широкого ключа bedolaga нет: '$_kw'"
for _k in rwp_shop rwp-shop telegram-shop shop-bot shopbot; do
    [[ "$_kw" == *" $_k "* ]] && ok || bad "4c прежний ключ $_k на месте"
done
_is_bot_infra_container remnawave_bot_db "postgres:15-alpine" && ok || bad "4d remnawave_bot_db (образ) — инфраструктура"
_is_bot_infra_container remnawave_bot_redis "redis:7-alpine" && ok || bad "4e remnawave_bot_redis (образ) — инфраструктура"
_is_bot_infra_container remnawave_bot_db && ok || bad "4f remnawave_bot_db (только имя) — инфраструктура"
_is_bot_infra_container remnawave_bot_redis && ok || bad "4g remnawave_bot_redis (только имя) — инфраструктура"
_is_bot_infra_container remnawave_bot "fr1ngg/remnawave-bedolaga-telegram-bot:latest" && bad "4h remnawave_bot — не инфраструктура" || ok
# ни один контейнер панели/биллинга/прод-бота, кроме rwp_*, не матчится новым ключом
for _c in remnawave remnawave-db remnawave-redis remnawave-nginx remnawave-subscription-page infra-billing infra-billing-db xray-checker; do
    [[ "$_c" == *remnawave_bot* ]] && bad "4i $_c ложно матчится ключом remnawave_bot" || ok
done
# резолвер (прод-путь cron): настроенный BOT_PATH → те же app/db, что и раньше
dk_reset; panel_stack; rwp_stack
BACKUP_TARGET="bot"; BOT_PATH="$BOT_DIR"; BOT_CONTAINER_NAME="rwp_shop"; DB_CONTAINER_NAME="rwp_shop_db"
resolve_bot_runtime > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$RB_PATH" == "$BOT_DIR" && "$RB_APP" == "rwp_shop" && "$RB_DB" == "rwp_shop_db" ]] && ok \
    || bad "4j resolve прод: rc=$rc path='$RB_PATH' app='$RB_APP' db='$RB_DB'"
# bedolaga без настроенных имён: путь и БД находятся сами
dk_reset; panel_stack; bedo_stack
BOT_PATH=""; BOT_CONTAINER_NAME=""; DB_CONTAINER_NAME=""
resolve_bot_runtime > /dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$RB_PATH" == "$BEDO_DIR" && "$RB_APP" == "remnawave_bot" && "$RB_DB" == "remnawave_bot_db" ]] && ok \
    || bad "4k resolve bedolaga: rc=$rc path='$RB_PATH' app='$RB_APP' db='$RB_DB'"
fi

# ============================================================ итог: сеть и песочница удаления
[[ ! -s "$NETLOG" ]] && ok || bad "Z1 ни одного сетевого вызова (curl/wget/aws/rclone/ssh/scp/nc/docker-бинарь): $(head -3 "$NETLOG")"
[[ ! -s "$T/rm_outside.log" ]] && ok || bad "Z2 rm/shred вне каталога теста не вызывались: $(head -3 "$T/rm_outside.log")"

echo "---"
echo "fix604-config: ok=$n_ok err=$n_err skip=$n_skip"
[[ $n_err -eq 0 ]] || exit 1
