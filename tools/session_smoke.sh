#!/usr/bin/env bash
#
# Proves a launch resumes where the previous launch stopped, on disk and across
# processes.
#
# The unit tests prove the rule and the model calls it, but nothing had ever started the
# app twice against one Application Support folder, so the file the hint is written to
# had never been read back by a second launch. This script starts the bundle three times,
# all three sharing one HOME, which means they share one Application Support folder and
# the second run is a genuine relaunch rather than a repeat in one process:
#
#   1. remember  writes a bank of three patches and a hint naming the third;
#   2. relaunch  loads those files through the same AppModel the window uses and prints
#                the status line, the selected patch and the position of the play head;
#   3. missing   gets a hint naming a patch the bank does not have, and has to fall back
#                to slot 1 and say why.
#
# The app's own lines are asserted, not the exit status alone, and the exit status is
# asserted as well. A green run therefore means the second launch opened the remembered
# patch, moved the play head onto its slot and printed the line the window shows.

set -o pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
executable="$root/build/SundayKeys.app/Contents/MacOS/SundayKeysApp"

fail() {
  echo "session probe: FAIL: $1"
  exit 1
}

[ -x "$executable" ] || fail "no executable at $executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

output=""

echo "session probe: running $executable against a fresh HOME at $work"

run() {
  local mode="$1"
  output="$(SUNDAYKEYS_PROBE_SESSION="$mode" HOME="$work" "$executable" 2>&1)"
  local status=$?
  printf '%s\n' "$output" | grep "^session probe:" || true
  echo "session probe: mode $mode exited $status"
  return "$status"
}

expect() {
  local wanted="$1"
  printf '%s\n' "$output" | grep -Fq "session probe: $wanted" \
    || fail "expected the line 'session probe: $wanted'"
  echo "session probe: saw '$wanted'"
}

run remember || fail "the write run exited non-zero"
expect "wrote 3 patches and 3 set list slots"
expect "remembered Rehearsal Pad"

run relaunch || fail "the relaunch exited non-zero"
expect "status: Resumed Rehearsal Pad, 3 patches and 3 set list slots"
expect "selected: Rehearsal Pad"
expect "play head on slot 3 of 3"
expect "resumed Rehearsal Pad with the head on its own slot"

run missing || fail "the missing-patch run exited non-zero"
expect "status: Opened Sunday Keys: the patch from the last launch is gone, 3 patches and 3 set list slots"
expect "play head on slot 1 of 3"
expect "fell back to slot 1 and said why"

echo "session probe: a relaunch opened the remembered patch and a deleted one fell back with its reason"
