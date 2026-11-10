
## Milestone: the arpeggiator session survives a launch (2026-11-10)

Status: implemented in the core, the panel layer and the app's section, and
proven by a GitHub-hosted macOS runner. Nothing here was validated on
hardware, on a real controller, or in a window anyone looked at: those stay
**Unknown**.

### Why this was the next item

The mission's priority list named preset and session management first. The
bank already holds the patches, their effects, the controller layouts and the
set list with its play head, and `SessionMemory` already restores the patch the
last launch ended on. What no file held was the arpeggiator: on, latch, the
pattern, the octave span, the tempo and the division were all forgotten when
the process ended, so a player dialled the whole panel in again at every
launch. That is the smallest session-management gap left, and it needs no Mac.

### What a session is, and why it is its own file

`ArpeggiatorSession` is those six choices as a value. `ArpeggiatorSessionStore`
writes it to `arpeggiator-session.json` beside the bank and the launch memory,
rather than inside `session.json`, for the same reason the launch memory is not
inside the bank: the bank's format does not move, and a session file that will
not read cannot stop a single patch from loading.

A session carries switches and choices, never held notes. `ArpeggiatorSession(panel:)`
reads the panel's own value, and `apply(to:)` puts it back through the panel's
own setters - `setPattern`, `setOctaves`, `setBeatsPerMinute`, `setDivision`,
`setLatched`, `setEnabled` - so a restored session takes exactly the path a
moved control takes and the app's mirrors are republished from the panel
afterwards. Nothing reaches into the service directly.

### The document, and what it refuses

`ArpeggiatorSessionDocument` is the versioned JSON form. Its known fields are
`version`, `enabled`, `latched`, `beatsPerMinute`, `division`, `pattern` and
`octaves`; the keys are sorted, so the same session always produces the same
bytes.

- **A later build's fields survive.** Every key this build does not read is held
  in `unknownFields` as a `JSONValue` and written back beside the known ones, so
  a document written by a later build passes through this one unchanged. A
  `JSONValue` rather than `JSONSerialization` is deliberate: the bridge answers
  `NSNumber` for every number and cannot tell a `Bool` that came from `1` from
  one that came from `true`, so a carried field could come back as the wrong
  type.
- **A later version is refused whole.** The version is checked before any field
  is read, so a format this build does not know is refused rather than half
  understood.
- **Every refusal has a name.** `ArpeggiatorSessionFailure` separates bytes that
  are not JSON, valid JSON that is not an object, an unsupported version, a
  missing field, a field of the wrong shape, an unknown division and an unknown
  pattern. A malformed document is reported, never crashed on and never partly
  applied.
- **An earlier document opens on the defaults.** `pattern` and `octaves` are
  optional on read and default to `.up` and one octave, which is what a document
  written before those two controls existed gets; re-encoding writes them.
- **The span still clamps.** The value goes through `ArpeggiatorSession`, which
  clamps to one to four and the tempo through the click's own bounds, so a
  hand-edited file cannot put the pattern somewhere its stepper could not.

The store is not `SessionStore`: a missing file is `nil`, but a file that exists
and will not read throws, because overwriting a session the player asked to keep
is their decision rather than a fallback.

### The app path

`AppModel` gains `arpeggiatorSessionStatus`, `saveArpeggiatorSession()` and
`restoreArpeggiatorSession()`. Saving reads the panel, not the mirrors; restoring
applies the document through the panel, republishes every arpeggiator mirror and
reports the result in the panel's own words. `ArpeggiatorSection` gains a
`Save session` and a `Restore session` button with that line beside them, under
the status line the controls already had.

### What the fifteen cases assert

`Tests/SundayKeysCoreTests/ArpeggiatorSessionTests.swift`, on `ManualHostClock`
with a recording sink, all of it through `ArpeggiatorPanel`:

1. a session that set nothing is the panel's own defaults, and applying it
   leaves `Arp off, latch off, Up, 1 octave, 120 bpm, eighth`;
