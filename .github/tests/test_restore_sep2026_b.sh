#!/usr/bin/env bash
# Регресс-тесты restore-правок 6.0.2 (перепроверка июльских находок на коде 6.0.1, 25.09.2026):
#  1) _restore_extract_checked + _VTS_BYTES: rc tar читается, нехватка места = отказ ДО распаковки.
#  2) _db_volume_from_container: из нескольких volume берётся смонтированный в /var/lib/postgresql
#     (или в предка PGDATA); чужой/bind — пусто.
#  3) _db_volume_from_compose: ключ из блока сервиса целиком (volumes: далеко от имени сервиса,
#     как у живых панели и бота), реальное имя — по меткам compose; неоднозначно = пусто.
#  4) assert_safe_bot_path: панель с переименованным сервисом бэкенда проходит по образу; чужой
#     compose — нет; для бота проверка по образу не включается.
#  5) статика execute_restore: имя volume до down, поиск членов -maxdepth 1, files_only без БД,
#     подхват снапшота при отказе от DROP, отказ импорта поверх таблиц, rc=4 при провале сайдкара.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске).

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
trap 'rm -rf "$T"' EXIT
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
send_telegram_notification() { :; }
debug_log() { :; }

# ============================================================ 1) распаковка с проверками
mkdir -p "$T/src/stack/sub"
head -c 1000 /dev/zero > "$T/src/stack/a.bin"
head -c 2345 /dev/zero > "$T/src/stack/sub/b.bin"
tar -czf "$T/arc.tar.gz" -C "$T/src" stack
validate_tar_safety "$T/arc.tar.gz" "$T/list.txt" >/dev/null 2>&1 && ok || bad "1a validate_tar_safety на чистом архиве"
[[ "$_VTS_BYTES" == "3345" ]] && ok || bad "1b _VTS_BYTES=3345 (сумма обычных файлов), got '$_VTS_BYTES'"

mkdir -p "$T/dst1"
_restore_extract_checked "$T/arc.tar.gz" "$T/dst1" "тест" "$_VTS_BYTES" >/dev/null 2>&1 && ok || bad "1c штатная распаковка rc=0"
[[ -f "$T/dst1/stack/sub/b.bin" ]] && ok || bad "1d файлы распакованы"

# мало места: df сообщает 10 МБ при нужных ~64 МБ запаса → отказ, ничего не распаковано
df() { printf 'Filesystem 1B-blocks Used Available Capacity Mounted\nx 100 0 10485760 0%% /\n'; }
mkdir -p "$T/dst2"
out=$(_restore_extract_checked "$T/arc.tar.gz" "$T/dst2" "тест" "$_VTS_BYTES" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok || bad "1e нехватка места → rc!=0"
[[ -z "$(ls -A "$T/dst2")" ]] && ok || bad "1f при нехватке места ничего не распаковано"
[[ "$out" == *"Мало места"* ]] && ok || bad "1g сообщение о нехватке места"
grep -q 'not enough space' "$LOG_FILE" && ok || bad "1h нехватка места в логе"
# need=0 → проверка места пропускается даже при «пустом» диске
mkdir -p "$T/dst3"
_restore_extract_checked "$T/arc.tar.gz" "$T/dst3" "тест" 0 >/dev/null 2>&1 && ok || bad "1i need=0 — df не блокирует"
unset -f df

# tar падает посередине (ENOSPC): rc читается, ошибка видна
tar() { if [[ " $* " == *" -xf "* ]]; then echo "tar: stack/sub/b.bin: Cannot write: No space left on device" >&2; return 2; fi; command tar "$@"; }
mkdir -p "$T/dst4"
out=$(_restore_extract_checked "$T/arc.tar.gz" "$T/dst4" "файлы стека" 1 2>&1); rc=$?
unset -f tar
[[ $rc -ne 0 ]] && ok || bad "1j tar rc=2 → отказ"
[[ "$out" == *"rc=2"* && "$out" == *"No space left"* ]] && ok || bad "1k в выводе rc и текст ошибки tar"
grep -q 'tar extract failed (файлы стека, rc=2)' "$LOG_FILE" && ok || bad "1l провал распаковки в логе"

# ============================================================ 2) volume по точке монтирования
DK_MOUNTS=""; DK_ENV=""
docker() {
    if [[ "$1" == "inspect" ]]; then
        case "$3" in
            *Mounts*) printf '%b' "$DK_MOUNTS"; return 0 ;;
            *Config.Env*) printf '%b' "$DK_ENV"; return 0 ;;
        esac
    fi
    if [[ "$1" == "volume" && "$2" == "ls" ]]; then
        local _p="" _v="" a
        for a in "$@"; do
            case "$a" in label=com.docker.compose.project=*) _p="${a#*=}"; _p="${_p#*=}" ;; label=com.docker.compose.volume=*) _v="${a#*=}"; _v="${_v#*=}" ;; esac
        done
        printf '%b' "$DK_VOLS" | awk -v p="$_p" -v v="$_v" '$2==p && $3==v {print $1}'
        return 0
    fi
    return 1
}
DK_MOUNTS='backups_vol\t/backups\nrw_db_data\t/var/lib/postgresql\n'
[[ "$(_db_volume_from_container c1)" == "rw_db_data" ]] && ok || bad "2a из двух volume выбран postgres-маунт"
DK_MOUNTS='kb_data\t/var/lib/postgresql/data\n'
[[ "$(_db_volume_from_container c1)" == "kb_data" ]] && ok || bad "2b /var/lib/postgresql/data тоже postgres"
DK_MOUNTS='backups_vol\t/backups\n'
_db_volume_from_container c1 >/dev/null && bad "2c единственный НЕ-postgres volume не должен выбираться" || ok
DK_MOUNTS='pgv\t/srv/pg\n'; DK_ENV='PATH=/usr/bin\nPGDATA=/srv/pg/18/docker\n'
[[ "$(_db_volume_from_container c1)" == "pgv" ]] && ok || bad "2d volume-предок PGDATA"
DK_MOUNTS=''; DK_ENV=''
_db_volume_from_container c1 >/dev/null && bad "2e bind-маунт (volume нет) → пусто" || ok

