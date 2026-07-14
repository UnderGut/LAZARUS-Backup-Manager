#!/usr/bin/env bash
# Tests for the 2026-07-10 surface-audit fixes (№1..№20):
#   №1  legacy password + failed migration -> save_config KEEPS the password in config.env
#   №2  encrypted inc over plain base: interactive refuse / cron auto-switch to FULL
#   №4  restore-chain receives the operator-verified password (_verified_pass)
#   №5  _encryption_ready: bare -f no longer counts as "encryption on"
#   №6  password never in argv (-pass env:), no fd:3 herestrings left
#   №8  unbind_bot_runtime restores DB_USER/DB_NAME/DB_SERVICE_NAME zeroed by bind
#   №14 EOF on password prompt -> return 1, not an infinite loop
#   №15 _ensure_encryption_or_confirm helper (shared local/remote), no-op in cron
#   №16 s3 rotation DRY_RUN must not touch nested <pfx>sub/lazarus_* keys
#   №20 all KEYWORDS sites use the single BOT_KEYWORDS_DEFAULT constant
#   + static checks for №7 (deferred save order), №12, №13, №17, №18, №19
# Counters n_ok/n_err (PASS= triggers secret-redaction on disk).

set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

SILENT_LOG="$TMP_DIR/silent.log"; : > "$SILENT_LOG"
export SILENT_LOG

# =============================================================================
# №20 — single KEYWORDS constant (static)
# =============================================================================
grep -q '^BOT_KEYWORDS_DEFAULT=(' "$SCRIPT" && ok || bad "№20 BOT_KEYWORDS_DEFAULT constant missing"
grep '^BOT_KEYWORDS_DEFAULT=(' "$SCRIPT" | grep -q '"rwp-shop"' && ok || bad "№20 dash-form rwp-shop missing in constant"
_kw_uses=$(grep -c 'KEYWORDS=("${BOT_KEYWORDS_DEFAULT\[@\]}")' "$SCRIPT")
[[ "$_kw_uses" -ge 4 ]] && ok || bad "№20 expected >=4 BOT_KEYWORDS_DEFAULT consumers, got $_kw_uses"
grep -Eq 'KEYWORDS=\("rwp_shop" "(rwp-shop|telegram-shop)"' "$SCRIPT" \
    && bad "№20 literal KEYWORDS copy still present (drift possible)" || ok

# =============================================================================
# №1 — legacy password + inaccessible password file -> save_config keeps password
# =============================================================================
(
    set -o pipefail
    INSTALL_DIR="$TMP_DIR/install"; mkdir -p "$INSTALL_DIR"
    CONFIG_FILE="$INSTALL_DIR/config.env"
    debug_log() { :; }; print_message() { :; }; log_message() { :; }
    source <(
        sed -n '/^env_escape() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^trim_ws() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^parse_env_value() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^load_config_file() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^_cfg_if_nondefault() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^write_password_file() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^save_config() {$/,/^}$/p' "$SCRIPT"
    )
    BACKUP_TARGET="bot"; _LEGACY_PWD_UNMIGRATED=0
    BACKUP_PASSWORD='legacy "sec\ret'
    BACKUP_PASSWORD_FILE="$TMP_DIR/outside/.password"   # вне INSTALL_DIR -> write откажет

    # (a) миграция проваливается (path guard)
    if write_password_file "$BACKUP_PASSWORD" 2>/dev/null; then
        echo "SUB-FAIL: write_password_file must refuse path outside INSTALL_DIR"
        exit 1
    fi
    _LEGACY_PWD_UNMIGRATED=1   # как это делает load_or_create_config при провале

    # (b) save_config обязан сохранить пароль (раньше писал "" -> потеря навсегда)
    save_config
    grep -q '^BACKUP_PASSWORD=""$' "$CONFIG_FILE" && { echo "SUB-FAIL: password wiped by save_config"; exit 1; }
    _orig="$BACKUP_PASSWORD"; BACKUP_PASSWORD=""
    load_config_file "$CONFIG_FILE"
    [[ "$BACKUP_PASSWORD" == "$_orig" ]] || { echo "SUB-FAIL: password roundtrip: '$BACKUP_PASSWORD'"; exit 1; }

    # (c) контроль: успешная миграция (флаг 0) -> в файле пусто, как раньше
    _LEGACY_PWD_UNMIGRATED=0; BACKUP_PASSWORD="whatever"
    save_config
    grep -q '^BACKUP_PASSWORD=""$' "$CONFIG_FILE" || { echo "SUB-FAIL: migrated password must be '' in config"; exit 1; }
    exit 0
) && ok || bad "№1 legacy password survival through save_config"

