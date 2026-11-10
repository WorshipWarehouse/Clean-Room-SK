#!/usr/bin/env bash
# MIDI start probe: does the app create a CoreMIDI client and an input port on
# this machine, and what sources does it see?
#
# Usage:
#   tools/midi_smoke.sh                use build/SundayKeys.app, bundling it first if absent
#   tools/midi_smoke.sh --app PATH     check a bundle that already exists
#
# What a pass proves: the bundle's own executable created a MIDI client and an
# input port, MIDIGetNumberOfSources returned a list, every online source was
# connected to that port, the client was disposed and the process exited 0.
#
# A runner with no controller attached has no sources. That is not a failure: the
# probe still proves the client and the port were created and the list was read as
# empty, and it is reported as a warning with the app's own line, so the run says
# what the hardware was. A client that could not be created, a port that could not
# be created, or a source that would not connect fails the step.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-midi.XXXXXX")"
log="$logdir/midi.log"
: > "$log"

if [[ ! -d "$app" ]]; then
  printf 'no bundle at %s; running tools/bundle_app.sh\n' "$app"
  bash tools/bundle_app.sh
fi
[[ -x "$exe" ]] || { printf '::error::no executable at %s\n' "$exe"; exit 1; }

fail() {
  printf '\nFAIL  %s\n' "$1" >&2
  printf '::error::midi smoke check: %s\n' "$1"
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

printf '== MIDI probe ==\n'
printf 'bundle         %s\n' "$app"
printf '\n'

# The exit timer is a backstop only: the probe exits on its own once it has a
# verdict, and if it never does, the process is killed and the step fails.
SUNDAYKEYS_PROBE_START_MIDI=1 SUNDAYKEYS_PROBE_EXIT_AFTER=20 "$exe" >"$log" 2>&1 &
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

if ! grep -qF "SundayKeysApp: MIDI: client created" "$log"; then
  fail "the app never reported a MIDI client; exit status was $status"
fi

sources="$(grep -oE 'SundayKeysApp: MIDI: [0-9]+ source\(s\)' "$log" | grep -oE '[0-9]+' | head -n 1 || true)"
[[ -n "$sources" ]] || fail "a MIDI client was created but no source count was reported"

if [[ "$status" -ne 0 ]]; then
  fail "the client was created but the probe exited with $status instead of 0"
fi

if [[ "$sources" -eq 0 ]]; then
  printf '\n::warning::this machine has no MIDI sources: the probe proved the client and input port were created and the source list was empty\n'
  printf 'LIMITATION  no controller here, so no source was connected\n'
  exit 0
fi

printf '\nPASS  a MIDI client and input port were created and %s source(s) were enumerated and connected\n' "$sources"
