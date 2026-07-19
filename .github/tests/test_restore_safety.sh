#!/usr/bin/env bash
# Tests for validate_tar_safety() from lazarus-backup.
# Verifies that:
#   1. Safe archives pass validation.
#   2. Archives with absolute or '..' path components are rejected.
#   3. №11 degrade: SAFE relative in-tree symlink/hardlink are ALLOWED (legacy backups
#      with symlinks stay restorable), while absolute-target / '..'-escaping links and
#      device/socket/fifo entries are still rejected.
#
# The functions are extracted via sed and sourced into the test shell so the
# real production logic is exercised (no re-implementation drift).
# Link fixtures are crafted with python tarfile (works without FS symlink support,
# e.g. git-bash on Windows); skipped if python is unavailable.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stubs required by validate_tar_safety
SILENT_LOG="$TMP_DIR/silent.log"
: > "$SILENT_LOG"
print_message() { :; }
log_message() { :; }
export SILENT_LOG

# Extract validate_tar_safety + его зависимости (_compress_detect_format для формат-детекта,
# _tar_link_target_safe — №11 helper) и подключаем. Без _compress_detect_format функция
# работала бы деградированно («command not found») — детект формата возвращал бы пусто.
FUNC_FILE="$TMP_DIR/validate_tar_safety.sh"
{
    sed -n '/^_compress_detect_format() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^_tar_link_target_safe() {$/,/^}$/p' "$SCRIPT"
    echo ""
    sed -n '/^validate_tar_safety() {$/,/^}$/p' "$SCRIPT"
} > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]] || ! grep -q '_tar_link_target_safe()' "$FUNC_FILE"; then
    echo "FAIL: could not extract validate_tar_safety/_tar_link_target_safe from $SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

assert_pass() {
    local archive="$1"
    local reason="${2:-}"
    local list="$TMP_DIR/list.$RANDOM"
    if ! validate_tar_safety "$archive" "$list"; then
        echo "FAIL: expected $archive to pass validation ${reason:+($reason)}" >&2
        exit 1
    fi
}

assert_fail() {
    local archive="$1"
    local reason="$2"
    local list="$TMP_DIR/list.$RANDOM"
    if validate_tar_safety "$archive" "$list"; then
        echo "FAIL: expected $archive to FAIL validation ($reason)" >&2
        exit 1
    fi
}

# --- Fixture 1: safe archive ---
SAFE_DIR="$TMP_DIR/safe"
mkdir -p "$SAFE_DIR/inner"
echo "ok" > "$SAFE_DIR/inner/file.txt"
SAFE_TGZ="$TMP_DIR/safe.tgz"
tar -C "$TMP_DIR" -czf "$SAFE_TGZ" safe
assert_pass "$SAFE_TGZ"

# --- Fixture 2: traversal archive (path begins with '../') ---
# Bare 'tar -czf ../evil ...' triggers GNU tar's leading-..-strip on archive
# CREATION, so we use --transform to inject the unsafe prefix into stored names.
EVIL_TGZ="$TMP_DIR/evil.tgz"
tar -C "$TMP_DIR" --transform 's,^safe,../safe,' -czf "$EVIL_TGZ" safe
assert_fail "$EVIL_TGZ" "path traversal '..'"

# --- Fixture 3: absolute path archive ---
ABS_TGZ="$TMP_DIR/abs.tgz"
tar -C "$TMP_DIR" --transform 's,^safe,/etc/safe,' -czf "$ABS_TGZ" safe -P
assert_fail "$ABS_TGZ" "absolute path"

# --- Fixtures 4-9 (№11): links crafted via python tarfile (no FS symlink needed) ---
PY=$(command -v python3 || command -v python || true)
if [[ -z "$PY" ]]; then
    echo "  restore safety: 3 fixtures OK (link fixtures skipped: no python)"
    exit 0
fi

