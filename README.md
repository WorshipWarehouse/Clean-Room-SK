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
| app | playable polyphonic instrument: wavetable voices, envelopes, splits and layers, CoreMIDI input, lock-free audio command queue, patch bank with gapless switching and JSON persistence, an original EQ/chorus/delay/reverb chain per patch, and a learned per-patch controller layout |
| not yet built | sessions and set lists, `.app` bundle |
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
| `docs/progress.md` | phase status, next actions, decisions, every CI run |
| `docs/re/access-determination.md` | what blocks decompilation and what access it needs |
| `Package.swift` | Swift package: `CSync`, `SundayKeysCore`, `SundayKeysApp` |
| `Sources/CSync/` | atomic index loads and stores for the audio queue and the effects settings seqlock |
| `Sources/SundayKeysCore/` | MIDI parsing, velocity curve, note ranges, layer routing, SPSC queue, wavetable instrument, patch model and bank store, controller mapping |
| `Sources/SundayKeysCore/Audio/Effects/` | EQ, chorus, delay and reverb processors and the chain that publishes their settings |
| `Sources/SundayKeysApp/` | SwiftUI shell with a playable keyboard, patch picker, layer editor, effects panel, controller mapping panel, CoreMIDI input, AVAudioEngine host |
| `Tests/SundayKeysCoreTests/` | unit tests for the core module |
| `.github/workflows/build.yml` | resolve, build, test, release build and bootstrap smoke check on a macOS runner |
| `tools/` | Mach-O, Swift metadata, literal and call-graph extractors, Ghidra drivers |

## Build the app

```bash
swift build        # library and app target
swift test         # core tests
```

The same commands run on a macOS runner for every push, and the check run on a commit carries the
result: the workflow also resolves the manifest, reports unique compiler warnings, builds the release
configuration and runs `bash tools/bootstrap.sh --check` as a smoke test. There is no Xcode project
yet: the package builds the app target, and bundling it into an `.app` is the next step in the
roadmap. The install path of the bootstrap script is not exercised anywhere, because it installs
Homebrew casks and needs sudo.

## The instrument

The keysounds are synthesised at startup from original partial sets, because the repository ships no
sample assets and the original libraries are proprietary. It is a wavetable synthesiser:

- additive keys table, twelve partials with even partials attenuated;
- two-operator FM bell table for the upper layer;
- 32 voices, 16 per layer, with linear 8 ms attack, 220 ms release and a 4 ms fade before a stolen
  voice is reused;
- notes are routed through `LayerRouter`, so a key only reaches layers whose range contains it;
- events cross to the render thread through a lock-free SPSC ring, so the render block never locks,
  allocates or drops a buffer.

## Patches

A patch is a name, a list of layers, an effects chain and a controller layout. Each layer has its own
key range, transpose, gain, timbre and enabled flag. The bank is JSON in Application Support, written
atomically, and a missing file loads the starter patch instead of an empty window.

- switching swaps the producer-side router, applies the new patch's effects and publishes the new
  timbres through the same command ring, then releases what is sounding over the existing 220 ms fade,
  so the change is heard as a tail under the new patch rather than as a gap and nothing is left
  hanging;
- editing the patch that is playing never releases voices, so moving a gain slider, turning an effect
  knob or moving a mapped controller cannot cut the chord under the player's hands;
- a program change selects the patch with that index, so a foot switch can walk a set list.

## Effects

The chain is EQ, chorus, delay and reverb, applied after the voice mix and owned by the patch. It is
original DSP written from a documented design: the analysis records the original app's effect
parameter ranges as **Unknown**, and nothing here guesses at them.

- **Ranges** live in one place, `EffectRanges`: mix 0 to 1, reverb decay and damping 0 to 1, chorus
  rate 0.05 to 6 Hz and depth 0 to 1, delay time 20 ms to 1.2 s and feedback 0 to 0.9, EQ gain -18 to
  +18 dB. Every processor clamps again on the render thread.
- **Reverb** is four damped combs at 29.7, 37.1, 41.3 and 43.9 ms plus two allpasses at 5.0 and
  1.7 ms; decay moves comb feedback from 0.35 to 0.93, damping moves a one-pole lowpass inside each
  comb. Those delay times are this implementation's own choice.
- **Chorus** reads a 50 ms line at a 12 ms base delay swept by up to 8 ms of sine LFO and mixes it
  with the dry signal.
- **Delay** is a 1.2 s line with a 30 ms glide to the new time, so moving the control on a held note
  bends the echo instead of clicking, and feedback is clamped so repeats always decay.
- **EQ** splits at 250 Hz and 3 kHz with a gain per outer band and the middle untouched. The bands sum
  to the input exactly, so unity gain is bit-transparent; because the split is one pole, a gain is a
  shelf rather than a full cut at the corner.
- **Bypass** is bit-exact dry: a disabled processor clears its state and returns before touching the
  buffer.
- **Settings** reach the render thread as a whole published through a seqlock on a `UInt64` using the
  `CSync` atomics, so the render block never locks or allocates and a torn read is discarded in
  favour of the previous settings for one more block.
- **Defaults** keep old patches dry: every effect starts bypassed, so a bank written before effects
  existed sounds exactly as it did, and only the starter patch engages a short reverb.

The tests measure the processing itself: a tail that is still audible a second after the input stops
and gone after seven, an impulse reappearing at exactly 4800 samples through a fully wet 100 ms
delay, repeats scaled by the feedback, a chorus difference signal that moves, an EQ that is
transparent at unity gain and moves each band, a bypassed chain that returns the buffer unchanged,
the engine rendering a reverb tail after every voice is freed, an effect change on a held note that
neither releases the voice nor silences it, and settings surviving the bank.

## Controller mapping

Each patch carries its own mapping, so two patches can put the same knob on different parameters and a
restored session restores what the knobs do.

- targets are one per layer gain plus reverb mix and decay, delay mix and feedback, chorus mix and
  depth, and the two EQ gains;
- a binding is a controller number, an optional channel and a target, and learning replaces in both
  directions, so a knob never moves two parameters and a parameter never has two knobs;
- a binding for the exact channel wins over an any-channel binding;
- a 7-bit value maps onto the full range with both endpoints exact;
- a target naming a layer the patch no longer has is ignored without touching anything else;
- the default layout binds CC 7 to the first layer's gain, CC 1 to reverb mix, CC 11 to delay mix and
  CC 74 to chorus mix. The original app's CC assignments are **Unknown** in the analysis, so these are
  this instrument's own defaults, and any of them can be relearned from the mapping panel.

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

- No runtime capture, so licence wire details, the original app's effect parameter ranges, split
  semantics, MIDI CC mappings, chunk size and tempo authority remain **Unknown**.
- 234 dispatch references resolve outside the local type table; 31 types have no module name.
- Call direction across modules is not yet recovered; the coupling map is co-occurrence.
- There are no session or setlist features yet, and the package builds an app target rather than a
  bundled `.app`.
- The effects chain is validated by offline tests that measure samples, not by listening: no audio
  device, controller or native launch has been exercised, because the Mac they need has been
  unreachable. No local build has been run; every result comes from the macOS runner.
- The instrument is a wavetable synthesiser, not a sampler: real sampled instruments need
  independently licensed or recorded material.

## Legal

This repository documents the behaviour of a commercially distributed application for
interoperability and clean-room replication. It contains no redistributed application code, assets
or sample libraries.
