#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: lazarus-backup not found"
  exit 1
fi

run_test() {
  local name="$1"
  echo "[TEST] $name"
  shift
  "$@"
}

run_test "restore safety" "$ROOT_DIR/.github/tests/test_restore_safety.sh"

echo "All tests passed"
