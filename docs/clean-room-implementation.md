# Clean-room implementation plan

A plan for rebuilding Sunday Keys from documented behaviour rather than from recovered code. Every
contract below cites the analysis section it comes from, so each implementation decision can be
traced back to an observation. Figures and labels are the same ones used in
[`sunday-keys-2.5.2-analysis.md`](sunday-keys-2.5.2-analysis.md).

## Rules

1. Implement from documented behaviour and public wire formats. Do not transcribe decompiled code,
   string tables or control flow.
2. Record the section reference for each behaviour used. If a behaviour is not in the analysis, it is
   Unknown and must not be invented silently.
3. Where a contract is Unknown, define the interface, implement one provisional behaviour behind it,
   and record the assumption so it can be replaced once a capture exists.
4. This plan reproduces client behaviour for interoperability. It does not describe bypassing
   entitlement checks; a clean-room client should behave like a correctly licensed one.

## Reconstructed contracts (Observed unless noted)

| contract | shape | evidence |
| --- | --- | --- |
| service base | `https://production.sundaysounds.com` | section 1 |
| response envelope | `{data}` on success, `{error}` on failure | section 13 |
| session payload | `UserSessionApi {maxAvailableBackups, maxAvailableAudioOutputs, userRole, license, accessibleProducts}` | section 11 |
| licence payload | optional `LicenseApi {status, gracePeriodsEndsAt}` | section 11 |
| licence states | `active`, `grace_period`, `expired` | section 12 |
| realtime auth | request `{socketId, channelName}`, response `{auth, channelData}` | section 13 |
| backup transfer | S3-style presigned upload and download | section 13 |
| product catalogue | bulk pull returning all accessible products | section 13 |
| peer mesh | access code plus machine ID, presence discovery, `connectKey` pairing, chunked setlists, rhythm and transition events | section 14 |
| model layer | 81 `Networking` Codable models | section 13 |

Endpoint paths, JSON key casing, date encoding and channel names are **Unknown**; they need one
captured session (see below) and must stay behind configuration in any implementation.

## Target module boundaries

Static dispatch analysis (sections 19 and 20) shows five first-party modules with almost no
protocol-level overlap:

| module | role | evidence |
| --- | --- | --- |
| `Domain` | models and rules | 477 dispatching bodies |
| `Networking` | transport and API models | 1,145 dispatching bodies |
| `Storage` | persistence, actor based | 147 dispatching bodies |
| `Audio` | audio engine, actor based | 219 dispatching bodies |
| `SundaySounds` | UI and app shell | 1,474 dispatching bodies |

The only substantial cross-module coupling is `Domain` with `SundaySounds` (25 function bodies),
which is the model to UI boundary. Depend in one direction only: UI and transport read `Domain`,
`Domain` depends on nothing else. Call direction is **Inferred**, not yet measured, so treat this
ordering as a design intent rather than a recovered fact (`section 20` states the limit).

## Implemented architecture (as built)

This section describes the code in this repository as it stands, not the original application. Every
claim here names a file and a symbol; the matching tests are named where they exist.

### The render path

`RealtimeKeysoundEngine` (`Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift`) owns a mono
`PolyphonicInstrument`, a `Metronome`, two `EffectChain` instances and an `SPSCCommandQueue`. Every
render block does the same four things in order:

1. drains the command ring (`queue.pop()` → `instrument.apply(_:)`) until it is empty;
2. renders the voices once into the block (`instrument.render(into:frameCount:)`);
3. runs the patch's effects over that mix (`effects.process(...)`, and `effectsRight` on the stereo
   path);
4. adds the click (`metronome.render(into:frameCount:)`).

Everything a player does — note on, note off, bend, channel pressure, patch switch, effect edit — is a
`RenderCommand` on that ring, so the render block never locks, never allocates and never waits. The
only state that does not travel as a command is the effects value itself, which is published through a
seqlock (below) because a whole settings struct is cheaper to publish than to enqueue per parameter.

### The effects chain

The chain is an insert on the voice mix, in this order:

**EQ → chorus → delay → reverb**

That order is a deliberate choice, and the reasons are audible rather than conventional:

- the EQ comes first so it shapes what the modulation and the echoes repeat, which is what makes a
  delay tail sit under the chord instead of fighting it;
- the chorus comes next so its detune is fed into the delay and therefore repeats rather than being
  smeared across an already-spread signal;
