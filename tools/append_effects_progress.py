import pathlib

ENTRY = """
## The effects chain, actually wired

The brief said the signal path still stopped at the dry instrument mix. It did not:
`EffectChain` had already been running inside the render callback since the effects
milestone, in the order EQ, chorus, delay, reverb, fed by a seqlock published from
`patch.effects`. Re-checking that first mattered, because it moved the work from
"build a chain" to "close the three real gaps in the chain that exists".

Those gaps, and what was done:

- The EQ had a low shelf and a high shelf and nothing between them. It is now a low
  shelf at 250 Hz, a peaking band at 1 kHz at Q 0.9 and a high shelf at 3 kHz, each a
  standard biquad section. A section at exactly 0 dB is set to pass-through
  coefficients, so a flat EQ stays bit-transparent instead of nearly so.
- The delay had one mono tap, so "independent left and right times" was not
  expressible. `DelaySettings` now carries `leftTime` and `rightTime`, with the old
  `time` kept as a both-sides property and as an initialiser label, and the decoder
  still reads a document that only has `time` into both taps.
- Stereo was made at the device by copying channel 0 everywhere, so a wide delay
  could not exist. `EffectChain` now knows which side it feeds and reads that side's
  tap, `RealtimeKeysoundEngine.renderStereo` runs one chain per side over the same
  mono voice mix (voices are still rendered once) and adds the click from its own
  scratch so a cue reaches both channels and the metronome advances once, and the
  device block fills left and right in 4,096-frame chunks, odd channels taking the
  right buffer.

The mono `render` was left untouched on purpose: every existing test and probe drives
it, so the stereo path is additive rather than a replacement.

Measured, not described: `EffectsStereoTests` asserts a flat EQ and a fully bypassed
chain are bit-identical in both channels, each EQ section moves its own range and
leaves distant ranges near unity, the left tap lands at 50 ms (sample 2,400) and the
right at 250 ms (sample 12,000) on their own sides, each side's repeats fall by the
feedback ratio, 0.9 feedback still decays and stays finite over 900 blocks, a fully
engaged chain stays finite and under 6 over 260 blocks, the stereo engine carries a
reverb tail in both channels and is exactly silent when dry, both taps and the peak
gain survive the patch bank, and a restored session opens the patch with its effects
while a bypassed patch stays dry. The earlier `EffectTests` suite (reverb tail versus
byte-identical bypass, delay timing and feedback, chorus modulation, EQ bands,
long-run stability, bank round-trip) still passes unchanged, as do the note, bend and
pressure tests.

Docs: `docs/re/effects-chain.md` records the order, the stereo split, the numbers,
which of them are this repository's own choices because the analysis records the
original's EQ curve, delay topology, reverb algorithm and channel handling as
Unknown, and what the tests do and do not establish.

Not established, and not claimed: nothing here was heard. There is no output device,
no controller and no window reachable from this environment, so "the two taps reach
the speakers" rests on the code path plus the measured samples, not on listening.
"""

path = pathlib.Path("docs/progress.md")
text = path.read_text(encoding="utf-8")
if "The effects chain, actually wired" in text:
    raise SystemExit("the entry is already in the log")
if not text.endswith("\n"):
    text += "\n"
path.write_text(text + ENTRY, encoding="utf-8")
print("appended", len(ENTRY), "characters")
