#!/usr/bin/env bash
# End-to-end regeneration of the Sunday Keys analysis artifacts.
#
# Usage:
#   tools/pipeline.sh "/Applications/Sunday Keys.app" [workdir]
#
# Steps:
#   1. extract the thin arm64 slice from the universal binary
#   2. recover Swift type metadata (types, fields, conformances)
#   3. resolve C-string literals to the code that references them
#   4. optionally decompile the highest-signal addresses (SK_DECOMPILE=1)
#
# Outputs land in the work directory (default /tmp/sk-analysis):
#   sundaykeys-arm64     thin slice
#   swift-meta.json      types and conformances
#   refs.tsv             string -> code addresses
#   decompiled.txt       decompiled C when SK_DECOMPILE=1

set -euo pipefail

APP=${1:?"usage: $0 <path to Sunday Keys.app> [workdir]"}
WORK=${2:-/tmp/sk-analysis}
BINARY="$APP/Contents/MacOS/Sunday Keys"
TOOLS=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$WORK"
SLICE="$WORK/sundaykeys-arm64"

if [ ! -f "$SLICE" ]; then
    lipo -thin arm64 "$BINARY" -output "$SLICE"
fi
echo "slice: $SLICE ($(wc -c <"$SLICE") bytes)"
shasum -a 256 "$SLICE"

python3 "$TOOLS/swift_metadata.py" "$SLICE" --json "$WORK/swift-meta.json"
python3 "$TOOLS/literal_refs.py" "$SLICE" --out "$WORK/refs.tsv"

if [ "${SK_DECOMPILE:-0}" = "1" ]; then
    : "${GHIDRA_INSTALL_DIR:?set GHIDRA_INSTALL_DIR to decompile}"
    # Decompile the functions behind the 200 most interesting literals.
    python3 - "$WORK" <<'PY'
import sys
from pathlib import Path

work = Path(sys.argv[1])
rows = []
for line in (work / "refs.tsv").read_text(encoding="utf-8").splitlines():
    text, addrs = line.split("\t")
    rows.append((text, addrs.split(",")[0]))
rows.sort(key=lambda row: len(row[0]))
addrs = []
for _text, addr in rows[:200]:
    if addr not in addrs:
        addrs.append(addr)
(work / "decompile-addrs.txt").write_text("\n".join(addrs) + "\n", encoding="utf-8")
print("addresses queued: %d" % len(addrs))
PY
    "$TOOLS/decompile.sh" "$WORK/decompile-addrs.txt" "$WORK/decompiled.txt"
fi

echo "done: $WORK"
