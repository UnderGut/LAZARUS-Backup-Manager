#!/usr/bin/env bash
# Tests for first-run / container-discovery audit fixes (v5.1.0):
#   - get_db_name (H5): returns rc=1 + empty stdout if POSTGRES_DB не найден,
#     fallback на $DB_NAME из config.env, никогда silent 'postgres'.
#   - get_db_user (M8): warn если config.env DB_USER явно отличается от .env.
#   - add_candidate (L1): дедуп по (path, bot), не только по path.
#   - read_bot_env: корректно парсит KEY=value и KEY="value", KEY='value'.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
CONFIG_FILE="$TMP_DIR/config.env"
debug_log() { :; }
print_message() { :; }
export SILENT_LOG CONFIG_FILE

# Extract helpers from production script
FUNCS="$TMP_DIR/funcs.sh"
{
    sed -n '/^read_bot_env() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^get_db_user() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^get_db_name() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^add_candidate() {$/,/^}$/p' "$SCRIPT"
} > "$FUNCS"

# shellcheck disable=SC1090
source "$FUNCS"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

# === Test 1: read_bot_env с обычным KEY=value ===
BOT_PATH="$TMP_DIR/bot1"
mkdir -p "$BOT_PATH"
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_USER=botuser
POSTGRES_DB=botdb
SOME_OTHER=irrelevant
EOF
v=$(read_bot_env "POSTGRES_USER")
[[ "$v" == "botuser" ]] && pass || fail "read_bot_env plain: got '$v'"

# === Test 2: read_bot_env с двойными кавычками ===
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_USER="quoted user"
POSTGRES_DB="quoted_db"
EOF
v=$(read_bot_env "POSTGRES_USER")
[[ "$v" == "quoted user" ]] && pass || fail "read_bot_env double-quoted: got '$v'"

# === Test 3: read_bot_env с одинарными кавычками ===
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_DB='single_quoted_db'
EOF
v=$(read_bot_env "POSTGRES_DB")
[[ "$v" == "single_quoted_db" ]] && pass || fail "read_bot_env single-quoted: got '$v'"

# === Test 4: read_bot_env возвращает пусто если .env нет ===
BOT_PATH="$TMP_DIR/missing"
v=$(read_bot_env "POSTGRES_DB")
[[ -z "$v" ]] && pass || fail "read_bot_env missing .env: got '$v'"

# === Test 5: get_db_name возвращает значение из .env ===
BOT_PATH="$TMP_DIR/bot2"
mkdir -p "$BOT_PATH"
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_DB=rwp_shop
EOF
if v=$(get_db_name 2>/dev/null); then
    [[ "$v" == "rwp_shop" ]] && pass || fail "get_db_name from .env: got '$v'"
else
    fail "get_db_name should succeed when POSTGRES_DB present"
fi

# === Test 6: get_db_name — H5 — возвращает rc=1 если POSTGRES_DB нет ===
# (раньше возвращал silent 'postgres' и rc=0 → бэкап пустой системной БД)
BOT_PATH="$TMP_DIR/bot3_no_db"
mkdir -p "$BOT_PATH"
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_USER=foo
EOF
DB_NAME=""
if v=$(get_db_name 2>/dev/null); then
    fail "get_db_name H5: should return rc=1 when POSTGRES_DB missing, got rc=0 v='$v'"
else
    [[ -z "$v" ]] && pass || fail "get_db_name H5: stdout should be empty, got '$v'"
fi

# === Test 7: get_db_name — fallback на DB_NAME из config.env ===
BOT_PATH="$TMP_DIR/bot3_no_db"   # тот же .env без POSTGRES_DB
DB_NAME="custom_override"
if v=$(get_db_name 2>/dev/null); then
    [[ "$v" == "custom_override" ]] && pass || fail "get_db_name DB_NAME fallback: got '$v'"
else
    fail "get_db_name should succeed with DB_NAME set"
fi
DB_NAME=""

# === Test 8: get_db_user — env wins over global DB_USER ===
BOT_PATH="$TMP_DIR/bot4"
mkdir -p "$BOT_PATH"
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_USER=env_user
EOF
DB_USER="config_user"
v=$(get_db_user)
[[ "$v" == "env_user" ]] && pass || fail "get_db_user .env wins: got '$v'"

# === Test 9: get_db_user — fallback на DB_USER если в .env нет ===
BOT_PATH="$TMP_DIR/bot5_no_user"
mkdir -p "$BOT_PATH"
cat > "$BOT_PATH/.env" <<'EOF'
POSTGRES_DB=somedb
EOF
DB_USER="from_config"
v=$(get_db_user)
[[ "$v" == "from_config" ]] && pass || fail "get_db_user fallback: got '$v'"

# === Test 10: add_candidate — дедуп по (path, bot) ===
FOUND_PATHS=()
FOUND_BOTS=()
add_candidate "/opt/bot1" "container_a"
add_candidate "/opt/bot1" "container_a"  # duplicate — игнор
add_candidate "/opt/bot1" "container_b"  # same path, разный bot — добавляем (L1)
add_candidate "/opt/bot2" "container_c"

if [[ ${#FOUND_PATHS[@]} -eq 3 ]]; then
    pass
else
    fail "add_candidate L1: expected 3 entries, got ${#FOUND_PATHS[@]}: ${FOUND_PATHS[*]}"
fi

# === Test 11: add_candidate игнорирует пустой path ===
FOUND_PATHS=()
FOUND_BOTS=()
add_candidate "" "container_x"
[[ ${#FOUND_PATHS[@]} -eq 0 ]] && pass || fail "add_candidate empty: should skip, got ${#FOUND_PATHS[@]}"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
