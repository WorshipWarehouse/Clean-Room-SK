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
| app | playable polyphonic instrument: wavetable voices, envelopes, splits and layers, CoreMIDI input, lock-free audio command queue, patch bank with gapless switching and JSON persistence, an original EQ/chorus/delay/reverb chain per patch, a learned per-patch controller layout, and an ordered set list with a play head |
| bundled app | `tools/bundle_app.sh` assembles and ad-hoc signs `SundayKeys.app`; CI lints the plist and verifies the signature on every push |
| launched in CI | the runner starts the bundle, sees AppKit finish launching and the SwiftUI root view appear, watches the run loop service a timer, and sees a status 0 exit; no person has seen the window |
| audio started in CI | the runner presses Start from inside the app, the graph opens on its default output device, plays a note and the render block reports a rendered voice; a machine with no output device is a typed error rather than a crash |
| MIDI connected in CI | the runner creates a CoreMIDI client and an input port, enumerates the source list, then publishes a virtual source of its own and lets the engine's own enumeration find it and connect it; the status reads `MIDI ready, 1 of 1 source(s) connected`, and a start with no source still says so instead of hiding it |
| MIDI received in CI | the runner sends a note on, a note off and a control change from a virtual source into the app's own input port, and the app reports the three messages it parsed and the one of two enabled layers it routed the note to |
| session resumed on launch | the patch that was playing is remembered in its own file beside the bank, so a relaunch opens where the service left off rather than at the first patch; a stale or unreadable hint falls back and says why |
| relaunch proven on disk | run `42821991761` starts the bundle three times against one folder: one writes a bank and remembers the third patch, the next launch prints the resumed patch with the play head on its slot, and a hint naming a deleted patch falls back with its reason |
| tempo and click | a sample-accurate click the render thread generates from a tempo clock: downbeats accented, a tempo change taking effect on the next beat, the click added after the patch's effects so nothing echoes it, and switching it off letting the click in flight finish |
| patch documents | a single patch leaves the bank as its own `.sundaykeyspatch` file and comes back with its layers, transposes, effects and controller layout intact; a file whose format or version this build does not know is refused with the reason and a version is checked before the patch is decoded, so a later format is never partly read; an import over a patch the bank already holds adds a second sound instead of overwriting the one being played |
| not yet verified on hardware | no controller has ever been connected and no person has seen the window; the only MIDI traffic the app has ever seen came from the probe's own virtual source |
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
| `docs/progress.md` | phase status, next actions, decisions, every CI run that was read |
| `docs/re/access-determination.md` | what blocks decompilation and what access it needs |
| `Package.swift` | Swift package: `CSync`, `SundayKeysCore`, `SundayKeysApp` |
| `Sources/CSync/` | atomic index loads and stores for the audio queue and the effects settings seqlock |
| `Sources/SundayKeysCore/` | MIDI parsing, velocity curve, note ranges, layer routing, SPSC queue, wavetable instrument, patch model and bank store, controller mapping, set list |
| `Sources/SundayKeysCore/Audio/Effects/` | EQ, chorus, delay and reverb processors and the chain that publishes their settings |
| `Sources/SundayKeysCore/Audio/AudioStartPlan.swift` | the start decision: rate accepted, rate replaced, or a typed refusal |
| `Sources/SundayKeysCore/MIDI/MIDIStartReport.swift` | the MIDI start report, its failures and the exit status that names which part failed |
| `Sources/SundayKeysApp/` | SwiftUI shell with a playable keyboard, patch picker, set list panel, layer editor, effects panel, controller mapping panel, CoreMIDI input, AVAudioEngine host |
| `Sources/SundayKeysApp/LaunchProbe.swift` | startup markers and the self-quit timer the launch check reads, plus the audio and MIDI probes |
| `Sources/SundayKeysApp/Audio/DefaultOutputDevice.swift` | asks CoreAudio whether an output device exists before the graph touches it |
| `Sources/SundayKeysApp/MIDI/MIDIEndpointReader.swift` | reads CoreMIDI's sources into the core's descriptions |
| `Tests/SundayKeysCoreTests/` | unit tests for the core module |
| `.github/workflows/build.yml` | resolve, build, test, release build, bundle, launch, audio, MIDI and bootstrap smoke checks on a macOS runner |
| `tools/bundle_app.sh` | assembles, signs and verifies `SundayKeys.app` from the release build |
| `tools/launch_smoke.sh` | starts the bundle, asserts its startup markers and a clean exit, and fails with the captured output otherwise |
| `tools/audio_smoke.sh` | presses Start inside the app, requires a rendered voice and a clean exit, and reports a missing output device as a limitation |
| `tools/midi_smoke.sh` | creates the MIDI client and input port inside the app, publishes a virtual source, requires the engine to enumerate and connect it, then sends a note on, a note off and a control change from that source and requires the app to parse them and route the note, and reports a machine with no source as a limitation |
| `Sources/SundayKeysCore/MIDI/MIDIConnectProbe.swift` | classifies what a connect attempt against the probe's own virtual source proved |
| `Sources/SundayKeysApp/MIDI/VirtualMIDISource.swift` | publishes, and then disposes, the virtual CoreMIDI source the connect probe connects to |
| `tools/` | Mach-O, Swift metadata, literal and call-graph extractors, Ghidra drivers |

