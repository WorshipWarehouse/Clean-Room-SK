#!/usr/bin/env bash
# Decompile the functions that contain a list of addresses.
#
# Usage:
#   tools/decompile.sh <addrs.txt> <out.c> [program]
#
# Environment:
#   GHIDRA_INSTALL_DIR  Ghidra 12.1.x install (required)
#   SK_PROJECT_DIR      Ghidra project directory (default /tmp/sk-proj)
#   SK_PROJECT_NAME     Ghidra project name (default SKProject)
#   SK_PROGRAM          imported program name (default sundaykeys-arm64)
#
# A saved, analysed project is reused with -noanalysis, so repeat runs take
# seconds instead of the ~10 minutes a fresh import needs.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <addrs.txt> <out.c> [program]" >&2
    exit 2
fi

ADDRS=$1
OUT=$2
PROGRAM=${3:-${SK_PROGRAM:-sundaykeys-arm64}}
GHIDRA=${GHIDRA_INSTALL_DIR:?set GHIDRA_INSTALL_DIR to a Ghidra 12.1.x install}
PROJECT_DIR=${SK_PROJECT_DIR:-/tmp/sk-proj}
PROJECT_NAME=${SK_PROJECT_NAME:-SKProject}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

export GHIDRA_HEADLESS_MAXMEM=${GHIDRA_HEADLESS_MAXMEM:-8G}

"$GHIDRA/support/analyzeHeadless" "$PROJECT_DIR" "$PROJECT_NAME" \
    -process "$PROGRAM" \
    -noanalysis \
    -scriptPath "$SCRIPT_DIR/ghidra" \
    -postScript DecompileAt.java "$ADDRS" "$OUT" "${SK_DECOMPILE_TIMEOUT:-120}"
