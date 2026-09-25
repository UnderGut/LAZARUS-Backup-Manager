#!/usr/bin/env bash
# Регресс-тесты группы integrity (6.0.3, перепроверка находок 4/5/11/12/29/30 на коде 6.0.2):
#  A) _hmac_envelope_create пишет в <out>.part и переименовывает только целым (#11): kill посреди
#     записи MAC не оставляет обрезанный .enc под штатным именем.
#  B) _hmac_envelope_decrypt: rc=1 — порча/MAC, rc=2 — «не удалось проверить» (нет TMPDIR, пустой
#     ключ MAC, пустой computed) (#4).
#  C) e2e create_backup db_only без пароля и с паролем: итоговый архив есть, *.part нет (#11);
#     verify rc=2 → «НЕ выполнена», не «ПОВРЕЖДЁН», TG «Бэкап не проверен», в альбоме both —
#     «не проверен» (#4); mktemp упал → тоже «не выполнена».
#  D) _backup_remote_target (ssh-цель через фейковый ssh): .part не остаётся, rm пустого
#     FILE_GLOBALS не сыплет «Is a directory», verify rc=2 → «НЕ выполнена» (#4/#11).
#  E) create_incremental_backup: версия со '/' санитизируется (#30), .part не остаётся (#11),
#     WARN «только локально» и понятная причина при DELETE_LOCAL_AFTER_REMOTE_UPLOAD (#12),
#     verify rc=2 → .enc оставлен с WARN, rc=1 → удалён (#4).
#  F) _sweep_stale_intermediates: старые lazarus_*.part, bot_files_inc_<ts>, .lazarus_mig_v2.* —
#     удалены; свежий .part и штатные архивы — целы (#11).
#  G) rotate_backups_by_size и меню очистки считают только архивы lazarus_*; снапшоты не
#     «съедают» лимит, WARN про не-архивные файлы с именами (#5).
#  H) _delete_orphan_inc_for_full ловит inc без версионного суффикса; сообщение orphan (#29).
#  I) get_backup_version: тег со '/' = отсутствует; _ver_suffix (#30).
#  J) статистика/ротация/diag не видят .part; миграция v1→v2 не оставляет временных файлов.
#  K) статика: ни одного combine прямо в "$BACKUP_DIR/$FILE_FINAL".
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
set +u   # RETURN-trap'ы бэкап-функций ссылаются на их local LOCK_ACQUIRED
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false; AUTO_CONFIRM=false
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
debug_log() { :; }
send_telegram_notification() { :; }
# Каналы доставки — только журнал вызовов (без сети).
send_telegram_alert() { echo "ALERT|$2" >> "$T/tg.log"; return 0; }
send_telegram_document() { echo "TGDOC|$1" >> "$T/tg.log"; return 0; }
_send_telegram_text() { printf 'TEXT|%s\n' "$1" >> "$T/tg.log"; return 0; }
upload_to_remote() { echo "UPLOAD|$1" >> "$T/tg.log"; return 0; }
acquire_lock() { return 0; }
release_lock() { :; }
check_lock_owner() { echo 0; }
assert_target_identity() { return 0; }
_billing_sidecar_active() { return 1; }
_kb_sidecar_active() { return 1; }
get_db_user() { echo postgres; }
get_db_name() { echo botdb; }

# Фейковые docker и ssh ИСПОЛНЯЕМЫМИ файлами: их зовут и из bash -c (_run_pipe_with_timeout),
# и через внешний timeout — функцию оттуда не видно.
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
case "$*" in
    *"{{.State.Running}}"*) echo true ;;
    *"{{.State.Health.Status}}"*) echo healthy ;;
    *pg_isready*) exit 0 ;;
    *pg_dumpall*) printf -- '-- globals\nCREATE ROLE x;\n' ;;
    *" pg_dump "*) printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\n'; head -c 3000 /dev/urandom | od -An -tx1 ;;
    *) exit 0 ;;
esac
EOF
cat > "$T/bin/fakessh" <<'EOF'
#!/bin/bash
exec bash -c "$*"
EOF
chmod +x "$T/bin/docker" "$T/bin/fakessh"
export PATH="$T/bin:$PATH"

PW="fixture-pass-603"   # фиктивный пароль
mk_plain() { head -c "${2:-4000}" /dev/urandom > "$T/plain.bin"; tar -czf "$1" -C "$T" plain.bin; }

