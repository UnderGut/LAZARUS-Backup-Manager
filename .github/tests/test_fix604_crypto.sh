#!/usr/bin/env bash
# 6.0.4 (группа crypto): регресс-тесты находок аудита [2], [12], [14], [16], [17].
#  1) _hmac_sha256_file байт-в-байт = `openssl dgst -sha256 -mac HMAC -macopt hexkey:` на ключах из
#     паролей (латиница, кириллица, длинный, спецсимволы) и произвольных hex-ключах (короткий, 64,
#     65 и 200 байт — ветка хеширования ключа), на файлах пустой / 1 байт / ровно 64 байта / 300 КБ
#     случайных; мусорный ключ и нечитаемый файл — отказ; сбой чтения (cat rc≠0) — отказ, не хеш.
#  2) [12] argv openssl (PATH-обёртка) при create/verify/decrypt не содержит hexkey:, K_mac и пароль.
#  3) совместимость: v2 по старой схеме (-macopt, как в 6.0.3) расшифровывается новым кодом, MAC
#     нового envelope сходится с -macopt; при наличии в истории 6414aeb — старый код ↔ новый.
#  4) [2] envelope-функции не ставят RETURN-trap: trap вызывающей функции срабатывает, trap -p RETURN
#     без «unset LAZARUS_ENC_PW»; LAZARUS_ENC_PW снят после успеха и после провала шифрования.
#  5) [2] _backup_remote_target с паролем: release_lock вызван, trap не затёрт; и даже если вложенная
#     функция затёрла RETURN-trap — явный release на успехе, провале verify (rc=1/2), отказе от
#     plaintext и провале mv после отказа шифрования.
#  6) [2] create_backup с паролем: release_lock вызван, trap -p RETURN без unset LAZARUS_ENC_PW.
#  7) [17] _backup_remote_target: dir_<ts> (tar стека) в SENSITIVE_TMP_PATHS в момент remote-tar,
#     снят после combine и на провале tar; TERM сразу после tar — cleanup_on_exit убирает dir_*.
#  8) [16] cleanup_on_exit: INT во время зачистки не обрывает её (trap '' INT TERM), shred -n 1 для
#     < 1 ГиБ, крупнее — rm без shred; в каталоге мелкий файл затирается (-size в k, не -1G).
#  9) [14] обновление: обрыв curl (rc=28, синтаксически целый кусок) и wget (rc=4) → не ставится;
#     битый синтаксис → не ставится; манифест SHA256 совпал/недоступен → mv; не совпал → отказ;
#     curl с --fail; «Текущая версия не изменена».
# Сеть заглушена: curl/wget/aws/rclone — функции, curl/wget/aws/rclone/ssh/scp/sftp/sshpass/nc —
# PATH-блокираторы; TG — журналы. rm/shred — только внутри каталога теста; shred файлов > 64 МБ
# не выполняется (журнал BIG_SHRED + rm), чтобы мутация не писала гигабайты на диск.
# LZ_CRYPTO_ONLY="1 5" — прогнать только указанные секции (для мутационной проверки).
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске). Пароли фиктивные.

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lz604crypto.XXXXXX") || { echo "FAIL: mktemp -d"; exit 1; }
# Windows-TMPDIR вида D:\… рвёт PATH на двоеточии диска — тогда каталог теста в /tmp
if [[ "$T" == *:* ]]; then command rm -rf "$T"; T=$(mktemp -d "/tmp/lz604crypto.XXXXXX") || { echo "FAIL: mktemp -d /tmp"; exit 1; }; fi
[[ -n "$T" && "$T" != "/" && -d "$T" ]] || { echo "FAIL: bad test dir '$T'"; exit 1; }

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }
ONLY="${LZ_CRYPTO_ONLY:-}"
sec() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }

