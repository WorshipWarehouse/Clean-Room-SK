# Step clock and caller milestone: the arpeggiator now has a path

This is the milestone record for the step clock and the service that drives it. It is written here
because `docs/progress.md` is 110,012 bytes and the contents API replaces whole files, so the text
could not be folded into it from this environment. **No workflow runner produced this record**: it
was written by hand, against the runs read below.

## The step clock

`Arpeggiator` answers *which notes on the next step*; nothing called it, so no arpeggiated note was
ever produced. `docs/re/step-clock.md` records what the analysis actually says - `ArpeggiatorStyleApi`'s
six style names, `MidiEffectApi`'s arpeggiator as a per-patch effect, `SyncOptionApi` subdivision and
frequency, `SubdivisionApi` quarter through thirtyTwo, and `MetronomeApi`/`tempo`/`_timeSignature`
with the clock source recorded as **Unknown** - and marks the step rate, whether the original follows
the patch tempo, the values behind the subdivision names, gate and note-off behaviour, swing, latch,
per-step velocity and switch-off behaviour as **Unknown**. Every rule applied is labelled this
repository's own and replaceable.

`StepClock` takes its time from an injected `HostClock` and owns no timer, no dispatch source and no
audio dependency. `tick()` repeats the step while the scheduled time is at or before the host's now,
so a late tick produces the steps it missed instead of drifting a whole interval per call. The
interval is `60 / bpm / stepsPerBeat`, with quarter, eighth, sixteenth and thirtySecond mapping to 1,
2, 4 and 8, and the tempo clamped by `MetronomeSettings.clampTempo`. Every step sends `MIDIMessage`
note ons to a `NoteEventSink` at the instant they are due, with a note off scheduled at step time
plus the gate fraction; events leave in time order, offs first at a shared instant. A tempo or
division change applies after the step already scheduled, a release ends the sounding note at the
release time and cancels its off, and an empty held set emits nothing while holding the grid at the
host's now.

## The caller

`ArpeggiatorService` is the layer that turns a keyboard into stepped events. It owns the held set and
the clock, and a key press, a key release, a style change and a tempo or division change each reach
it as their own call, in the same plain-call style the rest of the core uses.

- With the arpeggiator on, the first press of a chord starts the pattern on that instant and a press
  that arrives mid-phrase joins it on the next step. A release ends a sounding note at once and
  stops the pattern when it was the last note held.
- With it off, presses and releases pass straight through carrying the pressed velocity, so the
  keyboard still plays. Turning it on with keys held starts the pattern at that instant; turning it
  off releases the pattern and leaves a still-held key silent until it is pressed again. Both rules
  are this repository's own, because the analysis records nothing about the original's switching.
- The notes leave through the same `NoteEventSink` the clock uses. The default is
  `KeysoundNoteSink`, which forwards each message to a `KeysoundNoteTarget`;
  `RealtimeKeysoundEngine` already has `noteOn(note:velocity:)` and `noteOff(note:)`, so it conforms
  as it stands and the engine's interface, the render path and the MIDI architecture are untouched.

## What the tests assert

`Tests/SundayKeysCoreTests/ArpeggiatorServiceTests.swift` drives a `ManualHostClock` and asserts
exact `time on note` and `time off note` lines, thirteen cases: a three-note chord producing the full
nine-event sequence at 0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875 and 1.0 second with every
step at the configured velocity; the first step landing on the instant of the press, with nothing
tick()ed before it producing any event; an off preceding an on at a shared instant under a full
gate; a release ending the sounding note at 0.0625 and cancelling its scheduled off, with no second
off in the whole run; a second note held at 0.1 joining the sequence at 0.25; an empty held set
producing no events at all; a style change taking effect on the next step; a tempo change halving
the interval after the pending step; a division change to quarter doubling it after the pending
step; releasing the last note stopping the pattern and ending the sounding note; keys passing
straight through with the pressed velocity while the arpeggiator is off; turning it on with a key
held releasing the forwarded note and starting the pattern at that exact instant; and the default
sink reaching an engine-shaped target with `on 60` then `off 60`.

## The runs behind the proof

Every run below was read to a completed run and its conclusion before it was counted. All four are
on `1c1eba4d401009408afbcd72ac6508f4d6d3ba5c`, the commit that repaired the two caller defects the
first attempt exposed. Times are UTC, as the API reports them.

- `build` run 42857103692, job 129973021683: started 16:41:43, completed 16:43:05, **success**.
  Resolve dependencies 16:41:48-16:41:52; Build (debug, with tests) 16:41:52-16:42:19; Test
  16:42:19-16:42:23; Build (release) 16:42:23-16:42:42; Bundle the app 16:42:42-16:42:44; Launch the
  app 16:42:44-16:42:51; Probe the audio start 16:42:51-16:42:53; Probe the MIDI start
  16:42:53-16:42:56; Verify the bootstrap script 16:42:56-16:43:00.
- `session` run 42857103822, job 129973023382: started 16:41:40, completed 16:42:28, **success**,
  Probe the session resume 16:42:22-16:42:25.
- `click` run 42857103988, job 129973022781: started 16:41:41, completed 16:42:31, **success**,
  Probe the click 16:42:24-16:42:29.
- `patch_transfer` run 42857650571, job 129974988797: started 16:44:50, completed 16:45:31,
  **success**, Probe the patch transfer 16:45:27-16:45:29.

The first attempt on `a37c4207` was **not** green and is recorded here rather than hidden: `build`
run 42856089929 failed in Test at 16:36:45 on exactly two of the thirteen caller cases -
`testASecondNoteHeldMidRunJoinsAtTheNextStep`, which produced steps 60, 60, 64 where 60, 64, 60 was
specified, and `testEnablingWithKeysHeldStartsThePatternAtThatInstant`, which produced a note off at
2.0 with no note on. Both were real defects in the code rather than wrong expectations: the cursor
was clamped to the length of the pattern at the moment a note joined, and the notes forwarded while
the arpeggiator was off were released but never handed to the clock. `1c1eba4d` repairs both, and the
thirteen cases pass unchanged, with `StepClockTests` and `ArpeggiatorTests` unchanged as well.

Two `patch_transfer` dispatches never received a runner, and are recorded rather than glossed: run
42857103638 was cancelled while still queued and run 42857281037 was superseded by the dispatch that
did run. The `macos-15` queue carries a standing notice that jobs targeting macOS arm64 runners may
wait for capacity, so a queued probe was replaced instead of waited on.

This text was added by a commit that **changes documentation only**: no source, test, workflow or
resource file differs in it.

## What this does not establish and what is still open

No note was heard. The tests prove scheduling, ordering and the wiring into the note path; they
cannot prove sound or feel, and no window or audio callback constructs the service yet, so the app
still plays un-arpeggiated. The original's step rate, subdivision values, gate, latch, swing and
switch-off behaviour stay **Unknown** until a capture replaces them. Nothing here was validated on
hardware, through an audio device or against the original application.
