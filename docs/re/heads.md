# Heads after the expression milestone

A record of which commit carries which proof, kept beside the milestone notes so a
later pass does not have to reconstruct it from the run list.

| Commit | What it contains | Check runs on that head |
| --- | --- | --- |
| `8dd4f4cd` | staging commit for the wiring job | build, click, patch-transfer, session and concurrency were started and then cancelled by `d49e74f2`; the wire job itself ran green, `43054725729`, 16:05:00-16:05:06 |
| `d49e74f2` | the expression wiring and the job's own removal | none: pushed by the job's repository token |
| `2b692454` | the wiring plus `docs/re/expression-milestone.md` | five runs, all success: `43054883292` build 16:06:13-16:07:49, `43054883180` click 16:05:56-16:06:52, `43054883252` patch-transfer 16:05:59-16:06:43, `43054883117` session 16:05:58-16:06:54, `43054883163` concurrency 16:05:58-16:06:44 |
| `219288f0` | staging commit for the progress append | started and cancelled by `18368eb5`; the append job ran green, `43055409204`, 16:09:03-16:09:08 |
| `18368eb5` | the appended `docs/progress.md` section and the job's own removal | none: pushed by the job's repository token |
| this commit | this record | see the five runs raised with it |

## What the runs prove

- The code compiles in debug with tests, the whole suite passes on a `macos-15` runner,
  the release build and the bundle succeed, the app launches, and the audio, MIDI and
  licence-session probes return their recorded values.
- The MIDI routing seam compiles with complete concurrency checking and carries no
  diagnostic.
- The click, patch transfer and session resume behave as their own probes record.

## What they do not prove

- Nothing was heard. No output device, no microphone, no ear and no window were
  involved, and no controller was attached.
- The app has not been run on the local Mac, because it is unreachable; every result
  here comes from the hosted runner.
