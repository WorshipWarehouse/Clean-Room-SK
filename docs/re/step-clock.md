# The step clock

The layer that gives `Arpeggiator` a caller: it decides *when* a step happens, asks the pattern
*which notes*, and emits note on and note off messages in order. What the analysis records, what it
does not, and every rule this repository chose in the gap.

## Observed

- `ArpeggiatorStyleApi` names six orderings: up, down, upDown, downUp, random, chord
  (`docs/feature-inventory.md`, MIDI row "arpeggiator").
- `MidiEffectApi` names the MIDI effects a patch carries: octaveUp, easyChord, arpeggiator,
  sequencer. The arpeggiator is therefore a per-patch effect, not a global one.
- `SyncOptionApi` names subdivision and frequency, and `SubdivisionApi` names quarter through
  thirtyTwo (`docs/feature-inventory.md`, Effects row "time sync").
- `MetronomeApi`, `tempo` and `_timeSignature` exist, and the analysis records the clock source as
  Unknown (`docs/feature-inventory.md`, MIDI row "clock and tempo").

## Unknown

Recorded as Unknown, and deliberately not implemented or guessed at:

- the step rate the original uses, and whether it follows the patch tempo or a free frequency;
- the numeric values behind `SubdivisionApi`'s names;
- gate length, and whether a step sends a note off at all;
- swing, latch, and whether the pattern restarts on a new chord;
- what happens to a scheduled step when the tempo changes mid-phrase;
- the velocity each step carries.

## Decided here, for a testable first version

- **Time comes from the host.** `HostClock` asks the caller for the current time; the clock owns no
  timer, no dispatch source and no audio dependency. `ManualHostClock` is the test host.
- **A step is due when the host reaches it.** `tick()` repeats the step while the scheduled time is
  at or before the host's now, in a loop, so a late tick produces every step it missed rather than
  dropping them and drifting.
- **Tempo and division.** The interval is `60 / bpm / stepsPerBeat`, with quarter, eighth,
  sixteenth and thirtySecond mapping to 1, 2, 4 and 8 steps per beat. That mapping is this
  repository's own: the original's values are Unknown. The tempo is clamped with
  `MetronomeSettings.clampTempo`, so the step clock and the click agree on the range.
- **A tempo or division change takes effect after the step already scheduled.** The pending step
  keeps its time and the interval that follows uses the new value, so a change never pulls a step
  backwards into the past or skips one.
- **Gate.** Every note on is followed by a note off at step time plus `gateFraction` of the
  interval, clamped to 0.05 through 1.0. A gate of 1.0 means the off lands exactly on the next step.
- **Order.** Events are emitted in time order. At equal timestamps the note offs go first, so a
  pattern that revisits a note releases it before it sounds again.
- **Hold and release.** Releasing a note that is currently sounding emits its note off at once, at
  the release time, and cancels the scheduled one. A note held mid-phrase joins the pattern on the
  next step; the grid itself never moves.
- **Nothing held means no pattern.** While no note is held the clock emits nothing and holds its
  grid at the host's now, so the first note of a new chord lands on the tick that sees it rather
  than waiting for the next slot of a pattern that was not running.
- **Style change** restarts the pattern, which is the `Arpeggiator`'s own rule.
- **Events are `MIDIMessage`.** The clock emits the tree's existing note-event type rather than a
  second shape, and hands it to a `NoteEventSink` with the time it is due. It does not touch the
  audio engine interface: wiring the sink to `RealtimeKeysoundEngine.noteOn/noteOff` is the caller's
  decision.

## What the tests prove

`Tests/SundayKeysCoreTests/StepClockTests.swift` drives a virtual clock and asserts exact
sequences of `time on note` and `time off note` lines: the grid at 120 bpm in eighths at 0.125,
0.25, 0.375 and 0.5 second steps; that event times never go backwards and an off precedes an on at
the same instant; that releasing the sounding note ends it at the release time and cancels the
scheduled off; that a style change takes effect on the next step; that a tempo change and a division
change both apply after the pending step; that an empty held set produces no events and the first
note lands on the tick that sees it; that a tick exactly on the first step produces exactly one
step; and that a chord style emits every held note at one timestamp in pitch order.

They prove scheduling and ordering, not sound. The clock is not yet wired to the engine, nothing
heard has an arpeggio in it, and every timing rule above is this repository's own decision, so a
capture that shows the original's step rate, gate or latch behaviour replaces them outright.