# ============================================================ 3) запасной разбор compose
mkdir -p "$T/remnawave" "$T/Rwp-Shop"
cat > "$T/remnawave/docker-compose.yml" <<'EOF'
services:
  remnawave-db:
    image: postgres:18.6
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file:
      - .env
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    # комментарий внутри блока
    volumes:
      - remnawave-db-data:/var/lib/postgresql
  remnawave:
    image: local/remnawave-backend:3.4.4-trafficfmt
  infra-billing-db:
    image: postgres:18.6
    volumes:
      - "infra-billing-db-data-pg18:/var/lib/postgresql"
volumes:
  remnawave-db-data:
    name: remnawave-db-data
EOF
cat > "$T/Rwp-Shop/docker-compose.yml" <<'EOF'
services:
  "db":
    image: postgres:18
    volumes:
      - rwp_shop_db_data:/var/lib/postgresql:rw
  rwp_shop_kb_db:
    volumes:
      - rwp_shop_kb_data:/var/lib/postgresql/data
EOF
# «Живые» volume: имя | project | ключ compose
DK_VOLS='remnawave-db-data remnawave remnawave-db-data\ninfra-billing-db-data-pg18 remnawave infra-billing-db-data-pg18\nrwp_shop_db_data rwp-shop rwp_shop_db_data\nother_db_data other rwp_shop_db_data\n'
[[ "$(_db_volume_from_compose "$T/remnawave/docker-compose.yml" remnawave-db "$T/remnawave")" == "remnawave-db-data" ]] \
    && ok || bad "3a панель: volumes: через 16 строк от имени сервиса"
[[ "$(_db_volume_from_compose "$T/remnawave/docker-compose.yml" infra-billing-db "$T/remnawave")" == "infra-billing-db-data-pg18" ]] \
    && ok || bad "3b ключ берётся из блока СВОЕГО сервиса (кавычки снимаются)"
[[ "$(_db_volume_from_compose "$T/Rwp-Shop/docker-compose.yml" db "$T/Rwp-Shop")" == "rwp_shop_db_data" ]] \
    && ok || bad "3c бот: сервис в кавычках, суффикс :rw, проект из имени каталога (lowercase)"
_db_volume_from_compose "$T/remnawave/docker-compose.yml" remnawave "$T/remnawave" >/dev/null \
    && bad "3d у сервиса без postgres-volume → пусто" || ok
DK_VOLS='rwp_shop_db_data rwp-shop rwp_shop_db_data\nrwp_shop_db_data_2 rwp-shop rwp_shop_db_data\n'
_db_volume_from_compose "$T/Rwp-Shop/docker-compose.yml" db "$T/Rwp-Shop" >/dev/null \
    && bad "3e неоднозначно (2 volume) → пусто" || ok
