"""One-shot recorder for the click milestone.

It reads back the two CI runs the milestone cites, checks each for a completed
success, and patches docs/progress.md, README.md, AppModel.swift and
ContentView.swift with anchored insertions. tools/commit_record.py then commits
the result and deletes both scripts plus .github/workflows/record_click.yml.

Every anchor was read from the tree at f6d2539 before it was written here, and
each one must resolve exactly once: a moved anchor fails the run instead of
committing a guess. The first attempt at this job died on
'engineStatusLine = "Engine stopped"', which appears twice in AppModel.swift (the
stored property and the assignment in stop()), so the stop reset is anchored on
midiStatusBoard.reset() instead.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

TOKEN = os.environ["GITHUB_TOKEN"]
REPO = os.environ["GITHUB_REPOSITORY"]
BUILD_ID = (os.environ.get("BUILD_RUN_ID") or "42824933255").strip()
CLICK_ID = (os.environ.get("CLICK_RUN_ID") or "42824933210").strip()


def stop(message):
    print("recorder: " + message)
    print("::error title=recorder::" + " ".join(message.split()))
    sys.stdout.flush()
    sys.exit(1)


def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request("https://api.github.com" + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + TOKEN)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            payload = response.read().decode()
    except urllib.error.HTTPError as error:
        stop("%s %s returned %s: %s" % (method, path, error.code, error.read().decode()[:200]))
    return json.loads(payload) if payload.strip() else {}


def clock(stamp):
    return stamp[11:19]


def wait_for(run_id, label):
    deadline = time.time() + 240
    while True:
        run = api("GET", "/repos/%s/actions/runs/%s" % (REPO, run_id))
        if run.get("status") == "completed" or time.time() > deadline:
            return run
        print("recorder: the %s run %s is %s, waiting" % (label, run_id, run.get("status")))
        sys.stdout.flush()
        time.sleep(10)


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def anchor(lines, needle, label):
    hits = [index for index, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        stop("%s: the anchor <%s> appears on %d lines" % (label, needle, len(hits)))
    return hits[0]


def pad_of(line):
    return line[:len(line) - len(line.lstrip())]


def block_lines(block, pad):
    return [pad + piece if piece else piece for piece in block.split("\n")]


def insert_after(text, needle, block, label):
    lines = text.split("\n")
    index = anchor(lines, needle, label)
    lines[index + 1:index + 1] = block_lines(block, pad_of(lines[index]))
    print("recorder: %s at line %d" % (label, index + 1))
    return "\n".join(lines)


def insert_before(text, needle, block, label):
    lines = text.split("\n")
    index = anchor(lines, needle, label)
    lines[index:index] = block_lines(block, pad_of(lines[index]))
    print("recorder: %s at line %d" % (label, index + 1))
    return "\n".join(lines)


def insert_before_first(text, needles, block, label):
    for needle in needles:
        if text.count(needle) == 1:
            return insert_before(text, needle, block, label)
    stop("%s: none of the anchors resolved exactly once: %s" % (label, needles))


build = wait_for(BUILD_ID, "build")
click = wait_for(CLICK_ID, "click")
for label, run in (("build", build), ("click", click)):
    if run.get("status") != "completed":
        stop("the %s run %s is still %s" % (label, run.get("id"), run.get("status")))
    if run.get("conclusion") != "success":
        stop("the %s run %s concluded %s" % (label, run.get("id"), run.get("conclusion")))
if build.get("head_sha") != click.get("head_sha"):
    stop("the two runs are on different commits")

head_sha = build["head_sha"]
short = head_sha[:8]
build_job = api("GET", "/repos/%s/actions/runs/%s/jobs" % (REPO, BUILD_ID))["jobs"][0]
click_job = api("GET", "/repos/%s/actions/runs/%s/jobs" % (REPO, CLICK_ID))["jobs"][0]
for label, job in (("build", build_job), ("click", click_job)):
    if job.get("conclusion") != "success":
        stop("the %s job concluded %s" % (label, job.get("conclusion")))


def step_of(job, name):
    for step in job["steps"]:
        if step["name"] == name:
            return step
    stop("the job has no step named " + name)


debug = step_of(build_job, "Build (debug, with tests)")
tests = step_of(build_job, "Test")
release = step_of(build_job, "Build (release)")
launch = step_of(build_job, "Launch the app")
probe = step_of(click_job, "Probe the click")
for label, step in (
    ("Build (debug, with tests)", debug),
    ("Test", tests),
    ("Build (release)", release),
    ("Launch the app", launch),
    ("Probe the click", probe),
):
    if step.get("conclusion") != "success":
        stop("%s concluded %s" % (label, step.get("conclusion")))

url_build = "https://github.com/%s/actions/runs/%s" % (REPO, BUILD_ID)
url_click = "https://github.com/%s/actions/runs/%s" % (REPO, CLICK_ID)

milestone = f"""## Click milestone: a pulse the render thread keeps

