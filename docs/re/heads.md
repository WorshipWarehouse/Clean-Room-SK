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
| `8dd8419d` | the implemented-architecture section in `docs/clean-room-implementation.md`, `docs/tasks.md` and the row above | six runs, all terminal success: `43061174466` build (dispatched) 16:43:59-16:45:54, `Test` 16:44:49-16:44:54, launch and the audio, MIDI and licence probes green; `43061143444` build (attempt 3, after the dispatch cancelled attempt 1 and a runner-less attempt 2 was re-run) `Test` 16:48:08-16:48:14, launch 16:48:47-16:48:54, audio 16:48:54-16:48:56, MIDI 16:48:56-16:48:59, licence 16:48:59-16:49:09, complete 16:49:12; `43061143570` click 16:43:37-16:44:25; `43061143333` patch-transfer (attempt 3) 16:45:31-16:46:26; `43061143251` session 16:43:37-16:44:19; `43061143323` concurrency (attempt 2) 16:44:48-16:45:32 |
| `8d1def9c` | `RenderBudgetTests` and `.github/workflows/budget.yml`: the cost of one render block, measured on the real `renderStereo` path | six runs, all terminal success: `43062985714` build (attempt 2) debug-with-tests 16:55:57-16:56:27 with the budget test inside the suite, `Test` 16:56:27-16:56:33, release, bundle, launch 16:56:57-16:57:03, audio 16:57:03-16:57:06, MIDI 16:57:06-16:57:08, licence 16:57:08-16:57:13, complete 16:57:20; `43062985603` budget (attempt 2) 16:55:47-16:56:30, reporting engaged median 999.4 us of a 10,667 us block with a 2960.5 us worst block, and bypassed median 592.0 us with a 1671.8 us worst; `43062985817` click (attempt 2) 16:55:46-16:56:37; `43062985747` patch-transfer (attempt 2) 16:55:47-16:56:43; `43062985586` session 16:55:02-16:55:59; `43062985776` concurrency 16:54:59-16:55:43. Attempt 1 of build, budget, click and patch-transfer never picked up a runner, so each was cancelled and re-run |
| `47f701c7` | the measured budget in `docs/tasks.md` and the two rows above | five runs, all terminal success: `43063508533` build debug-with-tests 16:58:27-16:59:01, `Test` 16:59:01-16:59:07, release 16:59:07-16:59:31, bundle, launch 16:59:33-16:59:40, audio 16:59:40-16:59:43, MIDI 16:59:43-16:59:46, licence 16:59:46-16:59:51, bootstrap to 16:59:53, complete 16:59:58; `43063508664` click 16:58:14-16:58:55; `43063508696` patch-transfer 16:58:16-16:59:04; `43063508846` session 16:58:16-16:58:56; `43063508564` concurrency 16:58:15-16:58:57. The `budget` workflow did not run, because the push changed only docs |
| `d05b18a5` | `InstrumentCatalogue`, the three added `WaveTable` voices, `KeyLayer.instrument`, the table strip and rung command in `PolyphonicInstrument`, the rungs `setPatch` publishes, `InstrumentCatalogueTests`, `docs/tasks.md` and the two addenda | six runs, all terminal success: `43066184128` build (attempt 2) debug-with-tests 17:15:16-17:15:42 with the new test inside the suite, `Test` 17:15:43-17:15:48, release 17:15:49-17:16:10, bundle, launch 17:16:12-17:16:18, audio 17:16:18-17:16:20, MIDI 17:16:20-17:16:22, licence 17:16:22-17:16:28, bootstrap 17:16:28-17:16:30, complete 17:16:32; `43066184108` budget (attempt 2) 17:15:10-17:15:58, reporting engaged median 974.3 us of a 10,667 us block (9.1%) with a 3,064.6 us worst block (28.7%), and bypassed median 544.0 us (5.1%) with a 3,379.0 us worst (31.7%), the chain 1.8x the dry path; `43066184168` click (attempt 2) 17:15:09-17:16:05; `43066184198` patch-transfer (attempt 2) 17:15:10-17:15:59; `43066184036` session (attempt 2) 17:15:09-17:15:48; `43066575012` concurrency, dispatched, 17:16:44-17:17:31. Attempt 1 of all six never picked up a runner and was cancelled; the push-triggered concurrency run then failed to get one on three more attempts and was cancelled before the dispatch |
| `1d8443cf` | the appended `docs/progress.md` sections (effects closeout, render budget, instrument catalogue), the `docs/feature-inventory.md` addendum, and the instrument picker in `AppModel`/`ContentView` | none: pushed by the `progress-append` job's repository token, run `43066631011` 17:17:04-17:17:14, whose two verify steps checked both Swift edits before it pushed |
| `e9cfb583` | its `docs/re/heads.md` rows with the instrument-catalogue evidence and the row above, and the removal of `.github/workflows/progress_append.yml` | five runs, all terminal success at attempt 1 with runners: `43066957704` build debug-with-tests 17:19:19-17:19:49, `Test` 17:19:49-17:19:55, release 17:19:55-17:20:20, bundle 17:20:20-17:20:22, launch 17:20:22-17:20:30, audio 17:20:30-17:20:33, MIDI 17:20:33-17:20:35, licence 17:20:35-17:20:39, bootstrap 17:20:39-17:20:40, complete 17:20:46; `43066957703` click 17:19:12-17:19:50; `43066957591` patch-transfer 17:19:09-17:19:47; `43066957543` session 17:19:12-17:19:58; `43066957675` concurrency 17:19:11-17:19:46. The `budget` workflow did not run, because the push changed only docs and a workflow file |
| `4363807e` | `tools/strict_concurrency.sh`, the rescheduled `.github/workflows/concurrency.yml`, `docs/tasks.md`, `docs/re/ci-runner-queue.md` and the row above | build, click, patch-transfer and session on the push; `concurrency` starts on `workflow_run` once the build for this commit completes, and is the run whose first step prints `git rev-parse HEAD`; `budget` is skipped, because no `Sources`, `Tests` or `Package.swift` file changed |
| `fc5cbf40` | `Tests/SundayKeysAppTests/EffectsPanelTests.swift`, the effects-coverage entry in `docs/tasks.md` and `docs/re/effects-panel-coverage.md` | six runs, all terminal green: `43080592278` build (attempt 2) 18:45:23-18:47:24 - debug-with-tests 18:45:35-18:46:12 with the new file in the target, `Test` 18:46:13-18:46:20, release 18:46:20-18:46:53, bundle 18:46:53-18:46:55, launch 18:46:55-18:47:03, audio 18:47:03-18:47:06, MIDI 18:47:06-18:47:09, licence 18:47:09-18:47:15, bootstrap 18:47:17-18:47:20, complete 18:47:24; `43080593047` click (attempt 2) 18:45:22-18:46:18; `43080592029` patch-transfer (attempt 2) 18:45:21-18:46:07; `43080592416` session (attempt 3) 18:46:18-18:46:56; `43080628905` concurrency 18:44:37-18:45:12 and `43081086465` concurrency 18:47:31-18:48:19, the second fired by the build's completion; `43080592359` budget (attempt 7) 18:48:44-18:49:29, engaged median 911.1 us of a 10,667 us block (8.5%) with a 2,942.1 us worst block (27.6%), bypassed median 536.2 us (5.0%) with a 3,507.8 us worst (32.9%), the chain 1.7x the dry path. Attempt 1 of the five push runs never picked up a runner and was cancelled; budget attempts 3 and 5 never did either, and attempts 4 and 6 were cancelled on a stale runner-less reading while they were in fact starting, so attempt 7 was re-run alone and left to finish. Attempt 2 of budget had measured the same cost (engaged median 1,010.6 us) and failed only on one 18,117 us stalled block in the bypassed path |
| this commit | the run evidence above in `docs/re/heads.md` and `docs/re/effects-panel-coverage.md` | build, click, patch-transfer and session on the push; `concurrency` when the build for this commit completes; `budget` is skipped, because no `Sources`, `Tests` or `Package.swift` file changed |

