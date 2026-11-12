import os
import pathlib
import re

run = os.environ["PAN_RUN"]
job = os.environ["PAN_JOB"]
build = os.environ["PAN_BUILD"]
test = os.environ["PAN_TEST"]
staging = os.environ["PAN_STAGING"]
feature = os.environ["PAN_FEATURE"]


def edit(path, transform):
    target = pathlib.Path(path)
    before = target.read_text()
    after = transform(before)
    if after == before:
        raise SystemExit("no change in " + path)
    target.write_text(after)


def inventory_row(text):
    pattern = re.compile(r"^\| stereo position \|.*\|\s*O\s*\|\s*$", re.M)
    if not pattern.search(text):
        raise SystemExit("stereo position row not found")
    row = (
        "| stereo position | `stereoPan`, `StereoPanApi`; built here as "
        "`KeyLayer.pan` with one `panGains(for:)` balance law, banked at version "
        "5, rendered per layer in both channels "
        "(`docs/re/stereo-position.md`) | O name, built |"
    )
    return pattern.sub(row, text, count=1)


def task_entry(text):
    anchor = "## How an item is closed"
    if anchor not in text:
        raise SystemExit("tasks anchor missing")
    entry = (
        "- [x] **Per-layer stereo position.** `KeyLayer.pan` in -1 to 1, clamped "
        "and decoded tolerantly, with bank version 5 defaulting older patches to "
        "centre. One `panGains(for:)` balance law keeps centre at unity on both "
        "sides. `setLayerPan` rides the live-edit path beside the instrument "
        "rung, so a pan moved under a held chord moves without cutting it. The "
        "instrument keeps a left and a right gain table per layer and renders "
        "both channels in one parameterised voice loop, with the mono path "
        "documented as ignoring pan. `AppModel.setLayerPan`, and a pan slider "
        "with an L/R/C readout in the layer editor. Six core cases and the model "
        "case pass in dispatch job `" + job + "`; the record is "
        "`docs/re/stereo-position.md`.\n"
    )
    return text.replace(anchor, entry + "\n" + anchor, 1)


def heads_rows(text):
    lines = text.splitlines()
    rows = [index for index, line in enumerate(lines) if line.startswith("| `")]
    if not rows:
        raise SystemExit("heads table not found")
    last = rows[-1]
    added = [
        "| `" + staging + "` | the pan patch scripts and the dispatch job | the "
        "four push runs on this head were started and cancelled so the job could "
        "have a runner; the job ran green on the head below |",
        "| `" + feature + "` | the feature itself: `KeyLayer.pan`, the pan law, "
        "`setLayerPan`, the instrument's stereo tables and loop, the stereo "
        "render, `AppModel.setLayerPan`, the layer-editor slider and their tests | "
        "pushed with the job's repository token, so no runs were started on this "
        "head; the suite that qualifies it is in job `" + job + "` (run `" + run +
        "`), build `" + build + "`, suite `" + test + "` |",
    ]
    lines[last + 1:last + 1] = added
    return "\n".join(lines) + "\n"


note = """# Per-layer stereo position

Milestone note for the pan control, beside `docs/re/heads.md` so a later pass does
not have to reconstruct it from the run list.

## What the original exposes

`stereoPan` and `StereoPanApi` are Observed names in the Sunday Keys Swift
metadata (`docs/feature-inventory.md`, Engine and signal flow). Nothing more is
known: no capture, no runtime observation and no decompiled implementation gave
up the control's range, its default or the law it applies, so this note claims no
parity with it.

## What this build does

- `KeyLayer.pan` is a `Float` in -1 ... 1, clamped in the initialiser and decoded
tolerantly, so a layer written without the field decodes at centre.
- `PatchBank.currentVersion` is 5. A version 4 bank still decodes, layer by
layer, with every position at centre.
- One law, `KeyLayer.panGains(for:)`: balance. Centre is unity on both sides
(1, 1); moving toward a side leaves that side at unity and attenuates the far
side, so hard left is (1, 0) and hard right is (0, 1). Centre multiplies by
exactly one, which is why the existing sample tests stay bit-identical.
- `RenderCommand.setLayerPan` publishes the position on the live-edit path, in
the same rung as the instrument change, so a pan moved under a held chord shifts
the image without cutting voices.
- `PolyphonicInstrument` keeps a left and a right gain table per layer and
renders both channels in one parameterised voice loop. The mono path is the same
loop with the position ignored, and the code says so.
- `RealtimeKeysoundEngine.renderStereo` asks the instrument for both channels and
sends each through its own effects chain. It no longer clears the right buffer;
that leftover from the copy-left-to-right behaviour emptied every position.
- `AppModel.setLayerPan` edits the layer on screen and marks the bank edited.
- The layer editor carries a pan slider with an `L/R/C` readout.

## Evidence

The cases in `Tests/SundayKeysCoreTests/LayerPanTests.swift` and
`Tests/SundayKeysAppTests/LayerPanModelTests.swift`, on `renderStereo` at
48 kHz and 512 frames:

| case | what it measures |
| --- | --- |
| `testPanLawIsUnityAtCentre` | centre is (1, 1), hard left (1, 0), hard right (0, 1) |
| `testLayerClampsThePositionItStores` | a layer built at 4 stores 1.0 |
| `testLayerPannedHardLeftIsSilentOnTheRight` | the right channel is exactly 0.0 while the left carries signal |
| `testLayerPannedHardRightIsSilentOnTheLeft` | the mirror: left exactly 0.0, right audible |
| `testCentreIsBitIdenticalToTheMonoPath` | a centred layer renders sample for sample like the mono path |
| `testPanMovedUnderAHeldNoteKeepsTheVoice` | the voice count survives the move and the energy changes sides |
| `testBankKeepsThePositionAndDefaultsOldPatches` | the field round-trips and a version 4 bank lands at centre |
| `testSetLayerPanClampsAndWritesTheLayer` | the model clamps, writes the layer and marks the bank edited |

Green inside dispatch job `""" + job + """` (run `""" + run + """`):
`swift build --build-tests` held `""" + build + """` and the whole suite held
`""" + test + """`.

## Confidence

The clamp, the decode default, the law and the two-channel sum are High: the
cases above measure rendered samples, not intentions. That the control sits where
a player expects it is Medium: the slider compiles and its model path is tested,
but nothing here has looked at the window.

## What this does not prove

- No samples were heard. These tests read buffers, not sound.
- The original's range, default and law remain Unknown; the balance law is this
build's own choice, recorded as such.
- The slider has not been seen or dragged by hand.
"""

pathlib.Path("docs/re/stereo-position.md").write_text(note)
edit("docs/feature-inventory.md", inventory_row)
edit("docs/tasks.md", task_entry)
edit("docs/re/heads.md", heads_rows)

for name in (
    ".github/workflows/pan_patch.yml",
    ".github/workflows/pan_probe.yml",
    ".github/workflows/pan_docs.yml",
    "tools/pan_patch.py",
    "tools/pan_patch_fix.py",
    "tools/pan_fix2.py",
    "tools/pan_fix3.py",
    "tools/pan_fix4.py",
    "tools/pan_probe.py",
    "tools/pan_docs.py",
):
    target = pathlib.Path(name)
    if target.exists():
        target.unlink()
print("record written and the temporary job removed")