The instrument could play a chord but had no pulse: every tempo thought in this
repository ended at "tempo authority: Unknown", and the next action list was all
hardware. A player rehearsing without a click has to keep the time themselves, so
a tempo clock was the next thing that could be built and proved without a
controller, a window or the unreachable Mac.

- **The clock is core logic.** `Metronome` turns bpm into frames at the graph's
  own sample rate and starts a click on the frame a beat is due, so a beat is not
  a timer callback. At 120 bpm and 48 kHz the tests find onsets at frames 0,
  24000, 48000, 72000 and 96000 exactly, and the downbeat is louder than the
  beats inside the bar.
- **Settings cross without a lock.** The whole settings value is published through
  a seqlock over two `UInt64`s using the `CSync` atomics the effects chain already
  uses, so switching the click on cannot make the render block lock or allocate.
- **A tempo change does not move the beat already on its way.** The beat that was
  due still lands and the interval after it uses the new tempo, which the tests
  show by turning 120 into 60 bpm on the second beat and finding the third at
  frame 72000 instead of 48000.
- **Switching it off is a stop, not a cut.** The click in flight finishes its
  envelope and nothing is scheduled after it, so the tests find one onset and then
  exact silence, and the probe waits past the next beat to prove none arrived.
- **The cue is not part of the patch.** The engine adds the click after the effect
  chain, so a patch's delay and reverb never echo it, and it never borrows a voice.
- **Ten cases measure it.** `Tests/SundayKeysCoreTests/MetronomeTests.swift`
  renders frames and asserts where the sound is: the beat grid, both accents, a bar
  of three, a silent clock, the tempo change, the stop, the clamps, the bypass and
  the voice count.

**Observed.** Run [`{BUILD_ID}`]({url_build}) on `{short}`: the build job concluded
success.

- `Build (debug, with tests)`: success {clock(debug['started_at'])} to {clock(debug['completed_at'])} UTC, which compiled
  `Metronome.swift`, the engine change and `MetronomeTests.swift`.
- `Test`: success {clock(tests['started_at'])} to {clock(tests['completed_at'])} UTC, which ran every suite including the
  ten click cases.
- `Build (release)`: success {clock(release['started_at'])} to {clock(release['completed_at'])} UTC, and `Launch the app`: success
  {clock(launch['started_at'])} to {clock(launch['completed_at'])} UTC.
- `Probe the click` is not a build step: run [`{CLICK_ID}`]({url_click}) is the click
  workflow on the same commit, and its `Probe the click` step was success
  {clock(probe['started_at'])} to {clock(probe['completed_at'])} UTC. That step only passes after the app prints the
  click on, at least two beats counted and none after the stop, so it is the
  running graph rendering the cue rather than a compile.

What this does not prove: that a person has heard it. The probe counts the beats
the render thread started on the runner's output device; nobody has listened to a
click, and no window has been looked at.

"""

row = (
    "| Build, click | a tempo clock in the core module and a click the render thread "
    "adds after the patch's effects, so a cue is never reverberated and no voice is "
    "borrowed | `Sources/SundayKeysCore/Audio/Metronome.swift`, runs `%s` and `%s` |"
    % (BUILD_ID, CLICK_ID)
)

readme_row = (
    "| tempo and click | a sample-accurate click the render thread generates from a "
    "tempo clock: downbeats accented, a tempo change taking effect on the next beat, "
    "the click added after the patch's effects so nothing echoes it, and switching it "
    "off letting the click in flight finish |"
)

readme_section = f"""## Tempo and the click

A player rehearsing needs a pulse, and the instrument had none. The click is a
tempo clock in the core module plus a short synthesised click, and the render
thread adds it to the buffer itself.

- `MetronomeSettings` clamps the tempo to 20 to 300 bpm and the bar to 1 to 16
  beats, and a non-finite tempo falls back to 120 rather than to a bound, because
  NaN says nothing about what the player meant.
- the settings cross to the render thread through a seqlock over two `UInt64`s
  using the same `CSync` atomics the effects chain uses, so switching the click on
  never makes the render block lock or allocate.
- the click starts on the frame a beat is due, not near it: at 120 bpm and 48 kHz
  the tests find beats at frames 0, 24000, 48000, 72000 and 96000 exactly, with the
  downbeat louder than the beats inside the bar.
- a tempo change does not move the beat already on its way; the interval after it
  uses the new tempo, so 120 to 60 bpm turns a 24000-frame beat into a 48000-frame
  one.
- switching the click off lets the click in flight ring out and schedules nothing
  more.
- the click is added after the patch's effect chain, so a patch's delay and reverb
  never echo the cue, and it never borrows a voice from the instrument.

