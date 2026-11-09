# Progress log and roadmap

The single place to resume from. Read this first when execution restarts, then follow the next
actions in order. Findings themselves stay in
[`sunday-keys-2.5.2-analysis.md`](sunday-keys-2.5.2-analysis.md); this file tracks state.

## Phase status

| phase | status | evidence |
| --- | --- | --- |
| Investigate, static | done for what static methods allow | analysis sections 1 to 20 |
| Investigate, runtime | not started | needs one captured session |
| Design | specification, contracts and feature inventory written | `clean-room-implementation.md`, `feature-inventory.md` |
| Build | not started | needs a reachable machine with Xcode |
| Test | not started | follows the build |

A completed analysis is not a product. No application source exists yet.

## Blocking dependency

The build machine has been unreachable during the last several sessions, so nothing could be
compiled, and the whole-program re-decompilation could not run. Tool installation has the same
dependency: it needs a shell on that machine, so it cannot be delegated.

## Next actions, in order

1. `bash tools/bootstrap.sh --check` and install whatever it reports. Ghidra previously lived
   under `/tmp`, which does not survive a reboot, so expect to reinstall it.
2. `tools/decompile_all.sh /tmp/sk-named 2500 0`, about 11 minutes over 38 chunks, to produce a
   corpus whose bodies carry the metadata-derived names applied in section 17.
3. `python3 tools/callgraph.py --corpus /tmp/sk-named --names /tmp/sk-full/functions-named.tsv
   --out /tmp/callgraph.tsv`. This script has never been executed; if its summary reports zero
   bodies, the chunk header pattern is wrong and needs fixing before the numbers mean anything.
4. Add analysis section 21: module direction, replacing the co-occurrence limit stated at the
   end of section 20.
5. Work the decompilation targets listed at the end of `feature-inventory.md`, starting with
   `Audio.KeyboardVelocityScaling`, `Audio.LayerRangeLimit` with `Domain.RangeApi`, and the MIDI
   learn tables.
6. Begin M1, the licence and session module in a Swift package, then build it.

## Coverage that remains

| gap | cause | closes with |
| --- | --- | --- |
| call direction between modules | corpus is pre-rename | next actions 2 and 3 |
| 234 unattributable dispatch references | descriptors outside the local type table | a wider type table, or a capture |
| 31 types with no module name | no recoverable parent chain or mangled symbol | a capture |
| velocity curve, split range semantics, voice stealing | not yet decompiled | next action 5 |
| effect parameter ranges and defaults | not yet decompiled | next action 5 |
| licence JSON casing, date strategy, grace duration | not statically recoverable | one captured session |
| Pusher channel and event names, chunk size, payload encryption, tempo authority | not statically recoverable | one captured session |

## Decisions recorded

| decision | rationale |
| --- | --- |
| unknown licence status decodes to `expired` | fail closed rather than unlock features on an unrecognised wire value |
| module dependency direction is labelled Inferred | section 20 measured co-occurrence, not direction |
| no third-party audio dependency chosen yet | Core Audio, AVFoundation and Core MIDI cover the engine; add a library only when a concrete need appears |
| clean-room rules apply to all build work | behaviour from the analysis, no transcribed code, strings or assets |
| the original sample libraries cannot be reused | they are proprietary content, so an independent sampler and original sounds are required |

## Commit trail

| commit | purpose |
| --- | --- |
| `6981402` | module coupling map |
| `22e93a2` | repository README |
| `1b76ae9` | call graph extractor |
| `04b2cd5`, `316a8b7` | README corrections for the extractor and reproduce steps |
| `445fd58` | clean-room implementation plan |
| `b272896`, `7a2f069` | toolchain bootstrap, then invocation through bash |
| `d96b996` | this progress log |
| `d19f6e8` | feature inventory with evidence and gaps |

Earlier analysis commits are listed in the analysis document itself.
