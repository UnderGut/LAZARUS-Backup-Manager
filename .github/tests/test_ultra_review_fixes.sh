#!/usr/bin/env bash
# Регресс-локи на находки ultra-ревью (3 HIGH + 7 LOW). Статические проверки исходника —
# поведенческие части (docker/psql/ssh) недоступны в CI, поэтому проверяем инвариантность кода.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

# === HIGH1: restore preamble-return поднимает стек обратно (не оставляет offline) ===
grep -qE '^_restore_abort\(\)' "$SCRIPT" && ok || bad "HIGH1: должен быть хелпер _restore_abort"
# helper поднимает стек + снимает критсекцию
_ra=$(sed -n '/^_restore_abort() {/,/^}/p' "$SCRIPT")
grep -q 'docker compose up -d' <<<"$_ra" && ok || bad "HIGH1: _restore_abort должен поднимать стек (docker compose up -d)"
grep -q '_CRITICAL_SECTION=0' <<<"$_ra" && ok || bad "HIGH1: _restore_abort должен снимать _CRITICAL_SECTION"
# все preamble-гарды импорта идут через _restore_abort, а не голый rm+return
grep -qE 'ensure_bot_path; then _restore_abort' "$SCRIPT" && ok || bad "HIGH1: ensure_bot_path fail → _restore_abort"
grep -qE 'get_db_name.*then' "$SCRIPT" && grep -q '_restore_abort' "$SCRIPT" && ok || bad "HIGH1: get_db_name/assert_safe_db_target fail → _restore_abort"
# не осталось голых 'rm -rf "$TMP_DIR"; return 1' в этих 5 гардах (проверяем что _restore_abort встречается >=5 раз в execute_restore)
_rac=$(grep -c '_restore_abort' "$SCRIPT")
[[ "$_rac" -ge 6 ]] && ok || bad "HIGH1: ждали >=6 упоминаний _restore_abort (def + 5 гардов), нашли $_rac"

# === HIGH2: раздел misc достижим — ветки misc:1)/misc:2), голых 25)/26) нет ===
grep -qE '^\s+misc:1\)' "$SCRIPT" && ok || bad "HIGH2: ветка misc:1) (Бэкап логов) должна существовать"
grep -qE '^\s+misc:2\)' "$SCRIPT" && ok || bad "HIGH2: ветка misc:2) (Компрессия) должна существовать"
grep -qE '^\s+25\)' "$SCRIPT" && bad "HIGH2: голая 25) недостижима в case раздел:номер — должна быть misc:1)" || ok
grep -qE '^\s+26\)' "$SCRIPT" && bad "HIGH2: голая 26) недостижима — должна быть misc:2)" || ok

# === HIGH3: remote-бэкап регистрирует plaintext-дампы как sensitive-tmp ===
grep -qE 'register_sensitive_tmp "\$BACKUP_DIR/\$FILE_DB"' "$SCRIPT" && ok || bad "HIGH3: FILE_DB (remote) должен register_sensitive_tmp"
grep -qE 'register_sensitive_tmp "\$BACKUP_DIR/\$FILE_GLOBALS"' "$SCRIPT" && ok || bad "HIGH3: FILE_GLOBALS (remote) должен register_sensitive_tmp"
grep -qE 'register_sensitive_tmp "\$BACKUP_DIR/\$FILE_BILLING"' "$SCRIPT" && ok || bad "HIGH3: FILE_BILLING (remote) должен register_sensitive_tmp"
grep -q 'register_sensitive_tmp "\$_plain_final"' "$SCRIPT" && ok || bad "HIGH3: plaintext-combine (_plain_final) должен register + unregister после шифрования"
grep -q 'unregister_sensitive_tmp "\$_plain_final"' "$SCRIPT" && ok || bad "HIGH3: _plain_final должен unregister-иться (иначе cleanup сотрёт намеренный unencrypted-артефакт)"

# === LOW: cleanup_on_exit затирает (shred), а не просто rm ===
_ce=$(sed -n '/^cleanup_on_exit() {/,/^}/p' "$SCRIPT")
grep -q 'shred -fu' <<<"$_ce" && ok || bad "LOW: cleanup_on_exit должен shred'ить sensitive-файлы"
grep -q 'command -v shred' <<<"$_ce" && ok || bad "LOW: cleanup_on_exit должен иметь rm-fallback при отсутствии shred"

# === LOW: _rdir экранирован (_shq) в удалённой du; гейт места учитывает БД ===
grep -qE '_rdir_q=\$\(_shq "\$_rdir"\)' "$SCRIPT" && ok || bad "LOW: _rdir должен экранироваться _shq для удалённого shell"
grep -qE 'du -sm \$_rdir_q' "$SCRIPT" && ok || bad "LOW: удалённая du должна использовать _rdir_q (экранированный)"
grep -q '_dbsize_mb' "$SCRIPT" && ok || bad "LOW: гейт места переноса должен учитывать размер БД (_dbsize_mb)"
grep -qE '_need_mb=\$\(\( _rsize_mb \+ _dbsize_mb \)\)' "$SCRIPT" && ok || bad "LOW: need = файлы + БД"

# === LOW: авто-детект DB-контейнера на источнике ===
grep -q 'com.docker.compose.project.working_dir=\$_rdir_q' "$SCRIPT" && ok || bad "LOW: авто-детект DB-контейнера источника по compose-label"

# === LOW: _post_backup_prompt db_only не принимает скрытый «1» ===
grep -qE 'if \[\[ "\$_show_top" -eq 1 \]\]; then _show_top_in_archive' "$SCRIPT" && ok || bad "LOW: ветка 1|77 должна проверять _show_top"

# === LOW: S3 verify-skip взводит REMOTE_UPLOAD_SIZE_UNVERIFIED ===
# в ветке '*)' (head-object недоступен) флаг должен ставиться в true
_s3=$(awk '/head-object недоступен \(нет ListBucket/,/return 0/' "$SCRIPT")
grep -q 'REMOTE_UPLOAD_SIZE_UNVERIFIED="true"' <<<"$_s3" && ok || bad "LOW: S3 verify-skip должен ставить REMOTE_UPLOAD_SIZE_UNVERIFIED=true"

# === LOW: SSHPASS RETURN-trap сохраняется/восстанавливается ===
grep -q '_mig_prev_return_trap=\$(trap -p RETURN)' "$SCRIPT" && ok || bad "LOW: panel_migrate_in должен сохранять прежний RETURN-trap"
grep -q 'eval "\${_mig_prev_return_trap:-trap - RETURN}"' "$SCRIPT" && ok || bad "LOW: _mig_restore_env должен восстанавливать RETURN-trap"

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
