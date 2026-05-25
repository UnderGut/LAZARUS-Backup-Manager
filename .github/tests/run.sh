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

run_test "restore safety"        "$ROOT_DIR/.github/tests/test_restore_safety.sh"
run_test "password validation"   "$ROOT_DIR/.github/tests/test_password_validation.sh"
run_test "skipped report"        "$ROOT_DIR/.github/tests/test_skipped_report.sh"
run_test "version compare"       "$ROOT_DIR/.github/tests/test_version_compare.sh"
run_test "hmac envelope"         "$ROOT_DIR/.github/tests/test_hmac_envelope.sh"
run_test "s3 helpers"            "$ROOT_DIR/.github/tests/test_s3_helpers.sh"
run_test "timeout helpers"       "$ROOT_DIR/.github/tests/test_timeout_helpers.sh"

echo "All tests passed"
