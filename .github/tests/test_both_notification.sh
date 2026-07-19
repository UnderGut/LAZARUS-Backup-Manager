#!/usr/bin/env bash
# Тесты единого TG-уведомления both-режима (панель+бот) — _both_tg_flush / _both_tg_record /
# _delete_local_after_send / _json_escape / _send_telegram_album.
#
# Проверяем:
#   1. 2 годных файла → ОДИН sendMediaGroup (альбом), подпись перечисляет ОБЕ цели + размеры,
#      премиум-эмодзи применены, НЕТ фразы «не бэкапится».
#   2. 1 годный (второй >50МБ) → 1 sendDocument (не альбом), подпись всё равно перечисляет обе.
#   3. 0 годных (TG_SEND_FILE=false) → 1 текст-сводка (sendMessage-fallback).
#   4. Отложенное удаление: DELETE=any + доставка ok → оба локальных файла удалены после flush.
#   5. _json_escape корректно экранирует backslash/quote/newline.
#   6. Вынос _delete_local_after_send не сломал 4 режима (any/all/remote_only/false).
#
# Реальные функции извлекаются sed'ом и подключаются; сетевые отправители застаблены (пишут
# в счётчики), поэтому тестируется настоящая логика роутинга/сборки подписи (без drift).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

# --- извлекаем реальные функции ---
FUNCS="$TMP_DIR/funcs.sh"
{
    for fn in _json_escape _both_tg_record _delete_local_after_send _both_tg_flush tg_emoji; do
        sed -n "/^${fn}() {\$/,/^}\$/p" "$SCRIPT"
        echo ""
    done
} > "$FUNCS"
for fn in _json_escape _both_tg_record _delete_local_after_send _both_tg_flush tg_emoji; do
    grep -q "^${fn}() {" "$FUNCS" || { echo "FAIL: не извлеклась $fn из $SCRIPT" >&2; exit 1; }
done

# --- окружение/стабы ---
SILENT_LOG="$TMP_DIR/silent.log"; : > "$SILENT_LOG"
BACKUP_DIR="$TMP_DIR/backups"; mkdir -p "$BACKUP_DIR"
SEND_TO_TELEGRAM="true"; TG_SEND_FILE="true"; SEND_TO_REMOTE="true"
BOT_TOKEN="x"; CHAT_ID="y"; TG_MESSAGE_THREAD_ID=""
REMOTE_STORAGE_TYPE="off"; REMOTE_UPLOAD_SIZE_UNVERIFIED="false"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"
EMO_PACKAGE="1"; EMO_FOLDER="2"; EMO_DOC="3"; EMO_CALENDAR="4"; EMO_LOCK="5"; EMO_WARN="6"; EMO_STATS="7"; EMO_BADGE="8"

print_message() { :; }
log_message()   { :; }
debug_log()     { :; }
send_telegram_alert() { :; }
escape_markdown_v2() { printf '%s' "$1"; }   # identity — чтобы ассертить сырые подстроки

