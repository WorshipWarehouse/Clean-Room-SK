#!/usr/bin/env bash
#
# The strict-concurrency proof, kept in one file so the build and the
# concurrency workflow run exactly the same check.
#
# It exists because complete concurrency checking needs a macOS runner and
# those are the scarce resource here. The check itself is unchanged; only
# when its job is scheduled changed. See docs/re/ci-runner-queue.md.
#
# Modes, so each gate keeps its own named step in the run log:
#   build    compile with -strict-concurrency=complete, keep the log
#   flag     prove the flag actually reached the compiler
#   report   print every primary diagnostic and count them
#   gate     fail on a diagnostic in the MIDI routing seam
#   all      the four above, in order

set -euo pipefail

log=/tmp/strict.log
# Only a primary diagnostic line carries a file, a line and a column.
# Continuation lines are source snippets and report no location.
primary='^/.*\.swift:[0-9]+:[0-9]+: (warning|error):'
# The MIDI routing seam: the transport protocol, its router, the app model
# that conforms to it, and the suite that exercises it.
seam='Sources/SundayKeysCore/MIDI/|Sources/SundayKeysApp/AppModel.swift|Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift'

build() {
  echo "compiling with -strict-concurrency=complete"
  # No warnings-as-errors, so one diagnostic cannot hide the rest; the gate
  # below decides what is a failure.
  swift build --build-tests -v \
    -Xswiftc -strict-concurrency=complete 2>&1 | tee "$log"
}

flag() {
  if ! grep -q -- "-strict-concurrency=complete" "$log"; then
    echo "::error::the strict-concurrency flag never reached swiftc"
    return 1
  fi
  echo "strict-concurrency=complete was passed to the compiler"
}

report() {
  local total
  total=$(grep -cE "$primary" "$log" || true)
  echo "diagnostics in the strict build: ${total:-0}"
  { grep -E "$primary" "$log" || true; } \
    | sed -E "s#^${PWD}/##" \
    | sort -u > /tmp/strict-primary.log
  { cut -d: -f1 /tmp/strict-primary.log || true; } | sort | uniq -c | sort -rn
  while IFS= read -r line; do
    file=${line%%:*}
    echo "::warning file=${file}::${line#*: }"
  done < /tmp/strict-primary.log
}

gate() {
  if grep -E "$primary" "$log" | grep -E "$seam"; then
    echo "::error::strict concurrency diagnostics in the MIDI routing seam"
    return 1
  fi
  echo "no strict concurrency diagnostics in the MIDI routing seam"
}

case "${1:-all}" in
  build) build ;;
  flag) flag ;;
  report) report ;;
  gate) gate ;;
  all)
    build
    flag
    report
    gate
    ;;
  *)
    echo "::error::unknown mode ${1}" >&2
    exit 2
    ;;
esac
