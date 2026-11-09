# Clean-Room SK

Clean-room work on **Sunday Keys 2.5.2** (`com.sundaysounds.sundaykeys`, build 3367, macOS / Mac
Catalyst, arm64): static analysis of the shipped binary, and an independent Swift implementation
being built from what that analysis documents.

Nothing here is produced by executing the original app, and no original source was consulted.

## Status

| area | state |
| --- | --- |
| static analysis | 89,486 functions decompiled, 3,186 types recovered, 20 documented sections |
| feature inventory | capability checklist with evidence and gaps |
| implementation plan | contracts, milestones, unknowns |
| app | Swift package with a SwiftUI shell, CoreMIDI input and an AVAudioEngine scaffold |
| decompilation of the next targets | awaiting host access, see `docs/re/access-determination.md` |

Analysis figures: 3,316,097 lines of decompiled C (86.8 MB), 5,068 conformance descriptors parsed
with 4,864 attributable, 18,103 functions named from metadata (20.2 percent), 8,622 protocol
dispatch references over 2,527 descriptors.

## What is where

| path | purpose |
| --- | --- |
| `docs/sunday-keys-2.5.2-analysis.md` | the analysis: 20 sections of findings |
| `docs/feature-inventory.md` | capability checklist with evidence and gaps |
| `docs/clean-room-implementation.md` | replication plan: contracts, milestones, unknowns |
| `docs/progress.md` | phase status, next actions, decisions |
| `docs/re/access-determination.md` | what blocks decompilation and what access it needs |
| `Package.swift` | Swift package: `SundayKeysCore` library, `SundayKeysApp` executable |
| `Sources/SundayKeysCore/` | MIDI message parsing, velocity curve, note ranges |
| `Sources/SundayKeysApp/` | SwiftUI shell, CoreMIDI input, AVAudioEngine render scaffold |
| `Tests/SundayKeysCoreTests/` | unit tests for the core module |
| `.github/workflows/build.yml` | clean build and test on a macOS runner |
| `tools/bootstrap.sh` | install or verify the local toolchain |
| `tools/macho.py` | Mach-O parsing, chained fixups, relative pointers, string map |
| `tools/swift_metadata.py` | Swift type, field and conformance recovery |
| `tools/literal_refs.py` | literal slot and code-referenced string scan |
| `tools/swift_names.py` | name derivation from metadata and witness tables |
| `tools/inventory.py` | function enumeration and coverage statistics |
| `tools/callgraph.py` | caller to callee edges from a named corpus |
| `tools/decompile.sh`, `tools/decompile_all.sh`, `tools/pipeline.sh` | Ghidra drivers |
| `tools/ghidra/` | headless helpers: decompile by address, list functions, apply names |

## Build the app

```bash
swift build        # library and app target
swift test         # core tests
```

The same commands run on a macOS runner for every push, and the check run on a commit carries the
result. There is no Xcode project yet: the package builds the app target, and bundling it into an
`.app` is a later step in the roadmap.

## Reproduce the analysis

Requirements: Python 3.11+, Java 21+, Ghidra 12.1.4, and an arm64 slice of the app binary.

```bash
export GHIDRA_INSTALL_DIR=/path/to/ghidra_12.1.4_PUBLIC
export GHIDRA_HEADLESS_MAXMEM=8G

bash tools/bootstrap.sh --check

lipo -thin arm64 "/Applications/Sunday Keys.app/Contents/MacOS/Sunday Keys" \
  -output /tmp/sundaykeys-arm64

python3 tools/swift_metadata.py /tmp/sundaykeys-arm64 --json /tmp/meta.json
python3 tools/literal_refs.py /tmp/sundaykeys-arm64
python3 tools/swift_names.py /tmp/meta.json > /tmp/swift-names.tsv

tools/decompile_all.sh /tmp/sk-full 2500 0
tools/decompile_all.sh /tmp/sk-named 2500 0
python3 tools/callgraph.py --corpus /tmp/sk-named \
  --names /tmp/sk-full/functions-named.tsv --out /tmp/callgraph.tsv
```

Decompilation runs at roughly 140 functions per second, about eleven minutes for 38 chunks. The
reference slice is SHA-256 `9ae567e91f2e6e3e9cb93443b14bd0f0e17ddcd2b049f7e29dab76629cf6df00`.

## What the analysis establishes

- **Identity and surface**: bundle id, version, Mac Catalyst build, and a single network base
  `https://production.sundaysounds.com`.
- **Licence model**: `UserSessionApi {maxAvailableBackups, maxAvailableAudioOutputs, userRole,
  license, accessibleProducts}` with an optional `LicenseApi {status, gracePeriodsEndsAt}`, and the
  wire vocabulary `active` / `grace_period` / `expired`.
- **API layer**: 81 `Networking` Codable models, an `{data}` / `{error}` envelope, a Pusher auth
  handshake, bulk product pull, and S3-style backup presign.
- **Peer mesh**: Pusher doubles as a device-to-device mesh using an access code plus machine ID,
  with presence discovery, `connectKey` pairing, chunked setlists and rhythm events.
- **Engine shape**: `EngineConductor` through `PatchConductor` to `SoundConductor`, sampling per
  sound, multi-output mixers, twelve audio effects, and per-snapshot effect state.
- **Module separation**: 4,868 bodies dispatch protocols but only six module pairs ever co-occur,
  with `Domain` + `SundaySounds` at 25 bodies the one substantial boundary.

## Conventions

Every claim is labelled **Observed**, **Inferred** or **Unknown**. Measurements are recomputed from
artifacts rather than trusted from tool output, and retracted figures stay recorded as retracted.

## Known limits

- No runtime capture, so licence wire details, effect parameter ranges, split semantics, MIDI CC
  mappings, chunk size and tempo authority remain **Unknown**.
- 234 dispatch references resolve outside the local type table; 31 types have no module name.
- Call direction across modules is not yet recovered; the coupling map is co-occurrence.
- The audio engine is a scaffold: a try-lock on the render path drops buffers under contention and
  is scheduled for replacement with a lock-free queue.

## Legal

This repository documents the behaviour of a commercially distributed application for
interoperability and clean-room replication. It contains no redistributed application code, assets
or sample libraries.