# №1/№7 static: migration block ABOVE detect_bot_installation, its save deferred AFTER _CANON snapshot
_locc_body=$(sed -n '/^load_or_create_config() {$/,/^}$/p' "$SCRIPT")
_l_mig=$(printf '%s\n' "$_locc_body" | grep -n 'write_password_file "\$BACKUP_PASSWORD"' | head -1 | cut -d: -f1)
_l_det=$(printf '%s\n' "$_locc_body" | grep -n 'detect_bot_installation$' | head -1 | cut -d: -f1)
_l_canon=$(printf '%s\n' "$_locc_body" | grep -n '_CANON_SNAPSHOT_TAKEN=1' | head -1 | cut -d: -f1)
_l_save=$(printf '%s\n' "$_locc_body" | grep -n '_pwd_migration_save" == "1"' | head -1 | cut -d: -f1)
[[ -n "$_l_mig" && -n "$_l_det" && "$_l_mig" -lt "$_l_det" ]] && ok \
    || bad "№1/№7 migration block must precede detect_bot_installation (mig=$_l_mig det=$_l_det)"
[[ -n "$_l_canon" && -n "$_l_save" && "$_l_canon" -lt "$_l_save" ]] && ok \
    || bad "№7 deferred migration save must come AFTER _CANON snapshot (canon=$_l_canon save=$_l_save)"

# =============================================================================
# №2 — encrypted inc over plain base: refuse (interactive) / auto-full (cron)
# =============================================================================
_inc_env() {   # общий сетап сабшелла для create_incremental_backup
    BACKUP_DIR="$TMP_DIR/inc_backup"; mkdir -p "$BACKUP_DIR"
    debug_log() { :; }; print_message() { :; }; log_message() { :; }
    acquire_lock() { return 0; }; release_lock() { :; }; check_lock_owner() { echo 0; }
    register_sensitive_tmp() { :; }; unregister_sensitive_tmp() { :; }
    send_telegram_alert() { echo "TG:$1:$2" >> "$TMP_DIR/inc_tg.txt"; }
    create_backup() { echo "CREATE_BACKUP:$1" >> "$TMP_DIR/inc_cb.txt"; return 0; }
    GRAY=""; RESET=""; YELLOW=""; RED=""; GREEN=""; BOLD=""
    BACKUP_TARGET="bot"; TARGET_SSH=""; BACKUP_PASSWORD="pw"
    source <(sed -n '/^create_incremental_backup() {$/,/^}$/p' "$SCRIPT")
}

# T: интерактив -> отказ, create_backup НЕ вызван
(
    _inc_env
    rm -f "$TMP_DIR/inc_cb.txt" "$TMP_DIR/inc_tg.txt"
    touch "$BACKUP_DIR/lazarus_full_2026-01-01_00_00_00__v1.tar.gz"   # plain base
    IS_INTERACTIVE="true"
    create_incremental_backup >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 1 && ! -f "$TMP_DIR/inc_cb.txt" ]] || { echo "SUB-FAIL: rc=$rc cb=$([[ -f "$TMP_DIR/inc_cb.txt" ]] && echo yes)"; exit 1; }
    exit 0
) && ok || bad "№2 interactive: plain base + password must refuse inc without auto-full"

# T: cron -> авто-переключение на FULL + WARN в TG
(
    _inc_env
    rm -f "$TMP_DIR/inc_cb.txt" "$TMP_DIR/inc_tg.txt"
    touch "$BACKUP_DIR/lazarus_full_2026-01-01_00_00_00__v1.tar.gz"
    IS_INTERACTIVE="false"
    create_incremental_backup >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 0 ]] || { echo "SUB-FAIL: rc=$rc"; exit 1; }
    grep -q '^CREATE_BACKUP:full$' "$TMP_DIR/inc_cb.txt" || { echo "SUB-FAIL: create_backup full not called"; exit 1; }
    grep -q '^TG:WARN' "$TMP_DIR/inc_tg.txt" || { echo "SUB-FAIL: no WARN TG alert"; exit 1; }
    exit 0
) && ok || bad "№2 cron: plain base + password must auto-switch to full (with TG WARN)"

