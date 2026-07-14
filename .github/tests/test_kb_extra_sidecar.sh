#!/usr/bin/env bash
# KB-sidecar (rwp_shop_kb_db) + PANEL_EXTRA_PATHS: полное покрытие инфры одним lazarus.
# (1) _kb_sidecar_active — контракт rc (0 бэкапим / 1 skip / 2 required-но-недоступен) + гарды;
# (2) _kb_db_creds читает user/db из контейнера;
# (3) статическая проводка: config load/save, дамп в bot db+full архивы, restore-детект, extra-sidecar;
# (4) _print_targets_summary показывает «+ KB» когда бот в цели и контейнер запущен.
# Реальный скрипт как lib. Counters n_ok/n_err.

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

# Моки docker/timeout: State.Status и Config.Image управляются MOCK_STATE/MOCK_IMG.
MOCK_STATE="running"; MOCK_IMG="pgvector/pgvector:pg17"
docker() {
    local all="$*"
    case "$all" in
        *"Config.Image"*)          printf '%s\n' "$MOCK_IMG" ;;
        *"State.Status"*)          printf '%s\n' "$MOCK_STATE" ;;
        *"printenv POSTGRES_USER"*) printf 'kb\n' ;;
        *"printenv POSTGRES_DB"*)   printf 'knowledge\n' ;;
        *) return 0 ;;
    esac
}
timeout() { shift; "$@"; }
print_message() { :; }; log_message() { :; }; debug_log() { :; }

# Базовое валидное окружение (бот — цель, kb-контейнер отдельный)
_reset() {
    BACKUP_TARGET="bot"; BOT_KB_BACKUP="auto"; BOT_KB_DB_CONTAINER="rwp_shop_kb_db"
    BOT_TRANSPORT="local"
    DB_CONTAINER_NAME="rwp_shop_db"; PANEL_DB_CONTAINER="remnawave-db"; PANEL_BILLING_DB_CONTAINER="infra-billing-db"
    MOCK_STATE="running"; MOCK_IMG="pgvector/pgvector:pg17"
}

# === 1) _kb_sidecar_active — контракт ===
_reset; _kb_sidecar_active; [[ $? -eq 0 ]] && ok || bad "happy path (бот+kb запущен) должен дать rc=0"
_reset; BACKUP_TARGET="panel"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "target=panel → rc=1 (KB только для бота)"
_reset; BOT_KB_BACKUP="false"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "BOT_KB_BACKUP=false → rc=1"
_reset; BOT_KB_DB_CONTAINER=""; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "пустой контейнер (auto) → rc=1"
_reset; BOT_KB_DB_CONTAINER=""; BOT_KB_BACKUP="true"; _kb_sidecar_active; [[ $? -eq 2 ]] && ok || bad "пустой контейнер (true) → rc=2"
# ГАРД: совпадение с главной БД бота
_reset; BOT_KB_DB_CONTAINER="rwp_shop_db"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "kb==главная БД бота (auto) → rc=1 (гард)"
_reset; BOT_KB_DB_CONTAINER="rwp_shop_db"; BOT_KB_BACKUP="true"; _kb_sidecar_active; [[ $? -eq 2 ]] && ok || bad "kb==главная БД бота (true) → rc=2 (гард)"
# ГАРД: совпадение с БД панели / billing
_reset; BOT_KB_DB_CONTAINER="remnawave-db"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "kb==БД панели → rc=1 (гард)"
_reset; BOT_KB_DB_CONTAINER="infra-billing-db"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "kb==БД billing → rc=1 (гард)"
# ГАРД: не БД-образ
_reset; MOCK_IMG="nginx:1.31"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "не-БД образ (auto) → rc=1 (гард)"
_reset; MOCK_IMG="nginx:1.31"; BOT_KB_BACKUP="true"; _kb_sidecar_active; [[ $? -eq 2 ]] && ok || bad "не-БД образ (true) → rc=2 (гард)"
# не запущен
_reset; MOCK_STATE="exited"; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "не запущен (auto) → rc=1"
_reset; MOCK_STATE="exited"; BOT_KB_BACKUP="true"; _kb_sidecar_active; [[ $? -eq 2 ]] && ok || bad "не запущен (true) → rc=2"
# удалённый бот (ssh)
_transport_of() { echo ssh; }
_reset; _kb_sidecar_active; [[ $? -eq 1 ]] && ok || bad "бот ssh (auto) → rc=1 (не поддержан)"
_reset; BOT_KB_BACKUP="true"; _kb_sidecar_active; [[ $? -eq 2 ]] && ok || bad "бот ssh (true) → rc=2"
unset -f _transport_of

# === 2) _kb_db_creds ===
_reset; [[ "$(_kb_db_creds)" == "kb knowledge" ]] && ok || bad "_kb_db_creds должен вернуть 'kb knowledge', получил '$(_kb_db_creds)'"

# === 3) _print_targets_summary: строка «+ KB» ===
_reset; BACKUP_TARGET="panel"; BACKUP_SECONDARY="bot"
_target_status_line() { :; }; _hrule() { :; }; _transport_of() { echo local; }
PANEL_BILLING_BACKUP="false"; PANEL_EXTRA_PATHS=""
out=$(_print_targets_summary 2>&1)
printf '%s' "$out" | grep -q "KB ИИ-саппорта" && ok || bad "summary должен показать '+ KB' когда бот в цели и kb запущен"
unset -f _transport_of _target_status_line _hrule