## Build and run the app

```bash
swift build          # library and app target
swift test           # core tests
tools/bundle_app.sh  # release build, then build/SundayKeys.app
tools/launch_smoke.sh  # start it, prove it reached its run loop, prove it exited 0
tools/audio_smoke.sh   # press Start from inside it, prove the render block made a voice
tools/midi_smoke.sh    # create the client and port, publish a virtual source, prove it connects and receives
open build/SundayKeys.app
```

The same commands run on a macOS runner for every push, and the check run on a commit carries the
result: the workflow resolves the manifest, reports unique compiler warnings, builds the release
configuration, runs the bundler and verifies its output, launches the bundle, presses Start for audio,
presses Start for MIDI, and runs `bash tools/bootstrap.sh --check` as a smoke test.
There is no Xcode project: the package builds the app target and the bundler wraps it into an `.app`
with its own identifier (`com.worshipwarehouse.sundaykeys-cleanroom`, version 0.5.0) and an ad-hoc
signature, so it can be launched on Apple silicon without a developer certificate. That signature is
not distribution signing and nothing is notarised. The install path of the bootstrap script is not
exercised anywhere, because it installs Homebrew casks and needs sudo.

To run it by hand once a Mac is available: `tools/bundle_app.sh`, then `open build/SundayKeys.app`,
press Start, and play the on-screen keyboard or a connected controller. `swift run SundayKeysApp`
starts the same app without a bundle, which is convenient for a quick look and not how it ships.

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
- a program change selects the patch with that index, so a foot switch can walk a bank.

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

## Set list

A set list orders patches into one service and remembers where the player is in it. It lives in the
patch bank, so a service and the patches it names are saved together.

- a slot is an entry with its own id and a patch id, so the same patch can appear twice and the two
  slots stay distinct;
- the play head is an entry id rather than a position, so reordering or removing an earlier slot
  never moves the head onto a different sound;
- stepping wraps at both ends, which is what a foot switch needs; jumping to a slot number clamps,
  because a number means that slot or the nearest one that exists;
- removing the head hands it to the following slot, removing the last slot hands it to the new last
  one, and emptying the list clears it;
- deleting a patch prunes its slots and fixes the head, and a slot whose patch is missing is skipped
  while stepping;
- a bank written before set lists existed has none and plays in bank order, and the panel says so
  instead of showing an empty box;
- a set list step is a real patch switch: it goes through the same `setPatch` call as the bank picker,
  so it releases what is sounding and applies the new patch's effects. Tests assert that no reverb
  tail is inherited and that a step to a wetter patch does bring its reverb;
- picking a patch from the bank moves the head to its first slot, so the position shown and the sound
  playing agree.