# T (контроль, гейт-зеркало не сломан): .enc base + пустой пароль -> отказ без auto-full
(
    _inc_env
    rm -f "$TMP_DIR/inc_cb.txt"
    rm -f "$BACKUP_DIR"/lazarus_full_*
    touch "$BACKUP_DIR/lazarus_full_2026-01-01_00_00_00__v1.tar.gz.enc"
    BACKUP_PASSWORD=""; IS_INTERACTIVE="false"
    create_incremental_backup >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 1 && ! -f "$TMP_DIR/inc_cb.txt" ]] || { echo "SUB-FAIL: rc=$rc"; exit 1; }
    exit 0
) && ok || bad "№2 mirror gate (.enc base, no password) must still refuse"

# =============================================================================
# №4 / №14 — execute_restore: chain gets verified password; EOF -> return 1
# =============================================================================
RUNNER="$TMP_DIR/runner_restore.sh"
cat > "$RUNNER" <<'RUNEOF'
#!/usr/bin/env bash
# $1 = pass|eof, $2 = script path, $3 = workdir
MODE_ARG="$1"; SCRIPT="$2"; WORK="$3"
source <(sed -n '/^execute_restore() {$/,/^}$/p' "$SCRIPT")
SILENT_LOG="$WORK/silent.log"; : > "$SILENT_LOG"
TMPDIR="$WORK"
print_message() { :; }; log_message() { :; }; debug_log() { :; }
register_sensitive_tmp() { :; }; unregister_sensitive_tmp() { :; }
validate_tar_safety() { return 0; }
_hmac_envelope_decrypt() { : > "$2"; return 0; }   # «пароль верен», plaintext-заглушка
_resolve_incremental_chain() { printf '%s' "$3" > "$WORK/chain_pwd.txt"; return 1; }
IS_INTERACTIVE=false; TARGET_SSH=""; BACKUP_PASSWORD=""
RED=""; GREEN=""; YELLOW=""; GRAY=""; BOLD=""; RESET=""; CYAN=""
F="$WORK/lazarus_inc_2026-01-02_00_00_00__base_2026-01-01_00_00_00__v1.tar.gz.enc"
{ printf 'LAZ2'; head -c 100 /dev/zero; } > "$F"
if [[ "$MODE_ARG" == "eof" ]]; then
    execute_restore "full" "$F" < /dev/null
else
    execute_restore "full" "$F" <<< "testpass"
fi
RUNEOF

# №4: проверенный пароль дошёл до _resolve_incremental_chain
rm -f "$TMP_DIR/chain_pwd.txt"
bash "$RUNNER" pass "$SCRIPT" "$TMP_DIR" >/dev/null 2>&1
_rc4=$?
if [[ $_rc4 -eq 1 && -f "$TMP_DIR/chain_pwd.txt" && "$(cat "$TMP_DIR/chain_pwd.txt")" == "testpass" ]]; then
    ok
else
    bad "№4 chain password: rc=$_rc4 got='$(cat "$TMP_DIR/chain_pwd.txt" 2>/dev/null)'"
fi

# №14: EOF на вводе пароля -> return 1 быстро (не вечный цикл)
if command -v timeout >/dev/null 2>&1; then
    timeout 20 bash "$RUNNER" eof "$SCRIPT" "$TMP_DIR" >/dev/null 2>&1
else
    bash "$RUNNER" eof "$SCRIPT" "$TMP_DIR" >/dev/null 2>&1
fi
_rc14=$?
[[ $_rc14 -eq 1 ]] && ok || bad "№14 EOF must return 1 (got rc=$_rc14; 124=timeout/infinite loop)"

# =============================================================================
# №5 — _encryption_ready predicate
# =============================================================================
(
    INSTALL_DIR="$TMP_DIR/enc_install"; mkdir -p "$INSTALL_DIR"
    debug_log() { :; }; print_message() { :; }; log_message() { :; }
    source <(
        sed -n '/^read_password_file() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^_encryption_ready() {$/,/^}$/p' "$SCRIPT"
    )
    # (a) пароль в памяти -> готово
    BACKUP_PASSWORD="x"; BACKUP_PASSWORD_FILE="$INSTALL_DIR/.password"
    _encryption_ready || { echo "SUB-FAIL a"; exit 1; }
    # (b) файл СУЩЕСТВУЕТ, но вне INSTALL_DIR (-f true, read откажет) -> НЕ готово (ложно-зелёный кейс)
    BACKUP_PASSWORD=""; BACKUP_PASSWORD_FILE="$TMP_DIR/enc_outside.pwd"
    printf 'p' > "$BACKUP_PASSWORD_FILE"
    _encryption_ready && { echo "SUB-FAIL b: unreadable file counted as ready"; exit 1; }
    # (c) валидный файл внутри INSTALL_DIR -> готово + пароль загружен
    BACKUP_PASSWORD=""; BACKUP_PASSWORD_FILE="$INSTALL_DIR/.password"
    printf 'realpw' > "$BACKUP_PASSWORD_FILE"
    _encryption_ready || { echo "SUB-FAIL c"; exit 1; }
    [[ "$BACKUP_PASSWORD" == "realpw" ]] || { echo "SUB-FAIL c load"; exit 1; }
    # (d) пустой файл -> НЕ готово
    BACKUP_PASSWORD=""; : > "$BACKUP_PASSWORD_FILE"
    _encryption_ready && { echo "SUB-FAIL d: empty file counted as ready"; exit 1; }
    exit 0
) && ok || bad "№5 _encryption_ready states"
# №5 static: UI-точки больше не проверяют голый -f как «включено»
grep -q 'пароль НЕЧИТАЕМ' "$SCRIPT" && ok || bad "№5 readiness line lacks unreadable-file state"

