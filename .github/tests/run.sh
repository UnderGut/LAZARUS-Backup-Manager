#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: lazarus-backup not found"
  exit 1
fi

# Glob-цикл вместо ручного списка: раньше run.sh запускал 11 из 29 тестов и «зелёный локальный
# прогон» не исполнял ни одной проверки identity/guard-слоя — дрейф с ci.yml исключён навсегда.
fail=0
for t in "$ROOT_DIR"/.github/tests/test_*.sh; do
  name=$(basename "$t" .sh); name="${name#test_}"; name="${name//_/ }"
  echo "[TEST] $name"
  if ! bash "$t"; then
    echo "[FAIL] $name"
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "All tests passed"
