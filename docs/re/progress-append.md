## Milestone: the arpeggiator latch is a panel control (2026-11-10)

Status: implemented in the core and in the app's panel layer, and proven
by a GitHub-hosted macOS runner. Nothing here was validated on hardware,
on a real controller, or in a window anyone looked at: those stay
**Unknown**.

### Why this was the next item

The latch rule landed in the previous milestone and no control reached
it: the app had no arpeggiator panel at all, so on, tempo and division
had no surface either. The first entry in that section's next-actions
list was exactly this wiring, and it needs no local Mac - it is a model
and view job that a runner can compile and that the test target can
drive.

### The panel layer, and why it lives in the core

The tests only ever import `SundayKeysCore`, so logic the app cannot test
is logic nobody is checking. That decided the split:

- **`ArpeggiatorPanel`** is the surface the window binds to. One method
  per control - on or off, latch, tempo, division - each routed to the
  `ArpeggiatorService` the panel holds, and each reading the instant from
  the `HostClock` the panel was given rather than starting a timer. A
  toggle therefore lands at the instant the caller says, which is what
  makes the latch assertions exact.
- **`SystemHostClock`** is the app's clock. It reads the system's
  monotonic uptime rather than the wall clock, so a time correction
  mid-service cannot pull a pattern backwards or skip a step.
- **`AppModel`** owns one panel, lazily, because the panel needs the
  audio controller as its note target and a stored property initialiser
  cannot read another stored property. It mirrors the panel's state into
  published properties after every change, so the toggle, the tempo, the
  division and the status line cannot disagree with the service.
- **`ArpeggiatorSection`** is the panel in the window: an `On` toggle, a
  `Latch` toggle, a tempo stepper and a division picker, all bound to
  those model methods, plus the status line the panel composes.

Latch sits beside the other three and takes the identical path:
`setArpeggiatorLatched` to `ArpeggiatorPanel.setLatched` to
`ArpeggiatorService.setLatched(_:at:)`.

### What latch does, restated

Unchanged from the previous milestone, and still this repository's own
rule rather than a reproduction: a released key stays in the pattern and
the pattern keeps running with no key down; the first press made with
nothing physically held starts a new chord and releases the previous one
at that instant; a key pressed while another is still down joins the
running pattern; switching latch off drops the notes no key is holding
at the switch instant and stops the pattern when none remain.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorPanelTests.swift`, seven
cases on `ManualHostClock` with a recording sink:

1. the panel starts off, at 120 bpm and `.eighth`, with the status line
   `Arp off, latch off, 120 bpm, eighth`;
2. the latch toggle turns the service's latch on and back off, and the
   label follows;
3. a latched pattern driven through the panel keeps running for three
   steps after the key comes up - seven exact events from 0.0 to 0.75;
4. toggling latch off at 0.1 releases the unheld note at 0.1 and stops
   the pattern;
5. toggling latch off keeps the key still held in the pattern;
6. the tempo control lands clamped by the service's own bounds and the
   division control lands with its own label in the status line;
7. with the arpeggiator off, keys pass straight through even with latch
   on.

The eight service-level cases in `ArpeggiatorLatchTests.swift` are
unchanged and still pass, so the panel did not fork the semantics it
exposes.

### The runs

Run `42865901229` on `4a8523b5`: the job completed with every step
succeeding, including `Build (debug, with tests)` and `Test`, so the new
suite ran on the runner rather than merely compiling. The release
build, the bundle, the launch and the audio, MIDI and bootstrap probes
in the same workflow succeeded as well.

The path to it: commit `9c4487fb` assigned the panel in `init`, which
reads one stored property while another is still uninitialised - a use
of `self` before full initialisation, which Swift rejects. It was found
by reading the code before the build spent a runner on it, the queued
run was cancelled rather than left to fail, and `4a8523b5` made the
panel a lazy property instead.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorPanel.swift`,
  `SystemHostClock.swift`, `ArpeggiatorPanelTests.swift`,
  `ArpeggiatorSection.swift`, the edited `AppModel.swift`, the edited
  `ContentView.swift` (one line placing the section), and this section.
- Moved by a runner: this section's bytes were appended to
  `docs/progress.md` by the `append-progress` job on `ubuntu-latest`,
  which concatenates the section file and then commits and pushes. This
  file is far past what the contents API will replace in one call, so I
  did not write these bytes into it directly.

### What is still Unknown

- How any of it sounds, and whether a stepped pattern is musical.
- Whether the original's latch behaves like this rule.
- Anything needing the local Mac: a real controller, hardware MIDI, the
  panel's status line, the relaunch path, decompilation, latency and CPU
  under load.
- No window was looked at: the section compiles and its model is tested,
  it was not seen running.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel so
   an enabled arpeggiator steps what the player plays. Today the panel
   is reachable and its state is proven, but no key press reaches it.
2. A time source that ticks the panel while the arpeggiator is on; the
   panel deliberately owns none.
3. The hardware items the previous milestone left, unchanged.
