# Pitch bend and channel pressure reach the engine

Pitch bend and channel pressure were parsed, routed and counted, and then stopped:
`AppModel` recorded the event and the engine was never told. This milestone gives
both a real destination in the keysound engine and proves it from rendered samples.
Nothing here was heard, and nothing was validated on a controller: the local Mac is
unreachable, so every result comes from the `macos-15` runner.

## Observed

- `MIDIEvent` carries `pitchBend(value:channel:)` and `channelPressure(pressure:channel:)`,
  and `MIDIEventTransport` requires a method for each.
- `PolyphonicInstrument` had one phase increment per voice and one output gain, and
  no command that could move either.
- `RenderCommand` had four kinds: note on, note off, all notes off and layer timbre.

## Unknown

- The original's bend range. Two semitones is this repository's own decision.
- Whether the original responds to channel pressure at all, and how.
- Whether a bend is applied per channel, per layer or globally there; here it is
  global because the transport has one set of voices.
- Anything a controller or a person would hear. No ear was involved.

## Decided here, for a testable version

- **The wire value is converted once.** `ExpressionRange` turns a fourteen bit bend
  into -1 to 1 and a seven bit pressure into 0 to 1, clamping anything the wire could
  not have sent. It is a pure value type with no isolation, so the ends are asserted
  without a render thread.
- **The bend is a frequency ratio, not a re-trigger.** Two commands ride the same ring
  notes use: `pitchBend` and `channelPressure`. The instrument multiplies each voice's
  phase advance by the bend ratio, so a wheel moves the pitch of notes that are already
  sounding and releases none of them.
- **The range is two semitones either side.** A bend of 1 is `2^(2/12)`, a bend of -1
  is `2^(-2/12)`, and anything past the ends clamps rather than transposing further.
- **Pressure is a gain trim.** Zero pressure is exactly the neutral gain, so a
  controller that never sends aftertouch changes nothing at all; full pressure lifts
  the finished mix by 1.4. This is a replacement for a filter the engine does not have,
  and it is labelled this repository's own.
- **Neither command allocates on the render thread.** Both are plain values in the same
  fixed-size command, applied by assignment in the drain the engine already does.

## What the tests assert

`Tests/SundayKeysCoreTests/ExpressionTests.swift`, eleven cases, on concrete values:

1. the bend centre, `8192`, converts to exactly 0;
2. `16383` converts to exactly 1 and `0` to exactly -1;
3. a bend past the wire range clamps to 1;
4. `64` of 127 converts to `64.0 / 127.0` within 0.0001, `127` to 1 and `200` to 1;
5. a neutral bend leaves a rendered block byte-for-byte identical to no command;
6. a full bend up raises the zero-crossing count of a sounding A4 over 4800 frames by
   at least eight, which is what a two semitone lift must do;
7. a full bend down lowers that count by at least eight;
8. a bend of 2 renders identically to a bend of 1, so the clamp is in the render path
   and not only in the conversion;
9. zero pressure renders identically to no pressure command;
10. full pressure lifts the peak of the block by 1.4 within 0.01;
11. a pressure past the range renders identically to full pressure.

The crossing count is measured from the samples the instrument writes, not from the
commands it received, so a command that was queued but not applied fails the test.

## What this does not establish

- That any of it sounds musical: no ear, no output device, no window.
- That a real controller sends what the probe sends; no controller has been attached.
- That a bend on one channel leaves another channel alone: the engine has one voice set
  and the bend is global, which the original's behaviour is Unknown about.

## Next actions, in order

1. A controller on a real Mac, to see a real bend and aftertouch arrive.
2. Channel-scoped expression, if a capture shows the original scoping it per channel.
3. The hardware items the earlier milestones left unchanged.