The panel shows every slot with its number, name and a `now` marker, plus `Play`, `Up`, `Down` and
`Remove` per slot and `Prev`, `Next`, `Add patch` and `Fill from bank` for the list. `PatchBank`
format version 4 added the set list, and older banks load with an empty one.

The milestone is verified by run
[`42729742825`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42729742825): the debug
build, every test suite including the set list ordering, persistence and set-list switching tests, the
release build and the bootstrap smoke check all pass. `docs/progress.md` records that run and the
earlier ones, including the two assertions it caught and why they were wrong rather than the model.

## The bundle

`tools/bundle_app.sh` builds the release product and writes `build/SundayKeys.app`: the executable at
`Contents/MacOS/SundayKeysApp`, a generated `Info.plist`, `PkgInfo`, and an ad-hoc signature. It then
checks its own output, and the CI step fails if any check does.

- the identifier is `com.worshipwarehouse.sundaykeys-cleanroom`, deliberately not the original's
  `com.sundaysounds.sundaykeys`, so the two can be installed side by side;
- the version is this implementation's own 0.5.0 build 5, not the original's 2.5.2 build 3367;
- `LSMinimumSystemVersion` is 14.0, matching the package platform;
- the signature is ad hoc, which is what Apple silicon needs to launch it without a developer
  certificate, and is not distribution signing;
- the checks are `plutil -lint`, the executable bit, `codesign --verify --strict`, and the declared
  executable matching the one placed.

Run [`42730684997`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42730684997) is the
first to run the bundle step, and it passed.

## Launching it

A bundle that assembles is not an app that runs, so the workflow now starts it. Two marks make the
difference between a guess and an observation: that the app reached its run loop, and that it left
through a normal exit instead of a signal.

- `Sources/SundayKeysApp/LaunchProbe.swift` prints `SundayKeysApp: did finish launching` from
  `applicationDidFinishLaunching` and `SundayKeysApp: root view appeared` once SwiftUI installs the
  root view. A live PID proves only that the loader resolved symbols; these lines say where the app
  got to.
- `SUNDAYKEYS_PROBE_EXIT_AFTER=<seconds>` makes the app quit itself through `NSApp.terminate` after
  that long. A fired timer shows the run loop is being serviced, and the status 0 is a real exit. With
  the variable unset the app behaves normally, so nothing about a player's launch changes.
- `tools/launch_smoke.sh` prints the session it found (OS version, `launchctl managername`, whether
  `WindowServer` runs, whether the `gui/<uid>` domain is reachable, whether it is over SSH), starts
  the bundle's executable with the probe armed, waits up to 20 seconds for both markers, waits for the
  exit, and requires status 0. A dead process, a missing marker, a process that will not quit or a
  non-zero status each fail the step with the app's own output. Liveness is read from `ps -o state=`,
  so a finished child is not mistaken for a hang.
- it also attempts a LaunchServices launch (`open -n`) and reports whether a process appeared and
  stayed alive. That path cannot carry the probe or be captured, and stopping it takes a signal, so
  it is evidence rather than the pass condition.

Run [`42731763842`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42731763842) on
`7cb9a17` is where this first passed: every step green, and "Launch the app" took seven seconds. Since
the script only exits 0 after asserting the markers, the timer and the exit status, that green step
means the bundle loaded, AppKit finished launching, the root view was installed, the run loop serviced
a timer and the app exited 0 on a runner with no controller attached and nothing pressed.
What it does not show: a window nobody has looked at, audio from an output device, a controller, or
the audio graph and MIDI client starting - those are created when Start is pressed, which this check
does not do. The audio and MIDI checks below are the steps that press it. Nothing here has been
listened to.

## Pressing Start: the audio graph

The launch check ends where playback starts, so the workflow presses Start itself and reports what
happened. `SUNDAYKEYS_PROBE_START_ENGINE=1` runs the same `AudioEngineController.start()` the button
runs, plays note 69, waits half a second, prints the rate and the voice count the render block
produced, stops the graph and exits.