REAL_OPENSSL=$(type -P openssl) || { echo "  fix604 crypto: SKIPPED (нет openssl)"; command rm -rf "$T"; exit 0; }
REAL_SHRED=$(type -P shred) || REAL_SHRED=""
export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; command rm -rf "$T"; exit 1; }
trap 'command rm -rf "$T"' EXIT
trap - INT TERM
# RETURN-trap бэкап-функций ссылается на LOCK_ACQUIRED — глобал нужен и вне функции.
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
MOCK="$T/bin"; mkdir -p "$MOCK"
# shred — PATH-обёртка (её зовёт и `find -exec shred` из cleanup_on_exit, функцию оттуда не видно):
# пути только внутри $T, значение после -n — не путь; файлы > 64 МБ не затираем по-настоящему
# (BIG_SHRED + rm), чтобы мутация «shred без порога» не писала гигабайты на диск.
export LZ604_T="$T" REAL_SHRED
cat > "$MOCK/shred" <<'EOF'
#!/usr/bin/env bash
printf 'SHRED %s\n' "$*" >> "$LZ604_T/rm.log"
skip=""; files=()
for a in "$@"; do
    if [[ -n "$skip" ]]; then skip=""; continue; fi
    case "$a" in -n) skip=1; continue ;; -*) continue ;; "$LZ604_T"/*) files+=("$a"); continue ;; esac
    printf 'RM_OUTSIDE shred %s\n' "$a" >> "$LZ604_T/rm_outside.log"; exit 1
done
for f in "${files[@]}"; do
    if [[ -f "$f" && "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 67108864 ]]; then
        printf 'BIG_SHRED %s\n' "$f" >> "$LZ604_T/rm.log"; rm -f "$f"; exit 0
    fi
done
[[ -n "$REAL_SHRED" ]] || { rm -f "${files[@]}"; exit 0; }
exec "$REAL_SHRED" "$@"
EOF
chmod +x "$MOCK/shred"

# --- сеть: функции-блокираторы + PATH-блокираторы
NETLOG="$T/net.log"; : > "$NETLOG"
curl()   { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
wget()   { printf 'wget %s\n' "$*" >> "$NETLOG"; return 4; }
aws()    { printf 'aws %s\n' "$*" >> "$NETLOG"; return 1; }
rclone() { printf 'rclone %s\n' "$*" >> "$NETLOG"; return 1; }
for _nb in curl wget aws rclone ssh scp sftp sshpass nc; do
    cat > "$MOCK/$_nb" <<EOF
#!/usr/bin/env bash
echo "BLOCKED $_nb \$*" >> "$NETLOG"
exit 97
EOF
    chmod +x "$MOCK/$_nb"
done
export PATH="$MOCK:$PATH"

# --- Telegram / выгрузка: только журнал
TGLOG="$T/tg.log"; : > "$TGLOG"
send_telegram_notification() { :; }
send_telegram_alert()    { printf 'ALERT|%s|%s\n' "$1" "$2" >> "$TGLOG"; return 0; }
send_telegram_document() { printf 'DOC|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_text()    { printf 'TEXT|%s\n' "$1" >> "$TGLOG"; return 0; }
_send_telegram_album()   { printf 'ALBUM|%s\n' "$1" >> "$TGLOG"; return 0; }
upload_to_remote() { REMOTE_UPLOAD_STATUS_TEXT=""; REMOTE_UPLOAD_SIZE_UNVERIFIED="false"; printf 'UPLOAD|%s\n' "$1" >> "$TGLOG"; return 0; }

debug_log() { :; }
clear_screen() { :; }
sleep() { :; }
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
DEBUG_MODE=false; DRY_RUN=false; IS_INTERACTIVE=false; AUTO_CONFIRM=false
PW="fixture-pass-604c"   # фиктивный пароль

mkdir -p "$T/d"
head -c 300000 /dev/urandom > "$T/d/r300k.bin"
: > "$T/d/empty.bin"
printf 'x' > "$T/d/one.bin"
head -c 64 /dev/urandom > "$T/d/b64.bin"
hmac_ref() { "$REAL_OPENSSL" dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary "$2" | _to_hex; }
mk_plain() { head -c "${2:-4000}" /dev/urandom > "$T/plain.bin"; tar -czf "$1" -C "$T" plain.bin; }

# ============================================================ 1) _hmac_sha256_file = openssl -macopt
if sec 1; then
_pws=("Tr0ub4dor&3" "Пароль-Кириллица №1 ёЁ" "$(printf 'long%.0s' $(seq 1 120))" "sp \$HOME \`id\` \"q\" 'a' \\ ; | & * ? < > !x %s %%")
_keys=()
for _p in "${_pws[@]}"; do _keys+=("$(_derive_hmac_key "$_p")"); done
_keys+=("00" "3636" "5c5c5c" "ABCDEF0123456789" "$(head -c 64 /dev/urandom | _to_hex)" "$(head -c 65 /dev/urandom | _to_hex)" "$(head -c 200 /dev/urandom | _to_hex)")
_mis=0; _n=0
for _k in "${_keys[@]}"; do
    for _f in empty one b64 r300k; do
        _a=$(_hmac_sha256_file "$_k" "$T/d/$_f.bin" | _to_hex); _b=$(hmac_ref "$_k" "$T/d/$_f.bin")
        _n=$((_n + 1))
        [[ ${#_a} -eq 64 && "$_a" == "$_b" ]] || { _mis=$((_mis + 1)); echo "  mismatch: key[${#_k}]=${_k:0:12}… file=$_f got=${_a:0:16} want=${_b:0:16}"; }
    done
done
[[ $_mis -eq 0 && $_n -eq 44 ]] && ok || bad "1a HMAC-хелпер совпал с openssl -macopt на всех $_n парах (расхождений: $_mis)"
[[ ${#_keys[0]} -eq 64 && ${#_keys[1]} -eq 64 ]] && ok || bad "1b K_mac из пароля — 32 байта (hex 64)"
_o=$(_hmac_sha256_file "abc" "$T/d/one.bin"); _rc=$?
[[ $_rc -ne 0 && -z "$_o" ]] && ok || bad "1c ключ нечётной длины → отказ без вывода (rc=$_rc)"
_o=$(_hmac_sha256_file "zz11" "$T/d/one.bin"); _rc=$?
[[ $_rc -ne 0 && -z "$_o" ]] && ok || bad "1d не-hex ключ → отказ без вывода (rc=$_rc)"
_o=$(_hmac_sha256_file "" "$T/d/one.bin"); _rc=$?
[[ $_rc -ne 0 && -z "$_o" ]] && ok || bad "1e пустой ключ → отказ (rc=$_rc)"
_o=$(_hmac_sha256_file "${_keys[0]}" "$T/d/nonexistent.bin"); _rc=$?
[[ $_rc -ne 0 && -z "$_o" ]] && ok || bad "1f нечитаемый файл → отказ (rc=$_rc)"
# сбой чтения посреди потока (cat rc≠0) — отказ, а не «хеш обрывка» с rc=0. set +o pipefail — как в
# самом скрипте (глобально pipefail не включён): хелпер обязан включать его сам.
_o=$( set +o pipefail; cat() { command cat "$@"; return 1; }; _hmac_sha256_file "${_keys[0]}" "$T/d/r300k.bin" | _to_hex; exit "${PIPESTATUS[0]}" ); _rc=$?
[[ $_rc -ne 0 && -z "$_o" ]] && ok || bad "1g cat rc≠0 внутри хелпера → rc≠0 и пустой MAC (rc=$_rc, out=${_o:0:16})"
fi

# ============================================================ 2) argv openssl без ключа MAC
if sec 2; then
mkdir -p "$T/obin"; ARGV_LOG="$T/openssl_argv.log"; : > "$ARGV_LOG"; export ARGV_LOG REAL_OPENSSL
cat > "$T/obin/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
exec "$REAL_OPENSSL" "$@"
EOF
chmod +x "$T/obin/openssl"
_SAVE_PATH="$PATH"; export PATH="$T/obin:$PATH"
_pw2="Секрет-argv-604 \$&"
mk_plain "$T/a2.tar.gz" 50000
_hmac_envelope_create "$T/a2.tar.gz" "$T/a2.enc" "$_pw2" >/dev/null 2>&1; _rc1=$?
_fmt=$(_hmac_envelope_verify "$T/a2.enc" "$_pw2" 2>/dev/null); _rc2=$?
_hmac_envelope_decrypt "$T/a2.enc" "$T/a2.dec" "$_pw2" >/dev/null 2>&1; _rc3=$?
export PATH="$_SAVE_PATH"
_km=$(_derive_hmac_key "$_pw2")
[[ $_rc1 -eq 0 && $_rc2 -eq 0 && "$_fmt" == "v2" && $_rc3 -eq 0 ]] && cmp -s "$T/a2.dec" "$T/a2.tar.gz" && ok || bad "2a create/verify/decrypt через обёртку openssl работают (rc=$_rc1/$_rc2/$_rc3 fmt=$_fmt)"
[[ $(grep -c 'dgst -sha256 -binary' "$ARGV_LOG") -ge 6 ]] && ok || bad "2b обёртка действительно видела вызовы MAC-хелпера: $(head -3 "$ARGV_LOG")"
# rc=1 строго («не найдено»): падение grep (rc=2, abort на локали) не должно сойти за «нет ключа».
LC_ALL=C grep -q 'hexkey' "$ARGV_LOG"; [[ $? -eq 1 ]] && ok || bad "2c в argv openssl нет hexkey: $(LC_ALL=C grep -m1 hexkey "$ARGV_LOG" | cut -c1-60)"
LC_ALL=C grep -qF "$_km" "$ARGV_LOG"; [[ $? -eq 1 && ${#_km} -eq 64 ]] && ok || bad "2d K_mac не встречается в argv openssl"
LC_ALL=C grep -qF "Секрет-argv-604" "$ARGV_LOG"; [[ $? -eq 1 ]] && ok || bad "2e пароль не встречается в argv openssl"
fi

# ============================================================ 3) совместимость формата v2
if sec 3; then
mk_plain "$T/c.tar.gz" 120000
_km=$(_derive_hmac_key "$PW")
# v2, собранный ровно как в 6.0.3: openssl enc → LAZ2 + ciphertext + HMAC через -macopt hexkey:
LAZARUS_ENC_PW="$PW" "$REAL_OPENSSL" enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$T/c.tar.gz" -out "$T/c.cipher" -pass env:LAZARUS_ENC_PW 2>/dev/null
{ printf 'LAZ2'; command cat "$T/c.cipher"; "$REAL_OPENSSL" dgst -sha256 -mac HMAC -macopt "hexkey:$_km" -binary "$T/c.cipher"; } > "$T/c_old.enc"
_hmac_envelope_decrypt "$T/c_old.enc" "$T/c_old.dec" "$PW" >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 0 ]] && cmp -s "$T/c_old.dec" "$T/c.tar.gz" && ok || bad "3a v2 по схеме 6.0.3 (-macopt) расшифрован новым кодом (rc=$_rc)"
_fmt=$(_hmac_envelope_verify "$T/c_old.enc" "$PW"); _rc=$?
[[ $_rc -eq 0 && "$_fmt" == "v2" ]] && ok || bad "3b verify нового кода принимает MAC старой схемы (rc=$_rc fmt=$_fmt)"
_hmac_envelope_create "$T/c.tar.gz" "$T/c_new.enc" "$PW" >/dev/null 2>&1
_sz=$(stat -c%s "$T/c_new.enc"); _cl=$((_sz - 36))
tail -c +5 "$T/c_new.enc" | head -c "$_cl" > "$T/c_new.cipher"
[[ "$(tail -c 32 "$T/c_new.enc" | _to_hex)" == "$(hmac_ref "$_km" "$T/c_new.cipher")" ]] && ok || bad "3c MAC нового envelope = openssl -macopt над ciphertext (старый код его примет)"
_hmac_envelope_decrypt "$T/c_new.enc" "$T/c_new.dec" "$PW" >/dev/null 2>&1 && cmp -s "$T/c_new.dec" "$T/c.tar.gz" && ok || bad "3d новый envelope расшифрован новым кодом"
_hmac_envelope_decrypt "$T/c_new.enc" "$T/c_bad.dec" "wrong-$PW" >/dev/null 2>&1; _rc=$?
[[ $_rc -eq 1 && ! -s "$T/c_bad.dec" ]] && ok || bad "3e неверный пароль → rc=1 (MAC) до расшифровки (rc=$_rc)"
# Настоящий старый код (6414aeb) — если коммит есть в истории (в shallow-клоне CI его нет).
mkdir -p "$T/old"
if git -C "$ROOT_DIR" show 6414aeb:lazarus-backup > "$T/old/lazarus-backup" 2>/dev/null && [[ -s "$T/old/lazarus-backup" ]]; then
    ( source "$T/old/lazarus-backup" >/dev/null 2>&1
      SILENT_LOG="$T/silent.log"; TMPDIR="$T/tmp"; debug_log() { :; }
      _hmac_envelope_create "$T/c.tar.gz" "$T/c_oldcode.enc" "$PW" >/dev/null 2>&1 || exit 11
      _hmac_envelope_decrypt "$T/c_new.enc" "$T/c_oldcode.dec" "$PW" >/dev/null 2>&1 || exit 12
      exit 0 ) 2>/dev/null; _rc=$?
    [[ $_rc -eq 0 ]] && cmp -s "$T/c_oldcode.dec" "$T/c.tar.gz" && ok || bad "3f старый код (6414aeb) расшифровал envelope нового (rc=$_rc)"
    _hmac_envelope_decrypt "$T/c_oldcode.enc" "$T/c_oldcode2.dec" "$PW" >/dev/null 2>&1; _rc=$?
    [[ $_rc -eq 0 ]] && cmp -s "$T/c_oldcode2.dec" "$T/c.tar.gz" && ok || bad "3g новый код расшифровал envelope старого кода 6414aeb (rc=$_rc)"
else
    echo "  (3f/3g пропущены: коммита 6414aeb нет в истории — shallow-клон)"
fi
fi

# ============================================================ 4) envelope-функции без RETURN-trap
if sec 4; then
mk_plain "$T/t.tar.gz" 20000
_outer_c() { trap 'echo OUTER >> "$T/trap.log"' RETURN; _hmac_envelope_create "$1" "$2" "$PW" >/dev/null 2>&1; }
_outer_d() { trap 'echo OUTER >> "$T/trap.log"' RETURN; _hmac_envelope_decrypt "$1" "$2" "$PW" >/dev/null 2>&1; }
: > "$T/trap.log"; trap - RETURN; unset LAZARUS_ENC_PW
_outer_c "$T/t.tar.gz" "$T/t.enc"; _rt=$(trap -p RETURN)
[[ "$(cat "$T/trap.log")" == "OUTER" ]] && ok || bad "4a trap вызывающей функции сработал после _hmac_envelope_create: '$(cat "$T/trap.log")'"
[[ "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "4b после create trap -p RETURN без unset LAZARUS_ENC_PW: $_rt"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && ok || bad "4c после успешного create LAZARUS_ENC_PW снят"
: > "$T/trap.log"; trap - RETURN
_outer_d "$T/t.enc" "$T/t.dec"; _rt=$(trap -p RETURN)
[[ "$(cat "$T/trap.log")" == "OUTER" && "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "4d decrypt v2: trap вызывающего сработал, чужого trap нет: '$(cat "$T/trap.log")' / $_rt"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && cmp -s "$T/t.dec" "$T/t.tar.gz" && ok || bad "4e после decrypt v2 LAZARUS_ENC_PW снят, plaintext верный"
LAZARUS_ENC_PW="$PW" "$REAL_OPENSSL" enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$T/t.tar.gz" -out "$T/t.v1" -pass env:LAZARUS_ENC_PW 2>/dev/null
: > "$T/trap.log"; trap - RETURN; unset LAZARUS_ENC_PW
_outer_d "$T/t.v1" "$T/t1.dec"; _rt=$(trap -p RETURN)
[[ "$(cat "$T/trap.log")" == "OUTER" && "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "4f decrypt v1: trap вызывающего сработал, чужого trap нет: '$(cat "$T/trap.log")' / $_rt"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && cmp -s "$T/t1.dec" "$T/t.tar.gz" && ok || bad "4g после decrypt v1 LAZARUS_ENC_PW снят, plaintext верный"
# провал шифрования (нет входного файла) → rc=1, пароль из окружения снят, trap не затёрт
: > "$T/trap.log"; trap - RETURN
_outer_c "$T/no-such-input.tar.gz" "$T/t_fail.enc"; _rc=$?; _rt=$(trap -p RETURN)
[[ $_rc -ne 0 && ! -e "$T/t_fail.enc" ]] && ok || bad "4h провал openssl enc → rc≠0, .enc нет (rc=$_rc)"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && ok || bad "4i после ПРОВАЛА шифрования LAZARUS_ENC_PW снят (не остаётся в env меню)"
[[ "$(cat "$T/trap.log")" == "OUTER" && "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "4j провал шифрования: trap вызывающего сработал: '$(cat "$T/trap.log")' / $_rt"
trap - RETURN
fi

# ============================================================ 5–7) общая обвязка бэкап-путей
_harness_done=""
_backup_harness() {
    [[ -n "$_harness_done" ]] && return 0
    _harness_done=1
    cat > "$MOCK/docker" <<'EOF'
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
    cat > "$MOCK/fakessh" <<'EOF'
#!/bin/bash
exec bash -c "$*"
EOF
    chmod +x "$MOCK/docker" "$MOCK/fakessh"
    acquire_lock() { return 0; }
    release_lock() { echo REL >> "$T/lock.log"; }
    check_lock_owner() { echo 0; }
    assert_target_identity() { return 0; }
    _billing_sidecar_active() { return 1; }
    _kb_sidecar_active() { return 1; }
    get_db_user() { echo postgres; }
    get_db_name() { echo botdb; }
    BK="$T/bk"; mkdir -p "$BK"; BACKUP_DIR="$BK"
    BACKUP_TARGET="bot"; BACKUP_PREFIX="lazarus"; BACKUP_SECONDARY=""; BOT_KB_BACKUP="auto"
    BOT_PATH="$T/botsrc"; mkdir -p "$BOT_PATH"; echo "POSTGRES_DB=botdb" > "$BOT_PATH/.env"; echo "cfg" > "$BOT_PATH/app.conf"
    BOT_CONTAINER_NAME=""; DB_CONTAINER_NAME="testdb"; COMPRESSION="gzip"
    PG_DUMP_TIMEOUT_SEC=60; TAR_TIMEOUT_SEC=60; BACKUP_LOG_FILES="false"; MAX_FILE_SIZE_MB=50; EXCLUDE_DIRS=""
    REMOTE_STORAGE_TYPE="off"; SEND_TO_REMOTE="false"; SEND_TO_TELEGRAM="false"; TG_SEND_FILE="false"
    BOT_TOKEN=""; CHAT_ID=""; DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"; DELETE_MODE="count"; MAX_BACKUPS_COUNT="50"
    MAX_BACKUP_SIZE_MB="0"; DISK_WARN_PERCENT=101; DISK_CRITICAL_PERCENT=101; _BOTH_TG_DEFER=""
    # Обёртки: CLOBBER_RET — «вложенная функция ставит свой RETURN-trap» (затирает trap вызывающего);
    # ENC_FAIL — шифрование провалилось; FAKE_VRC — код verify-расшифровки; TAR_EXIT — «убит» после tar.
    eval "$(declare -f _hmac_envelope_create | sed '1s/^_hmac_envelope_create/_real_env_create/')"
    _hmac_envelope_create() {
        [[ -n "${CLOBBER_RET:-}" ]] && trap ':' RETURN
        [[ -n "${ENC_FAIL:-}" ]] && return 1
        _real_env_create "$@"
    }
    eval "$(declare -f _hmac_envelope_decrypt | sed '1s/^_hmac_envelope_decrypt/_real_env_decrypt/')"
    _hmac_envelope_decrypt() {
        if [[ "${FAKE_VRC:-0}" -ne 0 && "$2" == *lazarus_rverify* ]]; then return "$FAKE_VRC"; fi
        _real_env_decrypt "$@"
    }
    eval "$(declare -f _run_pipe_with_timeout | sed '1s/^_run_pipe_with_timeout/_real_rpwt/')"
    _run_pipe_with_timeout() {
        [[ "$2" == "remote-tar" ]] && printf '%s\n' "${SENSITIVE_TMP_PATHS[@]}" > "$T/sens_at_tar"
        _real_rpwt "$@"; local _r=$?
        [[ "$2" == "remote-tar" && -n "${TAR_EXIT:-}" ]] && exit "$TAR_EXIT"
        return $_r
    }
}
reset_bk() { rm -rf "$BK"; mkdir -p "$BK"; : > "$TGLOG"; : > "$LOG_FILE"; : > "$T/lock.log"; SENSITIVE_TMP_PATHS=(); trap - RETURN; unset LAZARUS_ENC_PW; }
n_arch() { find "$BK" -maxdepth 1 -type f -name "$1" | wc -l | tr -d ' '; }
n_rel() { grep -c '^REL$' "$T/lock.log" 2>/dev/null || true; }
has_sens() { local p; for p in "${SENSITIVE_TMP_PATHS[@]}"; do [[ "$p" == $1 ]] && return 0; done; return 1; }

# ============================================================ 5) _backup_remote_target: блокировка снимается
if sec 5; then
_backup_harness
TARGET_SSH="$MOCK/fakessh"
reset_bk; BACKUP_PASSWORD="$PW"
_backup_remote_target "db_only" > "$T/o5" 2>&1; _rc=$?; _rt=$(trap -p RETURN)
[[ $_rc -eq 0 && "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "5a remote db_only с паролем → rc=0 и .enc (rc=$_rc): $(grep -E 'ERROR' "$T/o5" | head -2)"
[[ "$(n_rel)" -ge 1 ]] && ok || bad "5b remote с паролем: release_lock вызван (сессия меню не держит лок)"
[[ "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "5c после remote с паролем trap -p RETURN без unset LAZARUS_ENC_PW: $_rt"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && ok || bad "5d после remote LAZARUS_ENC_PW снят"
# вложенная функция затёрла RETURN-trap → явный release на каждом позднем return
reset_bk; CLOBBER_RET=1
_backup_remote_target "db_only" > "$T/o5" 2>&1; _rc=$?
[[ $_rc -eq 0 && "$(n_rel)" -ge 1 ]] && ok || bad "5e trap затёрт, успех → явный release_lock перед return 0 (rc=$_rc, rel=$(n_rel))"
reset_bk; FAKE_VRC=1
_backup_remote_target "db_only" > "$T/o5" 2>&1; _rc=$?
[[ $_rc -ne 0 && "$(n_rel)" -ge 1 ]] && grep -q 'ПОВРЕЖДЁН' "$T/o5" && ok || bad "5f trap затёрт, verify rc=1 → release_lock (rc=$_rc, rel=$(n_rel))"
reset_bk; FAKE_VRC=2
_backup_remote_target "db_only" > "$T/o5" 2>&1; _rc=$?
[[ $_rc -ne 0 && "$(n_rel)" -ge 1 ]] && grep -q 'НЕ выполнена' "$T/o5" && ok || bad "5g trap затёрт, verify rc=2 → release_lock (rc=$_rc, rel=$(n_rel))"
FAKE_VRC=0
reset_bk; ENC_FAIL=1
_backup_remote_target "db_only" > "$T/o5" 2>&1; _rc=$?
[[ $_rc -ne 0 && "$(n_rel)" -ge 1 && "$(n_arch 'lazarus_db_*')" -eq 0 ]] && ok || bad "5h trap затёрт, шифрование провалено (без PLAINTEXT) → release_lock, plaintext не остался (rc=$_rc, rel=$(n_rel), $(ls "$BK"))"
# интерактивный PLAINTEXT, но mv в штатное имя не удался → тоже release
reset_bk
( IS_INTERACTIVE=true
  mv() { case "$*" in *"$BK"/lazarus_db_*.tar.gz) return 1 ;; esac; command mv "$@"; }
  _backup_remote_target "db_only" > "$T/o5" 2>&1 <<< "PLAINTEXT"; echo "rc=$?" >> "$T/o5" )
[[ "$(n_rel)" -ge 1 ]] && grep -q 'Не удалось переименовать' "$T/o5" && grep -qx 'rc=1' "$T/o5" && ok || bad "5i trap затёрт, PLAINTEXT + mv провален → release_lock (rel=$(n_rel)): $(grep -E 'ERROR|rc=' "$T/o5" | head -3)"
ENC_FAIL=""; CLOBBER_RET=""; BACKUP_PASSWORD=""; TARGET_SSH=""
fi

# ============================================================ 6) create_backup с паролем
if sec 6; then
_backup_harness
reset_bk; BACKUP_PASSWORD="$PW"
create_backup "db_only" > "$T/o6" 2>&1; _rc=$?; _rt=$(trap -p RETURN)
[[ $_rc -eq 0 && "$(n_arch 'lazarus_db_*.tar.gz.enc')" -eq 1 ]] && ok || bad "6a create_backup db_only с паролем → rc=0 и .enc (rc=$_rc): $(grep -E 'ERROR' "$T/o6" | head -2)"
[[ "$(n_rel)" -ge 1 ]] && ok || bad "6b create_backup с паролем: release_lock вызван"
[[ "$_rt" != *LAZARUS_ENC_PW* ]] && ok || bad "6c после create_backup с паролем trap -p RETURN без unset LAZARUS_ENC_PW: $_rt"
[[ -z "${LAZARUS_ENC_PW+x}" ]] && ok || bad "6d после create_backup LAZARUS_ENC_PW снят"
BACKUP_PASSWORD=""
fi

# ============================================================ 7) [17] tar стека удалённой цели — sensitive
if sec 7; then
_backup_harness
TARGET_SSH="$MOCK/fakessh"
reset_bk; BACKUP_PASSWORD="$PW"
_backup_remote_target "full" > "$T/o7" 2>&1; _rc=$?
[[ $_rc -eq 0 && "$(n_arch 'lazarus_full_*.tar.gz.enc')" -eq 1 ]] && ok || bad "7a remote full с паролем → rc=0 и .enc (rc=$_rc): $(grep -E 'ERROR' "$T/o7" | head -2)"
grep -qE "^$BK/dir_[0-9_-]+\.tar\.gz$" "$T/sens_at_tar" && ok || bad "7b в момент remote-tar dir_<ts> уже в SENSITIVE_TMP_PATHS: $(tr '\n' ' ' < "$T/sens_at_tar")"
! has_sens "$BK/dir_*" && ok || bad "7c после combine dir_<ts> снят с регистрации: ${SENSITIVE_TMP_PATHS[*]}"
[[ "$(n_arch 'dir_*')" -eq 0 ]] && ok || bad "7d dir_<ts> удалён после combine"
# провал tar (каталога нет) → dir_ удалён и снят с регистрации
reset_bk; _sv_bp="$BOT_PATH"; BOT_PATH="$T/no-such-stack"
_backup_remote_target "files_only" > "$T/o7" 2>&1; _rc=$?
BOT_PATH="$_sv_bp"
[[ $_rc -ne 0 ]] && grep -q 'Удалённый tar провален' "$T/o7" && ok || bad "7e провал remote tar → rc≠0 (rc=$_rc)"
[[ "$(n_arch 'dir_*')" -eq 0 ]] && ! has_sens "$BK/dir_*" && ok || bad "7f провал tar: dir_ удалён и снят с регистрации: ${SENSITIVE_TMP_PATHS[*]}"
# «убит» сразу после tar (TERM → exit 143): cleanup_on_exit убирает dir_ (раньше оставался до sweep)
reset_bk
( trap cleanup_on_exit EXIT; TAR_EXIT=143; _backup_remote_target "full" > "$T/o7" 2>&1 ); _rc=$?
[[ $_rc -eq 143 ]] && ok || bad "7g обвязка: подпроцесс завершён после tar (rc=$_rc)"
[[ "$(n_arch 'dir_*')" -eq 0 && "$(n_arch 'db_*')" -eq 0 ]] && ok || bad "7h TERM после remote-tar: dir_*/db_* убраны cleanup_on_exit: $(ls "$BK")"
BACKUP_PASSWORD=""; TARGET_SSH=""
fi