# ============================================================ A) envelope пишет в .part
mk_plain "$T/a.tar.gz" 200000
_hmac_envelope_create "$T/a.tar.gz" "$T/a.tar.gz.enc" "$PW" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && -f "$T/a.tar.gz.enc" ]] && ok || bad "A1 envelope создан (rc=$rc)"
[[ ! -e "$T/a.tar.gz.enc.part" ]] && ok || bad "A2 после успеха .part не остаётся"
[[ "$(head -c 4 "$T/a.tar.gz.enc")" == "LAZ2" ]] && ok || bad "A3 штатный файл — полный LAZ2-envelope"
# kill -9 в момент вычисления MAC (шаг 3 — запись envelope) → под штатным именем НИЧЕГО
{ (
    openssl() { if [[ "$1" == dgst && "$*" == *-macopt* ]]; then kill -9 "$BASHPID"; fi; command openssl "$@"; }
    _hmac_envelope_create "$T/a.tar.gz" "$T/k.tar.gz.enc" "$PW" >/dev/null 2>&1
); } 2>/dev/null
[[ ! -e "$T/k.tar.gz.enc" ]] && ok || bad "A4 kill посреди записи оставил обрезанный .enc под штатным именем"
[[ -e "$T/k.tar.gz.enc.part" ]] && ok || bad "A5 kill посреди записи оставляет только .part (для sweep)"

