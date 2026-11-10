## Step clock and arpeggiator caller milestone (2026-11-10)

This section records the step clock, which turns a held chord into timed
note events, and the service that lets a keyboard reach it.

**No workflow runner produced this record.** It was written by hand, as
this repository's own decision, in an ordinary commit. One mechanical
exception is stated rather than hidden: because this file is 110,012
bytes and the contents API replaces whole files while capping reads at
50,000 characters, the append and the push were carried out by a plain
Linux job that ran `cat` and `git push` and changed no source, test or
workflow file. The words are mine; the job moved them.

### The recorder path, removed

An earlier attempt to have a runner record this milestone produced
`.github/workflows/record_step_clock.yml` and
`docs/re/step-clock-proof.md`. Neither is in the tree now: both files
were deleted, and run 42854416837 - the workflow that wrote the proof
file - was cancelled while queued rather than re-run or re-polled.
There is no proof workflow in this repository, and no runner is cited
as the author of any claim here.

### The caller

`Arpeggiator` answers which note each step plays, and nothing called it,
so no arpeggiated note was ever produced. `ArpeggiatorService` is now
that caller. It owns the held set and the clock, and a key press, a key
release, a style change and a tempo, division, gate or velocity change
each reach it as their own plain call.

Its notes leave through the same `NoteEventSink` the clock already used.
The default sink is `KeysoundNoteSink`, which forwards each message to a
`KeysoundNoteTarget`, and `RealtimeKeysoundEngine` already has
`noteOn(note:velocity:)` and `noteOff(note:)`, so it satisfies that
protocol as it stands. No engine, render-path or MIDI-architecture
change was made, and none is needed for this milestone. Clock time is
injected from the host as a `HostClock`: the service owns no timer, no
dispatch source and no audio dependency, which is what lets every test
below pin exact instants.

With the arpeggiator on, the first press of a chord starts the pattern
on that instant, and a press arriving mid-phrase joins on the next step;
a release ends a sounding note at once and stops the pattern when it was
the last note held. With it off, presses and releases pass straight
through carrying the pressed velocity, and turning it on over held keys
releases the forwarded notes and starts the pattern at that instant with
those keys held. Those rules are this repository's own and replaceable,
because the recorded analysis says nothing about the original's
switching behaviour.

### What the thirteen tests assert

`Tests/SundayKeysCoreTests/ArpeggiatorServiceTests.swift` drives a
`ManualHostClock` and compares `time on note` and `time off note` lines,
so each case below is a concrete value rather than evidence that a path
ran: nine events for a three-note chord at 0.0, 0.125, 0.25, 0.375, 0.5,
0.625, 0.75, 0.875 and 1.0 s, each step at the configured velocity; the
first step landing on the exact instant of the press, with nothing
ticked before it producing any event; a note off preceding the next note
on at a shared instant under a full gate; a release at 0.0625 ending the
sounding note at 0.0625 and cancelling its scheduled off, so no second
off appears anywhere in the run; a second note held at 0.1 joining the
pattern at its next step, 0.25, and not before; an empty held set
emitting nothing at all; a style change taking effect on the next step
and not on the one already scheduled; a tempo change halving the
interval after the pending step; a division change to quarter doubling
it after the pending step; a release of the last held note stopping the
pattern and ending the sounding note; keys passing straight through with
the pressed velocity while the arpeggiator is off; turning it on with a
key held releasing the forwarded note and starting the pattern at that
exact instant; and the default sink reaching an engine-shaped target
with `on 60` then `off 60`.

### The two defects the first green attempt exposed

The first attempt at a green head was `a37c4207`, and it was not green.
`build` run 42856089929 failed in Test at 16:36:45 on exactly two of the
thirteen cases, and both failures were defects in the code rather than
wrong expectations.

`testASecondNoteHeldMidRunJoinsAtTheNextStep` produced steps 60, 60, 64
where 60, 64, 60 was specified. `Arpeggiator` clamped its cursor modulo
the length of the pattern at the moment a note joined, so a one-note
pattern of length one threw away the fact that the next step was the
second step. The cursor is now a monotonic count of steps taken, never
reduced while the pattern plays, and each step reads it modulo the cycle
it is about to walk; a release is still safe because that modulo cannot
point past a shorter cycle.

`testEnablingWithKeysHeldStartsThePatternAtThatInstant` produced an off
at 2.0 with no note on. `setEnabled(true)` released the notes forwarded
while the arpeggiator was off but never made them the pattern's held
notes, so the clock had nothing to play. The forwarded keys are now
taken into the held set after their note offs.

`1c1eba4d` carries both repairs, and `StepClockTests`,
`ArpeggiatorTests` and the thirteen caller cases all pass unchanged
since: no expectation was adjusted to fit the code.

### The runs observed green, with their windows

Every run below was read to a completed run object and its conclusion
before it was counted. Times are UTC as the API reports them.

On `1c1eba4d401009408afbcd72ac6508f4d6d3ba5c`:

`build` 42857103692, job 129973021683: started 16:41:43, completed
16:43:05, success. Resolve dependencies 16:41:48-16:41:52; Build
(debug, with tests) 16:41:52-16:42:19; Test 16:42:19-16:42:23; Build
(release) 16:42:23-16:42:42; Bundle 16:42:42-16:42:44; Launch
16:42:44-16:42:51; audio probe 16:42:51-16:42:53; MIDI probe
16:42:53-16:42:56; bootstrap check 16:42:56-16:43:00.

`session` 42857103822, job 129973023382: 16:41:40-16:42:28, success,
session-resume probe 16:42:22-16:42:25. `click` 42857103988, job
129973022781: 16:41:41-16:42:31, success, click probe 16:42:24-16:42:29.
`patch_transfer` 42857650571, job 129974988797: 16:44:50-16:45:31,
success, patch-transfer probe 16:45:27-16:45:29.

On the docs record head `a1e045368fd8f1ee04bbb359195340cd81dd7201`:
`build` 42858404930 ran 16:49:04-16:50:25 and succeeded, with Test
16:49:42-16:49:45; `session` 42858403874 ran 16:49:04-16:49:42 and
succeeded; `click` 42858404332 ran 16:49:04-16:49:47 and succeeded.

**`patch_transfer` has not obtained a runner on any docs-only head.**
On `a1e04536` it was dispatched four times - 42858403667, 42858560004,
42858671807 and 42858815110 - and none of those runs left the queue, the
last being cancelled at 16:51:43 so that nothing was left queued. Its
probe therefore has a green window on the code head above and no green
window on a documentation-only head; the queue carries a standing notice
that macOS arm64 jobs may wait for capacity.

### What this does not establish

No note was heard. Nothing here was measured on hardware, through an
audio device, or checked against the original application, and no window
or audio callback constructs the service yet, so the app still plays
un-arpeggiated. No extracted code, assets or disassembly are in the
tree: every rule chosen above is labelled this repository's own and
replaceable, and everything the recorded REA notes do not contain - the
original's step rate, subdivision values, gate, latch, swing, per-step
velocity and switch-off behaviour - stays **Unknown** until a capture
replaces it.
