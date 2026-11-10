# The arpeggiator's styles

What the analysis records about stepped playback, and what this implementation decided
where the record stops. The style names are Observed; every rule below is this
repository's own and is replaceable once a capture exists.

## Observed

- `ArpeggiatorStyleApi` names six styles: up, down, upDown, downUp, random, chord
  (`docs/feature-inventory.md`, MIDI row "arpeggiator").
- `MidiEffectApi` names the MIDI effects a patch can carry: octaveUp, easyChord,
  arpeggiator, sequencer (same table), so the arpeggiator is a per-patch MIDI effect
  rather than a global one.
- `SyncOptionApi` names subdivision and frequency, and `SubdivisionApi` names quarter
  through thirtyTwo (`docs/feature-inventory.md`, Effects row "time sync").

## Unknown

These are recorded as Unknown and are deliberately **not** implemented or guessed at:

- the step rate, and whether a step follows the patch's tempo or a free frequency;
- the octave span of a pattern, and whether `up` walks one octave or the whole held set;
- gate length, swing and latch behaviour;
- what each style does with a single note, and whether `chord` holds or retriggers;
- the subdivision values behind `SubdivisionApi`'s names.

## Decided here, for a testable first version

- The pattern is a pure function of the held notes and the style.
- Held notes are deduplicated and ordered ascending by pitch; every style is defined
  over that order.
- `up` walks the held notes ascending and wraps; `down` walks them descending and wraps.
- `upDown` and `downUp` turn without repeating the note at either end: three notes
  walk `60, 64, 67, 64` and `67, 64, 60, 64` respectively.
- `random` picks one held note per step from a seeded generator, so a run is
  reproducible; it can repeat a note, because a uniform draw does.
- `chord` sounds every held note at once, ascending, on every step.
- An empty pattern produces no notes and does not advance. Releasing the last note
  resets the pattern to its first step.
- Changing style restarts the pattern, because a cursor counted in one ordering means
  nothing in another.
- The type produces no sound and owns no clock: it answers which notes sound on the
  next step, and the caller asks it once per step.

## What the tests prove

`Tests/SundayKeysCoreTests/ArpeggiatorTests.swift` asserts the exact step sequence for
all six styles, that the turning styles do not repeat their end notes, that `chord`
returns every held note in pitch order, that an empty pattern returns nothing and does
not advance, that releasing the current note leaves the cursor inside a shorter
pattern, that repeated holds do not lengthen the pattern, that a fixed seed makes
`random` reproducible and eventually reaches every held note, and that `random` never
returns a note that is not held.

They prove ordering and state, not sound. They say nothing about timing, because the
step clock lives outside this type, and nothing about how the original steps a real
chord, which stays Unknown until a capture.
