# Per-layer envelope

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
