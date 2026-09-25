#!/usr/bin/env bash
# Регресс-тесты правок 6.0.1 (аудит 25.09.2026) на НАСТОЯЩЕМ коде (LAZARUS_LIB=true):
#  1) get_backup_version: подвижный тег бота (:dev) → точная версия из образа; тег-версия панели
#     (3.4.4-trafficfmt) — как есть; ванильный :2 → версия из env панели.
#  2) отказ Telegram (sendMessage / sendMediaGroup) пишется WARN с description ответа; успех — тихо;
#     токен в лог не попадает.
#  3) save_config во время restore вторичной цели пишет ИСХОДНУЮ пару целей (both не демотится).
#  4) _sweep_stale_intermediates: только промежуточные по шаблону тула и старше 60 мин.
#  5) _wait_pg_ready: два успеха подряд по TCP; fallback по сокету; таймаут → 1.
#  6) _restore_abort после volume rm откатывает БД из snapshot; до удаления — нет.
#  7) статика restore/интеграции: psql -d, нет sleep 5, предполёт, вызовы зачистки и tmpdir.
#  8) _setup_tmpdir: TMPDIR на диск; явный пользовательский не трогает; старые lazarus_* чистит.
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
trap 'rm -rf "$T"' EXIT            # скрипт поставил свой cleanup_on_exit — возвращаем свой
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
INSTALL_DIR="$T/install"; mkdir -p "$INSTALL_DIR"
send_telegram_notification() { :; }   # print_message ERROR не должен ходить в сеть
debug_log() { :; }
sleep() { :; }                         # _wait_pg_ready не должен реально ждать

