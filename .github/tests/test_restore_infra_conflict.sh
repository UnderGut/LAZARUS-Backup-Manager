#!/usr/bin/env bash
# Конфликт версий при restore: на сервере СВЕЖАЯ панель (новый docker-compose),
# архив — со старой. Проверяем:
# (1) _restore_rsync_flags: обычный режим = --delete + exclude .env;
#     RESTORE_KEEP_INFRA=1 = БЕЗ --delete + exclude всех compose-имён и .env;
# (2) rsync-поведение keep-infra на реальных файлах: compose/.env живые НЕ трогаются,
#     новые файлы свежей версии НЕ удаляются, остальное приходит из архива;
# (3) статика: вопрос конфликта стоит ДО файлового блока, выбор 1 → MODE=db_only,
#     полная замена бэкапит live-инфру в BACKUP_DIR (вне каталога цели);
# (4) migrate-интро перечисляет 3 нужные вещи (IP · порт · пароль).
# Counters n_ok/n_err.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
SILENT_LOG="$TMP_DIR/silent.log"; DEBUG_MODE=false; IS_INTERACTIVE=false
RESTORE_INCLUDE_ENV="false"

# === 1) _restore_rsync_flags — контракт флагов ===
declare -a _RS_DEL _RS_EXCL
RESTORE_KEEP_INFRA=0
_restore_rsync_flags
[[ "${_RS_DEL[*]}" == "--delete" ]] && ok || bad "обычный режим: ждали --delete, got '${_RS_DEL[*]}'"
[[ "${_RS_EXCL[*]}" == *".env"* ]] && ok || bad "обычный режим: .env должен быть в exclude"
[[ "${_RS_EXCL[*]}" == *"docker-compose"* ]] && bad "обычный режим: compose НЕ должен исключаться" || ok