- **A device is checked for before the graph touches it.** Reading `engine.outputNode` with no output
device raises an Objective-C exception Swift cannot catch, so `DefaultOutputDevice.exists()` asks
  CoreAudio for `kAudioHardwarePropertyDefaultOutputDevice` first and a missing device becomes a typed
  failure the app can show.
- **The decision is core logic.** `AudioStartPlanner.plan(forReportedSampleRate:)` keeps a reported
  rate, replaces the zero macOS reports before the engine runs with 48 kHz, refuses a negative or
  non-finite rate as `unsupportedFormat`, and refuses a missing device as `noOutputDevice`. The plan
  is always stereo. A rejection carrying a NaN rate compares by bit pattern, because NaN is never
  equal to itself.
- **A voice is the proof.** A voice only exists once the audio callback has drained the command ring,
  so a non-zero count says the render thread ran, not merely that the engine opened.
- **The exit status is the verdict**: 0 started and rendered, 4 refused to start, 5 started but
  produced no voice, 6 lost the graph. `tools/audio_smoke.sh` reads those and the markers.
- **A machine with no output device is reported, not hidden.** If the app prints the typed
  `No audio output device is available` failure and exits 4, the script publishes a warning annotation
  with that line and still exits 0, because refusing cleanly is right there and the run should record
  what the hardware was. Any other failure fails the step with the app's own output.

Run [`42733100695`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42733100695) on
`e6ae994` is the first green audio step: every step passed and the job published no warning
annotation, and the no-device path always publishes one, so the graph started and rendered at least
one voice on the runner's default output device. The printed rate and voice count are not quoted here
because the job log download truncates before the later steps; the pass is reported from the step's
status and the script's exit conditions. The first attempt, run `42732896895`, failed on my own NaN
equality and a `@Sendable` capture in the probe, both fixed in `e6ae994` rather than tested around.

## Pressing Start: the MIDI client

`MIDIInputService.start()` used to create the client and the input port and throw away every
`OSStatus`, so a client that could not be created and a machine with no controller looked identical:
an empty source list and no explanation. It now returns a verdict, and the workflow asks for it.

- **The verdict is core logic.** `MIDIStartReport.swift` holds the source description, the inventory,
  the failure and the verdict. A source with no name, a blank name or no manufacturer still gets a
  distinct line (its unique id and "unknown manufacturer" stand in), each line carries its position
  and count, and the summary is `MIDI: N source(s): X online, Y offline`.
- **Only online endpoints are connected.** An offline endpoint is listed and counted but not
  connected, because a refused connect there says nothing about the machine; a connect that fails on
  an online source is reported with its name and status.
- **The exit status is the verdict**: 0 the client and port were created and every online source
  connected - a zero-source list is still 0, since that is a fact about the hardware - 4 no client,
  5 no input port, 6 a source that would not connect.
- **A machine with no controller is reported, not hidden.** `tools/midi_smoke.sh` publishes a warning
  annotation with the app's own line and exits 0 when the count is zero, and fails the step on a
  missing client marker, a missing count, a non-zero status or a timeout.

Run [`42734422204`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42734422204) on
`2464172` is the first green MIDI step: all fifteen steps passed and "Probe the MIDI start" took two
seconds. The job published the probe's own warning, "this machine has no MIDI sources: the probe
proved the client and input port were created and the source list was empty", and the script only
reaches that line after finding the client marker, reading a source count and seeing exit 0. So a
CoreMIDI client and input port were created on the runner and `MIDIGetNumberOfSources` returned zero.
The connect path was not exercised, because there was nothing to connect: that is what a controller
attached to a real Mac is for, and it has not happened.

### Connecting without a controller

The runner has no controller, so for a long time the connect call itself had never run: the client and
port were created, `MIDIGetNumberOfSources` returned zero and the step said so.
`SUNDAYKEYS_PROBE_MIDI_CONNECT=1` closes that: the app creates a virtual source with
`MIDISourceCreateWithProtocol` before starting the engine, so the engine's own enumeration finds it,
its port connects it and the status it derives reads `MIDI ready, 1 of 1 source(s) connected`.

