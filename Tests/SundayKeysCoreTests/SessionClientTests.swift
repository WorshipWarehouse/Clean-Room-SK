#!/usr/bin/env bash
#
# Runs the app's own startup path against six stubbed sessions and asserts what it applied.
#
# The unit tests prove the seam and the launch decision, but the package has no test target that
# can import the executable target, so nothing until now had shown `AppModel` taking its launch
# behaviour from a `LicenceStanding`. This script starts the bundle six times, each with a
# different `SUNDAYKEYS_PROBE_LICENCE` mode, over one throwaway HOME. Each launch builds the same
# `AppModel` the window builds, hands it a `SessionClient` over a stub transport, runs the same
# `checkSession` the root view runs, and prints the line and the premium flag it applied:
#
#   active      an `active` licence                          -> licensed, premium allowed
#   grace       a `grace_period` ending in one day            -> licensed, countdown shown
#   expired     an `expired` licence with a product           -> refused, premium withheld
#   absent      a session with no `license` member            -> unlicensed, and says which
#   unreadable  a status this build does not know             -> unlicensed, quoting the value
#   failure     a transport that throws                       -> no verdict, premium untouched
#
# The app's lines are asserted rather than the exit status alone, and each mode's exit status is
# asserted too, so a green run means the model printed the expected line and applied the expected
# permission. This is not a live-server test: no request leaves the machine.

set -o pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
executable="$root/build/SundayKeys.app/Contents/MacOS/SundayKeysApp"

fail() {
  echo "licence probe: FAIL: $1"
  exit 1
}

[ -x "$executable" ] || fail "no executable at $executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

output=""

echo "licence probe: running $executable against a fresh HOME at $work"

run() {
  local mode="$1"
  output="$(SUNDAYKEYS_PROBE_LICENCE="$mode" HOME="$work" "$executable" 2>&1)"
  local status=$?
  printf '%s\n' "$output" | grep "^licence probe:" || true
  echo "licence probe: mode $mode exited $status"
  return "$status"
}

expect() {
  local wanted="$1"
  printf '%s\n' "$output" | grep -Fq "licence probe: $wanted" \
    || fail "expected the line 'licence probe: $wanted'"
  echo "licence probe: saw '$wanted'"
}

run active || fail "the active run exited non-zero"
expect "launch: Licence active"
expect "premium sounds allowed: true"
expect "applied active as expected"

run grace || fail "the grace run exited non-zero"
expect "launch: Licence in grace period: 1 day left"
expect "premium sounds allowed: true"
expect "applied grace as expected"

run expired || fail "the expired run exited non-zero"
expect "launch: Session refused: Licence expired: sounds downgraded"
expect "premium sounds allowed: false"
expect "applied expired as expected"

run absent || fail "the absent run exited non-zero"
expect "launch: Session unlicensed: No licence on this session"
expect "premium sounds allowed: false"
expect "applied absent as expected"

run unreadable || fail "the unreadable run exited non-zero"
expect 'launch: Session unlicensed: Licence could not be read: unknown licence status "trialing"'
expect "premium sounds allowed: false"
expect "applied unreadable as expected"

run failure || fail "the failure run exited non-zero"
expect "launch: Session not checked, not a licence verdict: the network is offline"
expect "premium sounds allowed: true"
expect "applied failure as expected"

echo "licence probe: the launch applied all six decisions from a LicenceStanding"
