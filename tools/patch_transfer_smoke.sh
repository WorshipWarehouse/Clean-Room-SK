#!/usr/bin/env bash
# Patch transfer probe: does the running app write one patch to a file, read it back
# unchanged, and refuse every document it cannot honestly interpret?
#
# Usage:
#   tools/patch_transfer_smoke.sh              use build/SundayKeys.app, bundling it if absent
#   tools/patch_transfer_smoke.sh --app PATH   check a bundle that already exists
#
# The round trip and each refusal are also asserted by
# Tests/SundayKeysCoreTests/PatchDocumentTests.swift, which is where the model
# behaviour belongs. This script covers the step those tests cannot reach: the app's
# own process, its own Application Support folder and a real file on disk. It needs no
# audio device and no controller, so unlike the launch, audio and click probes it has
# no limitation branch - either the file round trip held and the bad documents were
# refused, or the app exits non-zero and the step is red.

set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app=build/SundayKeys.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

exe="$app/Contents/MacOS/SundayKeysApp"
logdir="$(mktemp -d "${TMPDIR:-/tmp}/sundaykeys-patch.XXXXXX")"
log="$logdir/patch.log"
: > "$log"

if [[ ! -d "$app" ]]; then
  printf 'no bundle at %s; running tools/bundle_app.sh\n' "$app"
  bash tools/bundle_app.sh
fi
[[ -x "$exe" ]] || { printf '::error::no executable at %s\n' "$exe"; exit 1; }

fail() {
  printf '\nFAIL  %s\n' "$1" >&2
  printf '::error::patch transfer check: %s\n' "$1"
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

# The probe writes into a HOME of its own, so the exports it creates land in a
# temporary Application Support folder and can never touch a real player's session.
home="$logdir/home"
mkdir -p "$home"

printf '== patch transfer probe ==\n'
printf 'bundle         %s\n'
printf 'home           %s\n\n' "$home" "$app"

HOME="$home" SUNDAYKEYS_PROBE_PATCH_TRANSFER=1 SUNDAYKEYS_PROBE_EXIT_AFTER=20 "$exe" >"$log" 2>&1 &
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

grep -qF "patch transfer probe: wrote Probe Pad to" "$log" || fail "the app never wrote the patch document"
grep -qF "patch transfer probe: read back Probe Pad:" "$log" || fail "the app never read the document back"
grep -qF "patch transfer probe: refused the newer version:" "$log" || fail "a newer document version was not refused"
grep -qF "patch transfer probe: refused the foreign format:" "$log" || fail "a foreign format was not refused"
grep -qF "patch transfer probe: refused the missing file:" "$log" || fail "a missing file was not reported as a typed refusal"
grep -qF "patch transfer probe: adoption kept both patches" "$log" || fail "adoption did not keep both patches"
[[ "$status" -eq 0 ]] || fail "the probe reported a verdict, but the app exited with $status"

printf '\nPASS  the running app wrote the patch as a file, read it back unchanged and refused what it cannot read\n'
