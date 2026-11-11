
## Effects chain closeout (hand-written, 2026-11-11)

The chain itself landed before this section was written, so this closes the record rather than the code.
`EffectChain` (in `Sources/SundayKeysCore/Audio/Effects/`) is EQ, then chorus, then a two-tap stereo
delay, then reverb, inserted in that order inside `RealtimeKeysoundEngine.renderStereo`, with one chain
per side. `Patch.effects` reaches both chains through the engine's `setPatch` and `setEffects`, every
stage has a bit-identical bypass, and the mono voices are split to stereo before the chains run.

What `EffectTests` and `EffectsStereoTests` assert, with the values they use: a reverb tail against a
byte-identical bypass; a 100 ms wet impulse arriving at sample 4,800, with the left tap at 2,400 and the
right tap at 12,000; a 0.5 feedback ratio measured within 0.06; 0.9 feedback bounded over 900 blocks;
the chorus wet copy moving; EQ at 0 dB bit-transparent, +12 dB mid above 2.5x and -12 dB mid below 0.5x;
the engaged chain finite and under 6 over 260 blocks; both taps and the mid gain surviving a bank round
trip; and a restored session keeping the effects.

Not validated: nothing has been heard. "The taps reach the speakers" rests on the code path and the
measured samples, not on listening.

## Render budget (measured on a macos-15 runner, hand-written, 2026-11-11)

`RenderBudgetTests` measures the real `renderStereo` path: a `RealtimeKeysoundEngine` with a live patch,
ten voices on notes 48 to 57, 512 frames per block at 48 kHz, 60 warm-up blocks and then 240 measured
ones, timed with `DispatchTime.now().uptimeNanoseconds` around the render call only.

The budget comes from the block itself: 1,000,000,000 x 512 / 48,000 = 10,667 us per block.

| state | median | worst single block |
| --- | --- | --- |
| EQ + chorus + delay + reverb, ten voices | 999.4 us (9.4% of the block) | 2,960.5 us (27.8%) |
| the same voices, chain bypassed | 592.0 us (5.5%) | 1,671.8 us (15.7%) |

The chain therefore costs 1.7x the dry path. The test fails if the engaged median takes more than a
quarter of the block, or if any single block overruns the block budget, and it reports the measured
numbers on failure. `.github/workflows/budget.yml` re-runs the filter and publishes that line as a
check-run annotation, on a pass as well as a failure.

This is DSP cost in isolation. No output device exists in this environment, so it is not a latency
figure, not the quantum a real interface would ask for, and not evidence of glitch-free playback.

## Instrument catalogue wired to the layers (hand-written, 2026-11-11)

The gap this closes: a layer could only choose between two hard-wired tables, the catalogue the analysis
records (`InstrumentApi`, `BaseInstrumentInfoApi`, `InstrumentDownloader`) had no counterpart a layer
could reach, and no bank could name what its layers sounded like.

What is in the tree now:

- `Sources/SundayKeysCore/Catalogue/InstrumentCatalogue.swift`: `Instrument` (id, name, character, voice,
  default gain, bell flag) and `InstrumentCatalogue`, five entries. The array's index **is** the rung, so
  the strip order and the lookup cannot disagree, and an unknown id resolves to `keys` while the layer
  keeps the unknown text on disk.
- `Sources/SundayKeysCore/Audio/WaveTable.swift`: three more original generators (`pad`, `organ`,
  `electricPiano`) beside `keys` and `bell`, each a 2,048-sample cycle built from partials this
  repository chose rather than from anything recovered.
- `Sources/SundayKeysCore/Audio/KeyLayer.swift`: `instrument` is the stored selection; `timbre` is now a
  computed legacy view over it, so a bank written before the catalogue still loads — its `bell` decodes
  as the bell instrument — and the two names can never disagree.
- `Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift`: one table strip built from
  `InstrumentCatalogue.tables()`, a layer's table read as `rung * tableLength`, and a `setLayerTimbre`
  command that carries a rung instead of a bell flag, clamped to the strip.
- `Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift`: `setPatch` publishes every layer's rung,
  so an instrument change travels the lock-free ring the timbres already used.
- `AppModel.setLayerInstrument(_:instrumentID:)` and the layer editor's picker over
  `InstrumentCatalogue.builtIn`: the window offers the catalogue instead of two segmented tags.

`InstrumentCatalogueTests` drives the same `renderStereo` path and asserts: five or more entries with
unique ids and unique rungs, each table the strip size, and `keys` on rung 0; an unknown id keeping its
layer text while playing rung 0; `KeyLayer(timbre: .bell)` being the bell instrument and writing `timbre`
writing the instrument; a bank round trip keeping `pad`; a layer encoded without `instrument` decoding
from its `timbre`; every pair of built-in instruments rendering a tone whose largest normalised sample
difference exceeds 0.05 after the attack, with every sample finite and a peak above 0.01; an engine
started on keys and retargeted by `setPatch` to organ rendering sample-identical audio to an engine that
started on organ (1e-6), which fails if `setPatch` stops publishing rungs; and
`setPatch(releasingVoices: false)` keeping the held voice, which is the live-edit contract the editor
relies on.

Provenance: the three Swift sources, the test and the model method were written by hand in this pass.
The two Swift files that are too large to carry through the contents API — `AppModel.swift` and
`ContentView.swift` — had their two blocks applied by a runner running `tools/apply_instrument_ui.py`,
which asserted that both edits matched before pushing; the build on the head that followed is what
proves those edits compile. No bytes of the application being studied were copied.

Not validated, and not claimed: no sampled instrument, no download of purchased content, nothing about
how the original stores or streams its instruments, and the picker was never seen — it is compiled and
tested, not viewed.
