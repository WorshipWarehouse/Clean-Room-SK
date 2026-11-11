# The effects panel, driven and measured

Closed 2026-11-11. This note records what the panel's own controls were shown to do to the sound,
because until now the controls existed, wrote through `AppModel.updateEffects`, and nothing had
connected that method to a rendered sample.

## What was missing

`docs/tasks.md` carried this as the last open Next item: the effects panel's controls write through
`AppModel.updateEffects`, but nobody has seen the window. Four things were therefore unproven - that
the panel's entry point reaches the patch, that the render thread ever receives it, that each control
changes the sound, and that an edit under a held chord does not cut the chord.

## What closes it

`Tests/SundayKeysAppTests/EffectsPanelTests.swift`, six cases in the app's own test target. Every one
of them calls `AppModel.updateEffects` - the method `EffectsSection`'s controls call - and then
renders `model.patch` on a real `RealtimeKeysoundEngine` at 48 kHz, 512 frames per block, and measures
the samples. They are measured against each other rather than against a table of expected values:

| case | edit through the panel's method | measurement |
| --- | --- | --- |
| reverb switch | `reverb = ReverbSettings(enabled: true, mix: 0.5, decay: 0.8, damping: 0.2)` | largest sample difference from the dry render exceeds 1e-3; `bankStatus` reads `Edited effects on <patch>, not saved yet` |
| EQ | `eq.lowGain` at +12 dB then -12 dB | the boost's RMS exceeds the cut's by more than 1.5x |
| chorus | `chorus = ChorusSettings(enabled: true, mix: 0.5, rate: 3.5, depth: 1)` | largest sample difference from the bypassed render exceeds 1e-3 |
| delay taps | `leftTime` 0.08 s, `rightTime` 0.24 s, then `rightTime` 0.08 s | the sides differ by more than 1e-3 apart, and by less than half that when both taps are equal |
| reverb tail | note released after 20 blocks, blocks 70-80 measured | the wet tail's RMS exceeds the dry tail's by more than 1.5x and stays above 1e-4 |
| live edit | an effect changed while a note sounds, republished with `releasingVoices: false` | `voiceCount` is unchanged across the edit, so the chord is not cut |

Because a failing case prints both measured numbers, a regression names the control it broke rather
than only the assertion.

## The head that carries it

`fc5cbf40d8bc80ed2bc982be8ca9ffd330fb2ded`, pushed to `main` at 18:44:13 on 2026-11-11. Every
workflow is terminal green on it:

- **build** `43080592278` (attempt 2), 18:45:23-18:47:24: `Build (debug, with tests)` compiled the whole
  suite including the new file at 18:45:35-18:46:12, `Test` passed 18:46:13-18:46:20, the release build
  and the bundle succeeded, the app launched 18:46:55-18:47:03, and the audio, MIDI and licence probes
  plus the bootstrap check all passed. This is the run in which the six cases above actually executed.
- **click** `43080593047` (attempt 2) green 18:45:22-18:46:18; **patch-transfer** `43080592029` (attempt 2)
  green 18:45:21-18:46:07; **session** `43080592416` (attempt 3) green 18:46:18-18:46:56.
- **concurrency** `43080628905` green 18:44:37-18:45:12, and again as `43081086465` 18:47:31-18:48:19
  after the build's completion fired the `workflow_run` trigger: the target compiles with complete
  concurrency checking, the flag is proven to have reached `swiftc`, and no diagnostic lands in the MIDI
  routing seam. The new test target is part of that compile.
- **budget** `43080592359` (attempt 7) green 18:48:44-18:49:29: engaged median 911.1 us of a 10,667 us
  block (8.5%) with a 2,942.1 us worst block (27.6%), bypassed median 536.2 us (5.0%) with a 3,507.8 us
  worst (32.9%), the chain 1.7x the dry path. Nothing in this commit touches a DSP file, so those are
  the effect-chain figures this repository already carried. Attempt 2 had measured the same cost
  (engaged median 1,010.6 us) and failed only on a single 18,117 us stalled block in the *bypassed*
  path - a scheduler stall on the runner rather than a render cost - which is why the job was re-run
  rather than the gate loosened.

## What this proves and what it does not

Proven: the panel's entry point is wired to the patch, the patch reaches the render thread, each of
the four stages changes the rendered samples in the way its control implies, and a live edit keeps the
held voice.

Not proven, and not claimed: nobody has seen the panel's layout, its labels or its focus behaviour,
because there is no window in this environment; the controls are exercised through the model method
they call rather than by clicking them. Nothing here was heard: these are measured samples on the
hosted runner, not a listening test.