printf 'name: "custom-proj"\n' | cat - "$T/Rwp-Shop/docker-compose.yml" > "$T/Rwp-Shop/c2.yml"
DK_VOLS='custom-proj_rwp_shop_db_data custom-proj rwp_shop_db_data\nrwp_shop_db_data rwp-shop rwp_shop_db_data\n'
[[ "$(_db_volume_from_compose "$T/Rwp-Shop/c2.yml" db "$T/Rwp-Shop")" == "custom-proj_rwp_shop_db_data" ]] \
    && ok || bad "3f проект из top-level name: (префикс проекта в имени volume)"

# get_db_volume_name: контейнер есть → inspect; нет → compose
DB_CONTAINER_NAME="remnawave-db"; DB_SERVICE_NAME="remnawave-db"; BOT_PATH="$T/remnawave"
DK_VOLS='remnawave-db-data remnawave remnawave-db-data\n'
DK_MOUNTS='from_inspect\t/var/lib/postgresql\n'
[[ "$(get_db_volume_name)" == "from_inspect" ]] && ok || bad "3g get_db_volume_name: сначала docker inspect"
DK_MOUNTS=''
[[ "$(get_db_volume_name)" == "remnawave-db-data" ]] && ok || bad "3h get_db_volume_name: после down — compose"
unset -f docker

# ============================================================ 4) assert_safe_bot_path для панели
DK_SERVICES=""; DK_IMAGES=""
docker() {
    if [[ "$1" == "compose" && " $* " == *" config "* ]]; then
        if [[ " $* " == *" --images "* ]]; then printf '%b' "$DK_IMAGES"; else printf '%b' "$DK_SERVICES"; fi
        return 0
    fi
    return 1
}
mkdir -p "$T/panel"; : > "$T/panel/docker-compose.yml"
BACKUP_TARGET="panel"; KEYWORDS=("remnawave"); BOT_CONTAINER_NAME="remnawave"; DB_SERVICE_NAME="remnawave-db"
DK_SERVICES='backend\nremnawave-db\n'; DK_IMAGES='local/remnawave-backend:3.4.4-trafficfmt\npostgres:18.6\n'
assert_safe_bot_path "$T/panel" >/dev/null 2>&1 && ok || bad "4a панель с сервисом backend: проходит по образу"
DK_IMAGES='ghcr.io/remnawave/backend:latest\npostgres:18.6\n'
assert_safe_bot_path "$T/panel" >/dev/null 2>&1 && ok || bad "4b образ ghcr.io/remnawave/backend"
DK_SERVICES='rwp_shop\nremnawave-db\n'; DK_IMAGES='remnawave/subscription-page:latest\npostgres:18\n'
out=$(assert_safe_bot_path "$T/panel" 2>&1) && bad "4c чужой compose (subscription-page) не должен пройти" || ok
[[ "$out" == *"панель Remnawave"* ]] && ok || bad "4d текст ошибки для панели говорит про панель"
BACKUP_TARGET="bot"; KEYWORDS=("shop"); BOT_CONTAINER_NAME="rwp_shop_app"
DK_SERVICES='backend\ndb\n'; DK_IMAGES='local/remnawave-backend:3.4.4\npostgres:18\n'
assert_safe_bot_path "$T/panel" >/dev/null 2>&1 && bad "4e для цели bot образ панели не засчитывается" || ok
unset -f docker

# ============================================================ 5) статика execute_restore
ER_START=$(grep -n '^execute_restore() {' "$SCRIPT" | cut -d: -f1)
ER_END=$(awk -v s="$ER_START" 'NR>s && /^}/ {print NR; exit}' "$SCRIPT")
ER_BODY=$(sed -n "${ER_START},${ER_END}p" "$SCRIPT")
line_of() { grep -n -m1 -F -- "$1" <<< "$ER_BODY" | cut -d: -f1; }

