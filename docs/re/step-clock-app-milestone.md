# The arpeggiator's caller, inside the app

Status: **proven green on `fb36f87a`.** The build's `Test` step, the session,
click and patch-transfer probes and the concurrency check all completed
successfully on that exact sha. Everything below was read from the API; nothing
was run locally, nothing was heard, and nothing was validated on hardware, on an
audio device, or against the original application.

## The gap this closed

`docs/re/step-clock.md` already recorded the step clock: `StepClock` over an
injected `HostClock`, `NoteEventSink` carrying the tree's existing `MIDIMessage`,
`StepClockSettings`, and `ArpeggiatorService`/`ArpeggiatorPanel` as the caller.
That layer was proven by its own tests. What was missing was one layer up, and
`docs/progress.md` said so: `AppModel` never called the panel. `keyDown`,
`keyUp` and the `MIDIEventTransport` note methods went straight to the audio
controller, nothing ticked the clock, and the panel was built over
`SystemHostClock()`, so no arpeggiated event was ever produced and a test could
not move its time.

## What was built

- `AppModel.init(sessionClient:clock:audio:)` takes a `HostClock` and an
  `AudioEngineController`, defaulting to `SystemHostClock()` and a fresh
  controller, so no existing call site changed.
- `keyDown`, `keyUp`, the transport `noteOn`/`noteOff` and `panic()` route
  through `ArpeggiatorPanel`. The licence gate stays first on every path, and
  `panic()` silences the pattern as well as the voices.
- `tickArpeggiator()` emits whatever the host's time has reached. A 5 ms
  `stepTicker` drives it while the engine runs and is invalidated in `stop()`.
  The interval is this repository's own choice: `StepClock` keeps the grid, so
  the ticker only bounds how late a step reaches the voices.

The audio engine interface, the render path and the MIDI architecture are
untouched, and nothing was added to `Sources/SundayKeysCore`.

## The grid the tests assert

`StepClockSettings.stepInterval` is `60 / beatsPerMinute / stepsPerBeat`, the gate
is `gateFraction * stepInterval` after its note on, and note offs precede note
ons at equal instants. At 120 bpm in eighths that is a step every 0.25 s and a
gate of 0.125 s. This repository's own mapping, replaceable: the analysis names
the divisions and records no values.

`Tests/SundayKeysAppTests/StepClockWiringTests.swift` drives the model's own
note path over a `ManualHostClock` and a recording voicing, in the app ticker's
5 ms steps, eleven cases:

1. a three-note chord at 120 bpm in eighths producing the exact nine events the
   first second holds - `on 60`, `off 60`, `on 64`, `off 64`, `on 67`, `off 67`,
   `on 60`, `off 60`, `on 64` - plus the stepping status line;
2. the first step landing on the first tick, and a second tick at the same
   instant adding nothing;
3. a release mid-pattern ending the sounding note once, cancelling its scheduled
   off, and leaving the pattern silent;
4. a note held mid-phrase joining on the next step, at 0.25 s, not a step after
   the press;
5. a pattern change taking effect on the next step, with the old cycle's note
   releasing on its own scheduled off;
6. a tempo change keeping the step already scheduled at 0.25 s and halving the
   interval after it, putting the third step at 0.375 s;
7. a division change keeping the pending step at 0.25 s and then stepping at
   0.75 s, a quarter apart;
8. an empty held set producing no event at all;
9. the arpeggiator off still forwarding the pressed velocity;
10. a refused licence refusing the key before the pattern holds it, no step
    sounding, the gate and status unchanged, and the refusal reading
    `refused note C4 ch 1: licensed playback refused:`;
11. the licensed control case, which does sound, its second step at 0.25 s.

## Passing runs on `fb36f87a`

All read through `LIST_JOBS_FOR_A_WORKFLOW_RUN` on
`fb36f87a89c4cff90afc140ee69f61b373dc4eb7`.

- build `43042601731`: `Resolve dependencies` 14:52:02-14:52:05, `Build (debug,
  with tests)` 14:52:05-14:52:35, **`Test` 14:52:35-14:52:38 success**, then
  `Build (release)` from 14:52:38.
