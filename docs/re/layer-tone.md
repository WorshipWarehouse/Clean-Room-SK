# Per-layer tone

A layer now carries a low-pass corner and a resonance, the two fields the original's
`ModulationFilterApi` names as `filterRange` and `resonance`. What the original does with
them is **Unknown**: no captured session, no decompiled body and no parameter range was
available, so the topology and the mapping below are this repository's own and are claimed
as such, not as parity.

## The law, stated once

`LayerFilter` (`Sources/SundayKeysCore/Audio/LayerFilter.swift`) owns everything:

- The corner runs 20 Hz to 20 kHz, resonance 0 to 1, both clamped on read, on write into
  the layer, and again on decode, so a hand-edited bank cannot put the engine outside the
  law.
- A layer is **open** when the corner is at 20 kHz and resonance is zero. That is the
  default, which is why a bank written before the field existed decodes to an open filter
  and renders bit-identically to one this build wrote.
- The filter is a topology-preserving state-variable low pass. The corner is pre-warped
  (`g = tan(pi * f / fs)`, held just under Nyquist), the damping `k` runs from 1.414 at no
  resonance - a Butterworth corner - to 0.1 at full resonance, and the whole thing is
  reduced to three coefficients so the voice loop never divides per sample.
- The slider is a position in octaves above 20 Hz (0 to 10), because a player hears tone
  in octaves; `octaves(fromCutoff:)` and `cutoff(fromOctaves:)` are the only conversion and
  both live in the law.

## Where it runs

`PolyphonicInstrument` keeps four per-layer tables - three coefficient tables and a bypass
flag - written only on the render thread by a `setLayerFilter` command, or at init from the
layers it was built with. The one voice loop both render paths use tests the bypass flag
per voice per frame and, when a layer is filtered, runs that voice's own two-integrator
state. A voice's state is cleared when it starts, so a stolen voice cannot inherit the old
note's filter memory.

`RenderCommand` carries the corner in its float payload and the resonance in the new
`amount` field, because one float is not enough for both and the command is a fixed-size
slot. `RealtimeKeysoundEngine.setPatch` publishes every layer's tone beside the timbre and
pan rungs, and `setLayerFilter(layer:cutoff:resonance:)` is the live-edit door.
`AppModel.setLayerFilter` goes through `editLayer`, which is the no-release path, so a tone
turned under a held chord changes the sound rather than cutting it. The layer editor shows
a tone slider with a `tone open` / frequency readout and a resonance slider with its value.

The bank is version 6, and `LayerPanTests` now asserts that. Version 5 banks load with an
open filter.

## Evidence

`Tests/SundayKeysCoreTests/LayerFilterTests.swift`, all on the stereo path at 48 kHz and 512
frames per block:

- a layer that never sets a tone is open, and `coefficients` reports the bypass;
- the law clamps -5, 1e9 and NaN on the corner, -1 and 4 on resonance, and 1,280 Hz reads
  back as 6 octaves and 1,280 Hz again;
- a patch built with the defaults renders sample-identical to one that states the open
  values explicitly (bit-identical, not close);
- a 300 Hz corner takes a note at MIDI 96 (2,093 Hz) below half the dry RMS;
- a 1.5 kHz corner leaves a note at MIDI 48 (131 Hz) above 60% of its dry RMS;
- full resonance at 1,046 Hz puts back more than 1.2x the energy the same corner passes at
  no resonance;
- a tone moved under a held note - through `setPatch(releasingVoices: false)` and through
  `setLayerFilter` - keeps `voiceCount` and makes the held note darker;
- a bank round trip keeps the tone, a version 5 bank with the keys removed decodes open,
  and a decoded corner of 900,000 Hz clamps to 20 kHz.

## The render budget gate, reworked

`RenderBudgetTests` used to fail if any single block took longer than one block's wall
clock. On this runner that measured the host rather than the chain: on `017ec379` the
bypassed dry path - a fifth of the engaged chain's work - ran a 636.2 us median with a
2,244.9 us worst block, and the run before it failed while the engaged median stayed at
9.9%. A preemption moves one block; a regression moves the distribution.

The gate is now the median (under a quarter of the block), the 95th percentile (under 60%)
and a count of engaged blocks over half the budget (at most a twentieth, plus one), with a
four-block ceiling on the single worst block to catch a genuine blow-up. The tail figures
are printed as `RENDER_BUDGET_TAIL` so a passing run still records the distribution it
judged. On the tone branch that gate measured engaged median 949.2 us (8.9%), p95 1,337.5
us (12.5%) and 0 blocks over half, with bypassed median 625.8 us and p95 1,625.8 us - and
the worst blocks, 2,008.3 us engaged against 2,468.4 us dry, are again the host's, not the
chain's.

## Not proven

Nothing was heard. These are rendered samples and a CI measurement; the filter's musical
behaviour on real content, its interaction with the effect chain by ear, and any parity
with the original's filter are unverified, and the original's law remains Unknown.
