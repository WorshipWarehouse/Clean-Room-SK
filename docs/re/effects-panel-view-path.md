# The effects panel's live path

This note records the milestone that closed the last reachable gap in the effects panel: the
panel's controls exist, and `AppModel.updateEffects` was already proven against measured DSP
output, but nothing had shown that the shipped panel view was reachable and wired. The controls
had only ever been exercised by calling the model method they are supposed to call.

Hand-written by the agent through the GitHub API. The bytes were written with the Git data API
(`create blob` -> `create tree` -> `create commit` -> `update reference`); no runner moved them and
no runner authored any part of this file.

## What ships

`Sources/SundayKeysApp/EffectsSection.swift` is the panel the window shows. It is a type of its own
rather than a private property of `ContentView`, so the panel a test lays out is the panel that
ships. `ContentView` presents it, and an empty `EffectsSection` cannot silently pass a test that
renders it, because there is only one view.

Two controls carry the panel's edits, and both are AppKit views with a real target and action:

- `EffectsSwitch` - `NSViewRepresentable` around `NSButton(checkboxWithTitle:target:action:)`. Its
action reads the box's own state and calls `AppModel.updateEffects`. It sets
  `NSView.identifier` to the control's name.
- `EffectsSlider` - `NSViewRepresentable` around `NSSlider(value:minValue:maxValue:target:action:)`.
  Its own range is the effect's range (`-12...12` dB for a shelf, `0.02...1.2` s for the delay
  time, and so on), its action passes `doubleValue` through `AppModel.updateEffects`, and it sets
  `NSView.identifier` too.

Both exist because a SwiftUI control hosted offscreen cannot be operated. The evidence is in the
failing runs quoted below, not in an assumption.

## The cases and what they assert

`Tests/SundayKeysAppTests/EffectsSectionViewTests.swift` hosts the shipped view in an
`NSHostingView` at 900x210 with no window and no display, and renders the same view with
`ImageRenderer` at scale 1.

`testTheShippedPanelLaysOutAndCarriesItsLabels`

- The hosting view fits taller than 40 points and wider than 300, so it laid out rather than
  collapsing.
- The render is at least 800x120 and its dark-pixel share is above 0.005, so a blank render fails.
- The panel lays out exactly four `NSButton`s and eight `NSSlider`s, and every one of the twelve
  identifiers (`effects.eq.enabled`, `effects.eq.lowGain`, ... `effects.reverb.decay`) is present on
  a control.
- Each slider's own `minValue`/`maxValue` equals the range the effect accepts, within 1e-9, so a
  pointer reaches the value the model stores rather than a normalised 0...1.
- For each of the four rows: the switch and the first slider share a mid-line within 12 points; at
  least 60 points of label column separate the switch from its first slider; at least 80 points
  separate the two sliders, with the reading between them; and the band the row occupies draws more
  than 0.2% ink.
- The band under the last row draws more than 0.2% ink, which is the footnote.

`testTheReverbSwitchReachesTheModelAndTheAudio`

- `performClick(nil)` on the shipped checkbox, with the model read back after a layout and 20 ms
  run-loop settle.
- The patch's reverb is enabled and `bankStatus` reads
`Edited effects on <patch>, not saved yet`.
- Moving the mix to 0.6 and the decay to 0.85 writes those values through the sliders.
- The rendered left channel differs from the pre-edit render by more than 1e-3.

`testTheEQSlidersBoostAndCutMeasurably`

- Enabling EQ and moving `effects.eq.lowGain` to +12 then -12 writes both values.
- The RMS of the +12 dB render is more than 1.5x the RMS of the -12 dB render.

`testTheChorusControlsChangeTheWetCopy`

- Enabling chorus and moving mix to 0.5 and rate to 3.5 writes both; the rendered left channel
  differs from the bypassed render by more than 1e-3.

`testTheDelayTimeSliderMovesTheTapInTheRenderedSamples`

- Enabling delay, mix 0.6. A first render at `time = 1.0 s` carries no copy inside the 60 blocks
  rendered (30,720 frames, 0.64 s); it is the baseline, so the dry path and the mix are identical
  between baseline and measurement.
- At `time = 0.08 s` the first sample where the render differs from the baseline is 3,840 +/- 1,024
  frames; at `time = 0.24 s` it is 11,520 +/- 1,024; the second is more than 6,000 frames later than
  the first.

Every render is the real `RealtimeKeysoundEngine` at 48 kHz and 512 frames per block, driven from
`model.patch` after the control was touched. Nothing here starts a device, opens a window or fakes a
stage of the chain.

## Defects found, and how each was fixed

The panel was driven four times before it passed. Each failure named the next real break:

1. `FocusRingNSButton[id= enabled=true state=1 target=nil action=nil]` - the SwiftUI toggle behind a
   row has neither target nor action, and `accessibilityPerformPress()` could not be reached either
   because a detached host publishes no accessibility elements (`the tree carries []`). Fixed by
   shipping `EffectsSwitch`.
2. `CustomMarkedSlider[id= enabled=false]` x8 - the SwiftUI slider behind a row carries an empty
   identifier, so a query by name had nothing to match, and the rows were disabled because every
   stage starts bypassed. Fixed by shipping `EffectsSlider` with the identifier and the effect's own
   range on the control, and by disabling the slider itself rather than through a SwiftUI
   `.disabled`.
3. `("7.0") is not equal to ("3840.0")` - the delay was measured against a bypassed render, and
   enabling the stage attenuates the dry path, so the first difference was the attack at frame 7.
   Fixed by measuring against a render at `time = 1.0 s` with the same mix and no copy in the window.
4. `the panel should label low; saw []` - a detached host publishes no accessibility tree, and
   SwiftUI draws text itself instead of hosting `NSTextField`s, so no glyph was ever going to be
   read back as a string. Fixed by verifying the labels as what a render contains: the label column
   each row reserves and the ink each row and the footnote draw.

## Run evidence

Head `cf0e45f2` on `main`:

| Workflow | Run | Job | Window (UTC) |
| --- | --- | --- | --- |

See `docs/re/heads.md` for the filled-in table of that head; the run identifiers are recorded there
with their windows so they are not duplicated in two places.

## What is not verified

- The panel has never been seen in a window. There is no display in this environment, so layout,
  focus, keyboard traversal and what the panel looks like to a player remain unverified by eye.
- Nothing was heard. The measurements are rendered samples; no output device and no ear were
  involved, so nothing here says the effects sound good, only that each control changes the samples
  in the measured direction.
- The labels are not read back as strings: the row geometry proves the label column is reserved and
  the ink proves the rows and the footnote draw, but no test confirms that the glyphs spell "Reverb".
- A pointer was not used. The controls were driven through the same target/action and identifiers a
  pointer and VoiceOver reach, but no real mouse or assistive session touched them.