# ============================================================ 8) [16] cleanup_on_exit
if sec 8; then
mkdir -p "$T/c8"
head -c 4096 /dev/urandom > "$T/c8/a.bin"; head -c 4096 /dev/urandom > "$T/c8/b.bin"
: > "$T/rm.log"
# INT посреди зачистки (как повторный Ctrl+C): зачистка доходит до конца
( SENSITIVE_TMP_PATHS=("$T/c8/a.bin" "$T/c8/b.bin"); _CRITICAL_SECTION=0
  trap _lazarus_int_handler INT
  shred() { if [[ -z "${_sent:-}" ]]; then _sent=1; kill -INT "$BASHPID"; fi; command shred "$@"; }
  cleanup_on_exit
  trap -p INT TERM > "$T/c8/traps"
  echo DONE ) > "$T/c8/out" 2>&1; _rc=$?
[[ $_rc -eq 0 ]] && grep -q DONE "$T/c8/out" && ok || bad "8a INT во время cleanup_on_exit не обрывает её (rc=$_rc): $(head -2 "$T/c8/out")"
[[ ! -e "$T/c8/a.bin" && ! -e "$T/c8/b.bin" ]] && ok || bad "8b оба sensitive-файла удалены несмотря на INT: $(ls "$T/c8")"
grep -q "trap -- '' SIGINT" "$T/c8/traps" && grep -q "trap -- '' SIGTERM" "$T/c8/traps" && ok || bad "8c cleanup_on_exit игнорирует INT и TERM: $(cat "$T/c8/traps")"
# размеры: мелкий файл — shred -n 1; крупный (> 1 ГиБ, разреженный) — rm без shred; каталог
head -c 5000 /dev/urandom > "$T/c8/small.bin"
mkdir -p "$T/c8/dir/sub"; head -c 3000 /dev/urandom > "$T/c8/dir/sub/inner.bin"
_big=""
if command -v truncate >/dev/null 2>&1 && truncate -s 1100M "$T/c8/big.bin" 2>/dev/null && truncate -s 1100M "$T/c8/dir/big_in_dir.bin" 2>/dev/null; then _big=1; fi
: > "$T/rm.log"
( SENSITIVE_TMP_PATHS=("$T/c8/small.bin" "$T/c8/dir"); [[ -n "$_big" ]] && SENSITIVE_TMP_PATHS+=("$T/c8/big.bin"); cleanup_on_exit ) >/dev/null 2>&1
[[ ! -e "$T/c8/small.bin" && ! -e "$T/c8/dir" ]] && ok || bad "8d мелкий файл и каталог удалены: $(ls "$T/c8")"
grep -qE "^SHRED .*-n 1 .*$T/c8/small\.bin" "$T/rm.log" && ok || bad "8e мелкий файл затёрт одним проходом (shred -n 1): $(grep SHRED "$T/rm.log" | head -2)"
grep -qE "^SHRED .*-n 1 .*$T/c8/dir/sub/inner\.bin" "$T/rm.log" && ok || bad "8f файл в каталоге затёрт (find -size в k, а не -1G — иначе только пустые): $(grep SHRED "$T/rm.log" | head -2)"
if [[ -n "$_big" ]]; then
    [[ ! -e "$T/c8/big.bin" ]] && ok || bad "8g крупный файл удалён"
    ! grep -q 'BIG_SHRED' "$T/rm.log" && ! grep -qE "^SHRED .*big" "$T/rm.log" && ok || bad "8h файлы ≥ 1 ГиБ не shred'ятся (только rm): $(grep -E 'BIG_SHRED|SHRED .*big' "$T/rm.log" | head -2)"