# ============================================================ B) коды _hmac_envelope_decrypt
_hmac_envelope_decrypt "$T/a.tar.gz.enc" "$T/b.out" "$PW" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$T/b.out" "$T/a.tar.gz" && ok || bad "B1 валидный envelope → rc=0 и тот же plaintext (rc=$rc)"
cp "$T/a.tar.gz.enc" "$T/bad.enc"
printf '\xff' | dd of="$T/bad.enc" bs=1 seek=5000 conv=notrunc 2>/dev/null
_hmac_envelope_decrypt "$T/bad.enc" "$T/b.out" "$PW" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok || bad "B2 испорченный байт → rc=1 (порча), got $rc"
( TMPDIR="$T/nonexistent"; _hmac_envelope_decrypt "$T/a.tar.gz.enc" "$T/b.out" "$PW" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ok || bad "B3 нет TMPDIR → rc=2 (не удалось проверить), got $rc"
( _derive_hmac_key() { :; }; _hmac_envelope_decrypt "$T/a.tar.gz.enc" "$T/b.out" "$PW" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ok || bad "B4 пустой ключ MAC (сбой openssl) → rc=2, got $rc"
( openssl() { if [[ "$1" == dgst && "$*" == *-macopt* ]]; then return 1; fi; command openssl "$@"; }
  _hmac_envelope_decrypt "$T/a.tar.gz.enc" "$T/b.out" "$PW" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ok || bad "B5 пустой computed MAC (ошибка чтения) → rc=2, got $rc"

# ============================================================ C) e2e create_backup db_only
BK="$T/bk"; mkdir -p "$BK"; BACKUP_DIR="$BK"
BACKUP_TARGET="bot"; BACKUP_PREFIX="lazarus"; BACKUP_SECONDARY=""
BOT_PATH="$T/botsrc"; mkdir -p "$BOT_PATH"; echo "POSTGRES_DB=botdb" > "$BOT_PATH/.env"
BOT_CONTAINER_NAME=""; DB_CONTAINER_NAME="testdb"
REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"; SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"
BOT_TOKEN=""; CHAT_ID=""; DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"; DELETE_MODE="count"; MAX_BACKUPS_COUNT="50"
MAX_BACKUP_SIZE_MB="0"; DISK_WARN_PERCENT=101; DISK_CRITICAL_PERCENT=101; _BOTH_TG_DEFER=""
reset_bk() { rm -rf "$BK"; mkdir -p "$BK"; : > "$T/tg.log"; : > "$LOG_FILE"; }
n_arch() { find "$BK" -maxdepth 1 -type f -name "$1" | wc -l | tr -d ' '; }

reset_bk; BACKUP_PASSWORD=""
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok || bad "C1 create_backup db_only без пароля rc=0, got $rc: $(echo "$out" | grep -E 'ERROR|WARN' | head -3)"
[[ "$(n_arch 'lazarus_db_*.tar.gz')" -eq 1 ]] && ok || bad "C2 без пароля: итоговый lazarus_db_*.tar.gz есть"
[[ "$(n_arch '*.part')" -eq 0 ]] && ok || bad "C3 без пароля: *.part не осталось ($(ls "$BK"))"
[[ "$(n_arch 'db_*.sql.gz')" -eq 0 ]] && ok || bad "C4 промежуточный дамп удалён"

reset_bk; BACKUP_PASSWORD="$PW"
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok || bad "C5 create_backup db_only с паролем rc=0, got $rc: $(echo "$out" | grep -E 'ERROR|WARN' | head -3)"
[[ "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "C6 с паролем: итоговый .enc есть"
[[ "$(n_arch 'lazarus_db_*.tar.gz')" -eq 0 ]] && ok || bad "C7 с паролем: plaintext-архива нет"
[[ "$(n_arch '*.part')" -eq 0 ]] && ok || bad "C8 с паролем: *.part не осталось ($(ls "$BK"))"
grep -q '^UPLOAD|' "$T/tg.log" && ok || bad "C9 валидный архив доходит до выгрузки"

# verify rc=2 (I/O / нет места) — копия настоящей функции + обёртка только для verify-вызова
eval "$(declare -f _hmac_envelope_decrypt | sed '1s/^_hmac_envelope_decrypt/_real_hmac_decrypt/')"
FAKE_VRC=2
_hmac_envelope_decrypt() {
    if [[ "$FAKE_VRC" -ne 0 && ( "$2" == *lazarus_verify* || "$2" == *lazarus_rverify* || "$2" == *lazarus_incverify* ) ]]; then return "$FAKE_VRC"; fi
    _real_hmac_decrypt "$@"
}
reset_bk; SEND_TO_TELEGRAM="true"; BOT_TOKEN="000:fake"; CHAT_ID="1"
out=$(create_backup "db_only" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok || bad "C10 verify rc=2 → create_backup rc!=0 (как и раньше)"
[[ "$out" == *"Проверка архива НЕ выполнена"* ]] && ok || bad "C11 verify rc=2 → «Проверка архива НЕ выполнена»"
[[ "$out" != *"ПОВРЕЖДЁН"* ]] && ok || bad "C12 verify rc=2 → НЕ «ПОВРЕЖДЁН»"
[[ "$out" == *"свободно: TMPDIR"* ]] && ok || bad "C13 в сообщении свободное место TMPDIR/BACKUP_DIR"
grep -q 'ALERT|Бэкап не проверен' "$T/tg.log" && ok || bad "C14 TG-заголовок «Бэкап не проверен»"
! grep -q 'ALERT|Бэкап повреждён' "$T/tg.log" && ok || bad "C15 TG НЕ «Бэкап повреждён» при rc=2"
! grep -q '^UPLOAD|' "$T/tg.log" && ok || bad "C16 непроверенный архив не выгружается"
[[ "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "C17 непроверенный архив сохранён локально"
grep -q 'verification NOT PERFORMED' "$LOG_FILE" && ok || bad "C18 в логе «verification NOT PERFORMED»"

FAKE_VRC=1; reset_bk
out=$(create_backup "db_only" 2>&1)
[[ "$out" == *"ПОВРЕЖДЁН"* && "$out" != *"НЕ выполнена"* ]] && ok || bad "C19 verify rc=1 → «ПОВРЕЖДЁН»"
grep -q 'ALERT|Бэкап повреждён' "$T/tg.log" && ok || bad "C20 TG «Бэкап повреждён» при rc=1"

# mktemp под verify упал → «не выполнена» (раньше молча «ПОВРЕЖДЁН»)
FAKE_VRC=0; unset -f _hmac_envelope_decrypt
eval "$(declare -f _real_hmac_decrypt | sed '1s/^_real_hmac_decrypt/_hmac_envelope_decrypt/')"
reset_bk
out=$( mktemp() { if [[ "$*" == *lazarus_verify* ]]; then return 1; fi; command mktemp "$@"; }; create_backup "db_only" 2>&1 )
[[ "$out" == *"Проверка архива НЕ выполнена"* && "$out" != *"ПОВРЕЖДЁН"* ]] && ok || bad "C21 mktemp упал → «не выполнена», не «ПОВРЕЖДЁН»"

# both-режим: в альбоме «не проверен»
FAKE_VRC=2
eval "$(declare -f _hmac_envelope_decrypt | sed '1s/^_hmac_envelope_decrypt/_real_hmac_decrypt/')"
_hmac_envelope_decrypt() {
    if [[ "$FAKE_VRC" -ne 0 && ( "$2" == *lazarus_verify* || "$2" == *lazarus_rverify* || "$2" == *lazarus_incverify* ) ]]; then return "$FAKE_VRC"; fi
    _real_hmac_decrypt "$@"
}
reset_bk; _BOTH_TG_DEFER=1
_BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_SIZES=(); _BOTH_TG_BYTES=(); _BOTH_TG_ENC=(); _BOTH_TG_VERIFY=()
_BOTH_TG_REMOTE_OK=(); _BOTH_TG_REMOTE_UNVERIFIED=(); _BOTH_TG_IS_REMOTE=(); _BOTH_TG_VER=(); _BOTH_TG_RSTATUS=(); _BOTH_TG_SKIP=(); _BOTH_TG_SKIPCOUNT=()
create_backup "db_only" >/dev/null 2>&1
[[ "${_BOTH_TG_VERIFY[0]:-}" == "unverified" ]] && ok || bad "C22 both: статус прохода = unverified, got '${_BOTH_TG_VERIFY[0]:-}'"
: > "$T/tg.log"
_both_tg_flush >/dev/null 2>&1
grep -q 'не проверен' "$T/tg.log" && ok || bad "C23 both: в сводке альбома «не проверен»"
[[ "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "C24 both: непроверенный архив не удалён после flush"
_BOTH_TG_DEFER=""; SEND_TO_TELEGRAM="false"; BOT_TOKEN=""; CHAT_ID=""; FAKE_VRC=0

# ============================================================ D) _backup_remote_target (ssh)
TARGET_SSH="$T/bin/fakessh"
reset_bk; BACKUP_PASSWORD=""
_backup_remote_target "db_only" >"$T/r.out" 2>"$T/r.err"; rc=$?
[[ $rc -eq 0 ]] && ok || bad "D1 remote db_only без пароля rc=0, got $rc: $(grep -E 'ERROR' "$T/r.out" | head -2)"
[[ "$(n_arch 'lazarus_db_*.tar.gz')" -eq 1 && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "D2 remote без пароля: архив есть, .part нет ($(ls "$BK"))"
! grep -q 'Is a directory' "$T/r.err" && ok || bad "D3 пустой FILE_GLOBALS: rm не сыплет «Is a directory»"
reset_bk; BACKUP_PASSWORD="$PW"
_backup_remote_target "db_only" >"$T/r.out" 2>"$T/r.err"; rc=$?
[[ $rc -eq 0 && "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 && "$(n_arch 'lazarus_db_*.tar.gz')" -eq 0 && "$(n_arch '*.part')" -eq 0 ]] \
    && ok || bad "D4 remote с паролем: только .enc, без plaintext и .part (rc=$rc, $(ls "$BK"))"
FAKE_VRC=2; reset_bk
out=$(_backup_remote_target "db_only" 2>&1)
[[ "$out" == *"НЕ выполнена"* && "$out" != *"ПОВРЕЖДЁН"* ]] && ok || bad "D5 remote verify rc=2 → «НЕ выполнена», не «ПОВРЕЖДЁН»"
FAKE_VRC=1; reset_bk
out=$(_backup_remote_target "db_only" 2>&1)
[[ "$out" == *"ПОВРЕЖДЁН"* ]] && ok || bad "D6 remote verify rc=1 → «ПОВРЕЖДЁН»"
FAKE_VRC=0; TARGET_SSH=""

# ============================================================ E) create_incremental_backup
BASE_TS="2026-09-01_04_10_00"
mk_base() {   # base full с manifest.txt ($1 = с шифрованием или нет)
    rm -rf "$T/basestage"; mkdir -p "$T/basestage"
    _manifest_generate "$BOT_PATH" "$T/basestage/manifest.txt" >/dev/null 2>&1
    echo "7.1" > "$T/basestage/bot_version.txt"
    tar -czf "$BK/lazarus_full_${BASE_TS}.tar.gz" -C "$T/basestage" manifest.txt bot_version.txt
    if [[ "$1" == enc ]]; then
        _hmac_envelope_create "$BK/lazarus_full_${BASE_TS}.tar.gz" "$BK/lazarus_full_${BASE_TS}.tar.gz.enc" "$PW" >/dev/null 2>&1
        rm -f "$BK/lazarus_full_${BASE_TS}.tar.gz"
    fi
    touch -d '-1 hour' "$BK"/lazarus_full_*
}
echo "a" > "$BOT_PATH/app.txt"
reset_bk; BACKUP_PASSWORD=""; DB_CONTAINER_NAME=""; mk_base plain
echo "changed $RANDOM" >> "$BOT_PATH/app.txt"; sleep 1
( get_backup_version() { echo "5000/rwp"; }; create_incremental_backup >"$T/i.out" 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ok || bad "E1 inc с версией «5000/rwp» создаётся (rc=$rc): $(grep -E 'ERROR' "$T/i.out" | head -2)"
[[ "$(n_arch "lazarus_inc_*__base_${BASE_TS}__v5000-rwp.tar.gz")" -eq 1 ]] && ok || bad "E2 версия санитизирована в __v5000-rwp ($(ls "$BK"))"
[[ "$(n_arch '*.part')" -eq 0 ]] && ok || bad "E3 inc без пароля: .part не осталось"
# без версии (контейнер бота не задан) — имя без суффикса, база находится
rm -f "$BK"/lazarus_inc_*
echo "changed2 $RANDOM" >> "$BOT_PATH/app.txt"
REMOTE_STORAGE_TYPE="s3"; SEND_TO_REMOTE="true"
create_incremental_backup >"$T/i.out" 2>&1; rc=$?
_inc=$(ls "$BK"/lazarus_inc_* 2>/dev/null | head -1)
[[ $rc -eq 0 && "$_inc" == *"__base_${BASE_TS}.tar.gz" ]] && ok || bad "E4 inc без версии: …__base_<ts>.tar.gz (rc=$rc, '$_inc')"
[[ -n "$_inc" && "$(_find_base_for_inc "$_inc")" == *"lazarus_full_${BASE_TS}.tar.gz" ]] && ok || bad "E5 _find_base_for_inc находит base для inc без суффикса"
grep -q 'хранится только локально' "$T/i.out" && ok || bad "E6 WARN «инкремент хранится только локально» на экран"
grep -q 'Incremental kept local only' "$LOG_FILE" && ok || bad "E7 WARN «только локально» в логе"
REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"
out=$(create_incremental_backup 2>&1)
[[ "$out" != *"хранится только локально"* ]] && ok || bad "E8 без каналов доставки WARN «только локально» не печатается"
# нет локального full + удаление локальных копий → понятная причина
reset_bk; DELETE_LOCAL_AFTER_REMOTE_UPLOAD="remote_only"
out=$(create_incremental_backup 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"требует локально хранимый full"* ]] && ok || bad "E9 DELETE_LOCAL=remote_only без full → «требует локально хранимый full»"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"
out=$(create_incremental_backup 2>&1)
[[ "$out" == *"Нет существующего full backup"* ]] && ok || bad "E10 без DELETE_LOCAL — прежнее «Нет существующего full backup»"
# с паролем: только .enc, без .part; verify rc=2 → .enc оставлен с WARN; rc=1 → удалён
reset_bk; BACKUP_PASSWORD="$PW"; mk_base enc
echo "changed3 $RANDOM" >> "$BOT_PATH/app.txt"
create_incremental_backup >"$T/i.out" 2>&1; rc=$?
[[ $rc -eq 0 && "$(n_arch 'lazarus_inc_*.tar.gz.enc')" -eq 1 && "$(n_arch 'lazarus_inc_*.tar.gz')" -eq 0 && "$(n_arch '*.part')" -eq 0 ]] \
    && ok || bad "E11 inc с паролем: только .enc, без plaintext/.part (rc=$rc, $(ls "$BK"))"
rm -f "$BK"/lazarus_inc_*; FAKE_VRC=2
echo "changed4 $RANDOM" >> "$BOT_PATH/app.txt"
create_incremental_backup >"$T/i.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok || bad "E12 inc verify rc=2 → rc!=0"
[[ "$(n_arch 'lazarus_inc_*.tar.gz.enc')" -eq 1 ]] && ok || bad "E13 inc verify rc=2 → .enc НЕ удалён"
[[ "$(n_arch 'lazarus_inc_*.tar.gz')" -eq 0 && "$(n_arch '*.part')" -eq 0 ]] && ok || bad "E14 inc verify rc=2 → plaintext/.part не оставлены"
grep -q 'проверка НЕ выполнена' "$T/i.out" && ! grep -q 'не прошёл verify' "$T/i.out" && ok || bad "E15 inc verify rc=2 → WARN «проверка НЕ выполнена»"
rm -f "$BK"/lazarus_inc_*; FAKE_VRC=1
echo "changed5 $RANDOM" >> "$BOT_PATH/app.txt"
create_incremental_backup >"$T/i.out" 2>&1
[[ "$(find "$BK" -maxdepth 1 -name 'lazarus_inc_*' | wc -l | tr -d ' ')" -eq 0 ]] && ok || bad "E16 inc verify rc=1 (порча) → inc удалён, как раньше"
FAKE_VRC=0; BACKUP_PASSWORD=""; DB_CONTAINER_NAME="testdb"

# ============================================================ F) sweep
reset_bk
SW_OLD=( "lazarus_full_2026-09-20_04_10_00__v7.tar.gz.enc.part" "lazarus_db_2026-09-20_04_10_00.tar.zst.part"
         "lazarus_panel_db_2026-09-20_04_10_00.tar.gz.part"
         "bot_files_inc_2026-09-20_04_10_00.tar.gz" ".lazarus_mig_v2.AbC123" ".lazarus_mig_v2.AbC123.part" )
SW_KEEP=( "lazarus_full_2026-09-19_04_10_00.tar.gz.enc" "lazarus_db_2026-09-19_04_10_00.tar.gz"
          "pre_restore_snapshot_2026-09-19.sql.gz" "notes.part" "lazarus_full_x.tar.gz.bak" )
for f in "${SW_OLD[@]}" "${SW_KEEP[@]}"; do echo x > "$BK/$f"; touch -d '-2 hours' "$BK/$f"; done
echo x > "$BK/lazarus_full_2026-09-22_04_10_00.tar.gz.part"   # свежий — живой писатель
_sweep_stale_intermediates >/dev/null 2>&1
for f in "${SW_OLD[@]}"; do [[ ! -e "$BK/$f" ]] && ok || bad "F1 sweep не удалил брошенный $f"; done
for f in "${SW_KEEP[@]}"; do [[ -e "$BK/$f" ]] && ok || bad "F2 sweep тронул не свой/штатный файл $f"; done
[[ -e "$BK/lazarus_full_2026-09-22_04_10_00.tar.gz.part" ]] && ok || bad "F3 sweep удалил СВЕЖИЙ .part (<60 мин)"

# ============================================================ G) лимит — только на архивы
reset_bk; MAX_BACKUP_SIZE_MB=40
for i in 1 2 3 4 5; do truncate -s 5M "$BK/lazarus_db_2026-09-0${i}_04_10_00.tar.gz.enc"; touch -d "-$(( 10 - i )) hours" "$BK/lazarus_db_2026-09-0${i}_04_10_00.tar.gz.enc"; done
truncate -s 30M "$BK/pre_restore_snapshot_a.sql.gz"; truncate -s 30M "$BK/pre_restore_snapshot_b.sql.gz"
out=$(rotate_backups_by_size "true" 2>&1)
[[ "$(n_arch 'lazarus_db_*')" -eq 5 ]] && ok || bad "G1 архивы (25M) в лимите 40M — ни один не удалён из-за снапшотов, осталось $(n_arch 'lazarus_db_*')"
[[ -f "$BK/pre_restore_snapshot_a.sql.gz" && -f "$BK/pre_restore_snapshot_b.sql.gz" ]] && ok || bad "G2 снапшоты не тронуты"
[[ "$out" == *"НЕархивных"* && "$out" == *"pre_restore_snapshot_a.sql.gz"* ]] && ok || bad "G3 WARN про не-архивные файлы с именами"
[[ "$out" != *"меньше новейшего"* ]] && ok || bad "G4 нет ложного WARN «лимит меньше новейшего»"
grep -q 'NON-archive files' "$LOG_FILE" && ok || bad "G5 WARN про не-архивные файлы в логе"
reset_bk; MAX_BACKUP_SIZE_MB=30
for i in 1 2 3 4 5; do truncate -s 10M "$BK/lazarus_db_2026-09-0${i}_04_10_00.tar.gz.enc"; touch -d "-$(( 10 - i )) hours" "$BK/lazarus_db_2026-09-0${i}_04_10_00.tar.gz.enc"; done
truncate -s 60M "$BK/pre_restore_snapshot_a.sql.gz"
out=$(rotate_backups_by_size "true" 2>&1)
[[ "$out" == *"НЕархивных"* && "$out" != *"меньше новейшего"* ]] && ok || bad "G6a после удаления: WARN про не-архивные, без ложного «меньше новейшего»"
[[ "$(n_arch 'lazarus_db_*')" -eq 3 && ! -e "$BK/lazarus_db_2026-09-01_04_10_00.tar.gz.enc" && ! -e "$BK/lazarus_db_2026-09-02_04_10_00.tar.gz.enc" ]] \
    && ok || bad "G6 50M архивов при лимите 30M → удалены ровно 2 старейших, осталось $(n_arch 'lazarus_db_*')"
# меню очистки: архивы в лимите → «Чистка не требуется», а не «Превышен лимит»
reset_bk; MAX_BACKUP_SIZE_MB=40
truncate -s 5M "$BK/lazarus_db_2026-09-01_04_10_00.tar.gz.enc"; truncate -s 60M "$BK/pre_restore_snapshot_a.sql.gz"
out=$(cleanup_old_backups </dev/null 2>&1)
[[ "$out" == *"Чистка не требуется"* && "$out" != *"Превышен лимит"* ]] && ok || bad "G7 меню очистки считает только архивы"
MAX_BACKUP_SIZE_MB=0

# ============================================================ H) orphan inc без суффикса
reset_bk
FT="2026-09-01_04_10_00"
for f in "lazarus_full_${FT}__v7.1.tar.gz" "lazarus_inc_2026-09-02_04_10_00__base_${FT}__v7.1.tar.gz" \
         "lazarus_inc_2026-09-03_04_10_00__base_${FT}.tar.gz" "lazarus_inc_2026-09-04_04_10_00__base_${FT}.tar.zst.enc" \
         "lazarus_inc_2026-09-05_04_10_00__base_2026-09-02_04_10_00.tar.gz"; do echo x > "$BK/$f"; done
_delete_orphan_inc_for_full "$BK/lazarus_full_${FT}__v7.1.tar.gz" >/dev/null 2>&1
[[ "$_LAST_ORPHAN_COUNT" -eq 3 ]] && ok || bad "H1 удалены все 3 inc своего base (с суффиксом и без), got $_LAST_ORPHAN_COUNT"
[[ -e "$BK/lazarus_inc_2026-09-05_04_10_00__base_2026-09-02_04_10_00.tar.gz" ]] && ok || bad "H2 inc чужого base цел"
mkdir -p "$T/stage"
out=$(_resolve_incremental_chain "$BK/lazarus_inc_2026-09-09_04_10_00__base_2026-08-01_04_10_00.tar.gz" "$T/stage" "" 2>&1)
[[ "$out" == *"Base full '2026-08-01_04_10_00'"* ]] && ok || bad "H3 сообщение orphan называет base-ts для inc без суффикса"

# ============================================================ I) версия
[[ "$(_ver_suffix "5000/rwp")" == "__v5000-rwp" ]] && ok || bad "I1 _ver_suffix 5000/rwp"
[[ "$(_ver_suffix "ghcr.io/owner/bot")" == "__vghcr.io-owner-bot" ]] && ok || bad "I2 _ver_suffix ghcr.io/owner/bot"
[[ "$(_ver_suffix "7.1.0.49")" == "__v7.1.0.49" ]] && ok || bad "I3 _ver_suffix 7.1.0.49"
[[ -z "$(_ver_suffix "")" && -z "$(_ver_suffix "Unknown")" ]] && ok || bad "I4 _ver_suffix пусто/Unknown → пусто"
_ver_suffix "" >/dev/null; [[ $? -eq 0 ]] && ok || bad "I5 _ver_suffix всегда rc=0"
IMG=""; LBL="<no value>"
docker() {
    case "$*" in
        *"{{.State.Running}}"*) echo true ;;
        *"{{.Config.Image}}"*) echo "$IMG" ;;
        *"org.opencontainers.image.version"*) echo "$LBL" ;;
        *printenv*) : ;;
    esac
}
BOT_CONTAINER_NAME="bot"
IMG="registry.local:5000/rwp"; [[ -z "$(get_backup_version)" ]] && ok || bad "I6 registry:5000/rwp без тега → пусто, got '$(get_backup_version)'"
IMG="ghcr.io/owner/bot";      [[ -z "$(get_backup_version)" ]] && ok || bad "I7 ghcr.io/owner/bot без тега → пусто, got '$(get_backup_version)'"
IMG="10.0.0.5/rwp";           [[ -z "$(get_backup_version)" ]] && ok || bad "I8 10.0.0.5/rwp → пусто, got '$(get_backup_version)'"
IMG="registry.local:5000/rwp"; LBL="7.1.0.49"
[[ "$(get_backup_version)" == "7.1.0.49" ]] && ok || bad "I9 путь реестра без тега + OCI-лейбл → версия из лейбла"
IMG="ghcr.io/x/rwp_shop:dev"; LBL="7.1.0.49"
[[ "$(get_backup_version)" == "7.1.0.49" ]] && ok || bad "I10 :dev + лейбл → 7.1.0.49 (прод-путь)"
IMG="remnawave/backend:3.4.4-trafficfmt"; LBL="<no value>"
[[ "$(get_backup_version)" == "3.4.4-trafficfmt" ]] && ok || bad "I11 тег-версия панели сохраняется"
unset -f docker; BOT_CONTAINER_NAME=""

# ============================================================ J) .part невидим; миграция v1→v2
reset_bk; BACKUP_PREFIX="lazarus"
echo x > "$BK/lazarus_full_2026-09-01_04_10_00.tar.gz"; touch -d '-3 hours' "$BK/lazarus_full_2026-09-01_04_10_00.tar.gz"
echo x > "$BK/lazarus_full_2026-09-02_04_10_00.tar.gz"; touch -d '-2 hours' "$BK/lazarus_full_2026-09-02_04_10_00.tar.gz"
echo x > "$BK/lazarus_full_2026-09-03_04_10_00.tar.gz.enc.part"
get_backup_stats
[[ "$STATS_FULL" -eq 2 && "$STATS_LAST" == "02.09"* ]] && ok || bad "J1 статистика не считает .part (full=$STATS_FULL last=$STATS_LAST)"
MAX_BACKUPS_COUNT=1; rotate_backups_by_count "lazarus_full" "Полные" "true" >/dev/null 2>&1
[[ -e "$BK/lazarus_full_2026-09-02_04_10_00.tar.gz" && ! -e "$BK/lazarus_full_2026-09-01_04_10_00.tar.gz" ]] && ok || bad "J2 count-ротация: .part не вытесняет валидный новейший"
MAX_BACKUPS_COUNT=50
# diag_command определяется в ветке не-LIB — берём тело из скрипта
eval "$(sed -n '/^diag_command() {$/,/^}$/p' "$SCRIPT")"
out=$(diag_command 2>/dev/null)
[[ "$out" == *"Total:       1 файлов"* && "$out" == *"Незавершённые (.part): 1"* && "$out" != *"Latest:      lazarus_full_2026-09-03"* ]] \
    && ok || bad "J3 diag: .part не в Total/Latest, показан отдельно"
reset_bk
mk_plain "$T/v1src.tar.gz" 5000
LAZARUS_ENC_PW="$PW" openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$T/v1src.tar.gz" -out "$BK/lazarus_db_2026-01-01_00_00_00.tar.gz.enc" -pass env:LAZARUS_ENC_PW 2>/dev/null
_convert_v1_to_v2 "$BK/lazarus_db_2026-01-01_00_00_00.tar.gz.enc" "$PW" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(head -c 4 "$BK/lazarus_db_2026-01-01_00_00_00.tar.gz.enc")" == "LAZ2" ]] && ok || bad "J4 миграция v1→v2 проходит (rc=$rc)"
[[ -z "$(find "$BK" -maxdepth 1 \( -name '*.part' -o -name '.lazarus_mig_v2.*' \) )" ]] && ok || bad "J5 миграция не оставляет .part/.lazarus_mig_v2.* ($(ls -A "$BK"))"

# ============================================================ K) статика
[[ "$(grep -c -- '-cf "$BACKUP_DIR/$FILE_FINAL"' "$SCRIPT")" -eq 0 ]] && ok || bad "K1 остался combine прямо в \"\$BACKUP_DIR/\$FILE_FINAL\""
[[ "$(grep -c -- '-cf "$BACKUP_DIR/${FILE_FINAL}.part"' "$SCRIPT")" -eq 4 ]] && ok || bad "K2 4 combine (create×3 + remote) пишут в .part"
[[ "$(grep -c -- '-cf "$_inc_part"' "$SCRIPT")" -eq 1 ]] && ok || bad "K3 inc combine пишет в .part"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
