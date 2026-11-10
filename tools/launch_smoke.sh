#!/usr/bin/env bash
# Launch smoke check: start build/SundayKeys.app, prove it reached its run loop,
# then prove it exits cleanly. Any other outcome fails with the captured output.
#
# Usage:
#   tools/launch_smoke.sh                     use build/SundayKeys.app, bundling it first if absent
#   tools/launch_smoke.sh --app PATH          check a bundle that already exists
#   tools/launch_smoke.sh --exit-after N      seconds before the probe asks the app to quit (default 4)
#   tools/launch_smoke.sh --no-launchservices skip the supplementary LaunchServices attempt
#
# What this proves: the bundle's own executable loads, AppKit finishes launching,
# SwiftUI installs the root view, the process stays alive while the run loop
# services a timer, and it exits through NSApplication.terminate with status 0.
# The markers are printed by Sources/SundayKeysApp/LaunchProbe.swift.
#
# What it does not prove: that a person can see a window, that audio reaches an
# output device, that a controller is present, or that the audio graph and MIDI
# client start — the app only starts those when the player presses Start. Those
# need the Mac.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
exit_after=4
launchservices=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    --exit-after) exit_after="${2:?--exit-after needs a number}"; shift 2 ;;
    --no-launchservices) launchservices=0; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-launch.XXXXXX")"
applog="$logdir/app.log"
: > "$applog"

# A child that has exited is not reaped until it is waited for, and a zombie still
# answers `kill -0`. Reading the process state avoids reporting a finished app as
# a hang.
still_running() {
  local state
  state="$(ps -o state= -p "$1" 2>/dev/null || true)"
  [[ -n "$state" && "${state:0:1}" != "Z" ]]
}

fail() {
  printf '\nFAIL  %s\n' "$1" >&2
  printf '::error::launch smoke check: %s\n' "$1"
  printf '\n---- app output (last 120 lines) ----\n' >&2
  tail -n 120 "$applog" >&2 || true
  printf -- '---- end app output ----\n' >&2
  exit 1
}

if [[ ! -d "$app" ]]; then
  printf 'no bundle at %s; running tools/bundle_app.sh\n' "$app"
  bash tools/bundle_app.sh
fi
[[ -x "$exe" ]] || fail "no executable at $exe"

printf '== launch environment ==\n'
printf 'host           %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
printf 'session        %s\n' "$(launchctl managername 2>/dev/null || echo unknown)"
printf 'window server  %s\n' "$(pgrep -x WindowServer >/dev/null 2>&1 && echo running || echo absent)"
printf 'gui domain     %s\n' "$(launchctl print "gui/$(id -u)" >/dev/null 2>&1 && echo reachable || echo unreachable)"
printf 'ssh            %s\n' "${SSH_CONNECTION:-none}"
printf 'bundle         %s\n\n' "$app"

# Primary check. The bundle's executable is launched inside its bundle, with the
# probe timer armed, so a clean exit is the app's own NSApplication.terminate
# rather than a signal sent by this script.
printf 'launching %s (probe exit after %ss)\n' "$exe" "$exit_after"
SUNDAYKEYS_PROBE_EXIT_AFTER="$exit_after" "$exe" >"$applog" 2>&1 &
pid=$!
printf 'pid            %s\n' "$pid"

marker_launch="SundayKeysApp: did finish launching"
marker_view="SundayKeysApp: root view appeared"
deadline=$(( $(date +%s) + 20 ))
saw_launch=0
saw_view=0
while :; do
  grep -qF "$marker_launch" "$applog" && saw_launch=1
  grep -qF "$marker_view" "$applog" && saw_view=1
  if [[ "$saw_launch" -eq 1 && "$saw_view" -eq 1 ]]; then break; fi
  if ! still_running "$pid"; then break; fi
  if [[ "$(date +%s)" -ge "$deadline" ]]; then break; fi
  sleep 0.2
done

if [[ "$saw_launch" -ne 1 ]]; then
  still_running "$pid" && kill -TERM "$pid" 2>/dev/null || true
  fail "AppKit never reported a finished launch within 20s"
fi
if [[ "$saw_view" -ne 1 ]]; then
  still_running "$pid" && kill -TERM "$pid" 2>/dev/null || true
  fail "the root view never appeared within 20s"
fi
printf 'launch         ok: AppKit finished launching and SwiftUI installed the root view\n'

quit_deadline=$(( $(date +%s) + exit_after + 15 ))
hung=0
while still_running "$pid"; do
  if [[ "$(date +%s)" -ge "$quit_deadline" ]]; then hung=1; break; fi
  sleep 0.2
done

if [[ "$hung" -eq 1 ]]; then
  printf 'the process is still running after the probe asked it to quit; sending TERM\n' >&2
  kill -TERM "$pid" 2>/dev/null || true
  term_deadline=$(( $(date +%s) + 10 ))
  while still_running "$pid"; do
    if [[ "$(date +%s)" -ge "$term_deadline" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "the app hung: still running after $((exit_after + 15))s and did not exit on TERM"
    fi
    sleep 0.2
  done
fi

status=0
wait "$pid" || status=$?
printf 'exit status    %s\n' "$status"
[[ "$status" -eq 0 ]] || fail "the app exited with status $status instead of 0"
grep -qF "SundayKeysApp: probe exit firing" "$applog" \
  || fail "the probe timer never fired, so the run loop was not serviced"
printf 'run loop       ok: the probe timer fired\n'
printf 'exit           clean: status 0 through NSApplication.terminate\n'

# Supplementary evidence: a LaunchServices launch is the path a person takes when
# they double-click the app. It cannot carry the probe environment or be captured
# on stdout, so it is reported and not counted as the pass condition.
if [[ "$launchservices" -eq 1 ]]; then
  printf '\nsupplementary: LaunchServices launch\n'
  lslog="$logdir/open.log"
  if open -n "$app" >"$lslog" 2>&1; then
    ls_pid=""
    for _ in $(seq 1 50); do
      ls_pid="$(pgrep -f "$exe" | head -n 1 || true)"
      [[ -n "$ls_pid" ]] && break
      sleep 0.2
    done
    if [[ -n "$ls_pid" ]] && still_running "$ls_pid"; then
      printf 'LaunchServices ok: pid %s started and stayed alive; terminating it\n' "$ls_pid"
      kill -TERM "$ls_pid" 2>/dev/null || true
      for _ in $(seq 1 50); do
        still_running "$ls_pid" || break
        sleep 0.2
      done
      still_running "$ls_pid" && kill -KILL "$ls_pid" 2>/dev/null || true
      printf 'LaunchServices quit was a signal, not a graceful exit, so it is not counted above\n'
    else
      printf 'LaunchServices: open reported success but no live process was observed\n'
      cat "$lslog" 2>/dev/null || true
    fi
  else
    printf 'LaunchServices: open failed in this session (not counted as a failure):\n'
    cat "$lslog" 2>/dev/null || true
  fi
fi

printf '\n---- app output ----\n'
cat "$applog"
printf -- '---- end app output ----\n'
printf '\nPASS  the bundle launched, reached its run loop and exited cleanly\n'