- session `43042601531`: release 14:52:06-14:52:45, bundle 14:52:45-14:52:47,
  probe 14:52:47-14:52:52, job completed 14:52:54.
- click `43042601358`: release 14:52:00-14:52:31, bundle 14:52:31-14:52:34,
  probe 14:52:34-14:52:39, job completed 14:52:40.
- patch-transfer `43042601380`: release 14:52:03-14:52:40, bundle
  14:52:40-14:52:43, probe 14:52:43-14:52:45, job completed 14:52:48.
- concurrency `43042601772`: complete concurrency checking 14:51:59-14:52:19,
  diagnostics 14:52:19-14:52:20, job completed 14:52:20.

## Earlier runs, by ID

`35301f76` (the wiring itself, pushed by the patch runner):

- build `43039990844`: **failure** in `Test` at 14:36:30, after `Build (debug,
  with tests)` succeeded 14:36:00-14:36:26. Five assertions failed, verbatim:
  `XCTAssertEqual failed: ("["on 60 v100"]") is not equal to ("["on 60 v100",
  "off 60"]")`, four events where eight were expected in the chord case, and
  the division and mid-pattern cases disagreeing on counts. All expectation
  errors: the clock keeps the step already scheduled when tempo or division
  changes, and a note sink cannot expose instants.
- session `43039850230`, click `43039850248`, patch-transfer `43039850543`:
  **success**, release builds 14:35:10-14:35:45, probes 14:35:46-14:36:01.

`24f740b4` (the first correction):

- session `43040873482`: **success**, release 14:41:35-14:42:08, bundle
  14:42:08-14:42:10, probe 14:42:10-14:42:14.
- build `43040873479`, `43041264735`, `43041445911`: queued with `runner_id` `0`
  or `null` and `steps: []` - the arm64 capacity stall. The first two were
  cancelled and replaced; the third never ran.
- click `43040835355`, `43041264954`, `43041493009`: cancelled by their
  concurrency group or runnerless; `43041493009` was still `queued` with
  `runner_id: null`.
- patch-transfer `43040835634`, `43040873366`, `43041264608`: cancelled by
  concurrency group or runnerless. Twins `43040835347` and `43040835314` were
  cancelled at 14:41:22 and are not results.

`6a4abe64` (cleanup, scaffolding removed, first green-queue head):

- build `43041790011`: **failure** in `Test` at 14:48:09. Four cases failed,
  verbatim: `("["on 60 v100", "off 60", "on 64 v100"]") is not equal to
  ("["on 60 v100", "off 60", "on 64 v100", "off 64", "on 67 v100"]")`;
  `("["on 60 v100", "off 60"]") is not equal to ("["on 60 v100", "off 60",
  "on 60 v100"]")`; `XCTAssertTrue failed - got refused note C4 ch 1: licensed
  playback refused: Session refused: Licence expired: sounds downgraded`; and
  nine events where sixteen were expected. The suite had assumed an eighth at
  120 bpm was 0.125 s; the clock's formula makes it 0.25 s, so the horizons were
  wrong and the emitted sequences were right.
- build `43041724544` and click `43041724630`: **cancelled** at 14:47:08 and
  14:47:11 mid build, by their concurrency groups, when dispatched twins arrived
  while they held runners.
- session `43041725440`: runnerless when read; patch-transfer `43041725450`:
  **success**, release 14:46:44-14:47:16, probe 14:47:18-14:47:20.
- concurrency `43041724497`: **success** 14:46:52-14:47:26.

## What this does not establish

1. What an arpeggio sounds like. The tests prove scheduling, ordering and the
   routing into the note path; no ear, no audio device and no window were
   involved, and no screenshot was read.
2. The original application's step rate, subdivision values, gate, latch, swing
   and switch-off behaviour. All remain **Unknown**, and every rule applied is
   this repository's own and replaceable.
3. Anything about MIDI hardware, controllers or real devices.

## How progress.md was updated

`docs/progress.md` is 110 KB and the contents API replaces whole files, so the
append runs on a runner through a temporary dispatch-only job that appends this
file to the log; that job is removed in the following commit, which changes
documentation and tooling only.
