# Heads and what they carry

A record of which commit carries which proof, kept beside the milestone notes so a later pass does not
have to reconstruct it from the run list.

| Commit | What it contains | Check runs on that head |
| --- | --- | --- |
| `8dd4f4cd` | staging commit for the wiring job | build, click, patch-transfer, session and concurrency were started and then cancelled by `d49e74f2`; the wire job itself ran green, `43054725729`, 16:05:00-16:05:06 |
| `d49e74f2` | the expression wiring and the job's own removal | none: pushed by the job's repository token |
| `2b692454` | the wiring plus `docs/re/expression-milestone.md` | five runs, all success: `43054883292` build 16:06:13-16:07:49, `43054883180` click 16:05:56-16:06:52, `43054883252` patch-transfer 16:05:59-16:06:43, `43054883117` session 16:05:58-16:06:54, `43054883163` concurrency 16:05:58-16:06:44 |
| `219288f0` | staging commit for the progress append | started and cancelled by `18368eb5`; the append job ran green, `43055409204`, 16:09:03-16:09:08 |
| `18368eb5` | the appended `docs/progress.md` section and the job's own removal | none: pushed by the job's repository token |
| `5c989476` | the EQ peak band and the two delay taps in the settings model, plus the rewritten `EQProcessor` | one run reached the head: build `43058718631` failed in the debug-with-tests step on `MetronomeTests.swift:162`, `extra argument 'time' in call` |
| `0d13af8a` | staging commit for the stereo wiring job | build, click, patch-transfer, session and concurrency started and were superseded; the wire job ran green, `43058488272`, 16:27:22-16:27:29, and pushed `7ee38229` |
| `7ee38229` | the chain, engine and device wiring | none: pushed by the job's repository token |
| `b3d78c35` | the wiring plus `EffectsStereoTests` and `docs/re/effects-chain.md` | build `43058718631` failed on the missing `time:` initialiser; patch-transfer `43058718605` was green 16:28:48-16:29:36 |
| `e40713e6` | the restored `DelaySettings(time:)` shorthand initialiser | superseded before its runs finished |
| `e6989bba` | the appended `docs/progress.md` milestone | none: pushed by the job's repository token, `43059543923` was the append job |
| `c839b64e` | the effects code, tests and docs plus the proof section in `docs/re/effects-chain.md` | five runs, all terminal success: `43060202038` build (dispatched, since the path filter skips docs-only pushes) debug-with-tests 16:37:57-16:38:25, `Test` 16:38:26-16:38:30, release 16:38:30-16:38:53, bundle 16:38:53-16:38:55, launch 16:38:55-16:39:01, audio probe 16:39:01-16:39:03, MIDI probe 16:39:03-16:39:05, licence probe 16:39:06 onward; `43059645819` click (attempt 3) 16:36:45-16:37:29; `43059645864` patch-transfer (attempt 3) 16:36:43-16:37:27; `43059645350` session (attempt 2) 16:35:31-16:36:12; `43059645755` concurrency 16:34:41-16:35:26 |
| `8dd8419d` | the implemented-architecture section in `docs/clean-room-implementation.md`, `docs/tasks.md` and the row above | six runs, all terminal success: `43061174466` build (dispatched) 16:43:59-16:45:54, `Test` 16:44:49-16:44:54, launch and the audio, MIDI and licence probes green; `43061143444` build (attempt 3, after the dispatch cancelled attempt 1 and a runner-less attempt 2 was re-run) `Test` 16:48:08-16:48:14, launch 16:48:47-16:48:54, audio 16:48:54-16:48:56, MIDI 16:48:56-16:48:59, licence 16:48:59-16:49:05, complete 16:49:12; `43061143570` click 16:43:37-16:44:25; `43061143333` patch-transfer (attempt 3) 16:45:31-16:46:26; `43061143251` session 16:43:37-16:44:19; `43061143323` concurrency (attempt 2) 16:44:48-16:45:32 |
| `8d1def9c` | `RenderBudgetTests` and `.github/workflows/budget.yml`: the cost of one render block, measured on the real `renderStereo` path | six runs, all terminal success: `43062985714` build (attempt 2) debug-with-tests 16:55:57-16:56:27 with the budget test inside the suite, `Test` 16:56:27-16:56:33, release, bundle, launch 16:56:57-16:57:03, audio 16:57:03-16:57:06, MIDI 16:57:06-16:57:08, licence 16:57:08-16:57:13, complete 16:57:20; `43062985603` budget (attempt 2) 16:55:47-16:56:30, reporting engaged median 999.4 us of a 10,667 us block with a 2960.5 us worst block, and bypassed median 592.0 us with a 1671.8 us worst; `43062985817` click (attempt 2) 16:55:46-16:56:37; `43062985747` patch-transfer (attempt 2) 16:55:47-16:56:43; `43062985586` session 16:55:02-16:55:59; `43062985776` concurrency 16:54:59-16:55:43. Attempt 1 of build, budget, click and patch-transfer never picked up a runner, so each was cancelled and re-run |
| this commit | the measured budget in `docs/tasks.md` and these two rows | docs only: build, click, patch-transfer, session and concurrency; the `budget` path filter skips a docs-only push |

## What the runs prove
- The code compiles in debug with tests, the whole suite passes on a `macos-15` runner, the release
  build and the bundle succeed, the app launches, and the audio, MIDI and licence-session probes return
  their recorded values.
- The MIDI routing seam compiles with complete concurrency checking and carries no diagnostic.
- The click, patch transfer and session resume behave as their own probes record.
- The effects chain is measured on samples, not on plumbing: tail versus bit-identical bypass, tap
  positions at 2,400 and 12,000 samples, feedback ratios, chorus movement, per-band EQ response,
  long-run finiteness, and bank and session round trip.
- The render path's cost is measured, not inspected: `RenderBudgetTests` drives `renderStereo` with ten
  voices and the whole chain engaged at 512 frames and 48 kHz, and fails if the engaged median takes
  more than a quarter of the block or if any single block overruns it.

## What they do not prove

- Nothing was heard. No output device, no microphone, no ear and no window were involved, and no
  controller was attached.
- The app has not been run on the local Mac, because it is unreachable; every result here comes from
  the hosted runner.
- The device path fills left and right and the runner's probes start the graph, but no one has
  listened to the two sides, so "the taps reach the speakers" rests on the code path and the measured
  samples.
- The render budget is DSP cost in isolation on a CI runner, not a latency figure: no interface was
  involved, so it says nothing about the round trip a player would hear or about glitch-free playback.
