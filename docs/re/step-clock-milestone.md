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

## What this does not establish and what is still open

No note was heard. The tests prove scheduling, ordering and the wiring into the note path; they
cannot prove sound or feel, and no window or audio callback constructs the service yet, so the app
still plays un-arpeggiated. The original's step rate, subdivision values, gate, latch, swing and
switch-off behaviour stay **Unknown** until a capture replaces them.