mk_link_tar() {
    # $1 = outfile, $2 = kind
    "$PY" - "$1" "$2" <<'PYEOF'
import tarfile, io, sys
out, kind = sys.argv[1], sys.argv[2]
tf = tarfile.open(out, "w:gz", format=tarfile.GNU_FORMAT)
data = b"x"
ti = tarfile.TarInfo("root/real.txt"); ti.size = len(data)
tf.addfile(ti, io.BytesIO(data))
def link(name, target, typ):
    t = tarfile.TarInfo(name); t.type = typ; t.linkname = target
    tf.addfile(t)
if kind == "safe_sym":    # relative, in-tree: root/link.txt -> real.txt
    link("root/link.txt", "real.txt", tarfile.SYMTYPE)
elif kind == "dotdot_intree_sym":  # '..' but resolves INSIDE the tree: root/sub/l -> ../real.txt
    t = tarfile.TarInfo("root/sub/l.txt"); t.type = tarfile.SYMTYPE; t.linkname = "../real.txt"
    tf.addfile(t)
elif kind == "abs_sym":   # absolute target — must be rejected
    link("root/link.txt", "/etc/passwd", tarfile.SYMTYPE)
elif kind == "esc_sym":   # '..' escaping above archive root — must be rejected
    link("root/link.txt", "../../evil", tarfile.SYMTYPE)
elif kind == "safe_hard": # hardlink target is archive-root-relative and in-tree
    link("root/link.txt", "root/real.txt", tarfile.LNKTYPE)
elif kind == "esc_hard":  # hardlink escaping the root — must be rejected
    # NB: LEADING '../' is stripped by GNU tar itself on list/extract, so use an
    # embedded '..' escape which tar preserves verbatim in the listing.
    link("root/link.txt", "root/../../outside", tarfile.LNKTYPE)
elif kind == "chardev":   # char device — always rejected
    t = tarfile.TarInfo("root/dev0"); t.type = tarfile.CHRTYPE
    t.devmajor = 1; t.devminor = 3
    tf.addfile(t)
tf.close()
PYEOF
}

mk_link_tar "$TMP_DIR/safe_sym.tgz" safe_sym
assert_pass "$TMP_DIR/safe_sym.tgz" "№11: safe in-tree symlink must be allowed"

mk_link_tar "$TMP_DIR/dotdot_intree_sym.tgz" dotdot_intree_sym
assert_pass "$TMP_DIR/dotdot_intree_sym.tgz" "№11: '..' resolving in-tree must be allowed"

mk_link_tar "$TMP_DIR/abs_sym.tgz" abs_sym
assert_fail "$TMP_DIR/abs_sym.tgz" "№11: absolute symlink target"

mk_link_tar "$TMP_DIR/esc_sym.tgz" esc_sym
assert_fail "$TMP_DIR/esc_sym.tgz" "№11: '..'-escaping symlink target"

mk_link_tar "$TMP_DIR/safe_hard.tgz" safe_hard
assert_pass "$TMP_DIR/safe_hard.tgz" "№11: safe in-tree hardlink must be allowed"

mk_link_tar "$TMP_DIR/esc_hard.tgz" esc_hard
# GNU tar ≥1.32 САМ вычищает '..' из hardlink-target на listing/extract («Removing leading
# '..' from hard link targets») → цель становится in-tree и безопасной ЕЩЁ ДО нашего разбора,
# и extraction не выйдет за корень. bsdtar/libarchive (напр. Git-Bash на Windows) сохраняет
# escape verbatim. Поэтому проверяем ПРАВИЛЬНОЕ поведение под конкретный tar: если escape
# сохранён в листинге → validate ОБЯЗАН отклонить; если tar уже вычистил → цель безопасна,
# validate КОРРЕКТНО пропускает (второй рубеж — сам tar).
if tar -tvf "$TMP_DIR/esc_hard.tgz" 2>/dev/null | grep -E '^h' | grep -q '\.\.'; then
    assert_fail "$TMP_DIR/esc_hard.tgz" "№11: escaping hardlink target (сохранён tar'ом)"
else
    assert_pass "$TMP_DIR/esc_hard.tgz" "№11: hardlink escape вычищен самим tar (in-tree, безопасно)"
fi

mk_link_tar "$TMP_DIR/chardev.tgz" chardev
assert_fail "$TMP_DIR/chardev.tgz" "№11: char device still rejected"

echo "  restore safety: 10 fixtures OK (incl. №11 link degrade)"