# === 4) Статическая проводка исходника ===
grep -qE 'BOT_KB_DB_CONTAINER\) BOT_KB_DB_CONTAINER=' "$SCRIPT" && ok || bad "loader должен читать BOT_KB_DB_CONTAINER"
grep -qE '_cfg_if_nondefault "BOT_KB_DB_CONTAINER"' "$SCRIPT" && ok || bad "save_config должен писать BOT_KB_DB_CONTAINER"
grep -qE 'FILE_KB="kb_\$\{TIMESTAMP\}' "$SCRIPT" && ok || bad "должен быть KB-дамп (FILE_KB=kb_...)"
grep -qE '_db_inputs\+=\("\$FILE_KB"\)' "$SCRIPT" && ok || bad "FILE_KB должен добавляться в db_only архив"
grep -qE '_combine_inputs\+=\("\$FILE_KB"\)' "$SCRIPT" && ok || bad "FILE_KB должен добавляться в full архив"
grep -qE 'KB_DUMP=\$\(find' "$SCRIPT" && ok || bad "restore должен детектить kb_*.sql (KB_DUMP)"
grep -qE 'FILE_EXTRA="extra_\$\{TIMESTAMP\}' "$SCRIPT" && ok || bad "должен быть extra-sidecar (FILE_EXTRA=extra_...)"
grep -qE 'tar \$_tar_compress_args -cf "\$BACKUP_DIR/\$FILE_EXTRA" -C / ' "$SCRIPT" && ok || bad "extra-sidecar должен tar'ить относительно /"
grep -qE 'EXTRA_ARC=\$\(find' "$SCRIPT" && ok || bad "restore должен детектить extra_*.tar (EXTRA_ARC)"
# БЕЗОПАСНОСТЬ restore extra: НЕ извлекать прямо в / (untrusted-storage RCE); validate + allowlist rsync
grep -qE 'tar \$_ex_args -xf "\$EXTRA_ARC" -C / ' "$SCRIPT" \
    && bad "extra-restore НЕ должен извлекать архив прямо в / (path-traversal/RCE)" || ok
grep -qE 'validate_tar_safety "\$EXTRA_ARC"' "$SCRIPT" && ok || bad "extra-restore должен звать validate_tar_safety на EXTRA_ARC"
grep -qE 'rsync -a --safe-links "\$_ex_stage' "$SCRIPT" && ok || bad "extra-restore должен копировать через rsync --safe-links из STAGE (allowlist)"
# заглушка RESERVED убрана (PANEL_EXTRA_PATHS теперь работает)
grep -q 'зарезервирован и пока ИГНОРИРУЕТСЯ' "$SCRIPT" \
    && bad "старая RESERVED-заглушка PANEL_EXTRA_PATHS должна быть удалена" || ok
# KB-импорт в restore имеет гард против главной БД
grep -qE 'kb restore guard: collides with main db' "$SCRIPT" && ok || bad "KB-restore должен иметь гард против главной БД"
# KB-импорт обёрнут в критическую секцию (Ctrl+C-защита)
grep -qE '_CRITICAL_SECTION=1   # опасное окно импорта KB' "$SCRIPT" && ok || bad "KB-импорт должен ставить _CRITICAL_SECTION=1"

# === 6) «Доп. компоненты» — вторичность billing/KB (панель → бот → опционально это) ===
# 6a) отдельный раздел 8 в категориях настроек + view addons
grep -qE '8\. Доп\. компоненты' "$SCRIPT" && ok || bad "категории настроек должны содержать раздел 8 «Доп. компоненты»"
grep -qE '8\) _sview=addons' "$SCRIPT" && ok || bad "выбор 8 должен открывать _sview=addons"
grep -qE '_sview" == "addons"' "$SCRIPT" && ok || bad "должен существовать рендер раздела addons"
# 6b) пункт 14 (KB) — зеркальный обработчик п.13 (billing), с гардом «бот среди целей»
grep -qE '14\) # KB ИИ-саппорта' "$SCRIPT" && ok || bad "должен быть обработчик 14 (KB: режим+контейнер)"
grep -qE 'BOT_KB_BACKUP="false" ;;' "$SCRIPT" && ok || bad "обработчик 14 должен уметь выключать KB"
# 6c) billing больше НЕ живёт строкой в разделе general (переехал в addons)
_gen_start=$(grep -n '_sview" == "general"' "$SCRIPT" | head -1 | cut -d: -f1)
_gen_end=$(grep -n '# /general' "$SCRIPT" | head -1 | cut -d: -f1)
sed -n "${_gen_start},${_gen_end}p" "$SCRIPT" | grep -q 'Infra-billing БД' \
    && bad "billing-строка должна переехать из general в addons" || ok
# 6d) first-run: явный вопрос про обнаруженные доп. компоненты (Y/n), отказ = false
grep -qE 'бэкапить вместе с панелью\? \(Y/n\)' "$SCRIPT" && ok || bad "first-run должен спрашивать про infra-billing"
grep -qE 'бэкапить вместе с ботом\? \(Y/n\)' "$SCRIPT" && ok || bad "first-run должен спрашивать про KB"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