# =============================================================================
# №6 — пароль не в argv (static)
# =============================================================================
grep -q -- '-pass fd:3' "$SCRIPT" && bad "№6 fd:3 herestring password passing still present" || ok
_env_pass=$(grep -c -- '-pass env:LAZARUS_ENC_PW' "$SCRIPT")
[[ "$_env_pass" -eq 3 ]] && ok || bad "№6 expected 3 '-pass env:LAZARUS_ENC_PW' sites, got $_env_pass"

# =============================================================================
# №8 — bind zeroes / unbind restores DB fields
# =============================================================================
(
    debug_log() { :; }; print_message() { :; }; log_message() { :; }
    resolve_bot_runtime() { RB_PATH="/opt/rwp-shop"; RB_APP="rwp_shop"; RB_DB="rwp_shop_db"; return 0; }
    _panel_root_now() { echo "/opt/remnawave"; }
    _same_path() { [[ "$1" == "$2" ]]; }
    _dir_is_panel() { return 1; }
    resolve_backup_target() { :; }
    eval "$(grep '^BOT_KEYWORDS_DEFAULT=(' "$SCRIPT")"
    source <(
        sed -n '/^bind_bot_runtime_or_fail() {$/,/^}$/p' "$SCRIPT"
        sed -n '/^unbind_bot_runtime() {$/,/^}$/p' "$SCRIPT"
    )
    BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"; BACKUP_PREFIX="lazarus_panel"
    BOT_PATH="/opt/x"; BOT_CONTAINER_NAME="c"; DB_CONTAINER_NAME="d"
    DB_SERVICE_NAME="svc1"; DB_NAME="db1"; DB_USER="custom_user"
    bind_bot_runtime_or_fail "тест" >/dev/null 2>&1 || { echo "SUB-FAIL bind rc"; exit 1; }
    [[ -z "$DB_USER" && -z "$DB_NAME" && -z "$DB_SERVICE_NAME" ]] || { echo "SUB-FAIL bind must zero DB fields"; exit 1; }
    unbind_bot_runtime
    [[ "$DB_USER" == "custom_user" && "$DB_NAME" == "db1" && "$DB_SERVICE_NAME" == "svc1" ]] \
        || { echo "SUB-FAIL unbind restore: u=$DB_USER n=$DB_NAME s=$DB_SERVICE_NAME"; exit 1; }
    [[ "$BACKUP_TARGET" == "panel" && "$BACKUP_SECONDARY" == "bot" ]] || { echo "SUB-FAIL target restore"; exit 1; }
    exit 0
) && ok || bad "№8 unbind must restore DB_USER/DB_NAME/DB_SERVICE_NAME"
# №8 heal (static): пустой DB_USER на диске лечится дефолтом
grep -q 'if \[\[ -z "\$DB_USER" \]\]; then DB_USER="postgres"; fi' "$SCRIPT" && ok \
    || bad "№8 load-time heal for empty DB_USER missing"

# =============================================================================
# №15 — _ensure_encryption_or_confirm: no-op в cron, вызывается из remote
# =============================================================================
(
    print_message() { :; }; log_message() { :; }; debug_log() { :; }
    clear_screen() { :; }; safe_read() { :; }
    source <(sed -n '/^_ensure_encryption_or_confirm() {$/,/^}$/p' "$SCRIPT")
    IS_INTERACTIVE="false"; BACKUP_PASSWORD=""
    _ensure_encryption_or_confirm || { echo "SUB-FAIL cron no-op"; exit 1; }
    IS_INTERACTIVE="true"; BACKUP_PASSWORD="set"
    _ensure_encryption_or_confirm || { echo "SUB-FAIL password-set fast path"; exit 1; }
    exit 0
) && ok || bad "№15 _ensure_encryption_or_confirm basic paths"
_remote_body=$(sed -n '/^_backup_remote_target() {$/,/^}$/p' "$SCRIPT")
printf '%s' "$_remote_body" | grep -q '_ensure_encryption_or_confirm' && ok \
    || bad "№15 _backup_remote_target must call _ensure_encryption_or_confirm"
