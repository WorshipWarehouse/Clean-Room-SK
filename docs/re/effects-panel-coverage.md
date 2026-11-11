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

## What this proves and what it does not

Proven: the panel's entry point is wired to the patch, the patch reaches the render thread, each of
the four stages changes the rendered samples in the way its control implies, and a live edit keeps the
held voice.

Not proven, and not claimed: nobody has seen the panel's layout, its labels or its focus behaviour,
because there is no window in this environment; the controls are exercised through the model method
they call rather than by clicking them. Nothing here was heard: these are measured samples on the
hosted runner, not a listening test.
