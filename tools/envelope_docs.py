#!/usr/bin/env python3
"""Write the persistent record for the per-layer envelope, after the suite is green."""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def lines_of(path):
    return (ROOT / path).read_text(encoding="utf-8").split("\n")


def write(path, lines):
    (ROOT / path).write_text("\n".join(lines), encoding="utf-8")


NOTE = """# Per-layer envelope

A layer now carries its own attack, decay, sustain and release: the four fields the
original's `ADSRModel` names. What the original does with them is **Unknown** - no captured
session, no decompiled body and no parameter range were available - so the law, the ranges
and the defaults below are this repository's own and are claimed as such, not as parity.

## The law, stated once

`LayerEnvelope` (`Sources/SundayKeysCore/Audio/LayerEnvelope.swift`) owns everything:

- Attack runs 1 ms to 5 s, decay 0 to 5 s, sustain 0 to 1 and release 5 ms to 10 s. Every
  stage is clamped on write into the layer, again when it is read back through the type, and
  again on decode, so a hand-edited bank cannot put the voice loop outside the law. A value
  that is not a number takes the documented default instead of the edge, because a NaN in the
  loop would silence a note and never free its voice.
- The defaults are the instrument's original ramp to the sample: an 8 ms linear attack, no
  decay, full sustain and a 220 ms linear release. A bank written before the field existed
  decodes to exactly those, which is what makes the tone and pan work still render
  bit-identically.
- `frames(for:sampleRate:)` is the only conversion from seconds to frames and never returns
  less than one frame, so a ramp cannot divide by zero.
- `holdsLevel` is the render path's fast path: no decay or full sustain means the voice has
  no decay stage to run.

## Where it runs

`PolyphonicInstrument` keeps four per-layer tables - attack frames, decay frames, sustain
level and release frames - written only on the render thread by two commands. The envelope
needed four floats and the ring's slot has two, so it travels as `setLayerAttackDecay`
(attack in `velocity`, decay in `amount`) and `setLayerSustainRelease` (sustain in `velocity`,
release in `amount`) rather than growing the struct: the same reasoning that put the filter's
resonance in `amount`.

The voice loop gains one stage. When the attack completes, a voice with a decay and a sustain
below its peak enters `decay` and falls to `voice.sustainLevel`; otherwise it holds at the
peak, which is what an untouched layer does. Release now divides the voice's own level by its
layer's release frames at the moment the key comes up, so a release time edited under a held
note applies to that note.

`RealtimeKeysoundEngine.setPatch` publishes both commands for every layer beside the timbre,
pan and filter commands, and `setLayerEnvelope(layer:envelope:)` is the live door.
`AppModel.setLayerEnvelope` goes through `editLayer`, the no-release path, so an envelope
moved under a held chord shapes the next note without cutting the one sounding.

The bank is version 7, and `LayerPanTests` now asserts that. A version 6 bank loads with the
default envelope.

## The row the window draws

The layer editor's row is now built from `LayerSlider`s: real `NSSlider`s carrying
`layer.<id>.<parameter>` and their parameter's own range, for gain, pan, tone, resonance,
attack, decay, sustain and release. This is the same move `EffectsSlider` made for the
effects panel, for the same reason: a hosted SwiftUI slider has no identifier and cannot be
driven, so a control that exists only in the model could pass as done. `LayerRow.sliderNames`
is the list the body builds, and `LayerRowViewTests` walks that list against the hosted row.

## Evidence

`Tests/SundayKeysCoreTests/LayerEnvelopeTests.swift`, all at 48 kHz and 512 frames per block:

- the law clamps -1 s, 99 s and NaN on the attack, -3 s and 42 s on the decay, 2 and -2 on the
  sustain and 0 and 1e9 on the release, and `holdsLevel` is true for the defaults;
- a decoded envelope is clamped (9000 s reads back as 5 s, a sustain of 9 as 1) and a layer
  written without the field decodes to the default envelope;
- a layer round-trips all four stages within 1e-6;
- an unset envelope renders sample-identically to the defaults stated explicitly (1e-6);
- a 0.25 s attack holds the third block under 30% of the steady peak and has completed by
  0.27 s;
- a decay to 0.4 reaches 0.4 of the undecayed RMS within 0.06;
- a one second release is still audible 0.3 s after the key came up while a 0.05 s release is
  silent by 0.11 s;
- an envelope edited on the live path keeps the held voice, and the edited 3 s release keeps
  that voice alive at 0.64 s where the instrument's own 220 ms release would have freed it.

`Tests/SundayKeysAppTests/LayerRowViewTests.swift`, hosting the shipped row offscreen:

- the row lays out one slider per parameter per layer, each named `layer.<id>.<parameter>`,
  each with its parameter's own range;
- moving each of the eight sliders writes its own field through the model, leaves the status
  line reading `Edited <patch>, not saved yet`, and a 0.4 s attack written through the row
  holds the first blocks down in the rendered samples.

## Not proven

Nothing was heard: these are rendered samples and a CI measurement, and the envelope's
musical feel on real content is unverified. The row was hosted offscreen and never seen in a
window. The original's attack, decay, sustain and release ranges remain Unknown.
"""

