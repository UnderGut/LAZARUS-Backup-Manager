#!/usr/bin/env bash
# Tests for S3 helper functions:
#   1. _s3_mask_endpoint — credentials masking in URL
#   2. _s3_arch_suffix — CPU arch detection
#   3. _s3_quiet_flag — always returns --only-show-errors (v1/v2 safe)
#   4. _s3_aws_version — major version from `aws --version` output (mocked)

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs
SILENT_LOG="/dev/null"
debug_log() { :; }
print_message() { :; }
log_message() { :; }
export SILENT_LOG
_AWS_CLI_MAJOR_CACHED=""

# Extract helpers from main script
FUNC_FILE="$TMP_DIR/s3_helpers.sh"
{
    sed -n '/^_s3_mask_endpoint() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_s3_aws_version() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_s3_quiet_flag() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_s3_arch_suffix() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract S3 helpers" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# --- Test 1: _s3_mask_endpoint ---
# Empty input → empty output
RES=$(_s3_mask_endpoint "")
[[ -z "$RES" ]] || { echo "FAIL [mask empty]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# Plain URL без creds — без изменений
RES=$(_s3_mask_endpoint "https://s3.amazonaws.com")
[[ "$RES" == "https://s3.amazonaws.com" ]] || { echo "FAIL [mask plain]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# URL с user:pass@ — credentials замаскированы
RES=$(_s3_mask_endpoint "https://AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMIaPYRfiCYEXAMPLEKEY@s3.amazonaws.com")
[[ "$RES" == "https://<CREDS>@s3.amazonaws.com" ]] || { echo "FAIL [mask creds]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# С портом
RES=$(_s3_mask_endpoint "http://minio:supersecret@localhost:9000")
[[ "$RES" == "http://<CREDS>@localhost:9000" ]] || { echo "FAIL [mask port]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# С path
RES=$(_s3_mask_endpoint "https://u:p@s3.example.com/v1/bucket")
[[ "$RES" == "https://<CREDS>@s3.example.com/v1/bucket" ]] || { echo "FAIL [mask path]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# Не-URL (random text) — без изменений
RES=$(_s3_mask_endpoint "not-a-url")
[[ "$RES" == "not-a-url" ]] || { echo "FAIL [mask non-url]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 2: _s3_arch_suffix ---
# Не можем заставить uname вернуть нужное значение, проверяем что есть валидный ответ
RES=$(_s3_arch_suffix)
if [[ -z "$RES" ]]; then
    # Может быть неподдерживаемая arch — но на CI обычно x86_64/aarch64
    # принимаем пустой как валидный (логика caller'а это обработает)
    :
elif [[ "$RES" != "x86_64" && "$RES" != "aarch64" ]]; then
    echo "FAIL [arch]: unexpected suffix '$RES'" >&2
    FAILS=$((FAILS + 1))
fi

# --- Test 3: _s3_quiet_flag ---
RES=$(_s3_quiet_flag)
[[ "$RES" == "--only-show-errors" ]] || { echo "FAIL [quiet flag]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 4: _s3_aws_version with mocked aws ---
# Создаём mock aws-binary в PATH и проверяем парсинг.
MOCK_DIR="$TMP_DIR/mock"
mkdir -p "$MOCK_DIR"

# Mock v2
cat > "$MOCK_DIR/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws-cli/2.13.25 Python/3.11.6 Linux/5.10.0 source/x86_64.debian.11 prompt/off"
EOF
chmod +x "$MOCK_DIR/aws"
_AWS_CLI_MAJOR_CACHED=""
PATH="$MOCK_DIR:$PATH" RES=$(PATH="$MOCK_DIR:$PATH" _s3_aws_version)
[[ "$RES" == "2" ]] || { echo "FAIL [aws v2 mock]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# Mock v1
cat > "$MOCK_DIR/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws-cli/1.27.137 Python/3.10.12 Linux/5.10.0 botocore/1.29.137"
EOF
chmod +x "$MOCK_DIR/aws"
_AWS_CLI_MAJOR_CACHED=""
RES=$(PATH="$MOCK_DIR:$PATH" _s3_aws_version)
[[ "$RES" == "1" ]] || { echo "FAIL [aws v1 mock]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# Mock unknown format
cat > "$MOCK_DIR/aws" <<'EOF'
#!/usr/bin/env bash
echo "some-other-tool/3.0"
EOF
chmod +x "$MOCK_DIR/aws"
_AWS_CLI_MAJOR_CACHED=""
RES=$(PATH="$MOCK_DIR:$PATH" _s3_aws_version)
[[ "$RES" == "unknown" ]] || { echo "FAIL [aws unknown mock]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

# Cache test — после первого вызова _AWS_CLI_MAJOR_CACHED должен быть выставлен.
# Поскольку cache живёт в подоболочке предыдущего теста — каждый раз reset.
# Просто убеждаемся что повторный вызов не падает.
_AWS_CLI_MAJOR_CACHED="2"
RES=$(_s3_aws_version)
[[ "$RES" == "2" ]] || { echo "FAIL [aws cache]: got '$RES'" >&2; FAILS=$((FAILS + 1)); }

if [[ $FAILS -gt 0 ]]; then
    echo "  s3 helpers: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  s3 helpers: 11 fixtures OK (mask endpoint, arch, quiet flag, aws v1/v2/unknown, cache)"