else
    echo "  (8g/8h пропущены: нет truncate/разреженных файлов)"
fi
fi

# ============================================================ 9) [14] обновление: обрыв/битый/SHA
if sec 9; then
CU_BODY=$(declare -f check_for_updates); PU_BODY=$(declare -f perform_update)
P=${CU_BODY//'command -v curl'/'command -v "${FAKE_CURL_CMD:-curl}"'}
[[ "$P" != "$CU_BODY" ]] && ok || bad "9pre1 патч check_for_updates применился"
eval "$P"
P=${PU_BODY//'exec "$SCRIPT_PATH"'/'exec bash "$SCRIPT_PATH"'}
P=${P//'command -v curl'/'command -v "${FAKE_CURL_CMD:-curl}"'}
[[ "$P" != "$PU_BODY" && "$P" == *'exec bash'* ]] && ok || bad "9pre2 патч perform_update применился"
eval "$P"
INSTALL_DIR="$T/upd"; SCRIPT_NAME="lazarus-backup"; mkdir -p "$INSTALL_DIR"
SP="$INSTALL_DIR/$SCRIPT_NAME"
REMOTE_URLS=("https://example.invalid/lazarus-backup"); REMOTE_URL="${REMOTE_URLS[0]}"
mk_payload() {  # $1=файл $2=маркер: bash-скрипт ~21 КБ, VERSION="9.9.9", пишет маркер при запуске
    { echo '#!/bin/bash'; echo 'VERSION="9.9.9"'; echo "echo \"\$0\" > '$2'"
      local i; for i in $(seq 1 300); do echo "# padding line $i ................................................"; done; } > "$1"
}
mk_payload "$T/new.sh" "$T/RAN_NEW"
{ echo '#!/bin/bash'; echo 'VERSION="6.0.1"'; echo "echo old > '$T/RAN_OLD'"; } > "$T/old.sh"
head -n 200 "$T/new.sh" > "$T/partial.sh"            # обрыв на границе строк: синтаксис цел, bash -n не поймает
{ head -n 200 "$T/new.sh"; echo 'x="незакрытая кавычка — обрыв посреди строки'; tail -n 100 "$T/new.sh"; } > "$T/broken.sh"
head -c -1 "$T/new.sh" > "$T/new_nonl.sh"             # опубликованный файл без завершающего \n
bash -n "$T/partial.sh" && ! bash -n "$T/broken.sh" 2>/dev/null && [[ $(stat -c%s "$T/partial.sh") -ge 10000 ]] && ok || bad "9pre3 фикстуры: partial цел и ≥10000 байт, broken — с синтаксической ошибкой"
UPD_MODE=""; SHA_MODE=""; SHA_SRC=""
curl() {
    printf 'curl %s\n' "$*" >> "$T/upd_net.log"
    local out="" prev="" a url=""
    for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; [[ "$a" == https://* ]] && url="$a"; done
    if [[ "$url" == *.sha256* ]]; then
        case "$SHA_MODE" in
            good) printf '%s  lazarus-backup\n' "$(sha256sum "$SHA_SRC" | awk '{print $1}')" > "$out" ;;
            bad)  printf '%s  lazarus-backup\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$out" ;;
            *)    return 22 ;;
        esac
        return 0
    fi
    case "$UPD_MODE" in
        partial) command cat "$T/partial.sh"; return 28 ;;   # --max-time: тело оборвано
        broken)  command cat "$T/broken.sh"; return 0 ;;
        nonl)    command cat "$T/new_nonl.sh"; return 0 ;;
        good)    command cat "$T/new.sh"; return 0 ;;
    esac
    return 7
}
wget() {
    printf 'wget %s\n' "$*" >> "$T/upd_net.log"
    [[ "$*" == *.sha256* ]] && return 8
    command cat "$T/partial.sh"; return 4
}
upd_reset() { cp "$T/old.sh" "$SP"; command rm -f "$T/RAN_NEW" "$T/RAN_OLD"; : > "$T/upd_net.log"; }
upd_run() { ( check_for_updates ) > "$T/o9" 2>&1 <<< $'y\n\n\n'; }
no_tmp_left() { [[ -z "$(find "$INSTALL_DIR" -maxdepth 1 -name ".$SCRIPT_NAME.update.*")" ]]; }