(ROOT / "docs/re/layer-envelope.md").write_text(NOTE, encoding="utf-8")

# ------------------------------------------------------------------ tasks.md

path = "docs/tasks.md"
lines = lines_of(path)
entry = [
    "- [x] **Per-layer envelope.** Each layer now carries an attack, a decay, a sustain and a",
    "      release, the four fields the original's `ADSRModel` names,",
    "      clamped on write, on read and on decode by `LayerEnvelope`, with bank version 7",
    "      defaulting an older patch to the instrument's own 8 ms / no decay / full sustain /",
    "      220 ms ramp. The instrument keeps four per-layer tables and gains one stage: a",
    "      voice with a decay and a sustain below its peak falls to that level and holds there,",
    "      and release divides the voice's own level by its layer's release frames at the",
    "      moment the key comes up. The command carries two stages per slot",
    "      (`setLayerAttackDecay`, `setLayerSustainRelease`) rather than growing the ring's",
    "      struct. `RealtimeKeysoundEngine.setLayerEnvelope` and `AppModel.setLayerEnvelope`",
    "      ride the no-release live-edit path. The layer editor's row is now built from",
    "      `LayerSlider`s - real AppKit sliders named `layer.<id>.<parameter>` with their own",
    "      ranges - so every control it draws can be found and driven.",
    "Eight core cases in",
    "      `LayerEnvelopeTests` measure the law, the decoded defaults, the round trip, a slow",
    "      attack's position, the decay's sustain level, a long and a short release, and the",
    "      live edit on a held note; three cases in `LayerRowViewTests` host the shipped row",
    "      and prove each slider is constructed, carries its range and writes its own field,",
    "      including through to the samples. Evidence: `docs/re/layer-envelope.md`.",
]
for index, line in enumerate(lines):
    if line.strip() == "## How an item is closed":
        lines[index:index] = entry + [""]
        break
else:
    raise SystemExit("tasks.md: no closing section")
write(path, lines)

# ------------------------------------------------------- feature-inventory.md

path = "docs/feature-inventory.md"
lines = lines_of(path)
for index, line in enumerate(lines):
    if line.startswith("| envelope |"):
        lines[index:index + 1] = [
            "| envelope | `ADSRModel` attack, decay, sustain, release, plus fade; built here as",
            "`KeyLayer.envelope` with one `LayerEnvelope` law, banked at version 7",
            "(`docs/re/layer-envelope.md`) | O names, built |",
        ]
        break
else:
    raise SystemExit("feature-inventory.md: no envelope row")

lines.extend([
    "",
    "| per-layer envelope | `LayerEnvelope`'s attack/decay/sustain/release law over",
    "`KeyLayer.envelope`, four per-layer tables and one decay stage in the voice loop, the two",
    "stage commands, and the live `setLayerEnvelope` path | this build's own |",
])
write(path, lines)

# ------------------------------------------------------------------ heads.md

path = "docs/re/heads.md"
lines = lines_of(path)
row = [
    "| this commit | the per-layer envelope (`LayerEnvelope`, `KeyLayer.envelope`, the",
    "  instrument's four tables and decay stage, `setLayerAttackDecay` and",
    "  `setLayerSustainRelease`, `RealtimeKeysoundEngine.setLayerEnvelope`,",
    "  `AppModel.setLayerEnvelope`), `LayerSlider` and the rewritten layer row, the bank version",
    "  at 7 with `LayerPanTests` asserting it, `LayerEnvelopeTests`, `LayerRowViewTests`,",
    "  `docs/re/layer-envelope.md`, `docs/tasks.md`, `docs/feature-inventory.md` and the removal",
    "  of this job's own workflow and scripts | pushed with the job's repository token, so no",
    "  runs were started on this head; the suite that qualifies it is in the dispatch job that",
    "  pushed it, and the permanent workflows are dispatched against this commit afterwards",
    "  because the job's token suppresses push triggers |",
]
for index, line in enumerate(lines):
    if line.strip() == "## What the runs prove":
        lines[index:index] = row + [""]
        break
else:
    raise SystemExit("heads.md: no proof section")
write(path, lines)

print("record written")
