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
      measured a **999.4 µs median (9.4% of the block)** with a 2,960.5 µs worst block (27.8%), and
      the same voices with the chain bypassed measured 592.0 µs median (5.5%) with a 1,671.8 µs worst
      (15.7%) — the chain costs 1.7x the dry path. CI fails if the engaged median takes more than a
      quarter of the block or if any single block overruns it, and `.github/workflows/budget.yml`
      prints the numbers as annotations on a pass as well as a failure.

## Next
- [ ] **Device latency** — the budget above is DSP cost measured in isolation on a runner with no
      output device. The round trip through Core Audio, the buffer a real interface asks for, and
      glitch-free playback on hardware are still unmeasured.
- [ ] **Effects panel coverage** — the panel controls exist, but nobody has looked at the window; a
      pass should drive it through the probes and record what it does to the sound.
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
- **The render budget is DSP cost in isolation**: 999 µs of a 10.67 ms block is what the chain costs
  here, on a machine with no interface attached, not what a player would hear.
- **No controller is attached**, so mappings are exercised by synthetic events only.
- **The window has never been seen**, so layout, focus and panel behaviour are unverified by eye.
- **The original app's licence wire, effect parameter ranges, split semantics, MIDI CC numbers and
  session contents remain Unknown** (`docs/feature-inventory.md`, Known limits), so no parity is
  claimed for them.

## How an item is closed
A box is ticked only when the change is on `main` and the workflows for that head are terminal green:
build with its `Test` step, plus click, patch-transfer, session and concurrency. A run that never
picked up a runner is not evidence and is cancelled and re-run.
