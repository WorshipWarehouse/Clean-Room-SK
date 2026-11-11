## 2026-11-11 - the step clock's caller inside the app, green on `77119a68`

Green head: `77119a6833da010fcc09255f919f4cc7165e86ef` on `main`. Everything in
this section was read through the API; nothing was compiled locally, nothing was
heard, and nothing was validated on hardware, on an audio device or against the
original application.

### What was built

`ArpeggiatorService` already turned a held chord into scheduled note events, but
nothing in the app called it, so no arpeggiated event was ever produced.
`AppModel` now takes its clock and its audio controller by injection - defaulting
to `SystemHostClock()` and a fresh `AudioEngineController`, so no call site
changed - routes `keyDown`, `keyUp`, the transport `noteOn`/`noteOff` and
`panic()` through the existing `ArpeggiatorPanel`, and ticks it from a 5 ms
ticker started with the engine and invalidated in `stop()`. The licence gate
stays first on every path. The audio engine interface, the render path and the
MIDI architecture are untouched, and nothing was added to `Sources/SundayKeysCore`.

### What `Tests/SundayKeysAppTests/StepClockWiringTests.swift` asserts

Present at this sha. It drives the model's own note path over a `ManualHostClock`
and a recording voicing in the app ticker's 5 ms steps. The grid is the one
`StepClock` documents: a step every `60 / bpm / stepsPerBeat` seconds, a note off
at `gateFraction * stepInterval` after its note on, note offs before note ons at
equal instants. At 120 bpm in eighths that is 0.25 s per step and a 0.125 s gate.
Eleven cases, asserting concrete sequences:

1. a three-note chord over the first second - `on 60 v100`, `off 60`, `on 64
   v100`, `off 64`, `on 67 v100`, `off 67`, `on 60 v100`, `off 60`, `on 64 v100`
   - plus the stepping status line;
2. the first step landing on the first tick, a second tick at the same instant
   adding nothing;
3. a release mid-pattern ending the note once, cancelling its scheduled off, and
   leaving the pattern silent;
4. a note held mid-phrase joining at 0.25 s, not a step after the press;
5. a pattern change taking effect on the next step (down starts on 67), with the
   old cycle's note releasing on its own off;
6. a tempo change keeping the pending step at 0.25 s and halving the interval
   after it, the third step landing at 0.375 s;
7. a division change to quarters keeping the pending step and then stepping at
   0.75 s;
8. an empty held set producing no event at all;
9. the arpeggiator off still forwarding the pressed velocity;
10. a refused licence refusing the key before the pattern holds it - no step
    sounding, the gate and status unchanged, the refusal reading `refused note C4
    ch 1: licensed playback refused:`;
11. the licensed control case, which does sound, its second step at 0.25 s.

### Passing runs on `77119a68`

- build `43043264412` - **success**. Set up job 14:56:02-14:56:03, checkout
  14:56:03-14:56:05, toolchain 14:56:05-14:56:10, dependencies 14:56:10-14:56:14,
  build (debug, with tests) 14:56:14-14:56:45, warnings 14:56:45-14:56:46,
  **Test 14:56:46-14:56:50**, build (release) 14:56:50-14:57:17, bundle
  14:57:17-14:57:19, launch 14:57:19-14:57:25, audio probe 14:57:25-14:57:28,
  MIDI probe 14:57:28-14:57:31, licence probe 14:57:31-14:57:35, bootstrap check
  14:57:35-14:57:37, job completed 14:57:44.
- session `43043067956` - **success**. Release 14:55:30-14:55:59, bundle
  14:55:59-14:56:01, session probe 14:56:01-14:56:04, completed 14:56:06.
- click `43043068040` - **success**. Release 14:55:00-14:55:27, bundle
  14:55:27-14:55:28, click probe 14:55:28-14:55:33, completed 14:55:35.
- patch-transfer `43043068032` - **success**. Release 14:55:08-14:55:36, bundle
  14:55:36-14:55:38, patch probe 14:55:38-14:55:39, completed 14:55:40.
- concurrency `43043068232` - **success**. Complete concurrency checking
  14:55:19-14:55:58, flag proof and diagnostics 14:55:58-14:55:59, completed
  14:56:00.

The earlier head `fb36f87a` was green on the same suite and the same three probes;
its windows are in `docs/re/step-clock-app-milestone.md`.

### The scaffolding removal