- the delay feeds the reverb, so the tail belongs to the room the echoes are in rather than to the
  instrument;
- the reverb is last because nothing after it can smear its tail, and the click is added after the
  whole chain so a cue is never echoed or reverberated (`MetronomeTests` asserts exactly that).

Each stage is its own type in `Sources/SundayKeysCore/Audio/Effects/`: `EQProcessor`,
`ChorusProcessor`, `DelayProcessor`, `ReverbProcessor`. `EffectChain` holds the order and does not know
what any of them do inside.

### How a patch's settings reach the render thread

`Patch` owns an `EffectsSettings` (`Sources/SundayKeysCore/Audio/Effects/EffectsSettings.swift`, fields
`eq`, `chorus`, `delay`, `reverb`, plus `isDry`). Settings move by seqlock, not by the command ring:

- `EffectChain` holds `published: UnsafeMutablePointer<EffectsSettings>` and a `sequence` counter;
- `apply(settings:)` on the producer side writes the value under that counter (`CSync` atomics, the
  same ones the command ring uses);
- `process(into:frameCount:)` on the render side reads it once per block and never blocks; a torn read
  is impossible because the counter is checked around the copy;
- `RealtimeKeysoundEngine.setPatch(_:releasingVoices:)` and `setEffects(_:)` call `apply` on **both**
  `effects` and `effectsRight`, so the two sides can never disagree about the patch;
- `AudioEngineController.setPatch(_:releasingVoices:)` remembers the patch while stopped, so a graph
  started later is built with the right settings from its first block.

A parameter change therefore costs the render block one struct copy, not an allocation, and cannot
click: the processors glide or re-derive coefficients from the published value, so the next block
simply runs with the new numbers.

### Bypass and wet/dry semantics

Every stage owns an `enabled` flag and its own `mix` (wet share). The contract is:

- **disabled is exactly neutral.** Each processor returns before touching a sample, so the block is
  bit-identical to the no-effects render. `EffectTests` and `EffectsStereoTests` assert this for both
  channels, and `EffectsSettings.isDry` lets a caller ask before rendering.
- **0 dB on an EQ band is also exactly neutral.** `EQProcessor.gain(_:)` returns `nil` at exactly zero
  and the section is set to pass-through coefficients, so a flat but enabled EQ is bit-transparent
  rather than nearly so.
- **each stage is an insert with its own wet share,** not a send: `out = dry * (1 - mix) + wet * mix`
  inside the processor, which is why a fully wet delay in a test reappears at exactly 4,800 samples.
- **clamping happens twice** — the control range in `EffectRanges` and again inside each processor —
  because a document read from disk must not be able to drive a filter into a corner.

### The mono voice mix becomes stereo

The voices are mono: `PolyphonicInstrument` sums them into one buffer. Stereo is made by the effects,
not by rendering twice.

`RealtimeKeysoundEngine.renderStereo(intoLeft:intoRight:frameCount:)` renders the voices into the left
buffer once, copies that mix into the right, then runs one `EffectChain` per side (`effects` with
`channel == .left`, `effectsRight` with `.right`). Each chain owns its own EQ, chorus and reverb state,
so the sides cannot share a filter or a buffer. The delay is one tap per side and each chain reads its
own time — `delaySettings.time = channel == .left ? leftTime : rightTime` — which is what makes an
independent left/right delay audible without a cross-feed that could build.

The click is rendered into a private `clickScratch` and added to both channels afterwards, so one cue
reaches both sides and the metronome advances exactly once per block. `clickScratch` is allocated in
`init` and freed in `deinit`; nothing is allocated on the render thread.

The mono `render(into:frameCount:)` is kept unchanged beside it: every core test and every probe drives
that path, and the stereo path is additive rather than a replacement.

### How the right channel reaches the device

`AudioEngineController` (`Sources/SundayKeysApp/Audio/AudioEngineController.swift`) owns an
`AVAudioSourceNode` whose render block:

- allocates its right buffer once, on the main thread, in `start()` (`rightStorage`, 4,096 frames),
  and frees it in `stop()` and in the `engine.start()` failure path, so a failed start leaves nothing
  attached to the engine;
- fills the block in 4,096-frame chunks: a left slice over `buffers[0].mData` and a right slice over
  `rightStorage`, both handed to `keysound.renderStereo(intoLeft:intoRight:frameCount:)`;