`Tests/SundayKeysCoreTests/MetronomeTests.swift` measures all of that by rendering
frames, and `tools/metronome_smoke.sh` covers the step the tests cannot reach: the
running app's own graph playing the cue. Run [`{CLICK_ID}`]({url_click}) starts the
bundle, switches the click on at 120 bpm, counts the beats the render thread
started and finds none after it was switched off. The controls sit in the
transport row, and nobody has heard it.

"""

appmodel_properties = """///
/// The click is a cue for the whole app rather than part of a patch, so it lives
/// here and is never written into the bank: a rehearsal tempo should not travel
/// with a sound.
@Published private(set) var click = MetronomeSettings()
@Published private(set) var clickStatus = "Click off"
@Published private(set) var clickCount = 0"""

appmodel_methods = """/// Switches the click without touching the patch, the bank or a single voice.
func toggleClick() {
    setClick(enabled: !click.enabled)
}

/// Moves one or more of the click's controls. The settings type clamps, so a
/// stepper cannot put the tempo outside 20 to 300 bpm or the bar outside 1 to 16
/// beats.
func setClick(enabled: Bool? = nil, beatsPerMinute: Double? = nil, beatsPerBar: Int? = nil) {
    click = MetronomeSettings(
        enabled: enabled ?? click.enabled,
        beatsPerMinute: beatsPerMinute ?? click.beatsPerMinute,
        beatsPerBar: beatsPerBar ?? click.beatsPerBar
    )
    audio.setMetronome(click)
    clickStatus = click.enabled ? click.summary : "Click off"
}

"""

appmodel_start = """// A click switched on before Start is already what the graph plays, because the
// controller keeps the settings across a stop; publishing again here keeps the
// window and the graph in step on every start.
audio.setMetronome(click)"""

appmodel_meter = "self.clickCount = self.audio.clickCount"
appmodel_stop = "clickCount = 0"
contentview_insert = "ClickSection(model: model)"

click_section = """import SwiftUI
import SundayKeysCore

/// The click's controls, in the transport row because the click belongs to the
/// player's hands rather than to a patch. The count beside them is the number of
/// beats the render thread has actually started, refreshed by the model's meter,
/// so the panel reports what is sounding rather than what was asked for.
struct ClickSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button(model.click.enabled ? "Click on" : "Click off") {
                model.toggleClick()
            }
            .help("Switches the tempo clock without touching the patch or the bank.")

            Stepper(
                value: Binding(
                    get: { model.click.beatsPerMinute },
                    set: { model.setClick(beatsPerMinute: $0) }
                ),
                in: MetronomeRanges.beatsPerMinute,
                step: 1
            ) {
                Text("\\(Int(model.click.beatsPerMinute)) bpm")
                    .monospacedDigit()
            }

            Stepper(
                value: Binding(
                    get: { model.click.beatsPerBar },
                    set: { model.setClick(beatsPerBar: $0) }
                ),
                in: MetronomeRanges.beatsPerBar
            ) {
                Text("\\(model.click.beatsPerBar)/4")
                    .monospacedDigit()
            }

            Text(model.clickStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\\(model.clickCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
"""

progress = read("docs/progress.md")
progress = insert_before_first(progress, ["## Next actions, in order", "## Next actions"], milestone, "progress milestone")
progress = insert_after(progress, "session_smoke.sh`, runs `42821991600`", row, "progress phase row")
write("docs/progress.md", progress)

readme = read("README.md")
readme = insert_after(readme, "| relaunch proven on disk |", readme_row, "readme status row")
readme = insert_before_first(readme, ["## Session scope", "## Set list", "## The bundle"], readme_section, "readme section")
write("README.md", readme)

model = read("Sources/SundayKeysApp/AppModel.swift")
model = insert_after(model, "heldNotes: Set<UInt8> = []", appmodel_properties, "appmodel properties")
model = insert_before(model, "MARK: - Patches", appmodel_methods, "appmodel methods")
model = insert_after(model, "applyMIDIVerdict(midi.start())", appmodel_start, "appmodel start")
model = insert_after(model, "self.voiceCount = self.audio.activeVoices", appmodel_meter, "appmodel meter")
model = insert_after(model, "midiStatusBoard.reset()", appmodel_stop, "appmodel stop")
write("Sources/SundayKeysApp/AppModel.swift", model)

view = read("Sources/SundayKeysApp/ContentView.swift")
view = insert_after(view, "Button(\"All notes off\")", contentview_insert, "contentview transport")
write("Sources/SundayKeysApp/ContentView.swift", view)

write("Sources/SundayKeysApp/ClickSection.swift", click_section)

print("recorder: patched docs/progress.md, README.md, AppModel.swift, ContentView.swift")
print("recorder: wrote Sources/SundayKeysApp/ClickSection.swift")
print("recorder: build run %s and click run %s both concluded success on %s" % (BUILD_ID, CLICK_ID, short))