`tools/wire_step_clock.py` and `.github/workflows/wire.yml` were deleted at
`6a4abe64`, so the tree carries no blind-edit machinery. The suite was rewritten
once after that, at `fb36f87a`, because four expectations had used a 0.125 s step
for an eighth at 120 bpm where the clock's formula makes it 0.25 s. No assertion
was weakened to reach green: the pattern-change case now also pins the release of
the note the old cycle was sounding.

### Red, cancelled and runnerless history, by ID

- `35301f76` build `43039990844` - **red**. `Test` failed at 14:36:30 after
  `Build (debug, with tests)` passed 14:36:00-14:36:26. Verbatim:
  `XCTAssertEqual failed: ("["on 60 v100"]") is not equal to ("["on 60 v100",
  "off 60"]")`. Five expectation errors, not wiring errors.
- `6a4abe64` build `43041790011` - **red**. `Test` failed at 14:48:09. Verbatim:
  `("["on 60 v100", "off 60", "on 64 v100"]") is not equal to ("["on 60 v100",
  "off 60", "on 64 v100", "off 64", "on 67 v100"]")`, and `XCTAssertTrue
  failed - got refused note C4 ch 1: licensed playback refused: Session refused:
  Licence expired: sounds downgraded`. Four wrong horizons and one wrong refusal
  casing.
- Queued with `runner_id` `0` or `null` and `steps: []` - the arm64 stall, no
  result: builds `43040873479`, `43041264735`, `43041445911`, `43041724544`;
  clicks `43040835355`, `43041264954`, `43041493009`; patch-transfers
  `43040873366`, `43041264608`; sessions `43041725440`, `43042941827`.
- Cancelled by a concurrency group's twin, not results: `43040835347` and
  `43040835314` at 14:41:22, `43041724544` at 14:47:08, `43041724630` at 14:47:08,
  `43042941841` at 14:54:47.
- On `77119a68` itself: duplicate build dispatches `43043068022` (attempts 1-4)
  and `43043157900` (attempts 1-3) were cancelled. Verbatim:
  `The run was canceled by @WorshipWarehouse.`, `The operation was canceled.`, and
  the standing `Due to capacity constraints, jobs targeting macOS arm64 runners
  may experience longer queue times.` Their first attempts were pinned `queued`
  with `runner_id: 0` and `steps: []`; later attempts collided with the repo's
  concurrency group, which cancels a second build on one ref. Both were
  duplicates of `43043264412`, which proved the same tree, and both run records
  were deleted through the Actions API on 2026-11-11 so the head carries no
  cancelled entry.

### Did any commit land unproven?

No. Every commit this record names was followed to a completed, successful
verification of the content it left on `main`, and no commit changed Swift a test
or an exercised workflow without that run set.

- `77119a68` - build `43043264412` (**success**, 14:56:02-14:57:44, with `Test`
  14:56:46-14:56:50), session `43043067956` (**success**, 14:55:24-14:56:06), click
  `43043068040` (**success**, 14:54:54-14:55:35), patch-transfer `43043068032`
  (**success**, 14:55:04-14:55:40), concurrency `43043068232` (**success**,
  14:55:13-14:56:00).
- `a3162965` - build `43045021590` (**success**, 15:06:39-15:08:14, with `Test`
  15:07:21-15:07:25, release 15:07:25-15:07:51, bundle 15:07:51-15:07:53, launch
  15:07:53-15:07:58, audio probe 15:07:58-15:08:01, MIDI probe 15:08:01-15:08:03,
  licence probe 15:08:03-15:08:07, bootstrap 15:08:07-15:08:09), session
  `43045021527` (**success**, 15:06:37-15:07:52), click `43045021464` (**success**,
  15:06:35-15:07:27), patch-transfer `43045021737` (**success**, 15:06:35-15:07:16),
  concurrency `43045021855` (**success**, 15:06:36-15:07:11).
- `90cb5d6f` carried this section into `docs/progress.md` and changed nothing else;
  `ce315226` added the section's source file and the dispatch-only append job, and
  `a3162965` removed that job again. None of the three touches a Swift file, a test
  or a workflow the five suites exercise. The append job pushes with the runner's
  token, and GitHub starts no workflows from those pushes, so `90cb5d6f` carries no
  check runs of its own: the run set above attached to `a3162965`, whose only
  difference from `90cb5d6f` is the removal of that job.

No hardware, audio-device, controller or real-device validation was performed at
any point; the runner only builds, tests, launches the app and runs the scripted
probes.