upd_reset; UPD_MODE=partial; SHA_MODE=none; upd_run
cmp -s "$SP" "$T/old.sh" && [[ ! -e "$T/RAN_NEW" ]] && ok || bad "9a curl rc=28 с частичным (синтаксически целым) телом → НЕ установлено: $(grep -E 'ERROR|SUCCESS|Недоступен' "$T/o9" | head -3)"
grep -q 'Недоступен' "$T/o9" && ok || bad "9b неполная загрузка = источник недоступен"
grep -E '^curl ' "$T/upd_net.log" | grep -v sha256 | grep -q -- '--fail' && ok || bad "9c загрузка скрипта идёт с curl --fail: $(head -1 "$T/upd_net.log")"

upd_reset; UPD_MODE=broken; SHA_MODE=none; upd_run
cmp -s "$SP" "$T/old.sh" && [[ ! -e "$T/RAN_NEW" ]] && no_tmp_left && ok || bad "9d битый синтаксис → НЕ установлено, временный файл убран"
grep -q 'повреждён' "$T/o9" && grep -q 'Текущая версия не изменена' "$T/o9" && ok || bad "9e битый синтаксис: «повреждён … Текущая версия не изменена»: $(grep ERROR "$T/o9" | head -2)"

upd_reset; UPD_MODE=good; SHA_MODE=none; upd_run
cmp -s "$SP" "$T/new.sh" && [[ -e "$T/RAN_NEW" ]] && ok || bad "9f валидная загрузка, манифеста нет → установлено (mv) и запущено: $(grep -E 'ERROR' "$T/o9" | head -2)"
grep -q 'SHA256 manifest недоступен' "$T/o9" && ok || bad "9g манифест недоступен → WARN, как в install_script"

