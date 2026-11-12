# Task list

One persistent list for the build. It records what is done, what is next, and what is blocked, and it is
kept short on purpose: the evidence for each item lives in `docs/progress.md`, the milestone notes in
`docs/re/`, and the architecture in `docs/clean-room-implementation.md`.

## Done
- [x] **Static analysis** — 89,486 functions decompiled, 3,186 types recovered, 20 documented sections
      (`docs/sunday-keys-2.5.2-analysis.md`).
- [x] **Feature inventory** — capability checklist with Observed / Inferred / Unknown per row
      (`docs/feature-inventory.md`).
- [x] **Package and app shell** — `CSync`, `SundayKeysCore`, `SundayKeysApp`; SwiftUI shell with a
      playable keyboard, patch picker, set list, layer editor, effects panel and controller panel.
- [x] **Audio engine** — `AVAudioEngine` graph, lock-free `SPSCCommandQueue`, wavetable
      `PolyphonicInstrument`, 220 ms release fade, gapless patch switching.
- [x] **MIDI** — CoreMIDI input, source tracking, note/bend/pressure as `RenderCommand`s, per-patch
      controller mapping, program change.
- [x] **Patches and persistence** — `Patch`, `PatchBank` (JSON format 4), `PatchStore`, single-patch
      export and import with refusal for unknown formats.
- [x] **Set list** — ordered slots, id-based play head, wrap and clamp stepping, pruning on delete.
- [x] **Session resume** — `SessionMemory` plus `SessionScope.restore` with remembered / fallback /
      emptyBank and a reason on the status line.
- [x] **Click** — sample-accurate metronome on the render thread, tempo change on the next beat, added
      after the patch's chain so nothing echoes it.
- [x] **Effects chain** — EQ → chorus → stereo delay → reverb inside the render block, settings
      published by seqlock from `patch.effects` to both per-side `EffectChain` instances, one tap per
      side, wet/dry and bit-identical bypass per stage, mono voices split to stereo, right channel
      delivered by `AudioEngineController`. Measured by `EffectTests` and `EffectsStereoTests`, and
      recorded in `docs/re/effects-chain.md`.
- [x] **Render budget** — `RenderBudgetTests` drives the real `renderStereo` path with ten voices and
      every stage engaged, and measures each block on a monotonic clock against the budget the block
      itself implies: 512 frames at 48 kHz is 10,667 µs. On the `macos-15` runner the engaged chain
      measured a **999.4 µs median (9.4% of the block)** with a 2,960.5 µs worst block (27.8%), and the
      same voices with the chain bypassed measured 592.0 µs median (5.5%) with a 1,671.8 µs worst
      (15.7%) — the chain costs 1.7x the dry path. CI fails if the engaged median takes more than a
      quarter of the block or if any single block overruns it, and `.github/workflows/budget.yml`
      prints the numbers as annotations on a pass as well as a failure.
- [x] **Instrument catalogue** — `InstrumentCatalogue` in
      `Sources/SundayKeysCore/Catalogue/InstrumentCatalogue.swift` ships five original synthesised
      voices (`keys`, `bell`, `pad`, `organ`, `electricPiano`) built from `WaveTable`, and the array's
      index is the render thread's table rung. `KeyLayer.instrument` is the stored selection, with
      `timbre` kept as a computed legacy view so a pre-catalogue bank still loads;
      `PolyphonicInstrument` reads one table strip and a layer's rung rather than a bell flag;
      `RealtimeKeysoundEngine.setPatch` publishes every layer's rung on the same lock-free path the
      timbres used; the layer editor's picker offers the catalogue through
      `AppModel.setLayerInstrument(_:instrumentID:)`. `InstrumentCatalogueTests` requires five unique
      ids and rungs, an unknown id falling back to `keys` on rung 0, a bank round trip keeping `pad`, a
      layer encoded without `instrument` decoding from its `timbre`, every pair of instruments rendering
      a tone at least 0.05 apart after the attack, an engine retargeted by `setPatch` rendering
      sample-identical audio to one built on that instrument (1e-6), and `releasingVoices: false` keeping
      the held voice.
- [x] **Strict-concurrency scheduling** — the check is unchanged in substance and now lives in
      `tools/strict_concurrency.sh` (compile with `-strict-concurrency=complete`, prove the flag reached
      `swiftc`, inventory every primary diagnostic, gate the MIDI routing seam). What changed is when it
      is scheduled: `.github/workflows/concurrency.yml` no longer triggers on `push`, it triggers on
      `workflow_run` of `build` completing on `main` and checks out
      `github.event.workflow_run.head_sha`, so the strict job no longer competes with the build for a
      macOS runner. Evidence: `docs/re/ci-runner-queue.md`.