RESTORE_KEEP_INFRA=1
_restore_rsync_flags
[[ ${#_RS_DEL[@]} -eq 0 ]] && ok || bad "keep-infra: --delete должен быть снят (got '${_RS_DEL[*]}')"
for _n in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
    [[ "${_RS_EXCL[*]}" == *"$_n"* ]] && ok || bad "keep-infra: '$_n' должен быть в exclude"
done
# keep-infra исключает .env даже при RESTORE_INCLUDE_ENV=true (инфра важнее флага)
RESTORE_INCLUDE_ENV="true"; _restore_rsync_flags
[[ "${_RS_EXCL[*]}" == *".env"* ]] && ok || bad "keep-infra: .env обязан исключаться даже при RESTORE_INCLUDE_ENV=true"
RESTORE_INCLUDE_ENV="false"; RESTORE_KEEP_INFRA=0

# === 2) Поведение rsync keep-infra на реальных файлах ===
if command -v rsync >/dev/null 2>&1; then
    SRC="$TMP_DIR/arc"; DST="$TMP_DIR/live"
    mkdir -p "$SRC" "$DST"
    # архив (старая версия): старый compose, старый .env, данные, файл only-in-archive
    printf 'old-compose\n' > "$SRC/docker-compose.yml"
    printf 'old-env\n'     > "$SRC/.env"
    printf 'user-data\n'   > "$SRC/data.json"
    # live (свежая версия): новый compose/.env, файл появившийся в новой версии.
    # Контент НАМЕРЕННО другой длины: rsync -a квик-чек (size+mtime) иначе счёл бы
    # файлы одинаковыми (артефакт теста; в реальности версии отличаются размером).
    printf 'NEW-compose-longer-v2\n' > "$DST/docker-compose.yml"
    printf 'NEW-env-longer-v2\n'     > "$DST/.env"
    printf 'new-feature\n'           > "$DST/new_v2_file.conf"
    RESTORE_KEEP_INFRA=1
    restore_rsync_apply "$SRC" "$DST" >/dev/null 2>&1
    [[ "$(cat "$DST/docker-compose.yml")" == "NEW-compose-longer-v2" ]] && ok || bad "keep-infra: live compose затёрт архивным"
    [[ "$(cat "$DST/.env")" == "NEW-env-longer-v2" ]] && ok || bad "keep-infra: live .env затёрт архивным"
    [[ -f "$DST/new_v2_file.conf" ]] && ok || bad "keep-infra: файл новой версии УДАЛЁН (--delete прорвался)"
    [[ "$(cat "$DST/data.json" 2>/dev/null)" == "user-data" ]] && ok || bad "keep-infra: данные из архива не пришли"
    # обычный режим: compose затирается, лишние файлы удаляются (прежнее поведение)
    RESTORE_KEEP_INFRA=0
    restore_rsync_apply "$SRC" "$DST" >/dev/null 2>&1
    [[ "$(cat "$DST/docker-compose.yml")" == "old-compose" ]] && ok || bad "обычный режим: compose должен приходить из архива"
    [[ ! -f "$DST/new_v2_file.conf" ]] && ok || bad "обычный режим: --delete должен убрать лишние файлы"
    [[ "$(cat "$DST/.env")" == "NEW-env-longer-v2" ]] && ok || bad "обычный режим: .env защищён по умолчанию (RESTORE_INCLUDE_ENV=false)"
else
    echo "SKIP: rsync недоступен — поведенческая часть пропущена"
fi

# === 3) Статика: проводка конфликта в restore ===
grep -qE 'docker-compose в архиве ОТЛИЧАЕТСЯ' "$SCRIPT" && ok || bad "restore должен предупреждать о конфликте compose"
# вопрос стоит ДО файлового блока (строка с WARN раньше первого 'MODE" == "full" || "$MODE" == "files_only')
_w=$(grep -n 'docker-compose в архиве ОТЛИЧАЕТСЯ' "$SCRIPT" | head -1 | cut -d: -f1)
_f=$(grep -n '"\$MODE" == "full" || "\$MODE" == "files_only"' "$SCRIPT" | head -1 | cut -d: -f1)
[[ -n "$_w" && -n "$_f" && "$_w" -lt "$_f" ]] && ok || bad "конфликт-вопрос должен быть ДО файлового блока (w=$_w f=$_f)"
# выбор 1 → db_only
grep -qE 'MODE="db_only"$' "$SCRIPT" && ok || bad "выбор «только данные» должен переводить MODE в db_only"
# полная замена бэкапит live-инфру в BACKUP_DIR
grep -qE 'infra_replaced_' "$SCRIPT" && ok || bad "полная замена должна бэкапить live compose/.env (infra_replaced_)"
# compose из архива читается без распаковки (tar -xO)
grep -qE 'tar \$_pk_args -xOf "\$DIR_ARC"' "$SCRIPT" && ok || bad "peek compose из архива должен идти через tar -xO"

# === 4) Migrate-интро: 3 нужные вещи ===
grep -qE 'Понадобятся всего 3 вещи' "$SCRIPT" && ok || bad "migrate-интро должно перечислять 3 нужные вещи"
grep -qE 'IP-адрес' "$SCRIPT" && ok || bad "migrate-интро: IP-адрес"
grep -qE 'Пароль root' "$SCRIPT" && ok || bad "migrate-интро: пароль root"

# === 5) L11 (находки 12/28/33): files_only-restore распаковывает combine, а не трактует его как dir ===
# restore должен искать inner dir-член ТАКЖЕ по bot_files_* (имя из files-бэкапа), не только dir_*.
grep -qE 'name "bot_files_\*\.tar\.gz"' "$SCRIPT" && ok || bad "L11: DIR_ARC find должен ловить bot_files_*.tar.gz (files-архив)"
# старого безусловного 'files_only → DIR_ARC=WORK_FILE' быть не должно — только legacy-fallback при пустом DIR_ARC
grep -qE 'MODE" == "files_only" && -z "\$DIR_ARC"' "$SCRIPT" && ok || bad "L11: files_only должен ставить DIR_ARC=WORK_FILE лишь как legacy-fallback (при пустом inner)"
# конфликт-гард и extra-restore теперь достижимы для files-архива (гейт != db_only, а не == full)
grep -qE 'MODE" != "db_only" && -n "\$DIR_ARC"' "$SCRIPT" && ok || bad "L11: конфликт-гард должен работать для files_only (гейт по != db_only)"

# === 6) #3: db_only останавливает приложение на импорт и перезапускает стек (свежий пул A039) ===
grep -qE 'db_only" && -n "\$\{DB_SERVICE_NAME' "$SCRIPT" && ok || bad "#3: db_only должен останавливать приложение (сервисы кроме БД) на время импорта"
grep -qE 'docker compose stop "\$\{_app_svc' "$SCRIPT" && ok || bad "#3: db_only должен docker compose stop не-БД сервисы"
grep -qE '_dbonly_app_stopped' "$SCRIPT" && ok || bad "#3: должен трекать факт остановки приложения для последующего перезапуска"
grep -qE 'свежий пул после импорта' "$SCRIPT" && ok || bad "#3: после db_only-импорта стек поднимается заново (fresh pool)"

# === 7) #15: «точная копия» реально возвращает .env из архива ===
# при полной замене (KEEP_INFRA=0) rsync-exclude .env снимается, живой .env заранее в infra_replaced_
grep -qE 'RESTORE_INCLUDE_ENV="true"' "$SCRIPT" && ok || bad "#15: полная замена должна снимать exclude .env (RESTORE_INCLUDE_ENV=true)"
# и это ЛОКАЛЬНАЯ тень (не течёт в следующий restore сессии)
grep -qE 'local RESTORE_INCLUDE_ENV=' "$SCRIPT" && ok || bad "#15: RESTORE_INCLUDE_ENV должна быть локальной тенью в execute_restore"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