2. a panel set to on, latched, Down, two octaves, 140 bpm and sixteenth survives
   encode and decode and restores to
   `Arp on, latch on, Down, 2 octaves, 140 bpm, sixteenth`;
3. the same session always produces the same bytes, with sorted keys;
4. every JSON shape a later build might add - an object, an array, a string, a
   bool and null - comes back through a decode and an encode unchanged, and no
   known key is left in the carried set;
5. a later version is refused rather than half read;
6. a missing required field is named;
7. a field of the wrong shape is named;
8. bytes that are not JSON are refused;
9. valid JSON that is not an object is refused;
10. an unknown division number and an unknown pattern name are each named;
11. a document from before the pattern and span existed opens on `.up` and one
    octave, and still restores to
    `Arp on, latch off, Up, 1 octave, 132 bpm, eighth`;
12. an out-of-range span clamps to four through the panel;
13. a store writes and reads the session back from a temporary file, and
    restores `Arp on, latch on, UpDown, 4 octaves, 88 bpm, quarter`;
14. a corrupt file is reported rather than treated as nothing saved;
15. restoring emits no notes until a key arrives, so a session is state and not
    a chord.

The count is fifteen. The commit message for `d66e3a4` says thirteen; the file
has fifteen methods, and this line is the accurate one. No existing assertion
was changed, weakened or removed: the two edited files are app code, and every
earlier suite runs untouched in the same `Test` step.

### The runs

Every run below is on `d66e3a4`, the commit that carries this increment, and
every one was read to `status: completed` with `conclusion: success`:

- build `42872852592` - `Build (debug, with tests)` 18:12:55 to 18:13:12,
  `Test` 18:13:12 to 18:13:15 (the new suite ran here, not merely compiled),
  `Build (release)` 18:13:15 to 18:13:32, `Bundle the app`, `Launch the app`
  18:13:33 to 18:13:39, the audio probe, the MIDI probe and the bootstrap check,
  job completed 18:13:50;
- click `42872852586` - release build, bundle and click probe, completed 18:13:30;
- patch-transfer `42872852724` - release build, bundle and patch probe, completed
  18:13:32;
- session `42872852654` - release build, bundle and session-resume probe,
  completed 18:13:13.

This head needed no unblocking: all four took runners on the push, none sat in
the queue, so neither cancel-then-dispatch nor a trivial commit was used on
`d66e3a4`.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorSessionDocument.swift` (new),
  every byte of `ArpeggiatorSessionTests.swift` (new), the edited
  `AppModel.swift`, the edited `ArpeggiatorSection.swift`, and this section.
  The files were written through the git blob API from their full contents, so
  no transport rewrote them.
- Moved by a runner: this section's bytes were appended to `docs/progress.md` by
  the `append-progress` job on `ubuntu-latest`, which concatenates this file,
  deletes itself and its workflow, then commits and pushes. `docs/progress.md` is
  far past what the contents API will replace in one call, so I did not write
  these bytes into it directly.

`tools/bootstrap.sh` is untouched: this increment adds no dependency, no
package and no toolchain requirement, so what the script must install has not
changed. It remains unexecuted on the local Mac, and this milestone does not
claim otherwise.

### What is still Unknown

- Whether the original application stores a session at all, and in what shape:
  the recorded analysis says nothing, so this document format is this
  repository's own and replaceable.
- Whether pressing the two buttons in a window does what the model method does.
  No window was looked at; the runner compiles the section and the test target
  drives the panel, and those are different claims.
- Whether a second launch on a real Mac finds the file. The store is tested
  against a temporary path on the runner, not against a real Application
  Support folder across two processes.
- Anything needing the local Mac: a real controller, hardware MIDI I/O, the
  status line as rendered in a window, the relaunch path with a person watching,
  decompilation, latency and CPU under load.
- How any of it sounds, and whether a restored pattern is musical.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel, so an
   enabled arpeggiator steps what the player plays. This is still the oldest
   open software item, and it needs no Mac.
2. Restore a session on a real Mac across two launches and look at the buttons,
   which is the one part of this milestone the runner cannot reach.
3. The hardware items the earlier milestones left, unchanged.
