#!/usr/bin/env bash
# Decompile the whole program in chunks.
#
# Usage:
#   tools/decompile_all.sh <outdir> [chunkSize] [maxChunks]
#
# chunkSize defaults to 2000 functions per Ghidra invocation, which amortises the
# roughly 20 s headless startup over real work. maxChunks of 0 means all chunks;
# set it to run a measured sample first. Existing chunk outputs are skipped, so
# the job can be resumed.
#
# Outputs:
#   <outdir>/functions.tsv        entry point, name, size
#   <outdir>/all-addrs.txt        entry points only
#   <outdir>/chunks/batch-XX.c    decompiled C per chunk
#   <outdir>/chunks/index.tsv     chunk -> source address range

set -euo pipefail

OUT=${1:?"usage: $0 <outdir> [chunkSize] [maxChunks]"}
CHUNK=${2:-2000}
MAX=${3:-0}
GHIDRA=${GHIDRA_INSTALL_DIR:?set GHIDRA_INSTALL_DIR to a Ghidra 12.1.x install}
PROJECT_DIR=${SK_PROJECT_DIR:-/tmp/sk-proj}
PROJECT_NAME=${SK_PROJECT_NAME:-SKProject}
PROGRAM=${SK_PROGRAM:-sundaykeys-arm64}
TOOLS=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT/chunks"

if [ ! -s "$OUT/functions.tsv" ]; then
    "$GHIDRA/support/analyzeHeadless" "$PROJECT_DIR" "$PROJECT_NAME" \
        -process "$PROGRAM" -noanalysis \
        -scriptPath "$TOOLS/ghidra" \
        -postScript ListFunctions.java "$OUT/functions.tsv"
fi

cut -f1 "$OUT/functions.tsv" > "$OUT/all-addrs.txt"
TOTAL=$(wc -l < "$OUT/all-addrs.txt" | tr -d ' ')
echo "functions: $TOTAL  chunk: $CHUNK  maxChunks: $MAX"

# Remove only the fragment files, never the .c outputs, so runs resume.
for fragment in "$OUT"/chunks/batch-*; do
    case "$fragment" in
        *.c) ;;
        *) rm -f "$fragment" ;;
    esac
done
split -l "$CHUNK" "$OUT/all-addrs.txt" "$OUT/chunks/batch-"

INDEX="$OUT/chunks/index.tsv"
printf 'chunk\tfirst\tlast\tcount\n' > "$INDEX"

INDEX_N=0
for ADDRS in "$OUT"/chunks/batch-*; do
    INDEX_N=$((INDEX_N + 1))
    if [ "$MAX" != "0" ] && [ "$INDEX_N" -gt "$MAX" ]; then
        break
    fi
    NAME=$(basename "$ADDRS")
    OUT_C="$OUT/chunks/${NAME}.c"
    FIRST=$(head -1 "$ADDRS")
    LAST=$(tail -1 "$ADDRS")
    COUNT=$(wc -l < "$ADDRS" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\n' "$NAME" "$FIRST" "$LAST" "$COUNT" >> "$INDEX"
    if [ -s "$OUT_C" ]; then
        echo "skip $NAME (already decompiled)"
        continue
    fi
    echo "decompiling $NAME ($COUNT functions)"
    "$TOOLS/decompile.sh" "$ADDRS" "$OUT_C" "$PROGRAM"
done

echo "chunks written: $INDEX_N"
python3 "$TOOLS/inventory.py" "$OUT"