# счётчики отправок + захват подписи
CALL_ALBUM=0; CALL_DOC=0; CALL_TEXT=0; LAST_CAP=""; LAST_ALBUM_FILES=0
_send_telegram_album() { CALL_ALBUM=$((CALL_ALBUM+1)); LAST_CAP="$1"; shift; LAST_ALBUM_FILES=$#; return 0; }
send_telegram_document() { CALL_DOC=$((CALL_DOC+1)); LAST_CAP="$2"; return 0; }
_send_telegram_text() { CALL_TEXT=$((CALL_TEXT+1)); LAST_CAP="$1"; return 0; }

# shellcheck disable=SC1090
source "$FUNCS"

reset_acc() {
    _BOTH_TG_FILES=(); _BOTH_TG_LABELS=(); _BOTH_TG_SIZES=(); _BOTH_TG_BYTES=()
    _BOTH_TG_ENC=(); _BOTH_TG_VERIFY=(); _BOTH_TG_REMOTE_OK=(); _BOTH_TG_REMOTE_UNVERIFIED=(); _BOTH_TG_IS_REMOTE=()
    _BOTH_TG_VER=(); _BOTH_TG_RSTATUS=(); _BOTH_TG_SKIP=(); _BOTH_TG_TYPE=""
    CALL_ALBUM=0; CALL_DOC=0; CALL_TEXT=0; LAST_CAP=""; LAST_ALBUM_FILES=0
}

# записать цель напрямую в аккумулятор (эмулируем _both_tg_record из прохода)
rec() { # $1 target $2 file $3 size $4 bytes $5 enc $6 verify $7 remote_ok [$8 is_remote] [$9 ver] [$10 rstatus] [$11 skip]
    BACKUP_TARGET="$1"; TYPE="full"
    _both_tg_record "$2" "$3" "$4" "$5" "$6" "$7" "false" "${8:-false}" "${9:-}" "${10:-}" "${11:-}"
}

echo "== T1: 2 годных → альбом =="
reset_acc
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "12.3M" 12900000 "🔒 Encrypted" "true" "false"
rec bot   lazarus_full.tar.zst       "4.1M"  4300000  "🔒 Encrypted" "true" "false"
_both_tg_flush
[[ $CALL_ALBUM -eq 1 && $CALL_DOC -eq 0 && $CALL_TEXT -eq 0 ]] && ok "ровно 1 альбом" || bad "T1 роутинг: album=$CALL_ALBUM doc=$CALL_DOC text=$CALL_TEXT"
[[ $LAST_ALBUM_FILES -eq 2 ]] && ok "в альбоме 2 файла" || bad "T1 файлов в альбоме: $LAST_ALBUM_FILES"
[[ "$LAST_CAP" == *"Remnawave"* && "$LAST_CAP" == *"RWP Shop"* ]] && ok "подпись перечисляет обе цели" || bad "T1 нет обеих целей в подписи"
[[ "$LAST_CAP" == *"12.3M"* && "$LAST_CAP" == *"4.1M"* ]] && ok "подпись содержит оба размера" || bad "T1 нет размеров"
[[ "$LAST_CAP" == *"tg://emoji?id="* ]] && ok "премиум-эмодзи применены" || bad "T1 нет премиум-эмодзи"
[[ "$LAST_CAP" != *"не бэкап"* ]] && ok "нет фразы «не бэкапится»" || bad "T1 подпись говорит о том что НЕ бэкапится"
[[ "$LAST_CAP" == *"Бэкап создан"* ]] && ok "заголовок «Бэкап создан»" || bad "T1 нет заголовка"
[[ "$LAST_CAP" == *"Encrypted"* ]] && ok "строка шифрования (глобальная)" || bad "T1 нет строки шифрования"

echo "== T1d: восстановленные строки (версия · статус загрузки · пропущенные) =="
reset_acc
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "12.3M" 12900000 "🔒 Encrypted" "true" "true" "false" ""            $'\n☁️ S3: OK' ""
rec bot   lazarus_full.tar.zst       "4.1M"  4300000  "🔒 Encrypted" "true" "true" "false" " | 🏷 v6.6.2" $'\n☁️ S3: OK' $'\n⚠️ Skip: 2 (>100MB)'
_both_tg_flush
[[ "$LAST_CAP" == *"v6.6.2"* ]]  && ok "версия в подписи" || bad "T1d нет версии"
[[ "$LAST_CAP" == *"S3: OK"* ]]  && ok "детальный статус загрузки" || bad "T1d нет статуса загрузки"
[[ "$LAST_CAP" == *"Skip: 2"* ]] && ok "инфо о пропущенных файлах" || bad "T1d нет skip-инфо"
cnt=$(grep -o "S3: OK" <<<"$LAST_CAP" | wc -l | tr -d ' ')
[[ "$cnt" -eq 1 ]] && ok "статус загрузки без дублей (1×)" || bad "T1d дубли статуса загрузки ($cnt)"

echo "== T2: 1 годный (второй >50МБ) → sendDocument =="
reset_acc
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "80M"  84000000 "🔒 Encrypted" "true" "false"
rec bot   lazarus_full.tar.zst       "4.1M" 4300000  "🔒 Encrypted" "true" "false"
_both_tg_flush
[[ $CALL_DOC -eq 1 && $CALL_ALBUM -eq 0 && $CALL_TEXT -eq 0 ]] && ok "ровно 1 sendDocument" || bad "T2 роутинг: album=$CALL_ALBUM doc=$CALL_DOC text=$CALL_TEXT"
[[ "$LAST_CAP" == *"Remnawave"* && "$LAST_CAP" == *"RWP Shop"* ]] && ok "подпись перечисляет обе цели" || bad "T2 нет обеих целей"

echo "== T3: 0 годных (TG_SEND_FILE=false) → текст-сводка =="
reset_acc
TG_SEND_FILE="false"
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "12.3M" 12900000 "🔒 Encrypted" "true" "false"
rec bot   lazarus_full.tar.zst       "4.1M"  4300000  "🔒 Encrypted" "true" "false"
_both_tg_flush
[[ $CALL_TEXT -eq 1 && $CALL_ALBUM -eq 0 && $CALL_DOC -eq 0 ]] && ok "ровно 1 текст-сводка" || bad "T3 роутинг: album=$CALL_ALBUM doc=$CALL_DOC text=$CALL_TEXT"
[[ "$LAST_CAP" == *"Remnawave"* && "$LAST_CAP" == *"RWP Shop"* ]] && ok "сводка перечисляет обе цели" || bad "T3 нет обеих целей"
TG_SEND_FILE="true"

echo "== T4: отложенное удаление (DELETE=any, доставка ok) → файлы удалены =="
reset_acc
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="any"
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "12.3M" 12900000 "🔒 Encrypted" "true" "true"
rec bot   lazarus_full.tar.zst       "4.1M"  4300000  "🔒 Encrypted" "true" "true"
_both_tg_flush
[[ ! -e "$BACKUP_DIR/lazarus_panel_full.tar.zst" && ! -e "$BACKUP_DIR/lazarus_full.tar.zst" ]] \
    && ok "оба локальных файла удалены после доставки" || bad "T4 файлы не удалены (delete-after не применился)"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"

echo "== T4b: удалённая цель (is_remote) НЕ удаляется в both даже при DELETE=any =="
reset_acc
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="any"
: > "$BACKUP_DIR/lazarus_panel_full.tar.zst"; : > "$BACKUP_DIR/lazarus_full.tar.zst"
rec panel lazarus_panel_full.tar.zst "12.3M" 12900000 "🔒 Encrypted" "true" "true" "true"   # is_remote=true
rec bot   lazarus_full.tar.zst       "4.1M"  4300000  "🔒 Encrypted" "true" "true" "false"  # локальная
_both_tg_flush
[[ -e "$BACKUP_DIR/lazarus_panel_full.tar.zst" ]] && ok "удалённая цель — локаль сохранена" || bad "T4b remote-архив удалён (регрессия vs single-remote)"
[[ ! -e "$BACKUP_DIR/lazarus_full.tar.zst" ]] && ok "локальная цель — удалена по правилу any" || bad "T4b локальная цель не удалилась"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"

echo "== T5: _json_escape =="
r=$(_json_escape 'a\b"c
d')
[[ "$r" == 'a\\b\"c\nd' ]] && ok "backslash/quote/newline экранированы" || bad "T5 _json_escape: [$r]"

echo "== T6: _delete_local_after_send — 4 режима (single-режим не сломан) =="
mkf() { : > "$BACKUP_DIR/$1"; }
# false → всегда keep
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"; mkf f_false
_delete_local_after_send "f_false" "true" "true" "true" "false"
[[ -e "$BACKUP_DIR/f_false" ]] && ok "false → сохранён" || bad "T6 false удалил"
# any + оба провалились → keep
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="any"; mkf f_any_no
_delete_local_after_send "f_any_no" "true" "false" "false" "false"
[[ -e "$BACKUP_DIR/f_any_no" ]] && ok "any+провал → сохранён" || bad "T6 any удалил при провале"
# any + tg ok → delete
mkf f_any_yes
_delete_local_after_send "f_any_yes" "true" "true" "false" "false"
[[ ! -e "$BACKUP_DIR/f_any_yes" ]] && ok "any+tg ok → удалён" || bad "T6 any не удалил при доставке"
# remote_only + только tg ok (remote off) → keep
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="remote_only"; REMOTE_STORAGE_TYPE="off"; mkf f_ro
_delete_local_after_send "f_ro" "true" "true" "false" "false"
[[ -e "$BACKUP_DIR/f_ro" ]] && ok "remote_only+remote off → сохранён" || bad "T6 remote_only удалил без remote"
# verify fail → всегда keep даже при any+ok
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="any"; mkf f_vf
_delete_local_after_send "f_vf" "false" "true" "true" "false"
[[ -e "$BACKUP_DIR/f_vf" ]] && ok "verify fail → сохранён" || bad "T6 verify-fail удалил битый архив"
DELETE_LOCAL_AFTER_REMOTE_UPLOAD="false"; REMOTE_STORAGE_TYPE="off"

echo ""
echo "both-notification: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
