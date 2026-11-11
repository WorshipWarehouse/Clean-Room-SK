import pathlib

SECTION = """

## Milestone: pitch bend and channel pressure reach the engine

Pitch bend and channel pressure were parsed, routed and counted, and then stopped: no
engine code read either one. They now move the sound, and the movement is measured
from rendered samples rather than from the commands that were queued.

### Heads and runs

- Code landed at `d49e74f2` by the dispatch-only job `wire-expression`, run
  `43054725729`, window 16:05:00-16:05:06, conclusion success. The same job removed
  its own workflow and script, so `.github/workflows/wire-expression.yml` returns 404
  on `main`.
- Proven at `2b692454`, which carries that code plus one documentation file. Five
  workflows, all success:
  - `build` run `43054883292`, window 16:06:13-16:07:49. Steps: build (debug, with
    tests) 16:06:24-16:06:57, Test 16:06:57-16:07:02, build (release)
    16:07:02-16:07:24, bundle 16:07:24-16:07:26, launch 16:07:26-16:07:32,
    probe audio 16:07:32-16:07:35, probe MIDI 16:07:35-16:07:37, probe licence
    session 16:07:37-16:07:42, verify bootstrap 16:07:42-16:07:44.
  - `click` run `43054883180`, window 16:05:56-16:06:52.
  - `patch-transfer` run `43054883252`, window 16:05:59-16:06:43.
  - `session` run `43054883117`, window 16:05:58-16:06:54.
  - `concurrency` run `43054883163`, window 16:05:58-16:06:44.
- The staging commit `8dd4f4cd` was pushed to raise the job, and its build, session,
  click, patch-transfer and concurrency runs were cancelled by the job's own push to
  `main`, which is what the per-ref concurrency group does to an older head. Those
  runs cover a tree that the job replaced; none of them is counted as proof.

### What changed

- `Sources/SundayKeysCore/Audio/ExpressionRange.swift` (new) converts a fourteen bit
  bend to -1 to 1 with each half scaled separately, and a seven bit pressure to 0 to 1.
- `Sources/SundayKeysCore/Audio/RenderCommand.swift` gains two kinds, `.pitchBend` and
  `.channelPressure`, so expression rides the ring the notes already use.
- `Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift` multiplies every sounding
  voice's phase advance by the bend ratio and trims the finished mix by the pressure
  gain. Both are applied in the drain that already existed, on the render thread, with
  no allocation.
- `Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift` and
  `Sources/SundayKeysApp/Audio/AudioEngineController.swift` forward the two commands,
  and `Sources/SundayKeysApp/AppModel.swift` converts the wire value before queueing
  it, so the conversion happens once.
- `Tests/SundayKeysCoreTests/ExpressionTests.swift` (new) holds eleven cases.

### What the tests assert

Four conversion cases: `8192` is exactly 0, `16383` exactly 1, `0` exactly -1, a value
past the wire range clamps to 1, and `64` of 127 is `64/127` within 0.0001. Seven
render cases: a neutral bend renders identically to no command, a full bend up raises
the zero crossings of a sounding A4 over 4800 frames by at least eight and a full bend
down lowers them by at least eight, a bend of 2 renders identically to a bend of 1 so
the clamp is in the render path, zero pressure renders identically to no pressure, full
pressure lifts the peak of the block by 1.4 within 0.01, and a pressure past the range
renders identically to full pressure. A command that was queued but never applied fails
the render cases, because they read the samples the instrument wrote.

### This repository's decisions, all replaceable

- Two semitones either side for the bend range, and 1.4 at full pressure. The
  original's bend range, its aftertouch response and whether it responds at all are
  Unknown.
- Expression is global, not per channel, because the engine holds one voice set. The
  original's scoping is Unknown.

### Not established

- Nothing was heard: no output device, no ear, no window. The tests measure samples.
- No controller was attached, so what a real wheel and a real aftertouch strip send is
  untested here.
- `docs/re/expression-milestone.md` carries the same record beside the milestone files.

### Next actions, in order

1. A controller on an awake Mac, to see a real bend and a real aftertouch arrive.
2. Channel-scoped expression, if a capture shows the original scoping it per channel.
3. The hardware items the earlier milestones left unchanged, still blocked on an awake
   Mac.
"""

path = pathlib.Path("docs/progress.md")
text = path.read_text(encoding="utf-8")
if "pitch bend and channel pressure reach the engine" in text.lower():
    raise SystemExit("the section is already present; refusing to append twice")
path.write_text(text.rstrip("\n") + SECTION, encoding="utf-8")
print("appended", len(SECTION), "characters")
