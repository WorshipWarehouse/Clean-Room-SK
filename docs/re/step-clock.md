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
- the velocity each step carries, and whether the original switches the effect off without releasing
  the notes it is playing.

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

## The caller's contract

`ArpeggiatorService` is what connects a keyboard to the clock: it owns the held keys and the
`StepClock`, so every change a player makes is one call.

- **Key press.** With the arpeggiator on, a press joins the held set and is handed to the clock. The
  first press of a new chord starts the pattern on that instant, and a press that arrives mid-phrase
  joins it on the next step. Pressing a note already held changes nothing.
- **Key release.** A release ends a sounding note at once, cancels its scheduled note off, and stops
  the pattern when it was the last note held.
- **Off means straight through.** With the arpeggiator off, a press and a release are forwarded to
  the note path unchanged and carry the pressed velocity, so the keyboard still plays.
- **Switching.** Turning the arpeggiator on while keys are held releases anything forwarded and
  starts the pattern on that instant. Turning it off releases the pattern and cancels its scheduled
  note offs; a key still held is left silent until it is pressed again. What the original does when
  the effect is switched is **Unknown**, so this is this repository's own rule.
- **Changes.** Style, tempo, division, gate and velocity each have their own call and go straight to
  the clock, so a tempo or division change lands after the step already scheduled and a style change
  takes effect on the next step.
- **Where the notes go.** The service emits through the same `NoteEventSink` the clock uses. By
  default that is `KeysoundNoteSink`, which forwards each `MIDIMessage` to a `KeysoundNoteTarget`;
  `RealtimeKeysoundEngine` already has `noteOn(note:velocity:)` and `noteOff(note:)`, so it conforms
  as it stands and the engine's interface is untouched. The stepped notes therefore reach the note
  path that already exists. A test passes its own sink to read the exact instants.
- **Velocity.** Every step carries the service's configured velocity rather than the pressed one,
  because the pattern is not tied to one key. The original's per-step velocity is **Unknown**.

## What the tests prove

`Tests/SundayKeysCoreTests/StepClockTests.swift` drives a virtual clock and asserts exact
sequences of `time on note` and `time off note` lines: the grid at 120 bpm in eighths at 0.125,
0.25, 0.375 and 0.5 second steps; that event times never go backwards and an off precedes an on at
the same instant; that releasing the sounding note ends it at the release time and cancels the
scheduled off; that a style change takes effect on the next step; that a tempo change and a division
change both apply after the pending step; that an empty held set produces no events and the first
note lands on the tick that sees it; that a tick exactly on the first step produces exactly one
step; and that a chord style emits every held note at one timestamp in pitch order.

`Tests/SundayKeysCoreTests/ArpeggiatorServiceTests.swift` drives the same clock through the caller:
the full nine-event sequence of a three-note chord at exact instants; the first step landing on the
instant of the press and nothing sounding before it; an off preceding an on at a shared instant;
a release ending the sounding note at the release time with no second off; a second note joining the
sequence at the next step; nothing at all from an empty held set; a style change on the next step;
and tempo and division changes after the pending step. It also asserts the rules this repository
chose: keys passing straight through with the pressed velocity while the arpeggiator is off,
turning it on with keys held starting the pattern at that instant, and the default sink reaching an
engine-shaped target.

They prove scheduling, ordering and the wiring, not sound. Nothing heard yet has an arpeggio in it:
the service is built and tested, but no window and no audio callback constructs it, so a runner can
prove the events and never the sound. Every timing rule above is this repository's own decision, so
a capture that shows the original's step rate, gate, latch or switch-off behaviour replaces them
outright.
