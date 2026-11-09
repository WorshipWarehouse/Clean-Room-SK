# Progress log and roadmap

The single place to resume from. Read this first when execution restarts, then follow the next
actions in order. Findings stay in [`sunday-keys-2.5.2-analysis.md`](sunday-keys-2.5.2-analysis.md);
this file tracks state.

## Phase status

| phase | status | evidence |
| --- | --- | --- |
| Investigate, static | done for what static methods allow | analysis sections 1 to 20 |
| Investigate, runtime | not started | needs one captured session |
| Design | specification, contracts and feature inventory written | `clean-room-implementation.md`, `feature-inventory.md` |
| Build | app target compiles and tests pass in CI | run 42721262800, commit `43637aa`, conclusion success |
| Test | core unit tests run in CI | `Tests/SundayKeysCoreTests/`, same run |

A working package is not the finished product. The app has a shell, MIDI input and an engine
scaffold; there is no sampler, no effects, no patch management and no persistence yet.

## Decompilation: awaiting external access

No artifact that can be decompiled is reachable from this environment. The shell tool refused
every call with "run_terminal_command is not currently available", which means the desktop client
is not connected to the host, so no process can be started, no path can be examined and no Ghidra
run is possible. The repository tree was enumerated through the GitHub API and contains only docs,
tools and Swift sources: no Mach-O, `.app`, AUv3 bundle, `.aupreset`, CAF payload, Ghidra project or
prior decompilation export. Details and the exact access required are in
[`re/access-determination.md`](re/access-determination.md).

Required to resume decompilation: the Mac awake with the Freebuff desktop client connected,
`/Applications/Sunday Keys.app` installed, Ghidra 12.1.4 and Java 21 or newer reinstalled under a
persistent path rather than `/tmp`, and about ten minutes for a fresh import.

## Next actions, in order

1. Reconnect the host, then `bash tools/bootstrap.sh --check` and install what it reports.
2. `tools/decompile_all.sh /tmp/sk-named 2500 0`, about eleven minutes over 38 chunks.
3. `python3 tools/callgraph.py --corpus /tmp/sk-named --names /tmp/sk-full/functions-named.tsv
   --out /tmp/callgraph.tsv`. Never executed; if it reports zero bodies the header pattern is
   wrong and must be fixed before the numbers mean anything.
4. Decompile the queued targets: `Audio.KeyboardVelocityScaling`, `Audio.LayerRangeLimit` with
   `Domain.RangeApi`, the Realm MIDI learn tables, `Audio.SamplerPlugin` voice handling, and the
   rotor, chorus and delay parameter ranges. Commit extracts under `docs/re/` with provenance.
5. Add analysis section 21 for module direction.
6. Replace the render-path try-lock in `VoiceBank` with a lock-free single producer queue, then add
   a sample playback instrument behind `AudioEngineController`.
7. Add patch and snapshot models with Codable persistence, then the patch switching path.

## Build verification

`.github/workflows/build.yml` runs `swift build --build-tests` and `swift test` on a `macos-15`
runner for every push to main.

| commit | run | conclusion |
| --- | --- | --- |
| `43637aa` | [42721262800](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42721262800) | success, two annotations (warnings) |

That run built the library, the executable app target and the test bundle, then executed the core
tests. Later commits re-run the workflow; treat a commit as built only when its own check run is
green.

## Coverage that remains

| gap | cause | closes with |
| --- | --- | --- |
| call direction between modules | corpus is pre-rename | next actions 2 and 3 |
| 234 unattributable dispatch references | descriptors outside the local type table | a wider type table, or a capture |
| 31 types with no module name | no recoverable parent chain or mangled symbol | a capture |
| velocity curve, split range semantics, voice stealing | not yet decompiled | next action 4 |
| effect parameter ranges and defaults | not yet decompiled | next action 4 |
| licence wire details, Pusher channel and event names, chunk size, tempo authority | not statically recoverable | one captured session |
| sample playback, effects, patches, persistence | not implemented | next actions 6 and 7 |

## Decisions recorded

| decision | rationale |
| --- | --- |
| unknown licence status decodes to `expired` | fail closed rather than unlock features on an unrecognised wire value |
| module dependency direction is labelled Inferred | section 20 measured co-occurrence, not direction |
| the original sample libraries cannot be reused | proprietary content, so an independent sampler and original sounds are required |
| Swift package rather than an Xcode project | builds and tests headlessly on a clean runner, which is the only verification available while the host is away |
| render path try-locks instead of blocking | a dropped buffer is better than a stalled audio device, and it is a known staging step |
| velocity curve constants are independent | the original curve could not be read statically, so the shape is ours and replaceable |

## Commit trail

| commit | purpose |
| --- | --- |
| `445fd58` | clean-room implementation plan |
| `b272896`, `7a2f069` | toolchain bootstrap, then invocation through bash |
| `d96b996` | this progress log |
| `d19f6e8`, `a54d013` | feature inventory, then log update |
| `4cb34dc` | Swift package, core module, tests, CI workflow |
| `43637aa` | SwiftUI shell, CoreMIDI input, AVAudioEngine scaffold, access determination |
| `5d7a070` | README describing the package |
| `d1e3854` | log entry for the app target and the access determination |

Earlier analysis commits are listed in the analysis document itself.