- `MIDIConnectProbe` in the core module names the outcome - connected, refused by the port, no client
  or port, no source published, never enumerated, listed but never attempted - with its own exit
  status (0, 6, 4/5, 7, 8, 9) and its own line, so a green step can only mean the port accepted the
  source.
- the probe prints the ordinary report lines as well as its own, so both probes read the same
  markers, and it disposes the source and its client afterwards.
- `tools/midi_smoke.sh` treats a missing or unlisted source as a failure, and it still publishes the
  start probe's no-sources warning, because that is the machine's hardware answer rather than a pass.

Run [`42740507134`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42740507134) on
`7d5cd17` is the first green run of it: all fifteen steps passed and the step published "MIDI
connect probe: virtual source created, engine enumerated 1 source(s), connected 1, status: MIDI
ready, 1 of 1 source(s) connected". The next section is the pass that sent packets through it and read what the app parsed.

### Sending into the app

Connecting a source proves the port accepted it; it does not prove the app can read what arrives.
The same probe now sends. `SUNDAYKEYS_PROBE_MIDI_CONNECT=1` builds a packet list carrying a note on,
a note off and a control change, calls `MIDIReceived` on the source the port is connected to, then
waits for its own input block to collect what came back.

- `MIDIMessage.parseAll` is the packet-level parse: running status, real-time bytes skipped, a note
  on with velocity 0 read as a note off, and a stop at a truncated tail. It exists because one
  packet can carry several messages, and the input block used to read the first three bytes and drop
  the rest - a real defect the probe caught, recorded in `docs/progress.md`.
- `MIDIReceiveProbe` owns the expected bytes and the verdict, and counting filters on the expected
  note, controller and channel so nothing else on the machine can stand in.
- the app prints one `MIDI receive probe: received ...` line per parsed message, a summary, the layer
  the note reached and its verdict, and `tools/midi_smoke.sh` publishes the message lines as notices
  before it asserts anything, so a failing step still shows what the app saw.
- the exit status names the first thing missing: 0 every packet parsed, 10 no note off, 11 no control
  change, 12 nothing received, 13 no note on.

Run [`42744820518`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42744820518) on
`16b2c9f` is green with it: the job published "MIDI receive probe: received note on 60 velocity 100 on
channel 1", "MIDI receive probe: received note off 60 velocity 64 on channel 1", "MIDI receive probe:
layer routing sent note 60 to 1 of 2 enabled layer(s)" and "MIDI receive probe: outcome: the app
parsed every packet: 1 note on, 1 note off, 1 control change". A physical controller and a window
are still missing.

## Tempo and the click

A player rehearsing needs a pulse, and the instrument had none. The click is a
tempo clock in the core module plus a short synthesised click, and the render
thread adds it to the buffer itself.

- `MetronomeSettings` clamps the tempo to 20 to 300 bpm and the bar to 1 to 16
  beats, and a non-finite tempo falls back to 120 rather than to a bound, because
  NaN says nothing about what the player meant.
- the settings cross to the render thread through a seqlock over two `UInt64`s
  using the same `CSync` atomics the effects chain uses, so switching the click on
  never makes the render block lock or allocate.
- the click starts on the frame a beat is due, not near it: at 120 bpm and 48 kHz
  the tests find beats at frames 0, 24000, 48000, 72000 and 96000 exactly, with the
  downbeat louder than the beats inside the bar.
- a tempo change does not move the beat already on its way; the interval after it
  uses the new tempo, so 120 to 60 bpm turns a 24000-frame beat into a 48000-frame
  one.
- switching the click off lets the click in flight ring out and schedules nothing
  more.
- the click is added after the patch's effect chain, so a patch's delay and reverb
  never echo the cue, and it never borrows a voice from the instrument.

