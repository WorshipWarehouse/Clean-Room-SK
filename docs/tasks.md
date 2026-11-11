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

## Next

- [ ] **Effects panel coverage** — the panel controls exist, but nobody has looked at the window; a
      pass should drive it through the probes and record what it does to the sound.
- [ ] **Latency and CPU measurement** — the render path is allocation-free by inspection, but no
      measured block-time budget exists for a full patch at 48 kHz with the chain engaged.
- [ ] **Controller coverage** — one mapped layout is tested; learn-mode against a physical controller
      has not been exercised because none is attached.
- [ ] **Instrument management** — the catalogue models and the download path are not built; sounds are
      synthesised wavetables, not sampled libraries.
- [ ] **Multi-output routing** — `AudioEffectApi`-level multi-output behaviour in the original is
      Observed by name only; nothing here routes to more than the default output.

## Blocked, and why

- **Nothing has been heard.** No output device, no microphone, no ear and no window are reachable from
  this environment, so every audio claim rests on measured samples and the hosted runner's probes,
  never on listening.
- **No controller is attached**, so mappings are exercised by synthetic events only.
- **The window has never been seen**, so layout, focus and panel behaviour are unverified by eye.
- **The original app's licence wire, effect parameter ranges, split semantics, MIDI CC numbers and
  session contents remain Unknown** (`docs/feature-inventory.md`, Known limits), so no parity is
  claimed for them.

## How an item is closed

A box is ticked only when the change is on `main` and the workflows for that head are terminal green:
build with its `Test` step, plus click, patch-transfer, session and concurrency. A run that never
picked up a runner is not evidence and is cancelled and re-run.
