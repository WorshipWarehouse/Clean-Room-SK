## Milestone: the arp pattern and octave span are panel controls (2026-11-10)

Status: implemented in the core, the panel layer and the app's section,
and proven by a GitHub-hosted macOS runner. Nothing here was validated
on hardware, on a real controller, or in a window anyone looked at:
those stay **Unknown**.

### Why this was the next item

The latch landed in the previous milestone and the pattern behind it was
still fixed: every chord walked upward, one octave, with no control that
said otherwise. The first entry in that section's next-actions list was
the wiring, and it needs no local Mac - it is a model and view job a
runner can compile and the test target can drive.

### What the controls are, and the path they take

The pattern is a picker in the arpeggiator section offering Up, Down and
UpDown. The octave span is a 1 to 4 stepper beside it. Both sit with on,
latch, tempo and division, and both take the identical path those do:

    ArpeggiatorSection
      -> AppModel.setArpeggiatorPattern / setArpeggiatorOctaves
      -> ArpeggiatorPanel.setPattern / setOctaves
      -> ArpeggiatorService.setStyle / setOctaves
      -> StepClock.setStyle / setOctaves
      -> Arpeggiator

`AppModel` mirrors the pattern and the span into published properties
after every change, the same way it mirrors latch and tempo, so the
picker cannot show a value the service does not hold.

### Where the span lives, and why

The span belongs in `Arpeggiator`, the pure pattern type, because that
is where the cycle is decided. Each held note repeats twelve semitones
higher for every extra octave; a transposed note that would pass 127 is
left out rather than wrapped down onto a lower pitch; and one octave is
exactly the held keys, so nothing the earlier cases assert moves. A
pattern or span change restarts the cycle from its first step and leaves
the grid alone, which is the rule a style change already followed - so a
change made mid-phrase is heard on the next step, not immediately.

`ArpeggiatorService` owns the clamped span (one to four) and forwards it
to the clock, which forwards it to the pattern. `heldNotes` on the
service is still the keys the player holds, not the transposed notes,
which is what makes the latch assertions still read the way they did.

### What the patterns do

Up walks the held chord from its lowest note, Down from its highest, and
UpDown turns at the top and the bottom without repeating either end, so
60/64/67 walks `60, 64, 67, 64`. The analysis names six orderings and
records no behaviour for any of them, so these are this repository's own
rules and the code and the window both say so. The picker offers the
three a player can predict from the name; DownUp, Random and Chord stay
reachable in the core for when a capture says what they do. The span
rule is equally ours: the analysis records no octave behaviour at all.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorPatternTests.swift`, nine
cases on `ManualHostClock` with a recording sink, all through
`keyDown`/`keyUp` and `tick` at exact instants on the default grid (120
bpm, `.eighth`, so a step every 0.25 s):

1. Up over 60/64/67 sounds 60 at 0.0, 64 at 0.25, 67 at 0.5, 60 at 0.75;
2. Down sounds 67, 64, 60 over the same steps and wraps;
3. UpDown sounds 60, 64, 67, 64, 60 across 0.0 to 1.0;
4. one octave over 60/64 is exactly 60, 64, 60, 64;
5. two octaves over 60/64 is 60, 64, 72, 76;
6. four octaves over 60 alone is 60, 72, 84, 96;
7. `setOctaves(9)` clamps to 4, `setOctaves(0)` clamps to 1, and 3 stays 3;
8. with latch on and every key lifted, changing to Down at two octaves
   makes 0.5 sound 79 and 0.75 sound 76, while all three keys stay in the
   pattern and the pattern keeps running;
9. a pattern change does not move the grid: the step already due at 0.25
   still lands at 0.25, filled by the new order.

`ArpeggiatorPanelTests` gains three cases - the picker and stepper reach
`service.style` and `service.octaves` and the labels follow, the span
clamps through the panel, and a pattern-plus-span chosen through the
panel changes what four ticks emit - and its first case gains two
assertions for the default pattern and span. Its two exact status-line
assertions now read the extended line,
`Arp on, latch off, Up, 1 octave, 120 bpm, eighth`. No assertion was
removed or loosened; the status line is compared for exact equality,
before and after.

### The runs

Every run below is on `8603278d`, the commit that carries this
increment, and every one reads completed with conclusion success:

- build `42869548651` - toolchain, dependencies, debug build with tests,
  Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap
  script;
- click `42869796981` - release build, bundle, click probe;
- patch-transfer `42869797297` - release build, bundle, patch probe;
- session `42869797082` - release build, bundle, session-resume probe.

The push-triggered click, patch-transfer and session runs on this head
sat queued with no runner while build ran and after it finished. They
were cancelled and re-dispatched on the same head rather than left to
starve, and the three re-dispatched runs took runners at once: that is
the strategy that unblocked them, and it moved no commit. The build run
that proved the tests is the push-triggered one.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `Arpeggiator.swift`,
  `StepClock.swift`, `ArpeggiatorService.swift`, `ArpeggiatorPanel.swift`,
  `AppModel.swift`, `ArpeggiatorSection.swift`,
  `ArpeggiatorPanelTests.swift`, the new
  `ArpeggiatorPatternTests.swift`, and this section. The files were
  written through the git blob API from their full contents, so no
  transport rewrote them.
- Moved by a runner: this section's bytes were appended to
  `docs/progress.md` by the `append-progress` job on `ubuntu-latest`,
  which concatenates this file, deletes itself and its workflow, then
  commits and pushes. `docs/progress.md` is far past what the contents
  API will replace in one call, so I did not write these bytes into it
  directly.

### What is still Unknown

- How any of it sounds: whether a two-octave UpDown is musical, whether
  the gate is right, whether any of it is too fast to play.
- Whether the original's pattern or octave controls behave like these.
  The analysis records neither.
- Anything needing the local Mac: a real controller, hardware MIDI, the
  panel's status line as rendered, the relaunch path, decompilation,
  latency and CPU under load.
- No window was looked at: the section compiles and its model is tested,
  it was not seen running.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel so
   an enabled arpeggiator steps what the player plays. The controls are
   reachable and their state is proven; no key press reaches them yet.
2. A time source that ticks the panel while the arpeggiator is on; the
   panel deliberately owns none.
3. The hardware items the earlier milestones left, unchanged.
