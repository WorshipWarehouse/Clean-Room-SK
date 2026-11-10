## Milestone: typed MIDI message routing

**Status:** landed and green on `edd02e85`. The MIDI input path now has a strict,
typed layer between the bytes and the engine, and the MIDI inputs panel shows
what that layer did with the last packet.

**Why this one next:** preset and session management finished with
`ArpeggiatorSessionDocument` and its store, so the open piece of the input path
was the one the port left lenient. `MIDIMessage.parse` and `parseAll` keep
anything they do not model as `other` and pad a short message with zero, which
is the right behaviour for a CoreMIDI callback that must never drop a packet and
must never crash on one - but it means a malformed message and a note that
simply arrived look the same to the caller. The layer added here is the strict
form, and it is the one the tests can state.

**What the increment does:**

- `MIDIEvent` - one validated channel event: note on, note off, control change,
  program change, pitch bend, channel pressure. Channels, notes, velocities,
  controllers and programs are 0-127 (channels 0-15) because the decoder checks
  them; the fourteen-bit bend is 0-16383. A note on at velocity zero is
  translated to a note off at the decoder, so no downstream stage has to
  special case the wire's second spelling of it.
- `MIDIEventFailure` - every refusal has a name: `empty`,
  `unsupportedStatus`, `systemMessage`, `truncated(status:expected:got:)`,
  `dataByteOutOfRange(status:byte:)`. Rejection is a value that reaches the
  caller, not a crash and not a silently shortened note list.
- `MIDIEventDecoder.decode` decodes one message; `decodeAll` decodes a packet in
  arrival order, following running status, skipping real-time bytes, resyncing on
  a status byte that arrives where data belongs, and stopping at a message that
  stops short because where the next one starts cannot be known then.
- `MIDIEventTransport` - the injectable seam, one method per event, so nothing is
  accepted and then ignored. `MIDIEventRouter` is a value that owns no clock, no
timer and no hardware: it decodes, delivers in order, counts delivered and
  rejected, remembers the last of each, and words the status line. It is
  testable the way the step clock is testable through `ManualHostClock`.
- `AppModel` conforms to the transport. Notes go to the engine through
  `KeysoundNoteTarget`, the same note path the arpeggiator plays into; controllers
  go through the existing learn and `applyController` path; a program change
  selects a patch; bend and pressure are recorded because the engine has no
  destination for them yet. `midiRouteStatus` is a `@Published` mirror the panel
  reads, and the routing counts are published setters, in the same shape the
  arpeggiator controls already use.
- `ContentView` shows the status line under the MIDI inputs box. The wording is
  pinned by tests: `MIDI route: nothing yet`, then
  `MIDI route: 1 delivered, 0 rejected, last note on 60 velocity 100 ch 1`, then
  `MIDI route: 2 delivered, 1 rejected, last refused: truncated 0x90: expected 2 data byte(s), got 1`.

**Tests:** a new suite, `Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift`,
15 cases, and no existing test or assertion was touched. It pins every supported
message type delivered through a recording transport in arrival order; note off
versus note on at velocity zero; the exact typed refusal for truncated,
unsupported, system, empty-message and status-in-data input; channel and data
boundaries at 0 and the maximum for every type; running status; real-time bytes
skipped without disturbing the message around them; resync after a bad byte;
`decodeAll` agreeing with `decode` message by message; the exact status-line
strings; and note events reaching the keysound path. Nothing in the suite reads
wall time or hardware: the router is a value and the transport is a recorder.

**Runs on the final head `edd02e85`** (the push dispatched all four; each read
`completed` / `success`):

- build `42883756772` - completed, success. Debug build with tests, the new suite
  green in the Test step, release build, bundle, launch, audio probe, MIDI probe,
  bootstrap check.
- click `42883756937` - completed, success. Release build, bundle, click probe.
- patch-transfer `42883756795` - completed, success. Release build, bundle, patch
  transfer probe.
- session `42883756796` - completed, success. Release build, bundle, session
  resume probe.

Two earlier heads on the way here were read rather than re-run. `0057d91b` failed
build because the new suite asked the keysound target for a control change the
target never receives; fixed in `31535fab`. That head then failed one assertion
about an empty packet - the decoder refuses an empty *message*, while a packet
with no bytes carries no message to refuse - and `edd02e85` pins both halves of
that contract without changing the decoder. The warnings the runner reports
(`AppModel`'s main-actor methods satisfying a non-isolated protocol) are real and
harmless in this Swift 5 package; they become errors under Swift 6 and are the
next cleanup, not a failure of this head.

**Hand-written versus runner-moved:** every source and test byte in this
document's milestone was written here: `Sources/SundayKeysCore/MIDI/MIDIEventRouting.swift`
(new), `Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift` (new),
`Sources/SundayKeysApp/AppModel.swift` and `Sources/SundayKeysApp/ContentView.swift`
(rewritten), plus this section and the one-shot workflow that published it. The
runner moved the append itself: it wrote these bytes onto the end of
`docs/progress.md`, deleted `docs/re/midi-route-append.md` and
`.github/workflows/append_progress.yml`, and committed and pushed that result on
its own. No code byte was generated or moved by the runner.

**Unknown without the Mac:** whether a real controller drives this path - the
hardware MIDI I/O, the CoreMIDI connection, and a physical note arriving; how the
status line and the panel controls actually render in a window; the relaunch
path; decompilation; latency, audio behaviour and anything about how it sounds.
A macOS runner proves parsing, ordering, encoding and emitted events. It does
not prove a note is audible. `tools/bootstrap.sh` is unchanged by this increment
- it installs nothing new - and it remains unexecuted on the local machine; the
runner's bootstrap step only checks it.

**Next actions:** mark `MIDIEventTransport` (or the conformance) so the Swift 6
main-actor warnings stop being latent errors; give bend and pressure a real
engine destination once the engine has one; then continue the input-port work -
controller assignment through `ControllerMapping` from typed events rather than
from the permissive parse.
