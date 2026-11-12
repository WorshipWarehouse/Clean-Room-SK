# Per-layer stereo position

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

Green inside dispatch job `131204524837` (run `43224621165`):
`swift build --build-tests` held `13:09:44-13:10:16` and the whole suite held
`13:10:16-13:10:23`.

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
