#!/usr/bin/env bash
# MIDI probes: does the app create a CoreMIDI client and input port on this
# machine, what sources does it see, and does its connect path run against one?
#
# Usage:
#   tools/midi_smoke.sh                use build/SundayKeys.app, bundling it if absent
#   tools/midi_smoke.sh --app PATH     check a bundle that already exists
#
# Two probes run, both as the bundle's own executable:
#
#   1. the start probe reports what this machine has. A runner with no controller
#      has no sources, and that is published as a warning with the app's own line
#      rather than counted as a pass or a failure.
#   2. the connect probe publishes a virtual source from inside the app and then
#      runs the same start the button runs, so the engine's own enumeration finds
#      a source and its connect path runs with no hardware present. The step fails
#      unless the app reports the source created, the engine enumerating it, the
#      port connecting it, and a status line that says a source is connected.
#
# The app's exit status is its verdict: 0 the client and port were created and
# every online source connected, 4 no client, 5 no port, 6 a source the port
# refused. The connect probe adds 7 the system would not publish a source, 8 the
# engine never listed it and 9 it was listed but never attempted; all three fail
# this step, because the connect itself is what that probe is for.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-midi.XXXXXX")"
log="$logdir/start.log"

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

# Runs one probe to completion and prints its whole output, so a failure below
# quotes the app rather than the script. The exit timer is a backstop only: the
# probe exits on its own once it has a verdict, and a probe that never does is
# killed and fails the step.
run_probe() {
  local label="$1" variable="$2" path="$3" pid status deadline
  log="$path"
  printf '== %s ==\n' "$label"
  printf 'bundle         %s\n' "$app"

  env "$variable=1" SUNDAYKEYS_PROBE_EXIT_AFTER=20 "$exe" >"$path" 2>&1 &
  pid=$!
  printf 'pid            %s\n' "$pid"

  deadline=$(( $(date +%s) + 40 ))
  while still_running "$pid"; do
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      still_running "$pid" && kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "$label: the probe did not report a verdict within 40s"
    fi
    sleep 0.2
  done

  status=0
  wait "$pid" || status=$?
  printf 'exit status    %s\n\n' "$status"
  printf -- '---- app output ----\n'
  cat "$path"
  printf -- '---- end app output ----\n\n'
  return "$status"
}

printf '== MIDI probes ==\n\n'

# 1. What this machine has, with no source of our own.
start_status=0
run_probe "MIDI start probe" SUNDAYKEYS_PROBE_START_MIDI "$logdir/start.log" || start_status=$?

grep -qF "SundayKeysApp: MIDI: client created" "$log" || fail "the app never reported a MIDI client; exit status was $start_status"

sources="$(grep -oE 'SundayKeysApp: MIDI: [0-9]+ source\(s\)' "$log" | grep -oE '[0-9]+' | head -n 1 || true)"
[[ -n "$sources" ]] || fail "a MIDI client was created but no source count was reported"
[[ "$start_status" -eq 0 ]] || fail "the client was created but the start probe exited with $start_status instead of 0"

if [[ "$sources" -eq 0 ]]; then
  printf '::warning::this machine has no MIDI sources: the start probe proved the client and input port were created and the source list was empty\n'
  printf 'LIMITATION  no controller here, so the start probe connected nothing\n\n'
else
  printf 'PASS  the start probe enumerated %s source(s) and connected them\n\n' "$sources"
fi

# 2. The connect path, against a source the probe publishes itself.
connect_status=0
run_probe "MIDI connect probe" SUNDAYKEYS_PROBE_MIDI_CONNECT "$logdir/connect.log" || connect_status=$?

grep -qF "SundayKeysApp: MIDI: client created" "$log" || fail "the connect probe's app never reported a MIDI client; exit status was $connect_status"
grep -qF "SundayKeysApp: MIDI probe: virtual source created" "$log" || fail "the app did not publish a virtual MIDI source; exit status was $connect_status"

enumerated="$(grep -oE 'SundayKeysApp: MIDI probe: engine enumerated [0-9]+ source' "$log" | grep -oE '[0-9]+' | head -n 1 || true)"
[[ -n "$enumerated" ]] || fail "the connect probe did not report what the engine enumerated"
[[ "$enumerated" -ge 1 ]] || fail "a virtual source was created but the engine enumerated $enumerated source(s)"

connected="$(grep -oE 'SundayKeysApp: MIDI probe: connected [0-9]+ of' "$log" | grep -oE '[0-9]+' | head -n 1 || true)"
[[ -n "$connected" ]] || fail "the connect probe did not report how many sources the port connected"
[[ "$connected" -ge 1 ]] || fail "the engine enumerated $enumerated source(s) but the port connected none of them"

# The marker stream appends ` pid=<n>` to every line, so the status is stripped
# of it before it is compared, printed and published.
midi_status="$(sed -n 's/^SundayKeysApp: MIDI probe: status: //p' "$log" | sed 's/ pid=[0-9][0-9]*$//' | head -n 1)"
[[ -n "$midi_status" ]] || fail "the connect probe did not report a MIDI status"
[[ "$midi_status" =~ ^MIDI\ ready,\ [1-9][0-9]*\ of\ [1-9][0-9]*\ source\(s\)\ connected$ ]] \
  || fail "the MIDI status does not report a connected source: $midi_status"
[[ "$connect_status" -eq 0 ]] || fail "the app reported a connected source but exited with $connect_status instead of 0"

printf 'PASS  a virtual source was created, the engine enumerated %s source(s), the port connected %s, status: %s\n' "$enumerated" "$connected" "$midi_status"
printf '::notice::MIDI connect probe: virtual source created, engine enumerated %s source(s), connected %s, status: %s\n' "$enumerated" "$connected" "$midi_status"