# 5a–5c: распаковки через _restore_extract_checked, голых `tar ... -xf "$WORK_FILE"/"$DIR_ARC"` нет
[[ $(grep -c '_restore_extract_checked "' <<< "$ER_BODY") -eq 2 ]] && ok || bad "5a обе распаковки через _restore_extract_checked"
grep -qE '^\s*tar [^|]*-xf "\$(WORK_FILE|DIR_ARC)"' <<< "$ER_BODY" && bad "5b осталась распаковка без проверки rc" || ok
L_EXTR=$(line_of '_restore_extract_checked "$DIR_ARC"'); L_DOWN=$(line_of 'if ! docker compose down')
[[ -n "$L_EXTR" && -n "$L_DOWN" && "$L_EXTR" -lt "$L_DOWN" ]] && ok || bad "5c распаковка файлов стека до compose down"
# 5d–5e: имя volume снимается до down и используется после
L_PREVOL=$(line_of '_pre_db_volume=$(_db_volume_from_container')
[[ -n "$L_PREVOL" && "$L_PREVOL" -lt "$L_DOWN" ]] && ok || bad "5d имя volume до compose down"
grep -qF 'local volume_name="$_pre_db_volume"' <<< "$ER_BODY" && ok || bad "5e после rsync используется снятое имя"
# 5f–5g: поиск членов только на верхнем уровне; files_only без БД
[[ $(grep -c 'find "$TMP_DIR" -maxdepth 1 ' <<< "$ER_BODY") -eq 6 ]] && ok || bad "5f шесть find с -maxdepth 1"
grep -qE 'find "\$TMP_DIR" \\\(' <<< "$ER_BODY" && bad "5g остался рекурсивный find по TMP_DIR" || ok
grep -qF 'if [[ "$MODE" == "files_only" ]]; then DB_DUMP=""; GLOBALS_DUMP=""; fi' <<< "$ER_BODY" && ok || bad "5h files_only сбрасывает DB_DUMP"
# 5i–5k: DROP SCHEMA — подхват снапшота вне ветки подтверждения, отказ поверх таблиц
L_CDS=$(line_of 'confirm_drop_schema "$DB_CONTAINER_NAME"'); L_PICK=$(line_of '&& _live_snap="$_LAST_DROP_SNAPSHOT"'); L_IFD=$(line_of 'if [[ $_drop_ok -eq 1 ]]; then')
[[ -n "$L_CDS" && -n "$L_PICK" && -n "$L_IFD" && "$L_CDS" -lt "$L_PICK" && "$L_PICK" -lt "$L_IFD" ]] && ok || bad "5i снапшот подхватывается при любом исходе confirm_drop_schema"
ELSE_BLK=$(awk '/if \[\[ \$_drop_ok -eq 1 \]\]; then/ {f=1} f {print} f && /^        fi$/ {exit}' <<< "$ER_BODY")
grep -q "pg_tables WHERE schemaname = 'public'" <<< "$ELSE_BLK" && ok || bad "5j при отказе от DROP считаются таблицы public"
[[ $(grep -c '_restore_abort; return 1' <<< "$ELSE_BLK") -eq 2 ]] && ok || bad "5k отказ: провал DROP и таблицы в БД → _restore_abort"
# импорт без DROP — строго при 0 таблиц (пустой/нечисловой ответ psql = отказ)
grep -qF 'if [[ "$_pub_tables" == "0" ]]; then' <<< "$ELSE_BLK" && ok || bad "5k2 импорт без DROP только в пустую схему"
# 5l–5n: сайдкары → rc=4, migrate/firstrun понимают 4
[[ $(grep -c '_sidecar_fail+=(' <<< "$ER_BODY") -ge 14 ]] && ok || bad "5l провалы billing/KB/extra учитываются"
TAIL=$(tail -n 20 <<< "$ER_BODY")
grep -q 'return 4' <<< "$TAIL" && ok || bad "5m частичный restore → return 4"
MIG=$(sed -n "$(grep -n '^panel_migrate_in() {' "$SCRIPT" | cut -d: -f1),\$p" "$SCRIPT" | awk 'NR>1 && /^}/ {print; exit} {print}')
grep -qF 'elif [[ $_rrc -eq 4 ]]; then' <<< "$MIG" && ok || bad "5n panel_migrate_in различает rc=4"
grep -qF 'if [[ $_fr_mrc -eq 0 || $_fr_mrc -eq 4 ]]; then' "$SCRIPT" && ok || bad "5o первый запуск: неполный перенос = панель уже здесь"
# 5p: rsync — удаления после успешной передачи
declare -a _RS_DEL _RS_EXCL; RESTORE_KEEP_INFRA=0; RESTORE_INCLUDE_ENV=false
_restore_rsync_flags
[[ "${_RS_DEL[*]}" == "--delete-delay" ]] && ok || bad "5p rsync --delete-delay"

echo "restore-sep2026-b: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]]
