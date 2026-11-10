#!/usr/bin/env bash
# Metronome probe: does the running app render the click on the beat, and does it
# stop when the click is switched off?
#
# Usage:
#   tools/metronome_smoke.sh              use build/SundayKeys.app, bundling it if absent
#   tools/metronome_smoke.sh --app PATH   check a bundle that already exists
#
# The timing itself is measured by Tests/SundayKeysCoreTests/MetronomeTests.swift, which
# renders frames and asserts the exact frame each beat starts on. This script covers
# what those tests cannot reach: a real output device and the app's own graph. When it
# passes, the render thread of the running app started at least two clicks in the
# second the probe listened, and none in the 0.8 s after the click was switched off,
# which crosses the beat the click would have played.
#
# A machine with no output device is reported as a limitation with the app's own typed
# failure and still exits 0, exactly as tools/audio_smoke.sh does, because refusing
# cleanly is right there and the run should record what the hardware was.

set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-click.XXXXXX")"
log="$logdir/click.log"
: > "$log"

if [[ ! -d "$app" ]]; then
  printf 'no bundle at %s; running tools/bundle_app.sh\n' "$app"
  bash tools/bundle_app.sh
fi
[[ -x "$exe" ]] || { printf '::error::no executable at %s\n' "$exe"; exit 1; }

fail() {
  printf '\nFAIL  %s\n' "$1" >&2
  printf '::error::metronome smoke check: %s\n' "$1"
  printf '\n---- app output ----\n' >&2
  cat "$log" >&2 || true
  printf -- '---- end app output ----\n' >&2
  exit 1
}

still_running() {
  local state
  state="$(ps -o state= -p "$1" 2>/dev/null || true)"
  [[ -n "$state" && "${state:0:1}" != "Z" ]]
}

printf '== metronome probe ==\n'
printf 'bundle         %s\n\n' "$app"

# The exit timer is a backstop only: the probe exits on its own once it has a verdict.
SUNDAYKEYS_PROBE_METRONOME=1 SUNDAYKEYS_PROBE_EXIT_AFTER=20 "$exe" >"$log" 2>&1 &
pid=$!
printf 'pid            %s\n' "$pid"

deadline=$(( $(date +%s) + 40 ))
while still_running "$pid"; do
  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    still_running "$pid" && kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the probe did not report a verdict within 40s"
  fi
  sleep 0.2
done

status=0
wait "$pid" || status=$?
printf 'exit status    %s\n' "$status"
printf '\n---- app output ----\n'
cat "$log"
printf -- '---- end app output ----\n'

if grep -qF "metronome probe: engine failed: No audio output device is available" "$log"; then
  [[ "$status" -eq 4 ]] || fail "no output device was reported, but the app exited with $status instead of 4"
  printf '\n::warning::this machine has no audio output device, so the click could not be rendered; the typed failure was reported and the app exited cleanly\n'
  printf 'LIMITATION  no audio output device here: the click timing is proven by the tests, not by the graph\n'
  exit 0
fi

grep -qF "metronome probe: engine started at" "$log" || fail "the graph never started"
grep -qF "metronome probe: click on at 120 bpm" "$log" || fail "the probe never switched the click on"
grep -qE "metronome probe: click off after [2-9][0-9]* click\(s\)" "$log" \
  || fail "fewer than two beats were counted in the second the probe listened"
grep -qF "metronome probe: 0 click(s) after the stop" "$log" \
  || fail "the click did not stop when it was switched off"
[[ "$status" -eq 0 ]] || fail "the probe reported a verdict, but the app exited with $status"

printf '\nPASS  the running app rendered the click on the beat and stopped it when asked\n'
