## Milestone: arpeggiator latch (2026-11-10)

Status: implemented in the core and proven by a GitHub-hosted macOS
runner. Nothing in this section was validated on hardware, on a real
keyboard, or by ear. Those stay **Unknown**.

### Why this was the next item

The five "next actions, in order" at the end of the step clock
milestone are all blocked on the local Mac: a controller on a real
machine, hardware MIDI refinements, the panel's status line, the
relaunch path and the decompilation work. The highest-priority
software gap was therefore the one the step clock analysis already
names: latch was unimplemented and recorded **Unknown**.

### What the analysis says, and what it does not

The analysis names a latch control and records no behaviour for it.
The rule below is this repository's own and replaceable on its own:
it is stated in the source, tested directly, and can be changed
without touching the clock, the pattern or the engine.

### The rule this repository chose

- With latch on, a key release removes the key from the set the
  player is physically holding and leaves the note in the pattern, so
  the pattern keeps running with no key down.
- The next press made when no key is physically held begins a new
  chord: the previous chord's sounding notes are released at that
  instant and the pattern restarts on that press.
- A press made while another key is still down joins the running
  pattern on the next step instead of restarting it.
- Switching latch off drops the notes no key is holding, at that
  instant, and stops the pattern when none remain.
- Latch does nothing while the arpeggiator is off, where a press and
  a release are forwarded unchanged.
- Latch defaults to off, so no existing caller changes behaviour.

### Code

`Sources/SundayKeysCore/ArpeggiatorService.swift` gained `isLatched`,
`setLatched(_:at:)`, an initialiser parameter defaulted to off, and a
private `physicallyHeld` set kept alongside the pattern's notes.
`keyDown`, `keyUp`, `setEnabled` and `allNotesOff` were updated to
keep that set in step, and the clock's `hold` and `release` do the
note work exactly as before, so latch adds no scheduling rule.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorLatchTests.swift`,
eight cases on `ManualHostClock` with a recording sink, asserting
exact emitted events:

1. latch defaults to off;
2. a latched pattern keeps running for three steps after the last
   key comes up, seven exact events from 0.0 to 0.75;
3. a new chord pressed at 0.2 releases the old note at 0.2, and the
   old chord's second note never sounds;
4. switching latch off releases an unheld latched note at the
   release instant and stops the pattern;
5. switching latch off keeps a note that is still held;
6. latch does nothing while the arpeggiator is off;
7. a press while another key is down joins the pattern and wraps
   the cycle, with note ons at 0.0, 0.25 and 0.5;
8. enabling under latch keeps the held key in the pattern for two
   steps after release.

### The defect this found, and the fix

The first run of the suite (build 42862109269 on head 48975da2)
compiled cleanly and then failed five of its cases. The failures
were in the expectations, not the service: the grid at 120 bpm with
eighth division is a step every 0.25 s, with the note off 0.125 s
after its note on, and the suite had been written against a 0.125 s
step. That same output already showed the rules holding (off 60 at
0.2, on 67 at 0.2, and 64 never sounding), so the repair corrected
every instant, extended three cases and added the default case; the
service itself was not changed. Commit 7abcb2c1.

### Runner evidence

All on GitHub-hosted `macos-15` runners (Xcode 16.4, Swift 6.1.2).

- build 42862109269, head 48975da2: completed/failure. Debug build
  success 17:10:25 to 17:10:53; Test failed at 17:10:57 on the five
  wrong expectations above. This is the run that found the defect.
- build 42862603335, head 7abcb2c1: completed/success, job finished
  17:14:30. Debug build 17:13:06 to 17:13:34; Test success 17:13:34
  to 17:13:39; release build 17:13:39 to 17:14:07; bundle, launch,
  audio probe, MIDI probe and bootstrap check all success. This is
  the run that proves the latch suite.

The clock's own derivation was confirmed from its source for this
milestone: `stepInterval` is 60 / beatsPerMinute / stepsPerBeat, and
the gate is the gate fraction of that interval.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorService.swift`,
  every byte of `ArpeggiatorLatchTests.swift`, every byte of this
  section, and the one-shot append job's workflow file.
- Moved by a runner: this section's bytes were appended to
  docs/progress.md by the `append-progress` job on `ubuntu-latest`,
  which concatenates the section file and then commits and pushes.
  The file is far past what the contents API will replace in one
  call, so I did not write these bytes into it directly.

### What is still Unknown

- Whether the original's latch behaves like this rule.
- Anything needing the local Mac: a real controller, hardware MIDI,
  the panel's status line, the relaunch path, decompilation.
- Latency, CPU and audio behaviour under load.

### Next actions, in order

1. Wire latch to a control in the app and show its state, once the
   panel's status line exists.
2. Get `patch_transfer` a green run on a head it can keep; it
   starves on docs-only heads.
3. The remaining hardware items, when a Mac is available.
