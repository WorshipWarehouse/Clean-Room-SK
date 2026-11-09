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
| Build, shell | done | commit `43637aa` |
| Build, instrument | polyphonic wavetable instrument, lock-free command queue, layer routing | `Sources/SundayKeysCore/Audio/` |
| Test | unit tests for parsing, curves, ranges, the queue, envelopes, stealing and split exclusion | `Tests/SundayKeysCoreTests/` |

This is a working instrument, not a finished product. Still missing: the effects chain, the patch
and snapshot model, persistence, sample assets, and an `.app` bundle.

## Audio milestone: what the instrument actually is

- **Sound source.** No sample assets exist in this repository and none from the original app may be
  used, so the keysounds are synthesised at startup into two 2048-sample tables: an additive keys
  table (twelve harmonic partials, even partials attenuated) and a two-operator FM bell. This is a
  wavetable synthesiser, not a sampled instrument, and the code says so.
- **Polyphony.** Thirty-two voices by default, sixteen per layer. Allocation prefers retriggering
  the same note on the same layer, then a free voice, then the quietest releasing voice in the
  layer, then the oldest voice in the layer.
- **Envelopes.** Linear attack from exactly zero over 8 ms, linear release to exactly zero over
  220 ms after which the voice is freed. A stolen voice fades out over 4 ms before the replacement
  starts its own attack, so stealing cannot click.
- **Command transport.** `SPSCCommandQueue` is a lock-free ring of fixed-size commands. The
  producer release-stores the write index after writing a slot and the consumer acquire-loads it
  before reading; the consumer release-stores the read index and the producer acquire-loads it
  before reusing a slot. Each thread loads its own index relaxed. The full argument is in the file.
- **No dropped buffers.** The render block never waits: it drains every queued command and then
  renders. A full ring makes the *producer* spin, at most one buffer period, which is 10.7 ms at
  48 kHz with 512-frame blocks.
- **Splits and layers.** MIDI and the on-screen keyboard both go through `LayerRouter`, which maps a
  key to the layers whose `NoteRange` contains it. Commands carry the layer and the transposed note,
  so a note outside a layer's range never reaches the render thread for that layer.
- **Latency.** One block, plus whatever the device buffer adds: 512 frames is 10.7 ms at 48 kHz and
  5.3 ms at 96 kHz.

## Decompilation: awaiting external access

No artifact that can be decompiled is reachable from this environment. The shell tool refused every
call with "run_terminal_command is not currently available", so no process can be started, no path
can be examined and no Ghidra run is possible. The repository contains only docs, tools and Swift
and C sources: no Mach-O, `.app`, AUv3 bundle, `.aupreset`, CAF payload, Ghidra project or prior
decompilation export. Details and the exact access required are in
[`re/access-determination.md`](re/access-determination.md).

Required to resume: the Mac awake with the Freebuff desktop client connected, the app installed,
Ghidra 12.1.4 and Java 21 or newer under a persistent path, and about ten minutes for an import.

## Next actions, in order

1. Patch and snapshot model: a `Patch` of layers plus effect settings, Codable persistence, and
   switching that reuses the existing keysound engine instead of rebuilding the graph.
2. Effects chain: EQ, chorus, delay and reverb as source-level DSP after the voice mix, with tests
   for gain, stability and bypass.
3. MIDI controller mapping: CC to layer gain and effect parameters, learned and stored with the
   patch.
4. Session and setlist management on top of the patch model.
5. Bundle the package into a signed `.app` and add an audio-unit or standalone build target.
6. Reconnect the host, then decompile the queued targets (`Audio.KeyboardVelocityScaling`,
   `Audio.LayerRangeLimit` with `Domain.RangeApi`, the Realm MIDI learn tables,
   `Audio.SamplerPlugin` voice handling, and the rotor, chorus and delay parameter ranges) and
   commit the extracts under `docs/re/` with provenance.

## Build verification

`.github/workflows/build.yml` runs `swift build --build-tests` and `swift test` on a `macos-15`
runner for every push to main.

| commit | run | conclusion |
| --- | --- | --- |
| `43637aa` | [42721262800](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42721262800) | success. Both annotations are workflow notices: a Node 20 deprecation on `actions/checkout@v4` and a macOS queue-time notice, not code warnings. |
| `33086584` | [42721455596](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42721455596) | success, same two workflow notices |

Treat a commit as built only when its own check run is green; later commits re-run the workflow.

## Coverage that remains

| gap | cause | closes with |
| --- | --- | --- |
| call direction between modules | corpus is pre-rename | a named re-decompilation |
| 234 unattributable dispatch references | descriptors outside the local type table | a wider type table, or a capture |
| 31 types with no module name | no recoverable parent chain or mangled symbol | a capture |
| velocity curve, split range semantics, voice stealing | not decompiled | awaiting external access |
| effect parameter ranges and defaults | not decompiled | awaiting external access |
| licence wire details, Pusher channel and event names, chunk size, tempo authority | not statically recoverable | one captured session |
| effects, patches, persistence, controller mapping, `.app` bundle | not implemented | next actions 1 to 5 |

## Decisions recorded

| decision | rationale |
| --- | --- |
| unknown licence status decodes to `expired` | fail closed rather than unlock features on an unrecognised wire value |
| module dependency direction is labelled Inferred | section 20 measured co-occurrence, not direction |
| the original sample libraries cannot be reused | proprietary content, so the keysounds are synthesised from original partial sets |
| Swift package rather than an Xcode project | builds and tests headlessly on a clean runner |
| C target for the atomic index operations | the memory orderings are the compiler's own builtins, with no dependency to resolve and no deprecated wrapper |
| commands are never dropped | the producer spins instead; only the render thread is latency-critical |
| wavetables and voices are built before the graph starts | allocation must not happen on the render thread |
| voice stealing fades before retriggering | a hard reassignment is audible as a click |

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
| `33086584` | log entry for the green build |
| `78b907f` | SPSC queue, wavetable instrument, layer routing, audio tests |

Earlier analysis commits are listed in the analysis document itself.
