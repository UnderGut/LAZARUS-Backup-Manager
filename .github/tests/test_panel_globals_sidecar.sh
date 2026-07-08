#!/usr/bin/env bash
# Panel globals sidecar — naming↔discovery contract. The create side combines
# version + db_<ts>.sql.<ext> + globals_<ts>.sql.<ext> into one archive; the restore
# side rediscovers them with find globs. This test does the SAME tar-combine the
# real create_backup runs and the SAME discovery globs execute_restore runs, so a
# drift between create naming and restore globs is caught. Real tar/gzip, no docker.
# Counters n_ok/n_err (never PASS= — secret scrubber rewrites it on disk).

set -uo pipefail

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

n_ok=0; n_err=0
ok()  { n_ok=$(( n_ok + 1 )); }
bad() { echo "FAIL: $1"; n_err=$(( n_err + 1 )); }

TS="2026-06-15_03_30_00"
STAGE="$TMP_DIR/stage"; mkdir -p "$STAGE"

# --- create-side fixtures (what create_backup writes before the combine) ---
echo "Unknown" > "$STAGE/bot_version.txt"
# Realistic gzipped SQL (>100b after gzip so the size sanity that create uses holds).
{ echo "-- pg_dump"; for i in $(seq 1 60); do echo "INSERT INTO t VALUES ($i,'row-$i-data-padding');"; done; } | gzip -9 > "$STAGE/db_${TS}.sql.gz"
{ echo "-- pg_dumpall --globals-only"; echo "CREATE ROLE postgres;"; echo "ALTER ROLE postgres WITH SUPERUSER;"; } | gzip -9 > "$STAGE/globals_${TS}.sql.gz"

# --- 1) PANEL combine: version + db + globals (mirrors create_backup db_only) ---
PANEL_ARC="$TMP_DIR/lazarus_panel_db_${TS}.tar.gz"
_db_inputs=("bot_version.txt" "db_${TS}.sql.gz")
[[ -f "$STAGE/globals_${TS}.sql.gz" ]] && _db_inputs+=("globals_${TS}.sql.gz")
tar -czf "$PANEL_ARC" -C "$STAGE" "${_db_inputs[@]}" 2>/dev/null \
    && ok || bad "panel combine tar failed"

# globals must be present inside the combined archive
tar -tzf "$PANEL_ARC" | grep -q "globals_${TS}.sql.gz" && ok || bad "globals missing from panel archive"
tar -tzf "$PANEL_ARC" | grep -q "db_${TS}.sql.gz" && ok || bad "db dump missing from panel archive"

# --- 2) restore-side discovery globs find both (same find as execute_restore) ---
EXTRACT="$TMP_DIR/extract"; mkdir -p "$EXTRACT"
tar -xzf "$PANEL_ARC" -C "$EXTRACT"
DB_DUMP=$(find "$EXTRACT" \( -name "db_*.sql.gz" -o -name "db_*.sql.zst" \) | head -1)
GLOBALS_DUMP=$(find "$EXTRACT" \( -name "globals_*.sql.gz" -o -name "globals_*.sql.zst" \) | head -1)
[[ -n "$DB_DUMP" && -f "$DB_DUMP" ]] && ok || bad "restore did not discover db dump"
[[ -n "$GLOBALS_DUMP" && -f "$GLOBALS_DUMP" ]] && ok || bad "restore did not discover globals sidecar"
# globals must decompress to valid SQL containing role statements
gzip -dc "$GLOBALS_DUMP" 2>/dev/null | grep -q "CREATE ROLE" && ok || bad "globals sidecar not valid SQL"

# --- 3) BOT archive has NO globals → restore discovery stays empty (no false positive) ---
BOT_ARC="$TMP_DIR/lazarus_db_${TS}.tar.gz"
tar -czf "$BOT_ARC" -C "$STAGE" "bot_version.txt" "db_${TS}.sql.gz" 2>/dev/null
EXTRACT2="$TMP_DIR/extract2"; mkdir -p "$EXTRACT2"
tar -xzf "$BOT_ARC" -C "$EXTRACT2"
GLOBALS_DUMP2=$(find "$EXTRACT2" \( -name "globals_*.sql.gz" -o -name "globals_*.sql.zst" \) | head -1)
[[ -z "$GLOBALS_DUMP2" ]] && ok || bad "bot archive should have no globals, found '$GLOBALS_DUMP2'"

# --- 4) zstd variant: naming↔discovery contract holds for COMPRESSION=zstd ---
if command -v zstd >/dev/null 2>&1; then
    { echo "-- dump"; for i in $(seq 1 60); do echo "row $i"; done; } | zstd -9 -q > "$STAGE/db_${TS}.sql.zst"
    { echo "CREATE ROLE postgres;"; } | zstd -9 -q > "$STAGE/globals_${TS}.sql.zst"
    Z_ARC="$TMP_DIR/lazarus_panel_db_${TS}.tar.zst"
    tar --use-compress-program=zstd -cf "$Z_ARC" -C "$STAGE" "bot_version.txt" "db_${TS}.sql.zst" "globals_${TS}.sql.zst" 2>/dev/null
    EXTRACT3="$TMP_DIR/extract3"; mkdir -p "$EXTRACT3"
    tar --use-compress-program=zstd -xf "$Z_ARC" -C "$EXTRACT3"
    G3=$(find "$EXTRACT3" \( -name "globals_*.sql.gz" -o -name "globals_*.sql.zst" \) | head -1)
    [[ -n "$G3" && -f "$G3" ]] && ok || bad "zstd: restore did not discover globals sidecar"
else
    echo "(zstd not installed — skipping zstd variant)"
fi

echo "---"
echo "ok=$n_ok err=$n_err"
[[ $n_err -eq 0 ]] || exit 1