# ---------------------------------------------------------------- заглушка docker
DK_RUNNING=1; DK_IMAGE=""; DK_LABEL=""; DK_RWENV=""
PG_TCP_SEQ=(); PG_SOCK_OK=0
docker() {
    if [[ "$1" == "container" && "$2" == "inspect" ]]; then [[ "$DK_RUNNING" == 1 ]]; return; fi
    if [[ "$1" == "inspect" && "$2" == "-f" ]]; then
        case "$3" in
            *Config.Image*)   echo "$DK_IMAGE" ;;
            *image.version*)  echo "${DK_LABEL:-<no value>}" ;;
            *)                echo "" ;;
        esac
        return 0
    fi
    if [[ "$1" == "exec" ]]; then
        case "$*" in
            *"printenv __RW_METADATA_VERSION"*)
                [[ -n "$DK_RWENV" ]] && { echo "$DK_RWENV"; return 0; }; return 1 ;;
            *"pg_isready -h 127.0.0.1"*)
                local _r=1
                if [[ ${#PG_TCP_SEQ[@]} -gt 0 ]]; then _r="${PG_TCP_SEQ[0]}"; PG_TCP_SEQ=("${PG_TCP_SEQ[@]:1}"); fi
                return "$_r" ;;
            *"pg_isready -q"*)
                [[ "$PG_SOCK_OK" == 1 ]]; return ;;
        esac
    fi
    return 1
}

# ---------------------------------------------------------------- 1) get_backup_version
BOT_CONTAINER_NAME="rwp_shop"
DK_RUNNING=1; DK_IMAGE="registry.rwp.rw/jesus/rwp-shop:dev"; DK_LABEL="7.1.0.41"; DK_RWENV=""
[[ "$(get_backup_version)" == "7.1.0.41" ]] && ok || bad "1a :dev → '$(get_backup_version)', ждали 7.1.0.41"

DK_IMAGE="local/remnawave-backend:3.4.4-trafficfmt"; DK_LABEL=""; DK_RWENV="3.4.4"
[[ "$(get_backup_version)" == "3.4.4-trafficfmt" ]] && ok || bad "1b тег-версия панели → '$(get_backup_version)'"

DK_IMAGE="remnawave/backend:2"; DK_LABEL=""; DK_RWENV="3.4.4"
[[ "$(get_backup_version)" == "3.4.4" ]] && ok || bad "1c ванильный :2 → '$(get_backup_version)', ждали 3.4.4"

DK_IMAGE="foo/app:latest"; DK_LABEL=""; DK_RWENV=""
[[ "$(get_backup_version)" == "latest" ]] && ok || bad "1d без версии в образе → '$(get_backup_version)', ждали latest"

DK_RUNNING=0
[[ -z "$(get_backup_version)" ]] && ok || bad "1e контейнер не запущен → ждали пусто"
DK_RUNNING=1

# ---------------------------------------------------------------- 2) логирование отказа Telegram
BOT_TOKEN="123456:SECRETTOKENVALUE"; CHAT_ID="-1001"; TG_MESSAGE_THREAD_ID=""; CURL_SILENT="-s"
CURL_BODY=""; CURL_CODE=""
curl() { printf '%s\n%s' "$CURL_BODY" "$CURL_CODE"; }

: > "$LOG_FILE"
CURL_BODY='{"ok":false,"error_code":400,"description":"Bad Request: can'"'"'t parse entities"}'; CURL_CODE=400
out=$(_send_telegram_text "x" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok || bad "2a sendMessage 400 → rc=$rc, ждали 1"
[[ "$out" == *"Telegram: sendMessage не доставлено (HTTP 400 — Bad Request: can't parse entities)"* ]] && ok || bad "2a нет WARN с описанием: $out"
grep -q "telegram sendMessage failed: HTTP 400 — Bad Request" "$LOG_FILE" && ok || bad "2a нет строки в LOG_FILE"

: > "$LOG_FILE"
CURL_BODY='{"ok":true,"result":{}}'; CURL_CODE=200
out=$(_send_telegram_text "x" 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" && ! -s "$LOG_FILE" ]] && ok || bad "2b успех должен быть тихим (rc=$rc out='$out')"

: > "$LOG_FILE"
CURL_BODY=""; CURL_CODE="000"
out=$(_send_telegram_text "x" 2>&1)
[[ "$out" == *"HTTP 000 — нет ответа (сеть/таймаут)"* ]] && ok || bad "2c сеть: $out"

: > "$LOG_FILE"
printf 'a' > "$T/f1"; printf 'b' > "$T/f2"
CURL_BODY='{"ok":false,"error_code":413,"description":"Request Entity Too Large"}'; CURL_CODE=413
out=$(_send_telegram_album "cap" "$T/f1" "$T/f2" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"sendMediaGroup не доставлено (HTTP 413 — Request Entity Too Large)"* ]] && ok || bad "2d альбом: rc=$rc $out"

grep -rq "SECRETTOKENVALUE" "$LOG_FILE" "$SILENT_LOG" && bad "2e токен утёк в лог" || ok

# ---------------------------------------------------------------- 3) save_config во время restore
CONFIG_FILE="$T/cfg_restore.env"; rm -f "$CONFIG_FILE"
BOT_TOKEN=""; CHAT_ID=""
BACKUP_TARGET="bot"; BACKUP_SECONDARY="bot"      # так в памяти во время restore вторичной цели
_t3_restore() { local _PERSIST_TARGET_PAIR="panel|bot"; save_config > /dev/null 2>&1; }
_t3_restore
grep -q '^BACKUP_TARGET="panel"$' "$CONFIG_FILE" && ok || bad "3a на диск ушла не исходная цель: $(grep '^BACKUP_TARGET=' "$CONFIG_FILE")"
grep -q '^BACKUP_SECONDARY="bot"$' "$CONFIG_FILE" && ok || bad "3b SECONDARY: $(grep '^BACKUP_SECONDARY=' "$CONFIG_FILE")"
[[ -z "${_PERSIST_TARGET_PAIR:-}" ]] && ok || bad "3c пара «прилипла» после выхода из меню"
# контроль: без пары тот же save пишет транзиентную пару bot/bot (это и был баг)
rm -f "$CONFIG_FILE"; save_config > /dev/null 2>&1
grep -q '^BACKUP_SECONDARY="bot"$' "$CONFIG_FILE" && grep -q '^BACKUP_TARGET="bot"$' "$CONFIG_FILE" \
    && ok || bad "3d контроль: без защиты ожидалась пара bot/bot"
grep -q 'local _PERSIST_TARGET_PAIR="${_prim}|${_sec}"' "$SCRIPT" && ok || bad "3e menu_restore не объявляет пару"

# ---------------------------------------------------------------- 4) зачистка промежуточных
BACKUP_DIR="$T/bk"; mkdir -p "$BACKUP_DIR"
old=(db_2026-07-12_13_21_35.sql.gz dir_2026-07-12_13_21_35.tar.gz globals_2026-07-12_13_21_35.sql.gz
     billing_2026-07-12_13_21_35.sql.zst kb_2026-07-12_13_21_35.sql.gz extra_2026-07-12_13_21_35.tar.gz
     bot_files_2026-07-12_13_21_35.tar.zst)
keep_old=(lazarus_db_2026-07-12_13_21_35__vdev.tar.gz.enc lazarus_panel_full_2026-07-12_04_10_02__v3.4.4.tar.gz.enc
          pre_restore_snapshot_20260712_132135.sql.gz .last_skipped.txt notes.txt db_manual.sql.gz
          db_2026-07-12_13_21_35.sql.gz.enc bot_version.txt)
fresh=db_2026-09-25_15_00_00.sql.gz
for f in "${old[@]}" "${keep_old[@]}"; do printf 'x' > "$BACKUP_DIR/$f"; touch -d '3 hours ago' "$BACKUP_DIR/$f"; done
printf 'x' > "$BACKUP_DIR/$fresh"
: > "$LOG_FILE"
_sweep_stale_intermediates > /dev/null 2>&1
gone=1; for f in "${old[@]}"; do [[ -e "$BACKUP_DIR/$f" ]] && { gone=0; bad "4a не удалён брошенный: $f"; }; done
[[ $gone -eq 1 ]] && ok
kept=1; for f in "${keep_old[@]}"; do [[ -e "$BACKUP_DIR/$f" ]] || { kept=0; bad "4b удалён чужой/нужный файл: $f"; }; done
[[ $kept -eq 1 ]] && ok
[[ -e "$BACKUP_DIR/$fresh" ]] && ok || bad "4c удалён СВЕЖИЙ промежуточный (<60 мин) — мог быть живой прогон"
[[ $(grep -c "sweep: удалён брошенный" "$LOG_FILE") -eq ${#old[@]} ]] && ok || bad "4d в логе не ${#old[@]} записей"

# ---------------------------------------------------------------- 5) _wait_pg_ready
PG_TCP_SEQ=(1 0 1 0 0); PG_SOCK_OK=0
_wait_pg_ready "db" 10 && ok || bad "5a два успеха подряд по TCP → ждали 0"
PG_TCP_SEQ=(0 1 0 1 0 1); PG_SOCK_OK=0
_wait_pg_ready "db" 6 && bad "5b единичные успехи (временный сервер initdb) приняты за готовность" || ok
PG_TCP_SEQ=(); PG_SOCK_OK=1
_wait_pg_ready "db" 3 && ok || bad "5c TCP закрыт, сокет готов → ждали 0 (fallback)"
PG_TCP_SEQ=(); PG_SOCK_OK=0
_wait_pg_ready "db" 3 && bad "5d всё недоступно → ждали 1" || ok
_wait_pg_ready "" 3 && bad "5e пустой контейнер → ждали 1" || ok

# ---------------------------------------------------------------- 6) _restore_abort
ROLLBACK_CALLED=0
_rollback_real="$(declare -f _rollback_after_volume_drop)"
_rollback_after_volume_drop() { ROLLBACK_CALLED=1; return 0; }
BOT_PATH=""
_t6() { local _vol_dropped="$1"; local TMP_DIR="$T/abort_tmp_$1"; mkdir -p "$TMP_DIR"; _restore_abort; }
ROLLBACK_CALLED=0; _t6 1 > /dev/null 2>&1
[[ $ROLLBACK_CALLED -eq 1 ]] && ok || bad "6a после volume rm откат не вызван"
ROLLBACK_CALLED=0; _t6 0 > /dev/null 2>&1
[[ $ROLLBACK_CALLED -eq 0 ]] && ok || bad "6b до volume rm откат вызван зря"
eval "$_rollback_real"
_t6c() { local _live_snap=""; local DB_CONTAINER_NAME="db"; _rollback_after_volume_drop; }
out=$(_t6c 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"БД ПУСТАЯ"* ]] && ok || bad "6c нет snapshot → должно громко сказать про пустую БД (rc=$rc)"

# ---------------------------------------------------------------- 7) статика
grep -q 'psql -U "$expected_user" -d "$expected_db" -tAc "SELECT current_database()"' "$SCRIPT" \
    && ok || bad "7a assert_safe_db_target без -d"
[[ $(grep -c 'psql -U "$ACTUAL_DB_USER" -c "DROP SCHEMA' "$SCRIPT") -eq 0 ]] && ok || bad "7b остался DROP SCHEMA без -d"
[[ $(grep -c 'psql -U "$ACTUAL_DB_USER" -d "$ACTUAL_DB_NAME" -c "DROP SCHEMA' "$SCRIPT") -eq 2 ]] && ok || bad "7c ожидалось 2 DROP SCHEMA с -d"
# Тело функции — в переменную, а не `sed | grep -q`: при pipefail grep -q выходит на первом
# совпадении, sed ловит SIGPIPE на остатке (~60 КБ) — и проверка краснеет СЛУЧАЙНО (гонка буфера).
ER_START=$(grep -n '^execute_restore() {' "$SCRIPT" | cut -d: -f1)
ER_END=$(awk -v s="$ER_START" 'NR>s && /^}/ {print NR; exit}' "$SCRIPT")
ER_BODY=$(sed -n "${ER_START},${ER_END}p" "$SCRIPT")
[[ $(grep -cE '^[[:space:]]*sleep 5$' <<<"$ER_BODY") -eq 0 ]] && ok || bad "7d в execute_restore остался sleep 5"
grep -qF 'if [[ "$_pf_role" != "absent" && "$_pf_role" != "unknown" ]]; then' <<<"$ER_BODY" \
    && ok || bad "7e условие предполёта (живой стек, не absent/unknown) изменено/отсутствует"
PF_LINE=$(grep -n '_restore_preflight=1' <<<"$ER_BODY" | head -1 | cut -d: -f1)
DOWN_LINE=$(grep -n 'if ! docker compose down' <<<"$ER_BODY" | head -1 | cut -d: -f1)
[[ -n "$PF_LINE" && -n "$DOWN_LINE" && "$PF_LINE" -lt "$DOWN_LINE" ]] && ok || bad "7e2 предполёт не стоит ДО compose down ($PF_LINE vs $DOWN_LINE)"
grep -qF 'if [[ "$_restore_preflight" != "1" ]] && ! ensure_bot_path' <<<"$ER_BODY" && ok || bad "7e3 пост-проверка ensure_bot_path не учитывает предполёт"
grep -q 'if docker volume rm "$volume_name"' <<<"$ER_BODY" && ok || bad "7f rc volume rm не проверяется"
[[ $(grep -c '^    _sweep_stale_intermediates' "$SCRIPT") -eq 3 ]] && ok || bad "7g зачистка вызвана не в 3 точках (backup/remote/inc)"
MAIN_FIRST=$(awk '/^if \[\[ "\$\{LAZARUS_LIB\}" != "true" \]\]; then$/ {f=1; next} f && NF {print; exit}' "$SCRIPT")
grep -q '_setup_tmpdir' <<<"$MAIN_FIRST" && ok || bad "7h _setup_tmpdir не первый шаг основного блока"
[[ $(grep -c 'CURRENT_VER=$(get_backup_version' "$SCRIPT") -eq 3 ]] && ok || bad "7i версия не из get_backup_version в 3 точках"

# ---------------------------------------------------------------- 8) _setup_tmpdir
if ( unset TMPDIR; INSTALL_DIR="$T/i8"; _setup_tmpdir; [[ "$TMPDIR" == "$T/i8/tmp" && -d "$T/i8/tmp" ]] ); then ok; else bad "8a TMPDIR не ушёл на диск"; fi
if ( TMPDIR=/tmp; INSTALL_DIR="$T/i8b"; _setup_tmpdir; [[ "$TMPDIR" == "$T/i8b/tmp" ]] ); then ok; else bad "8b TMPDIR=/tmp не заменён"; fi
if ( TMPDIR="$T/custom"; INSTALL_DIR="$T/i8c"; _setup_tmpdir; [[ "$TMPDIR" == "$T/custom" && ! -e "$T/i8c/tmp" ]] ); then ok; else bad "8c явный TMPDIR пользователя изменён"; fi
mkdir -p "$T/i8d/tmp/lazarus_restore.OLD" "$T/i8d/tmp/lazarus_restore.NEW"
printf 'x' > "$T/i8d/tmp/lazarus_enc.OLD"; printf 'x' > "$T/i8d/tmp/foreign.OLD"
touch -d '2 days ago' "$T/i8d/tmp/lazarus_restore.OLD" "$T/i8d/tmp/lazarus_enc.OLD" "$T/i8d/tmp/foreign.OLD"
( unset TMPDIR; INSTALL_DIR="$T/i8d"; _setup_tmpdir )
[[ ! -e "$T/i8d/tmp/lazarus_restore.OLD" && ! -e "$T/i8d/tmp/lazarus_enc.OLD" ]] && ok || bad "8d старые lazarus_* не удалены"
[[ -e "$T/i8d/tmp/lazarus_restore.NEW" ]] && ok || bad "8e удалён свежий рабочий каталог restore"
[[ -e "$T/i8d/tmp/foreign.OLD" ]] && ok || bad "8f удалён чужой файл"

echo "sep2026-fixes: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