- [x] **Effects panel coverage (model path)** — the panel's controls are exercised through the one
      method they call, `AppModel.updateEffects`, and measured on the samples that path produces.
      `Tests/SundayKeysAppTests/EffectsPanelTests.swift` edits the patch through the model and renders
      `model.patch` on the real `RealtimeKeysoundEngine` at 48 kHz, 512 frames per block, then asserts
      measured facts: the reverb switch changes the rendered samples and leaves the model's status line
      reading `Edited effects on <patch>, not saved yet`; a +12 dB low shelf carries more than 1.5x the
      RMS of the same shelf at -12 dB; the chorus edit changes the wet copy from the bypassed render; the
      two delay taps at 0.08 s and 0.24 s render the sides apart by more than 1e-3 and equal taps bring
      them back under half of that; the wet tail at blocks 70-80 outlives the dry release by more than
      1.5x; and an effect changed while a note sounds, republished with `releasingVoices: false`, leaves
      `voiceCount` unchanged, so a live edit does not cut the held chord. Evidence:
      `docs/re/effects-panel-coverage.md`. This item says nothing about the view the window shows; the
      item below covers that.
- [x] **Effects panel live path** — the panel the window shows is now exercised as that view.
      `Tests/SundayKeysAppTests/EffectsSectionViewTests.swift` hosts the shipped `EffectsSection` in an
      `NSHostingView` at 900x210 with no window and no display, renders the same view with
      `ImageRenderer`, and drives the controls a player touches. Both controls ship as AppKit views with
      real actions and `NSView.identifier`s — `EffectsSwitch`, an `NSButton` checkbox, and
      `EffectsSlider`, an `NSSlider` whose own range is the effect's range — because a hosted SwiftUI
      `Toggle` has no target and no action and a hosted SwiftUI `Slider` carries no identifier. The
      cases require the panel to lay out four switches and eight sliders by name with each slider's
      range, every row to reserve at least 60 points of label column and draw ink, then: clicking
      `effects.reverb.enabled` writes through `AppModel.updateEffects`, leaves the status line reading
      `Edited effects on <patch>, not saved yet`, and changes the rendered samples; a +12 dB shelf
      carries more than 1.5x the RMS of the same shelf at -12 dB; chorus mix 0.5 / rate 3.5 changes the
      wet copy; and the delay's copy arrives at 3,840 frames at 0.08 s and 11,520 at 0.24 s, measured
      against a render whose copy falls outside the 0.64 s window. Evidence:
      `docs/re/effects-panel-view-path.md`. Not claimed: that the panel has been seen or heard, or that
      its labels read back as strings — a detached host publishes no accessibility tree, so the labels
      are proven as the column each row reserves and the ink it draws.

## Next

Nothing reachable is open. Every item still in this list is in Blocked below, because it needs hardware
(an output device, a second interface, a physical controller), a purchase or entitlement, a credential,
or a window this environment does not have. The next pass should start from the capability rows in
`docs/feature-inventory.md` and take one that code alone can close.

## Blocked, and why

- **Nothing has been heard.** No output device, no microphone, no ear and no window are reachable from
  this environment, so every audio claim rests on measured samples and the hosted runner's probes,
  never on listening.
- **Device latency is unmeasurable here.** The render budget is DSP cost on a machine with no output
  device; the round trip through Core Audio, the buffer a real interface asks for and glitch-free
  playback all need hardware that this environment does not have, so the item is recorded rather than
  guessed at.
- **No controller is attached.** Mappings are exercised by synthetic events through `MIDIEventRouter`;
  learn-mode against a physical controller, and the CC numbers the original uses (Unknown), cannot be
  exercised here.
- **Multi-output routing needs more than one device.** `ExclusiveMultiOutMixer`, `MultiOutMixer` and
  `OutputDeviceMapping` are Observed names in the original, and nothing here routes beyond the default
  output, because a second device does not exist in this environment.
- **Purchased instrument downloads and sample libraries cannot be built here.** The original's
  `InstrumentDownloader`, `/api/v1/instruments/search` and `aupresetUrl` are Observed names with an
  Unknown wire and an Unknown container format, the content is licensed and was not copied, and there
  is no entitlement to download it; the catalogue above is synthesised for that reason.
- **The window has never been seen**, so layout, focus and panel behaviour are unverified by eye. The
  effects panel is now driven through its own shipped controls offscreen
  (`docs/re/effects-panel-view-path.md`), but no window was involved, so what a player sees is still
  unverified; the instrument picker is compiled and tested but not viewed.
- **The original app's licence wire, effect parameter ranges, split semantics, MIDI CC numbers and
  session contents remain Unknown** (`docs/feature-inventory.md`, Known limits), so no parity is
  claimed for them.

- [x] **Per-layer stereo position.** `KeyLayer.pan` in -1 to 1, clamped and decoded tolerantly, with bank version 5 defaulting older patches to centre. One `panGains(for:)` balance law keeps centre at unity on both sides. `setLayerPan` rides the live-edit path beside the instrument rung, so a pan moved under a held chord moves without cutting it. The instrument keeps a left and a right gain table per layer and renders both channels in one parameterised voice loop, with the mono path documented as ignoring pan. `AppModel.setLayerPan`, and a pan slider with an L/R/C readout in the layer editor. Six core cases and the model case pass in dispatch job `131204524837`; the record is `docs/re/stereo-position.md`.

## How an item is closed
A box is ticked only when the change is on `main` and the workflows for that head are terminal green:
build with its `Test` step, plus click, patch-transfer, session and concurrency. `concurrency` starts
when the build for the same commit finishes, by design, so it appears later than the rest of the set and
it checks out the commit the build ran for; what makes it evidence is that it runs and succeeds, not
that it queued early. A run that never picks up a runner is not evidence: it is cancelled or re-run and
the reason is recorded.
