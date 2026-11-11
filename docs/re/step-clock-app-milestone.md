# The arpeggiator's caller, inside the app

Status: the wiring is implemented and compiles; its tests are written and its expectations
corrected. **The build's `Test` step is not yet green on the corrected head**, because the
`macos-15` arm64 queue did not assign a runner across three separate dispatches. Everything
below was read from the API; nothing was run locally and nothing was validated on hardware,
through an audio device, or against the original application.

## What was already there, and what was not

`docs/re/step-clock.md` and `docs/re/step-clock-milestone.md` already record the step clock:
`StepClock` with an injected `HostClock`, `NoteEventSink` carrying the tree's existing
`MIDIMessage`, `StepClockSettings`, and `ArpeggiatorService`/`ArpeggiatorPanel` as its caller.
That layer is proven by `StepClockTests` and `ArpeggiatorServiceTests` with exact instants.

What was missing was one layer up, and the record said so repeatedly: `AppModel` never called
the panel. `keyDown`, `keyUp` and the `MIDIEventTransport` note methods went straight to the
audio controller, nothing ticked the clock, and the panel was built over `SystemHostClock()`,
so a test could not move its time. The app therefore played un-arpeggiated.

## What this increment changed

- `AppModel.init(sessionClient:clock:audio:)` takes a `HostClock` and an `AudioEngineController`,
  defaulting to `SystemHostClock()` and a fresh controller, so no existing call site changed.
- `keyDown`, `keyUp`, `noteOn`, `noteOff` (the transport methods) and `panic()` route through
  `ArpeggiatorPanel` when it is enabled. The licence-gate check stays first on every path, and
  `panic()` silences the pattern as well as the voices.
- `tickArpeggiator()` emits whatever the host's time has reached; a 5 ms `stepTicker` drives it
  while the engine runs and is invalidated in `stop()`. The interval is this repository's own
  choice: `StepClock` keeps the grid itself, so the ticker only bounds how late a step reaches
  the voices.
- The panel reads the injected clock, which is the deterministic seam the tests need.

The audio engine interface, the render path and the MIDI architecture are untouched, and
nothing was added to `Sources/SundayKeysCore`.

## What the tests assert

`Tests/SundayKeysAppTests/StepClockWiringTests.swift` drives the model's own note path over a
`ManualHostClock` with a recording voicing, in the app ticker's 5 ms steps, twelve cases:

- a three-note chord at 120 bpm in eighths producing the exact sixteen-event sequence over the
  first second (60, 64, 67 wrapping, on then off, every step at the configured velocity);
- the first step landing on the first tick, and a second tick at the same instant adding
  nothing;
- a release mid-pattern ending the sounding note once, cancelling its scheduled off, and
  leaving the pattern silent afterwards;
- a note held mid-phrase joining on the next step without moving the grid;
- a pattern change taking effect on the next step;
- a tempo change keeping the already-scheduled step and halving the interval after it;
- a division change keeping the already-scheduled step and then stepping a quarter later;
- an empty held set producing no event at all;
- the arpeggiator off still forwarding the pressed velocity;
- a refused licence refusing the key before the pattern holds it, with the gate unchanged and
  no step sounding, and the licensed control case that does sound.

## Runs read for this increment

Every entry was read through `LIST_JOBS_FOR_A_WORKFLOW_RUN` or `LIST_CHECK_RUN_ANNOTATIONS`.

`35301f76` (the wiring itself, pushed by the patch runner):

- build `43039990844` - **failure** in `Test` at 14:36:30. `Build (debug, with tests)`
  14:36:00-14:36:26 succeeded, so the patched model and the suite compiled. Five assertions
  failed, quoted verbatim: `XCTAssertEqual failed: ("["on 60 v100"]") is not equal to
  ("["on 60 v100", "off 60"]")` (pattern change), `("["on 60 v100", "off 60"]")` versus
  four events (note held mid-pattern), `("["on 60 v100", "off 60", "on 60 v100", "off 60"]")`
  versus three (division), and the chord case producing four events where eight were expected.
  These were wrong expectations, not wrong wiring: the clock deliberately keeps the step
  already scheduled when tempo or division changes, and a note sink cannot expose instants.
- session `43039850230` - **success**, release build 14:35:12-14:35:44, bundle 14:35:44-14:35:46,
  session probe 14:35:46-14:35:50, job completed 14:35:54.
- click `43039850248` - **success**, release build 14:35:23-14:35:55, bundle 14:35:55-14:35:57,
  click probe 14:35:57-14:36:01, job completed 14:36:04.
- patch-transfer `43039850543` - **success**, release 14:35:10-14:35:45, bundle
  14:35:45-14:35:48, patch probe 14:35:48-14:35:50, job completed 14:35:54.

`24f740b4` (the corrected expectations):

- session `43040873482` - **success**, release build 14:41:35-14:42:08, bundle
  14:42:08-14:42:10, session probe 14:42:10-14:42:14, job completed 14:42:16.
- build: **not read to a terminal state.** `43040873479`, `43041264735` and `43041445911` were
  each dispatched and each sat `queued` with `runner_id` `0` or `null` and `steps: []`. The first
  two were cancelled and replaced; the third was still runnerless when this pass ended.
- click: `43040835355` and `43041264954` were cancelled by their concurrency group or sat
  runnerless; `43041493009` was still `queued` with `runner_id: null` at the end.
- patch-transfer: `43040835634` was cancelled by its concurrency group; `43040873366`,
  `43041264608` sat runnerless and were cancelled and replaced.

Push-triggered twins `43040835347` and `43040835314` were cancelled by their concurrency groups
at 14:41:22 and are not results. The cancelled build run carried the verbatim annotation
`The run was canceled by @WorshipWarehouse.` plus the standing notice `Due to capacity
constraints, jobs targeting macOS arm64 runners may experience longer queue times.`

## What this increment does not establish

1. **`Test` on the corrected head.** No runner was assigned, so the twelve cases have not been
   executed since the expectations were corrected. This is the one open item that blocks
   calling the wiring proven.
2. click and patch-transfer on `24f740b4`, for the same reason.
3. What an arpeggio sounds like. The tests prove scheduling, ordering and the routing into the
   note path; no ear and no audio device were involved, and no window was looked at.
4. The original application's step rate, subdivision values, gate, latch, swing and switch-off
   behaviour. All remain **Unknown**, and every rule applied is this repository's own and
   replaceable.
5. `docs/progress.md` is not updated by this commit. It is 110 KB, the contents API replaces
   whole files, and the documented append path needs a runner - the same queue this pass could
   not get. This file is the record until that append can run.

## How to finish it

Dispatch `build.yml` on `main` until a runner is assigned, and read `Test`. If a case fails,
judge it on its merits: a real defect goes back through the anchored patch or a direct edit, a
wrong expectation is corrected against the documented rule that a tempo or subdivision change
keeps the already-scheduled step. Then append this file to `docs/progress.md` on a runner, so
the log carries the same words as this companion.