printf '%s' "$_remote_body" | grep -q 'NO PASSWORD' && ok \
    || bad "№15 remote cron empty-password marker (NO PASSWORD) missing"

# =============================================================================
# №16 — s3 rotate DRY_RUN не показывает вложенные sub/lazarus_* ключи
# =============================================================================
(
    print_message() { :; }; log_message() { :; }; debug_log() { :; }
    _s3_aws_run() {
        printf 'backups/lazarus_db_2020-01-01_00_00_00.tar.gz\t2020-01-01T00:00:00.000Z\n'
        printf 'backups/sub/lazarus_db_2019-01-01_00_00_00.tar.gz\t2019-01-01T00:00:00.000Z\n'
        printf 'backups/lazarus_full_2099-01-01_00_00_00.tar.gz\t2099-01-01T00:00:00.000Z\n'
    }
    source <(sed -n '/^_s3_rotate_old() {$/,/^}$/p' "$SCRIPT")
    REMOTE_STORAGE_TYPE="s3"; S3_BUCKET="b"; S3_PATH="backups"; S3_REGION=""; S3_ENDPOINT=""
    DRY_RUN="true"
    out=$(_s3_rotate_old 7 2>/dev/null)
    # старый плоский ключ — кандидат на удаление
    printf '%s' "$out" | grep -q 'backups/lazarus_db_2020-01-01_00_00_00.tar.gz' \
        || { echo "SUB-FAIL: flat old key missing from DRY_RUN"; exit 1; }
    # вложенный ключ не трогается ВООБЩЕ
    printf '%s' "$out" | grep -q 'sub/lazarus_db_2019' \
        && { echo "SUB-FAIL: nested key appeared in DRY_RUN"; exit 1; }
    # новейший плоский — под защитой
    printf '%s' "$out" | grep -q 'lazarus_full_2099' \
        && { echo "SUB-FAIL: newest key must be protected"; exit 1; }
    exit 0
) && ok || bad "№16 s3 rotate scope (flat-only, newest protected)"

# =============================================================================
# Статические проверки: №12, №13, №17, №18, №19
# =============================================================================
# №12: get_compose_file — обёртка над _compose_in; усечённые 2-имённые выборки выпилены
_gcf_body=$(sed -n '/^get_compose_file() {$/,/^}$/p' "$SCRIPT")
printf '%s' "$_gcf_body" | grep -q '_compose_in "\$BOT_PATH"' && ok \
    || bad "№12 get_compose_file must wrap _compose_in"
grep -q '\-f "\$BOT_PATH/compose.yaml" \]\] && compose_file=' "$SCRIPT" \
    && bad "№12 truncated 2-name compose_file pattern still present" || ok
grep -q '\-f "\$BOT_PATH/compose.yaml" \]\] && _cf=' "$SCRIPT" \
    && bad "№12 truncated 2-name _cf pattern still present" || ok

# №13: help не прячет bot-команды в panel-режиме
grep -q 'недоступно в режиме panel' "$SCRIPT" \
    && bad "№13 stale M29 help gate still present" || ok

# №17: мёртвая функция удалена
grep -q 'get_bot_version_display' "$SCRIPT" \
    && bad "№17 dead get_bot_version_display still present" || ok

# №18: FOUND_VIA_FALLBACK потребляется в UI (пометка-догадка)
grep -q 'догадка по labels' "$SCRIPT" && ok || bad "№18 label-fallback UI mark missing"
grep -q 'догадка по compose-labels' "$SCRIPT" && ok || bad "№18 single-candidate guess wording missing"

# №19: PANEL_EXTRA_PATHS теперь АКТИВЕН (extra-sidecar), RESERVED-заглушка удалена.
grep -q 'PANEL_EXTRA_PATHS задан, но зарезервирован' "$SCRIPT" \
    && bad "№19 RESERVED-заглушка PANEL_EXTRA_PATHS должна быть удалена (фича активирована)" || ok
grep -qE 'tar \$_tar_compress_args -cf "\$BACKUP_DIR/\$FILE_EXTRA" -C / ' "$SCRIPT" && ok \
    || bad "№19 PANEL_EXTRA_PATHS должен потребляться (extra-sidecar tar -C /)"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