upd_reset; UPD_MODE=good; SHA_MODE=good; SHA_SRC="$T/new.sh"; upd_run
cmp -s "$SP" "$T/new.sh" && [[ -e "$T/RAN_NEW" ]] && ! grep -q 'SHA256 manifest недоступен' "$T/o9" && ok || bad "9h SHA256 совпал → установлено без WARN: $(grep -E 'ERROR|WARN' "$T/o9" | head -2)"

upd_reset; UPD_MODE=nonl; SHA_MODE=good; SHA_SRC="$T/new_nonl.sh"; upd_run
[[ -e "$T/RAN_NEW" ]] && ! grep -q 'mismatch' "$T/o9" && ok || bad "9i опубликован без завершающего \\n: SHA256 сверен по контенту → установлено: $(grep -E 'ERROR' "$T/o9" | head -2)"

upd_reset; UPD_MODE=good; SHA_MODE=bad; upd_run
cmp -s "$SP" "$T/old.sh" && [[ ! -e "$T/RAN_NEW" ]] && no_tmp_left && ok || bad "9j SHA256 не совпал → НЕ установлено"
grep -q 'SHA256 mismatch' "$T/o9" && grep -q 'Текущая версия не изменена' "$T/o9" && ok || bad "9k SHA256 mismatch: сообщение и «Текущая версия не изменена»"

upd_reset; FAKE_CURL_CMD="lz604-no-such-curl"; UPD_MODE=""; upd_run; unset FAKE_CURL_CMD
cmp -s "$SP" "$T/old.sh" && [[ ! -e "$T/RAN_NEW" ]] && grep -q '^wget ' "$T/upd_net.log" && ok || bad "9l wget rc=4 с частичным телом → НЕ установлено: $(head -2 "$T/upd_net.log")"
# сетевые заглушки секции — вернуть блокираторы
curl()   { printf 'curl %s\n' "$*" >> "$NETLOG"; return 7; }
wget()   { printf 'wget %s\n' "$*" >> "$NETLOG"; return 4; }
fi

# ============================================================ итог: сеть и песочница удаления
[[ ! -s "$NETLOG" ]] && ok || bad "Z1 ни одного сетевого вызова (curl/wget/aws/rclone/ssh…): $(head -3 "$NETLOG")"
[[ ! -s "$T/rm_outside.log" ]] && ok || bad "Z2 rm/shred вне каталога теста не вызывались: $(head -3 "$T/rm_outside.log")"

echo "---"
echo "fix604 crypto: ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
