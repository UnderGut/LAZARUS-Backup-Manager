#!/usr/bin/env bash
# Регресс 6.0.5: ложное «ciphertext extract INCOMPLETE» на ЦЕЛОМ v2-архиве.
# Было `tail -c +5 файл | head -c N`: head закрывал трубу, прочитав N байт шифротекста, и если
# 32 байта MAC tail дописывал отдельной записью (буфер 8 КиБ; остаток (size-4) mod 8192 в 1..32 —
# ~1 архив из 256), tail получал SIGPIPE (rc 141) → verify «повреждён/не проверен», архив не уходил
# в хранилище, а restore в 6.0.4 обрывался «расшифровка не выполнена». На реальном архиве панели
# 27.09.2026 гонка воспроизводилась 385 раз из 400. Стало `head -c <4+N> файл | tail -c +5`.
# Проверяем: (1) порядок в коде; (2) архив ровно в окне гонки многократно проходит verify и decrypt
# с байтовым совпадением; (3) обычные размеры не пострадали.
# Счётчики n_ok/n_err (НЕ PASS= — скраббер секретов переписывает его на диске).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
T=$(mktemp -d "${TMPDIR:-/tmp}/lz605pipe.XXXXXX")

n_ok=0; n_err=0; n_skip=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

export LAZARUS_LIB=true
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1 || { echo "FAIL: could not source script as lib"; exit 1; }
trap 'rm -rf "$T"' EXIT
SILENT_LOG="$T/silent.log"; : > "$SILENT_LOG"
LOG_FILE="$T/lazarus.log"; : > "$LOG_FILE"
TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
send_telegram_notification() { :; }
debug_log() { :; }

# ============================================================ 1) порядок в конвейере
[[ $(grep -c 'tail -c +5 "$file" 2>/dev/null | head -c' "$SCRIPT") -eq 0 && $(grep -c 'tail -c +5 "$infile" 2>/dev/null | head -c' "$SCRIPT") -eq 0 ]] \
    && ok || bad "1a не осталось «tail -c +5 … | head -c» (tail с ранним закрытием трубы)"
[[ $(grep -c 'head -c "$((cipher_len + 4))" "$file" 2>/dev/null | tail -c +5' "$SCRIPT") -eq 1 ]] && ok || bad "1b verify: head — производитель"
[[ $(grep -c 'head -c "$((cipher_len + 4))" "$infile" 2>/dev/null | tail -c +5' "$SCRIPT") -eq 1 ]] && ok || bad "1c decrypt: head — производитель"

# openssl с -pbkdf2 и -pass env: (Git Bash на части машин не умеет — тогда поведенческую часть пропускаем)
PW='pipe-race-pw-605'
if ! printf 'x' | LAZARUS_ENC_PW="$PW" openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -salt -pass env:LAZARUS_ENC_PW > /dev/null 2>&1; then
    echo "SKIP: openssl без -pbkdf2/-pass env — поведенческие проверки пропущены"
    n_skip=$(( n_skip + 1 ))
else
# ============================================================ 2) архив ровно в окне гонки
# Подбираем размер открытого текста так, чтобы (size-4) mod 8192 попал в 1..32 (последняя запись
# tail — только байты MAC). Шаг открытого текста 16 байт двигает шифротекст на 16.
found=""; rem=0
for n in $(seq 20000 16 30000); do
    head -c "$n" /dev/urandom > "$T/plain.bin"
    _hmac_envelope_create "$T/plain.bin" "$T/win.enc" "$PW" > /dev/null 2>&1 || continue
    s=$(stat -c%s "$T/win.enc"); rem=$(( (s - 4) % 8192 ))
    if (( rem >= 1 && rem <= 32 )); then found=1; break; fi
done
[[ -n "$found" ]] && ok || bad "2pre не удалось подобрать архив в окне гонки"
if [[ -n "$found" ]]; then
    echo "  архив в окне гонки: $(stat -c%s "$T/win.enc") байт, остаток (size-4) mod 8192 = $rem"
    vbad=0; dbad=0; cbad=0
    for i in $(seq 1 60); do
        _hmac_envelope_verify "$T/win.enc" "$PW" > /dev/null 2>&1 || vbad=$(( vbad + 1 ))
        rm -f "$T/out.bin"
        if _hmac_envelope_decrypt "$T/win.enc" "$T/out.bin" "$PW" > /dev/null 2>&1; then
            cmp -s "$T/plain.bin" "$T/out.bin" || cbad=$(( cbad + 1 ))
        else
            dbad=$(( dbad + 1 ))
        fi
    done
    [[ $vbad -eq 0 ]] && ok || bad "2a verify архива в окне гонки: провалов $vbad/60"
    [[ $dbad -eq 0 ]] && ok || bad "2b decrypt архива в окне гонки: провалов $dbad/60"
    [[ $cbad -eq 0 ]] && ok || bad "2c расшифровка байт-в-байт: расхождений $cbad"
    grep -q 'INCOMPLETE' "$LOG_FILE" && bad "2d в логе ложное INCOMPLETE: $(grep INCOMPLETE "$LOG_FILE" | head -1)" || ok
fi

# ============================================================ 3) обычные размеры
for n in 1 15 16 17 4095 8192 100000; do
    head -c "$n" /dev/urandom > "$T/p$n.bin"
    rm -f "$T/o$n.bin"
    if _hmac_envelope_create "$T/p$n.bin" "$T/e$n.enc" "$PW" > /dev/null 2>&1 \
       && _hmac_envelope_verify "$T/e$n.enc" "$PW" > /dev/null 2>&1 \
       && _hmac_envelope_decrypt "$T/e$n.enc" "$T/o$n.bin" "$PW" > /dev/null 2>&1 \
       && cmp -s "$T/p$n.bin" "$T/o$n.bin"; then ok; else bad "3 размер $n: create/verify/decrypt/cmp"; fi
done
# неверный пароль и порча — по-прежнему rc=1 (не «I/O»)
_hmac_envelope_decrypt "$T/e100000.enc" "$T/x.bin" "wrong-pw" > /dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok || bad "3w неверный пароль → rc=1 (got $rc)"
cp "$T/e100000.enc" "$T/bad.enc"; printf 'Z' | dd of="$T/bad.enc" bs=1 seek=5000 conv=notrunc status=none 2>/dev/null
_hmac_envelope_decrypt "$T/bad.enc" "$T/x.bin" "$PW" > /dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok || bad "3x порча байта → rc=1 (got $rc)"
fi

echo "fix605-pipe: ok=$n_ok err=$n_err skip=$n_skip"
[[ $n_err -eq 0 ]]
