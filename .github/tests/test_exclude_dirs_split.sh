#!/usr/bin/env bash
# Tests for _split_exclude_dirs.
# Verifies:
#   1. Comma-separated → массив с trim'нутыми элементами
#   2. Semicolon-separated → нормализуется в `,`
#   3. Space-separated (legacy) — backward-compat
#   4. Пути с пробелами через `,` сохраняются целиком
#   5. Trailing/leading whitespace вокруг элементов trim'ится
#   6. Пустые элементы (двойная запятая) пропускаются
#   7. Пустой input → пустой массив

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/lazarus-backup"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FUNC_FILE="$TMP_DIR/exclude_split.sh"
sed -n '/^_split_exclude_dirs() {$/,/^}$/p' "$SCRIPT" > "$FUNC_FILE"
if ! [[ -s "$FUNC_FILE" ]]; then
    echo "FAIL: could not extract _split_exclude_dirs" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNC_FILE"

FAILS=0

# --- Test 1: comma-separated basic ---
ARR=()
_split_exclude_dirs "node_modules, .git, .cache" ARR
if [[ ${#ARR[@]} -ne 3 ]]; then
    echo "FAIL [comma basic]: expected 3 items, got ${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi
[[ "${ARR[0]}" == "node_modules" ]] || { echo "FAIL [comma item 0]: '${ARR[0]}'" >&2; FAILS=$((FAILS + 1)); }
[[ "${ARR[1]}" == ".git" ]] || { echo "FAIL [comma item 1]: '${ARR[1]}'" >&2; FAILS=$((FAILS + 1)); }
[[ "${ARR[2]}" == ".cache" ]] || { echo "FAIL [comma item 2]: '${ARR[2]}'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 2: semicolon separator ---
ARR=()
_split_exclude_dirs "foo;bar;baz" ARR
if [[ ${#ARR[@]} -ne 3 || "${ARR[1]}" != "bar" ]]; then
    echo "FAIL [semicolon]: count=${#ARR[@]}, mid='${ARR[1]:-?}'" >&2; FAILS=$((FAILS + 1))
fi

# --- Test 3: legacy space-separated backward-compat ---
ARR=()
_split_exclude_dirs "node_modules .git cache" ARR
if [[ ${#ARR[@]} -ne 3 ]]; then
    echo "FAIL [legacy space]: expected 3 items, got ${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi
[[ "${ARR[2]}" == "cache" ]] || { echo "FAIL [legacy space item]: '${ARR[2]}'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 4: paths with spaces via comma ---
ARR=()
_split_exclude_dirs "node_modules, my data/cache, temp dir" ARR
if [[ ${#ARR[@]} -ne 3 ]]; then
    echo "FAIL [spaces in paths]: count=${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi
[[ "${ARR[1]}" == "my data/cache" ]] || { echo "FAIL [path with space 1]: '${ARR[1]}'" >&2; FAILS=$((FAILS + 1)); }
[[ "${ARR[2]}" == "temp dir" ]] || { echo "FAIL [path with space 2]: '${ARR[2]}'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 5: trailing/leading whitespace ---
ARR=()
_split_exclude_dirs "  foo  ,   bar   ,baz  " ARR
[[ "${ARR[0]}" == "foo" ]] || { echo "FAIL [trim 0]: '${ARR[0]}'" >&2; FAILS=$((FAILS + 1)); }
[[ "${ARR[1]}" == "bar" ]] || { echo "FAIL [trim 1]: '${ARR[1]}'" >&2; FAILS=$((FAILS + 1)); }
[[ "${ARR[2]}" == "baz" ]] || { echo "FAIL [trim 2]: '${ARR[2]}'" >&2; FAILS=$((FAILS + 1)); }

# --- Test 6: double comma → empty items skipped ---
ARR=()
_split_exclude_dirs "foo,,bar,," ARR
if [[ ${#ARR[@]} -ne 2 ]]; then
    echo "FAIL [empty items]: expected 2, got ${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi

# --- Test 7: empty input ---
ARR=( "stale" )  # должно очиститься
_split_exclude_dirs "" ARR
if [[ ${#ARR[@]} -ne 0 ]]; then
    echo "FAIL [empty input]: expected 0 items, got ${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi

# --- Test 8: mixed comma+semicolon ---
ARR=()
_split_exclude_dirs "a, b; c, d; e" ARR
if [[ ${#ARR[@]} -ne 5 ]]; then
    echo "FAIL [mixed]: count=${#ARR[@]}" >&2; FAILS=$((FAILS + 1))
fi

# --- Test 9: single item ---
ARR=()
_split_exclude_dirs "single_dir" ARR
if [[ ${#ARR[@]} -ne 1 || "${ARR[0]}" != "single_dir" ]]; then
    echo "FAIL [single]: '${ARR[0]:-?}'" >&2; FAILS=$((FAILS + 1))
fi

if [[ $FAILS -gt 0 ]]; then
    echo "  exclude_dirs split: $FAILS test(s) FAILED" >&2
    exit 1
fi
echo "  exclude_dirs split: 9 fixtures OK (comma, semi, legacy-space, paths-with-space, trim, double-comma, empty, mixed, single)"
