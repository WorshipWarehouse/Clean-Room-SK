#!/usr/bin/env bash
# Audio start probe: does the audio graph actually start and render on this
# machine, and if not, why not?
#
# Usage:
#   tools/audio_smoke.sh                use build/SundayKeys.app, bundling it first if absent
#   tools/audio_smoke.sh --app PATH     check a bundle that already exists
#
# What this proves when it passes with a voice count: the bundle's own executable
# started the AVAudioEngine graph, the render block drained the command ring and a
# note allocated a voice, and the graph then stopped and the process exited 0.
#
# A machine with no output device cannot do that, and pretending otherwise would
# be a lie. That case is accepted only when the app reports the typed
# `no output device` failure and exits 4, and it is reported as a warning with the
# app's own line, so the run says what the hardware was. Any other failure — a
# crash, a hang, an engine that refuses to start for another reason, or a start
# that produces no voice — fails the step.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-audio.XXXXXX")"
log="$logdir/audio.log"
: > "$log"

if [[ ! -d "$app" ]]; then
  printf 'no bundle at %s; running tools/bundle_app.sh\n' "$app"
  bash tools/bundle_app.sh
fi
[[ -x "$exe" ]] || { printf '::error::no executable at %s\n' "$exe"; exit 1; }

fail() {
  printf '\nFAIL  %s\n' "$1" >&2
  printf '::error::audio smoke check: %s\n' "$1"
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

printf '== audio probe ==\n'
printf 'bundle         %s\n' "$app"
printf 'default output %s\n' "$(system_profiler SPAudioDataType 2>/dev/null | grep -m 1 -A 1 'Devices:' || echo 'not reported')"
printf '\n'

# The exit timer is a backstop only: the probe exits on its own once it has a
# verdict, and if it never does, the process is killed and the step fails.
SUNDAYKEYS_PROBE_START_ENGINE=1 SUNDAYKEYS_PROBE_EXIT_AFTER=20 "$exe" >"$log" 2>&1 &
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

if grep -qF "SundayKeysApp: engine started at" "$log" \
  && grep -qE "SundayKeysApp: engine rendered [1-9][0-9]* voice" "$log"; then
  [[ "$status" -eq 0 ]] || fail "the graph started and rendered, but the app exited with $status"
  printf '\nPASS  the audio graph started, rendered a voice and exited cleanly\n'
  exit 0
fi

if grep -qF "SundayKeysApp: engine failed: No audio output device is available" "$log"; then
  [[ "$status" -eq 4 ]] || fail "no output device was reported, but the app exited with $status instead of 4"
  printf '\n::warning::this machine has no audio output device, so the audio graph could not be started; the typed failure was reported and the app exited cleanly\n'
  printf 'LIMITATION  no audio output device here: the start path refused instead of crashing\n'
  exit 0
fi

fail "the audio probe neither started the graph nor reported a missing output device"