`Tests/SundayKeysCoreTests/MetronomeTests.swift` measures all of that by rendering
frames, and `tools/metronome_smoke.sh` covers the step the tests cannot reach: the
running app's own graph playing the cue. Run [`42824933210`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42824933210) starts the
bundle, switches the click on at 120 bpm, counts the beats the render thread
started and finds none after it was switched off. The controls sit in the
transport row, and nobody has heard it.


## Patch documents

A patch is editable in the window and stored in the bank, but until now it had no life of
its own: carrying one sound to another Mac meant carrying every sound. `PatchDocument`
fixes that, and it is an envelope rather than a bare patch so a reader can tell a patch
file from a bank, from unrelated JSON and from a document a later build wrote.

- `format` is `sundaykeys-cleanroom.patch`, version 1, and this build refuses any other
  format by name and any version it does not know rather than partly reading it;
- `PatchTransfer.write` puts the document in
  `Application Support/SundayKeysCleanRoom/Patch Exports`, creating the folder, and
  `PatchTransfer.read` turns a missing or unreadable file into a typed reason;
- the filename is derived from the patch name and is always a filename;
- `PatchAdoption.adopt` adds an imported patch without overwriting one the bank holds: a
  colliding id gets a fresh one and a colliding name a suffix;
- `Export patch` and `Import patch` sit under the patch panel, and the status line beside
  them says what happened.

The model is proven by `Tests/SundayKeysCoreTests/PatchDocumentTests.swift` and by the
`patch-transfer` workflow, which starts the bundle and runs
`tools/patch_transfer_smoke.sh`; run [42830474030](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830474030) is where the probe step
passed. Nobody has used the two buttons, and the format is this implementation's own:
the original app's preset format is recorded as **Unknown**.

## Session scope

The bank has always kept the sounds; it did not keep where the player was. Every launch
opened the first patch in bank order, so a player rehearsing the fourth song of a service was
put back on the first one. The selection is remembered now, in a file of its own.

- `SessionMemory { lastPatchID }` lives in `session.json` beside `patches.json`, so the bank's
  format and its version 4 documentation do not move and a bank from an older build still
  loads;
- `SessionScope.restore(memory:patches:)` resolves a launch to `remembered`, `fallback` with
  the reason, or `emptyBank`, and the status line names which happened - `Resumed Worship
  Pad` or `Opened Sunday Keys: the patch from the last launch is gone`;
- a missing, unreadable or malformed hint reads as nothing remembered, because a hint about
  the previous launch must never cost the bank;
- `Setlist.alignHead(to:)` puts the play head on the first slot that plays the restored patch,
  so the position shown and the sound playing agree, and a patch that is in no slot leaves
  the head where it was;
- the model records the selection on every path that changes it and before a manual save; the
  write is best effort and is not on the bank's save path.

`Tests/SundayKeysCoreTests/SessionMemoryTests.swift` covers the three outcomes, their lines,
the round trip, a corrupt file, the head alignment and where the file sits. It is proven by
those tests and by the suites passing on the runner: no probe starts the app twice, so the
on-disk resume has not run end to end and no window has been seen.

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
  semantics, MIDI CC mappings, session contents, chunk size and tempo authority remain **Unknown**.
- 234 dispatch references resolve outside the local type table; 31 types have no module name.
- Call direction across modules is not yet recovered; the coupling map is co-occurrence.
- The bundle is assembled, signed, checked, started and given an audio graph and a MIDI client on the
runner, but no person has seen its window: nothing has been listened to, no controller has been
  connected, and no local build has been run; the only MIDI traffic the app has ever seen came from the probe's own virtual source, and every
  result comes from the macOS runner.
- The set list panel, the effects panel and the controller panel have never been looked at on a
  screen.
- The MIDI status is published by the model and refreshed on every source-list change, but the app
  target has no view test and nobody has read the line on screen.
- The instrument is a wavetable synthesiser, not a sampler: real sampled instruments need
  independently licensed or recorded material.

## Legal

This repository documents the behaviour of a commercially distributed application for
interoperability and clean-room replication. It contains no redistributed application code, assets
or sample libraries.
