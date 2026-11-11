# The effects chain

What runs between the voices and the device, what is this repository's own design,
and what is still Unknown about the original.

## Where it sits

`PolyphonicInstrument` sums its voices into one buffer. `RealtimeKeysoundEngine`
runs the patch's `EffectChain` over that block and only then adds the click, so no
cue is ever reverberated, delayed or equalised. Effects belong to the patch: `Patch`
owns an `EffectsSettings`, `setPatch` publishes it, and `setEffects` publishes an
edit without touching a sounding voice.

Order is deliberate: **EQ, chorus, delay, reverb**. The EQ shapes what the chorus
and delay repeat, the delay feeds the reverb so the tail belongs to the space rather
than to the instrument, and the reverb is last so nothing smears its tail. Every
stage has its own wet share and its own switch; a disabled stage returns before
touching a sample, which is what makes bypass exactly neutral.

## Stereo

The voices are mono. The engine copies that mix to the right channel, runs one chain
per side over its own channel, and the device block writes the left channel to even
output channels and the right to odd ones. So stereo is made by the chain, and the
two delay taps are what make it audible.

Each chain owns its EQ, chorus and reverb state, so the two sides cannot share a
filter or a buffer. The delay is one tap per side reading `leftTime` or `rightTime`;
feedback is shared and clamped to 0.9, and there is no cross-feed, so a wide setting
decays instead of building.

## What each stage is

- **EQ** — a low shelf at 250 Hz, a peaking band at 1 kHz (Q 0.9) and a high shelf at
  3 kHz, each a standard biquad section. A section at exactly 0 dB is set to
  pass-through coefficients, so a flat EQ is bit-transparent rather than nearly so.
- **Chorus** — a modulated delay line: 12 ms base swept by up to 8 ms at the
  configured rate, read with linear interpolation, one LFO per side.
- **Delay** — a 1.2 s line per side, fractional read, the time glided over 30 ms so
  moving it bends the tail instead of cutting it.
- **Reverb** — four damped comb filters in parallel into two allpasses in series;
  damping is a one-pole lowpass in each comb's feedback path.

## This repository's decisions, all replaceable

The analysis records the original's EQ curve, delay topology, reverb algorithm and
chorus depth as Unknown. Every number here is therefore a decision, not a
measurement: the 250 Hz / 1 kHz / 3 kHz corners, the 0.9 peaking width, the 20 % to
1.2 s delay range with 0.9 feedback, the 12 ms chorus base and 8 ms sweep, and the
reverb's four comb times between 29.7 ms and 43.9 ms. The stereo split itself is a
decision: the original's channel handling is Unknown.

## What the tests assert

Measured on samples, not on command plumbing. The original suite proves a decaying
diffuse reverb tail after the input stops and byte-identical output when bypassed,
delay repeats at the configured interval with the feedback ratio correct, chorus
modulation moving the wet copy, EQ bands lifting and cutting their range, the chain
staying finite over a long run, and settings surviving the patch bank including a
bank written before effects existed. `EffectsStereoTests` adds: a flat EQ and a
fully bypassed chain bit-identical in both channels, each EQ section moving only its
own range, the left tap at 50 ms and the right tap at 250 ms landing at exactly
those sample offsets, each side's repeats decaying by the feedback ratio, maximum
feedback staying bounded, the chain staying finite over 260 blocks, the stereo
engine carrying a reverb tail in both channels and being exactly silent when dry,
both taps surviving the bank, and a restored session opening the patch with its
effects.

## What the proof is

The proof this milestone accepts is the hosted-runner set on the head that carries
this document: the build workflow's `Test` step passing together with the click,
patch-transfer, session and concurrency workflows. That is a proof about the
emphasis on the sample measurements and the render path, and it is deliberately
stronger than "it compiles".

## What is not established

Nothing here was heard: no output device, no ear, no window, and no controller. The
device path is exercised only by the runner's launch and audio probe on a virtual
device, so "the two taps reach the speakers" rests on the code path and on the DSP
measurements, not on a listening test.