- writes the remaining channels with `memcpy` — odd channels take the right buffer, even channels take
  the left slice — so a stereo device hears the chain's two sides and a mono device hears the left.

The graph is `AVAudioSourceNode` → `mainMixerNode` → `outputNode`, built and attached on the main
thread only.

### Persistence of the chain

The settings are part of the patch document, not a side table: `Patch.effects` is encoded with the
bank (`PatchStore`, JSON, format version 4) and with a single exported `.sundaykeyspatch`
(`PatchDocument`). `DelaySettings.init(from:)` reads `leftTime`/`rightTime` when present and falls back
for the single `time` a document written before the two taps existed, so an old bank loads with both
taps equal instead of failing. A restored session (`SessionScope.restore(memory:patches:)`) opens the
patch the player left, which brings its effects with it; a patch whose chain is bypassed stays dry.

### What is this repository's choice, and what is not

Observed in the analysis: the effect vocabulary. `AudioEffectApi` names a set that includes chorus,
delay, reverb and an equaliser, and `EqualizerApi` names high-pass, low shelf, four bands, high shelf
and low-pass (`docs/feature-inventory.md`, Effects). That is where the observation stops.

| decision | status |
| --- | --- |
| insert order EQ → chorus → delay → reverb | **this repository's own**; the original's routing is Unknown |
| EQ corners 250 Hz, 1 kHz at Q 0.9, 3 kHz | **own**; band count is Observed, frequencies and Q are Unknown |
| per-side delay taps with shared feedback clamped to 0.9 | **own**; the original's delay topology is Unknown |
| per-stage wet/dry with disabled = bit-identical | **own**; the original's mix semantics are Unknown |
| four damped combs into two allpasses | **own**; the original's reverb algorithm is Unknown |
| mono voices, stereo made by the chain | **own**; the original's channel handling is Unknown |
| click added after the chain | **own**, and asserted by `MetronomeTests` |
| parameter ranges in `EffectRanges` | **own**, provisional, replaceable once a capture exists |

## Milestones

| milestone | outcome | exit criteria |
| --- | --- | --- |
| M1 licence and session | client obtains a session, models licence state and the three statuses, gates features from `maxAvailableBackups` and `maxAvailableAudioOutputs` | state machine unit tested against all three statuses plus a missing and a malformed licence |
| M2 catalogue | bulk product pull populates accessible products | models round trip a recorded fixture |
| M3 persistence and backups | local store plus presigned backup and restore | upload and download verified against a fixture, no credentials in the client |
| M4 setlists and realtime | setlist editing, chunked transfer, presence and pairing | two clients in one session see each other and exchange a setlist |
| M5 audio engine | sound playback, rhythm and transition behaviour | rendering matches a captured reference within a stated tolerance |
| M6 interface | arrangement views over `Domain` | feature parity list from the analysis, each item marked Observed or Inferred |
| M7 effects chain | patch-owned insert chain in the render path, one per side, carried by the patch | measured: tail versus bit-identical bypass, tap positions and feedback ratio, chorus movement, per-band EQ response, long-run finiteness, bank and session round trip |

M1 is the correct starting point: it is the only subsystem whose model is fully reconstructed, and
every later milestone depends on the gating it exposes. M7 is done as of the effects milestone and its
section above is the record of what was built; `docs/tasks.md` carries the live status.

## Unknowns that gate fidelity

These cannot be recovered statically and each maps to one captured session:

| unknown | blocks |
| --- | --- |
| JSON key casing and date strategy | exact request and response encoding |
| grace period duration | faithful licence countdown |
| Pusher channel and event names | interoperability with existing peers |
| chunk size for setlist transfer | mesh compatibility |
| payload encryption, if any | mesh compatibility |
| tempo authority | rhythm behaviour across peers |
| effect parameter ranges and defaults | effect presets that sound plausible |
| the original's effect routing and mix semantics | any claim of parity for the chain |

The capture needed is one launch of the signed-in app behind a local proxy, recorded as fixtures.
Until then, every item above is configuration with a provisional default and a recorded assumption.

## Verification

Fixture driven, in this order: recorded request and response bodies as contract tests, a golden state
machine walk for the licence statuses, then behavioural comparison against captured traces for the
audio and mesh milestones. A milestone is done when its fixtures pass, not when the code compiles.

## Non-goals

No redistribution of application code, assets or string tables. No circumvention of entitlement
checks. No claim of parity for anything still listed as Unknown.
