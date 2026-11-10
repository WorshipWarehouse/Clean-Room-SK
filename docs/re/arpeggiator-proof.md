## Arpeggiator milestone: six styles, stepped and asserted

The inventory names `ArpeggiatorStyleApi` with six styles and records their behaviour as
**Unknown**. Ordering is the one part of stepped playback that needs no capture: it is a pure
function of the held notes and the style, so it can be written from the recorded names and proved
on a runner without hearing a note.

- **`docs/re/arpeggiator.md`** states what is Observed (the six style names; `MidiEffectApi`'s
  octaveUp, easyChord, arpeggiator, sequencer; `SyncOptionApi` subdivision and frequency) and what
  stays **Unknown**: the step rate and whether it follows the patch tempo, the octave span, gate
  length, swing, latch, what a single note does, and the values behind `SubdivisionApi`'s names.
  None of it is guessed at.
- **`Arpeggiator`** owns no clock and makes no sound: it answers which notes sound on the next
  step, and a caller that owns a clock asks it once per step. `up` and `down` walk the held notes
  and wrap; `upDown` and `downUp` turn without repeating the note at either end; `random` draws one
  note per step from a seeded SplitMix64 generator, so a run is reproducible; `chord` sounds every
  held note ascending. Notes are deduplicated and ordered by pitch, an empty pattern returns
  nothing and does not advance, and changing style restarts the pattern.
- **`ArpeggiatorTests`** asserts exact step sequences, not that the path ran: five steps of `up` and
  of `down`, six of each turning style, both two-note turns, `chord` ordering, an empty pattern
  leaving the cursor at the first step, releasing the current note keeping the cursor inside the
  shorter pattern, a repeated hold not lengthening the pattern, a fixed seed reproducing `random`
  and reaching every held note, `random` never returning an unheld note, and every style being
  covered - fifteen cases in all.

**Observed.** Run [42851404966](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404966)
on `3098d9b6`: the build job concluded success with every step green. `Build (debug, with tests)`
16:07:41 to 16:07:57 compiled `Arpeggiator.swift` and the new suite, `Test` 16:07:57 to 16:08:01
ran every suite including the fifteen arpeggiator cases, `Build (release)` 16:08:01 to 16:08:16
followed, `Bundle the app` 16:08:16 to 16:08:17, `Launch the app` 16:08:17 to 16:08:23, the audio
probe 16:08:23 to 16:08:25, the MIDI probe 16:08:25 to 16:08:27 and the bootstrap check 16:08:27 to
16:08:28; the job completed at 16:08:31. The same head's session workflow, run
[42851404845](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404845), stayed
green (release 16:07:46 to 16:08:16, bundle 16:08:16 to 16:08:18, probe 16:08:18 to 16:08:20); so
did the click workflow, run
[42851404693](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404693) (release
16:08:03 to 16:08:32, probe 16:08:35 to 16:08:39), and the patch transfer workflow, run
[42851404757](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404757) (release
16:08:06 to 16:08:35, probe 16:08:37 to 16:08:39).

**What this does not establish.** No note was heard: the tests prove ordering and state, and a
runner can judge neither the sound nor the feel. No step clock exists yet, so nothing here says how
fast a pattern moves or whether it follows the patch tempo; the original's own stepping stays
**Unknown** until a capture. The six style names are the only thing this milestone took from the
record, and every rule in it is this repository's own and is replaceable.