## What the runs prove
- The code compiles in debug with tests, the whole suite passes on a `macos-15` runner, the release
  build and the bundle succeed, the app launches, and the audio, MIDI and licence-session probes return
  their recorded values.
- The MIDI routing seam compiles with complete concurrency checking and carries no diagnostic. That
  proof is `tools/strict_concurrency.sh`, run as four named steps of the `concurrency` workflow, which
  now starts only after the build for the same commit has finished.
- The click, patch transfer and session resume behave as their own probes record.
- The effects chain is measured on samples, not on plumbing: tail versus bit-identical bypass, tap
  positions at 2,400 and 12,000 samples, feedback ratios, chorus movement, per-band EQ response,
  long-run finiteness, and bank and session round trip.
- The render path's cost is measured, not inspected: `RenderBudgetTests` drives `renderStereo` with ten
  voices and the whole chain engaged at 512 frames and 48 kHz, and fails if the engaged median takes
  more than a quarter of the block or if any single block overruns it.
- The instrument catalogue reaches the sound: `InstrumentCatalogueTests` renders the real path and
  requires five instruments to differ by more than 0.05 after the attack, an engine retargeted by
  `setPatch` to render sample-identical audio to one built on that instrument, a bank round trip to keep
  the id, and `releasingVoices: false` to keep the held voice.
- The effects panel reaches the sound through the method its controls call: `EffectsPanelTests` edits
  through `AppModel.updateEffects`, then renders `model.patch` on the real engine and measures a shelf
  boost against a shelf cut, the two delay taps against each other, the wet tail against the dry
  release, and `voiceCount` across a live edit.

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
  It is also sensitive to a stalled runner: attempt 2 of `fc5cbf40` failed on one 18 ms block while its
  median stayed at 9.5% of the budget.
- The effects panel has not been seen: its controls were driven through the model method they call, so
  layout, labels and focus behaviour remain unverified.
- The instrument picker was compiled and never seen, no sampled instrument ships, and nothing here says
  how the original stores, downloads or streams its instruments.
- Runner scheduling is GitHub's, not this repository's. Moving the strict job behind the build removes
  the burst that starved it; it cannot promise a runner within any given number of seconds.
