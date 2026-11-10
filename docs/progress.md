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
| Build, patches | patch bank, gapless switching, live layer editing, JSON persistence | `Sources/SundayKeysCore/Patch/`, run `42724195726` |
| Build, effects | EQ, chorus, delay and reverb after the voice mix, owned by the patch | `Sources/SundayKeysCore/Audio/Effects/`, run `42726206476` |
| Build, controllers | learned per-patch CC mapping for layer gains and effect parameters | `Sources/SundayKeysCore/ControllerMapping.swift`, run `42726991886` |
| Build, set list | ordered service list with a play head, stepping, reorder and removal, stored in the bank | `Sources/SundayKeysCore/Setlist.swift`, `PatchBank.currentVersion` 4, run `42729742825` |
| Build, bundle | `SundayKeys.app` assembled from the release build, ad-hoc signed, plist and signature verified | `tools/bundle_app.sh`, run `42730684997` |
| Test | queue stress, envelope, release, bounded stealing, patch persistence and switching, effects DSP, effect persistence, controller mapping, set list ordering and set-list switching | `Tests/SundayKeysCoreTests/` |

This is a working instrument with a working patch system, an original effects chain, a learned
controller layout, a playable set list and a bundle that CI assembles and verifies, not a finished
product. What is still missing is everything that needs to be seen and heard: the bundle has never
been launched, and no audio device, controller or native window has been exercised, because the Mac
that would do it is unreachable.

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

## Patch milestone: what a patch is

- **Model.** `Patch` is an id, a name, `[KeyLayer]`, an `EffectsSettings` and a
  `ControllerMapping`. A `KeyLayer` carries an id, a name, a `NoteRange`, a transpose, a gain, a
  timbre and an `enabled` flag. `PatchBank` is the versioned list, and `PatchStore` reads and
  writes it as JSON at `~/Library/Application Support/SundayKeys/patches.json`.
- **Persistence.** Writes are atomic and create the directory, so a crash mid-save cannot leave a
  half-written bank. A missing file is not an error: the starter bank loads and the player gets an
  instrument rather than an empty window. `KeyLayer`, `Patch`, `EffectsSettings`, `ControllerMapping`
  and `Setlist` all decode with documented defaults, so a bank written before a field existed still
  loads.
- **Switching is gapless.** `setPatch` swaps the producer-side router, publishes each layer's timbre
  through the existing SPSC ring as `setLayerTimbre` commands, applies the new patch's effects and
  releases every sounding voice. Release is the same 220 ms fade, so the change is heard as a tail
  under the new patch rather than as a gap, and no key held across the switch can hang on a layer
  the new patch dropped. Nothing in the graph is rebuilt, so no allocation, lock or dropped buffer
  enters the audio path.
- **Live edits do not cut notes.** `setPatch(_:releasingVoices:false)` updates ranges, gains,
  timbres and effect settings without all-notes-off. The app uses that path for checkbox, stepper,
  slider and controller edits, so the chord under the player's hands keeps sounding while a value is
  being changed.
- **App surface.** Patch picker with previous/next, rename, new (a copy of the current patch), delete
  (guarded so the bank is never empty) and an explicit Save. A program change selects the patch with
  that index, which is how a foot switch walks a bank. Each layer row edits enable, low and high
  note, transpose, timbre and gain.
- **Defaults.** Two layers: Keys 36 to 96 at gain 0.85 and Bell 72 to 96 at gain 0.45, so the overlap
  sounds twice and notes below 72 sound once.

## Effects milestone: an original chain, per patch

Chain order is EQ, chorus, delay, reverb, applied after the voice mix inside
`RealtimeKeysoundEngine.render`. Every processor is original code written from the design here; none
of it is derived from the original app's DSP, and the analysis still records its effect parameters as
**Unknown**.

- **Ranges are ours and documented.** `EffectRanges` holds them in one place: mix 0 to 1, reverb
  decay and damping 0 to 1, chorus rate 0.05 to 6 Hz, chorus depth 0 to 1, delay time 20 ms to
  1.2 s, delay feedback 0 to 0.9, EQ gain -18 to +18 dB. Every processor clamps again on the render
  thread, so a value that arrived from an old bank or a controller cannot destabilise a filter.
- **Reverb.** Four damped combs at 29.7, 37.1, 41.3 and 43.9 ms plus two allpasses at 5.0 and 1.7 ms,
  with wet gain 0.9. Decay moves comb feedback from 0.35 to 0.93 (`0.35 + 0.58 * decay`, clamped),
  damping moves a one-pole lowpass inside each comb up to a coefficient of 0.7. These delay times are
  chosen for this implementation; they are not Freeverb's and not measured from the original.
- **Chorus.** A 50 ms line read at a 12 ms base delay swept up to 8 ms by a sine LFO, mixed with the
  dry signal. Rate and depth are the two controls.
- **Delay.** A 1.2 s line with a 30 ms glide to the target time, so moving the control on a held note
  bends the echo instead of clicking; feedback is clamped so repeats always decay.
- **EQ.** One-pole splits at 250 Hz and 3 kHz with a gain per outer band and the middle band
  untouched. The three bands sum exactly to the input, which is why the stage is bit-transparent at
  unity gain. Because the split is one pole, a gain is a shelf rather than a full cut at the corner:
  a 6 kHz tone is about 89 percent inside the high band, measured at 0.555 through a -12 dB high cut.
- **Bypass is exact.** A disabled processor clears its state and returns before touching the buffer,
  so bypass is bit-for-bit dry; the chain bypass test asserts sample equality, not approximate
  equality. Re-enabling starts from a clear tail rather than replaying what was there before.
- **Settings reach the render thread without a lock.** `EffectChain` publishes a whole
  `EffectsSettings` through a seqlock on a `UInt64` using the `CSync` atomics: the writer stores an
  odd sequence, writes the settings, then stores the even sequence; the reader takes the sequence,
  copies the settings, re-reads it, and discards a torn read, keeping the previous settings for one
  more block. Nothing allocates or locks on the render thread, and a settings change mid-chord is a
  parameter change rather than a cut.
- **Buffers are allocated once.** Every delay line and filter state is allocated in the processor's
  `init`, which runs on the control thread with the graph, never inside the render block.
- **Defaults keep old banks dry.** Every effect starts bypassed, so a patch saved before effects
  existed sounds exactly as it did, and an engine built straight from layers stays dry, which is why
  the envelope, split and stealing tests are untouched. `Patch.starter`, the patch the app opens
  with, engages only a short reverb (mix 0.18, decay 0.5, damping 0.4).
- **Persistence.** Effects live in `Patch`, `PatchBank.currentVersion` is 4, and `Patch` decodes
  `effects` with `decodeIfPresent`, so a version 1 or 2 bank loads with the chain bypassed.

What the effects tests cover: a reverb tail that is audible a second after the input stops, quieter
than the burst, and gone after seven seconds; a bypassed reverb that does not leak its tail; a single
impulse reappearing at exactly 4800 samples through a fully wet 100 ms delay with nothing before it;
repeats scaled by the feedback (0.5, then 0.25) at 4800-sample spacing; a chorus whose difference
signal moves as the delay sweeps; an EQ that is bit-transparent at unity gain, lifts the low band,
cuts the high band and leaves the other band alone; a bypassed chain that returns the buffer
unchanged; the whole chain staying finite, bounded and decaying two and a half seconds after the
input stops; the engine rendering a reverb tail after every voice is freed; a dry engine falling to
exactly zero after release; an effect change on a held note that neither releases the voice nor drops
it to silence; a patch switch that replaces the settings and does not inherit the previous tail;
effect updates from another thread while the render loop runs; and the whole chain surviving a bank
round trip while a bank written before effects existed loads dry.

## Controller milestone: learned, per patch

- **Model.** `ControllerTarget` names what a control moves: one target per layer gain, plus reverb
  mix and decay, delay mix and feedback, chorus mix and depth, and the two EQ gains.
  `ControllerMapping` holds `ControllerBinding` values of controller number, optional channel and
  target.
- **The layout belongs to the patch.** Two patches can want the same knob to do different things, and
  a restored session has to restore what the knobs do as well as what the keys sound like, so the
  mapping is stored in `Patch` and survives save and relaunch with everything else.
- **Learning replaces rather than stacks.** A target carries one controller and a controller carries
  one target; binding either direction removes the previous pairing, so a relearned knob cannot fire
  two parameters at once.
- **Channel precedence.** A binding for the exact channel wins over an any-channel binding, which
  lets a controller split across channels be assigned per channel while the any-channel default keeps
  answering everywhere else.
- **Values reach both ends.** A 7-bit value maps linearly onto a range, with 0 exactly at the lower
  bound and 127 exactly at the upper, so a control can dial a parameter fully off and fully on.
- **A mapping can outlive a layer.** A target naming a layer the patch no longer has is ignored and
  reported as not moved; nothing else changes.
- **Defaults are chosen, not recovered.** `ControllerMapping.standard` binds CC 7 to the first layer's
  gain, CC 1 to reverb mix, CC 11 to delay mix and CC 74 to chorus mix. The analysis records the
  original app's CC assignments as **Unknown**, so these are this instrument's defaults and any of
  them can be relearned.
- **App surface.** A mapping panel lists every target with its CC and channel, a Learn button that
  waits for the next control change (and applies the value that taught it, so the player hears where
  the knob already is), and a Clear button. A control change on a bound controller goes through the
  same no-release path as a slider, so turning a knob cannot cut a held chord.

What the controller tests cover: both ends and the midpoint of the value mapping; replacement in both
binding directions; channel precedence; unbinding; a bound change moving only its own parameter and
no layer; an unbound controller changing nothing at all; a layer gain moving inside its clamp while
the other layer is untouched; a target whose layer is gone being ignored; the standard layout
answering on any channel; the target list being free of duplicates; the mapping surviving a bank
round trip with its channel; a version 2 bank loading the standard layout; and a new patch starting
with it.

## Session and set list milestone

A `Setlist` is an ordered list of `SetlistEntry` slots plus one play head, stored in `PatchBank`, so a
service survives save, relaunch and any edit to the patches themselves. The original app's session
format is not documented anywhere in the analysis, so the type reproduces the behaviour a player
needs, not a recovered file layout; that separation is stated in the source as well.

- **Slots have their own identity.** A slot is an entry with an id and a patch id, not a patch id on
  its own, because a service can play the same patch twice and stepping has to tell the two slots
  apart. A test pins that.
- **The head is an identity, not an index.** `currentEntryID` names the slot, so removing an earlier
  slot or reordering the list cannot move the head onto a different sound. Both cases are tested.
- **Stepping wraps, jumping clamps.** `step(by:available:)` wraps at both ends so a foot switch can
  cycle the service; `jump(to:)` clamps, because a slot number means that slot or the nearest one
  that exists. Both choices are documented in the source and pinned by tests.
- **Removal keeps a head.** Removing the head hands it to the slot that followed; removing the last
  slot hands it to the new last one; emptying the list clears it. A head can never point at nothing.
- **Insert clamps its index**, so a caller cannot fail to place a slot, and the first slot in an
  empty list becomes the head.
- **Missing patches are handled twice.** Deleting a patch prunes its slots and fixes the head, and
  loading a hand-edited bank prunes too; stepping also skips a slot whose patch is gone, so a dangling
  entry cannot stall a service.
- **A bank with no set list plays in bank order.** That is what a bank written before set lists
  existed gets: `stepSetlist` falls back to the patch order, wrapping the same way, and the app says
  so in the panel instead of showing an empty box. `Fill from bank` turns that order into a real list.
- **Adding a patch does not silently extend the service.** The player adds the slot deliberately, so
  the set list stays what they built.
- **The set list switch is the patch switch.** The app's only path from a slot to the engine is
  `bank.patch(forEntry:)` followed by `setPatch`, the same call the bank picker makes, so a set list
  step releases what is sounding and applies the new patch's effects. A test drives exactly those two
  calls and asserts that the voices are freed and that the next patch inherits no reverb tail; a
  second test asserts that stepping to a wetter patch does bring its reverb, which only happens if the
  step really applied the settings.
- **Picking a patch moves the head.** Selecting a patch from the bank picker moves the set list head
  to that patch's first slot when it has one, so the position shown is the sound that is playing.
  Program change goes through the same path.
- **Persistence.** `PatchBank.currentVersion` is 4. A version 1, 2 or 3 bank has no `setlist` key and
  decodes to an empty list, which plays in bank order; the stored version is reported as written. The
  starter bank ships one slot pointing at the starter patch, so a fresh install has something to
  step through.
- **App surface.** A set list panel between the patch panel and the effects panel: every slot with
  its number and patch name, a `now` marker on the current slot, `Play`, `Up`, `Down` and `Remove`
  per slot, and `Prev`, `Next`, `Add patch` and `Fill from bank` for the list. The window scrolls, so
  all five panels are reachable on a short display.

What the set list tests cover: append keeping order and seeding the head; stepping with wrap at both
ends and a zero step doing nothing; jumping with clamping; removing the head, the last slot and the
whole list; removing an earlier slot leaving the head on its own patch; reorder keeping the head on
its slot, in both directions; the same patch filling two slots while stepping tells them apart; insert
clamping; pruning on delete and on load; a dangling slot being skipped; bank order covering every
patch once; stepping a bank with no set list in bank order, wrapping; resolution of the patch a step
lands on; the round trip through `PatchStore` including the play head; a version 3 bank loading
without a set list and still stepping; and the engine tests above.

Two of those tests failed the first time they ran (run `42728534122`), and in both cases the
expectation was wrong and the model was right: the head reports the position of the slot that
actually played, so skipping a dangling middle slot lands on index 2 and not 1, and a voice is still
fading 20 blocks after a release that lasts 20.6 blocks. Both repairs are in `18e0268` and are
recorded in the table below.

## Bundle milestone: `SundayKeys.app`

The package produced an executable but no bundle, so there was nothing to put in Applications, nothing
to hand to another Mac and nothing to launch. `tools/bundle_app.sh` now assembles one from the release
build and verifies its own output.

- **Its own identity, not the original's.** The analysis documents the original as bundle id
  `com.sundaysounds.sundaykeys`, version 2.5.2, build 3367. This bundle is
  `com.worshipwarehouse.sundaykeys-cleanroom`, version 0.5.0, build 5, so the two can be installed
  side by side and nothing here claims to be that build. The script says so too.
- **The plist is written by the script, not checked in.** `CFBundleExecutable` is the SwiftPM product
  name, `CFBundlePackageType` is `APPL`, `LSMinimumSystemVersion` is 14.0 to match
  `Package.swift`, and `NSHighResolutionCapable` is set. `PkgInfo` carries `APPL????`.
- **The signature is ad-hoc.** Apple silicon will not launch an unsigned bundle, and there is no
  developer certificate in this environment, so the script signs with `-`. That is enough to launch
  locally and is explicitly not distribution signing; nothing is notarised.
- **The script verifies instead of assuming.** It lints the plist, checks the executable bit, runs
  `codesign --verify --strict`, and asserts that the bundle's declared executable is the one it
  placed. Any failed check exits non-zero, so the CI step fails with it.
- **CI runs it.** The workflow builds the release configuration, then runs the bundler, then repeats
  the executable, plist and signature checks and lists the bundle's files, so a red run says which
  check failed. Run `42730684997` is the first to include the step and it passed.

What this does not cover, and the script says so at the top: nobody has opened `SundayKeys.app`. The
window, the AVAudioEngine start path against a real output device, CoreMIDI against a controller and
the set list panel on screen are all still unverified, and a bundle that assembles and signs is not
the same thing as an app that runs.

## Remote development: what CI actually does

The local Mac has been unreachable for this whole stretch of work, so every result in this log comes
from the `macos-15` runner and nothing is claimed from a local build. `.github/workflows/build.yml`
runs on every push to `main`, on pull requests and on demand, with `contents: read`, a concurrency
group that supersedes an older run, and a 25-minute timeout. Its steps are:

1. check out the repository and print the toolchain: `xcode-select -p`, `xcodebuild -version`,
   `swift --version`, `xcrun --find swift`;
2. `swift package resolve` and `swift package show-dependencies`, which validate the manifest and
   prove the package needs no network beyond the checkout;
3. `swift build --build-tests -v`, with the log kept for the next step;
4. surface up to twenty unique compiler warnings as check-run warnings, and on failure surface up to
   twenty-five `error:` lines as check-run errors, so a red run is readable without the job log;
5. `swift test -v`, with the same error and assertion surfacing on failure;
6. `swift build -c release`, which compiles the optimised configuration as well as the debug one;
7. `tools/bundle_app.sh`, which assembles `SundayKeys.app`, signs it ad hoc and verifies the plist,
   the executable and the signature, then the workflow repeats those checks and lists the files;
8. run `bash tools/bootstrap.sh --check` and fail the job if it exits with anything other than 0 (all
   present) or 1 (tools missing) or if it fails to report the toolchain, which is the smoke test for
   the script's reporting and exit codes.

What that does not cover, and this log will not pretend otherwise: the install path of
`tools/bootstrap.sh` (it installs Homebrew casks and needs sudo, so it runs only on a developer
machine), notarisation and distribution signing, launching the bundle, `AVAudioEngine` against a
real output device, CoreMIDI against a real controller, and anything that needs to be heard. The DSP
is validated by offline tests that measure sample values, and neither the set list panel nor the
bundle has ever been looked at on a screen: nobody has listened to this or clicked through it on this
hardware.

## Decompilation: awaiting external access

No artifact that can be decompiled is reachable from this environment. The shell tool refused every
call again this session, so no process can be started, no path can be examined and no Ghidra run is
possible. The repository contains only docs, tools and Swift and C sources: no Mach-O, `.app`, AUv3
bundle, `.aupreset`, CAF payload, Ghidra project or prior decompilation export. Details and the exact
access required are in [`re/access-determination.md`](re/access-determination.md).

Required to resume: the Mac awake with the Freebuff desktop client connected, the app installed,
Ghidra 12.1.4 and Java 21 or newer under a persistent path, and about ten minutes for an import.

## Next actions, in order

1. Launch `SundayKeys.app` on the Mac and do the first hardware validation: audio device output, a
   real controller, a click through the patch, set list, effects and mapping panels, and a listen to
   the effects chain. This is the only step that needs the App Store Xcode and a person listening.
2. An unattended launch smoke check in CI: start the bundle, wait for the process to stay alive, then
   quit it, so a crash on launch is caught by the runner instead of by the player. The runner has a
   window server, so this should be possible without the Mac, and it is the next thing to try.
3. MIDI controller mapping refinements that need hardware: relative encoders, a foot switch, and the
   behaviour of a controller that sends on several channels.
4. Session scope beyond one ordered list, once there is evidence for it: the original app's session
   contents are **Unknown**, so the next step is a capture or a decompiled session type, not a guess.
5. Reconnect the host, then decompile the queued targets (`Audio.KeyboardVelocityScaling`,
   `Audio.LayerRangeLimit` with `Domain.RangeApi`, the Realm MIDI learn tables,
   `Audio.SamplerPlugin` voice handling, and the rotor, chorus and delay parameter ranges) and
   commit the extracts under `docs/re/` with provenance.

## Build verification

`.github/workflows/build.yml` runs the steps listed above on a `macos-15` runner for every push to
main, and republishes compiler and test errors as check-run annotations, so a failing run is readable
without the job log. Rows are added only for runs whose conclusion has been read from the API.

| commit | run | conclusion |
| --- | --- | --- |
| `43637aa` | [42721262800](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42721262800) | success. Both annotations are workflow notices, not code warnings. |
| `33086584` | [42721455596](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42721455596) | success, same two notices. |
| `78b907f` | [42722291245](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42722291245) | failure: `UnsafeMutableBufferPointer` has no `initialize(repeating:count:)` or `deinitialize(count:)`; fixed in `57740fe`. |
| `57740fe` | [42722636068](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42722636068) | compiled fully, then one test failed: the split test expected the voice pool back after 8 blocks, but release is 220 ms and needs 21 blocks at 512 frames. Fixed in `e859ccf`. |
| `e859ccf` | [42722698841](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42722698841) | success: build and all test suites pass. |
| `b3e20b5` | [42723395400](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42723395400) | failure: one line of the new `setPatch` doc comment lost its `///` prefix, so it was parsed as code. Fixed in `6f08875`. |
| `c1fccc2` | [42724058815](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42724058815) | failure, one test: the persistence fixture minted fresh random patch ids on every call, so the relaunch equality assertion could never hold. Fixed in `bd43567`. |
| `bd43567` | [42724195726](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42724195726) | success: build and all suites pass, including the patch persistence, resolution, switching and live-edit tests. |
| `4c7b179` | [42724369999](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42724369999) | success: the patch milestone write-up. |
| `5266e48` | [42725183689](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42725183689) | success: the effects chain compiles and every pre-existing suite still passes. |
| `2f9af82` | [42725884346](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42725884346) | failure, one test of the new suite: `testEQBandsLiftAndCutTheirBand` demanded a full -12 dB at 6 kHz and measured 0.555. A one-pole 3 kHz split leaves about 89 percent of a 6 kHz tone in the high band, so the assertion was wrong, not the DSP. Also dropped the cache action that emitted a Node 20 deprecation warning. Fixed in `242d555`. |
| `242d555` | [42726206476](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42726206476) | success: the EQ test now asserts the shelf shape and band isolation, the whole effects suite passes, the release build passes and the bootstrap smoke step passes. |
| `8a95eb0` | [42726778003](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42726778003) | failure, before tests ran: `ContentView.swift:329` passed a ternary mixing `.secondary` (a hierarchical style) and `.orange` (a colour) to `foregroundStyle`, which has no common type. Fixed in `34a0c0e`. |
| `34a0c0e` | [42726991886](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42726991886) | success: the fixed tree, the controller mapping tests, the release build and the bootstrap smoke step. |
| `ea50641` | [42727234267](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42727234267) | success: the effects and controller write-up, with no code change to the tree above. |
| `da1a85d` | [42728077480](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42728077480) | failure, before tests ran, six annotations: the new set list fixture in `SetlistTests.swift` declared its bank with `let` and then stepped it, which is a mutating call, so the suite did not compile. A fixture, not product code. Fixed in `9c6768d`. |
| `0fe89b7` | [42728400967](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42728400967) | failure: the write-up commit carried the same fixture, so the same compile error and no test ran. Fixed in `9c6768d`. |
| `9c6768d` | [42728534122](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42728534122) | failure, two tests of the new suite, eleven annotations, and both were assertions rather than the model: `testASlotWhosePatchIsMissingIsSkippedWhileStepping` expected the head at index 1 after stepping over the dangling middle slot, but a skipped slot is not removed, so the head is on index 2 of three; `testSteppingToAWetterPatchAppliesItsEffects` demanded an empty voice pool after 20 blocks, which is 10,240 frames of the 10,560-frame release. Fixed in `18e0268`. |
| `18e0268` | [42729742825](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42729742825) | success: the debug build, all test suites including the set list ordering, persistence and set-list switching tests, the release build and the bootstrap smoke step. |
| `a1a5e61` | [42730136694](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42730136694) | success: the set list write-up, with no code change; build, tests, release build and the bootstrap smoke step. |
| `3e0c3a9` | [42730684997](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42730684997) | success: build, all suites, the release build, the new bundle step and the bootstrap smoke step. The bundle step ran the script and passed its plist, executable and strict signature checks. The two annotations are the macOS queue notice and the SwiftPM manifest warning, not code warnings. |

## Coverage that remains

| gap | cause | closes with |
| --- | --- | --- |
| call direction between modules | corpus is pre-rename | a named re-decompilation |
| 234 unattributable dispatch references | descriptors outside the local type table | a wider type table, or a capture |
| 31 types with no module name | no recoverable parent chain or mangled symbol | a capture |
| velocity curve, split range semantics, voice stealing | not decompiled | awaiting external access |
| the original app's effect parameter ranges and defaults | not decompiled | awaiting external access; this implementation's ranges are its own design and are documented in `EffectRanges` |
| the original app's MIDI CC assignments | not decompiled | awaiting external access; this implementation's default layout is its own design and can be relearned |
| the original app's session and set-list contents | not decompiled and not captured | a capture or a decompiled session type; the type here reproduces the behaviour, not the file layout |
| licence wire details, Pusher channel and event names, chunk size, tempo authority | not statically recoverable | one captured session |
| launching the bundle, audio device output, a real controller, a clicked-through window | need the unreachable Mac | next action 1 |
| an unattended launch smoke check | not written yet; needs a runner with a window server | next action 2 |

## Decisions recorded

| decision | rationale |
| --- | --- |
| unknown licence status decodes to `expired` | fail closed rather than unlock features on an unrecognised wire value |
| module dependency direction is labelled Inferred | section 20 measured co-occurrence, not direction |
| the original sample libraries cannot be reused | proprietary content, so the keysounds are synthesised from original partial sets |
| C target for the atomic index operations | the memory orderings are the compiler's own builtins, with no dependency to resolve and no deprecated wrapper |
| commands are never dropped | the producer spins instead; only the render thread is latency-critical |
| wavetables and voices are built before the graph starts | allocation must not happen on the render thread |
| voice stealing fades before retriggering | a hard reassignment is audible as a click |
| tests own their own block counts | a release window is a property of the envelope, not of the test, so the test renders past it |
| patches are switched in place through the command ring | rebuilding the graph would click, allocate and drop buffers on the audio thread |
| a live edit of the playing patch does not release voices | releasing on every slider step would cut the chord the player is holding |
| the persistence fixture uses fixed patch ids | a decoded bank has to keep patch identity, and random ids could never assert it |
| effects are stored in the patch, not the engine | a patch is the whole sound; an effect that outlived its patch would bleed into the next one |
| every effect starts bypassed | a bank written before effects existed, and an engine built from layers alone, must sound exactly as they did |
| effect settings travel through a seqlock | a whole-settings publish with no lock and no allocation is the only way to change a parameter on a held note safely |
| the chain is EQ, chorus, delay, reverb | the order that keeps modulation out of the reverb tail and lets the EQ shape what the effects receive |
| a bypassed processor returns before touching the buffer | bypass has to be bit-exact dry, not approximately dry |
| the EQ is a shelf, not a brick-wall split | one-pole splits sum to the input exactly, which keeps unity gain transparent |
| the controller layout is stored per patch | two patches want the same knob to do different things, and a session has to restore both |
| learning replaces both directions | a knob must never move two parameters, and a parameter must never have two knobs |
| a controller value maps onto the full range with exact endpoints | a control that cannot reach the end of its range is a bug the player notices |
| the CI cache action was removed | it emitted a Node 20 deprecation warning for a build that takes under a minute |
| a set list slot has its own id | a service can play the same patch twice, and stepping has to tell the slots apart |
| the play head is an entry id, not an index | reordering or deleting an earlier slot must never move the head onto a different sound |
| stepping wraps and jumping clamps | a foot switch cycles the service; a slot number pressed on purpose means that slot or the nearest one |
| the set list lives in the bank, not in a separate file | a service and the patches it names are one thing to save, and a bank already carries its own format and defaults |
| a bank without a set list plays in bank order | old banks keep working and a fresh bank needs no migration step |
| a set list step goes through `setPatch` | it is a patch switch, so it must release voices and apply effects exactly like the bank picker |
| adding a patch does not add a slot | the service is what the player built, not a side effect of editing patches |
| skipping a slot does not compact the list | the head reports the position that actually played, so a skipped dangling slot leaves the head on index 2 of three, and the UI numbering keeps matching the list |
| a test that asserts the voice pool empty renders past the release | 220 ms is 20.6 blocks of 512 frames, so 20 blocks leaves a voice still fading; the envelope was right and the block count in the test was wrong |
| the bundle carries its own identifier and version | the original is `com.sundaysounds.sundaykeys` 2.5.2 build 3367; reusing that identity would be false and would collide, so this is 0.5.0 build 5 of its own line and the two can be installed side by side |
| the bundle is signed ad hoc, not for distribution | Apple silicon will not launch an unsigned bundle and there is no developer certificate here; ad-hoc signing is enough to launch locally and nothing is notarised, which the script states |
| the bundler verifies its own output | a bundle that assembles is not a bundle that is well formed, so the script lints the plist, checks the executable, verifies the signature and fails the run if any check does |

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
| `31596438` | app hosts the keysound engine; old voice bank superseded |
| `e174d13` | voice bank deleted; CI republishes build errors as annotations |
| `a825ae4` | voice pool initialised from locals; layer list computed |
| `57740fe` | buffer pointer initialise and deinitialise forms |
| `e859ccf` | split test renders past the release tail |
| `b3e20b5` | patch bank, layer `enabled` flag, gapless switching, patch tests |
| `6f08875` | doc-comment prefix restored after `b3e20b5` broke the build |
| `84a0756` | audio controller owns and switches the current patch |
| `c1fccc2` | bank, switching and the layer editor wired into the app; live edits do not release voices |
| `bd43567` | persistence fixture with stable patch ids, plus the live-edit tests |
| `5266e48` | EQ, chorus, delay and reverb processors, the chain with its seqlock, per-patch settings |
| `2f9af82` | effects tests, effects panel, CI toolchain and dependency steps, bootstrap smoke step |
| `242d555` | EQ test asserts the shelf shape and band isolation; cache action removed |
| `86eea5a` | controller targets, bindings, value mapping and per-patch persistence with tests |
| `8a95eb0` | learn mode in the app model and the mapping panel |
| `34a0c0e` | the `foregroundStyle` ternary fixed to a single type |
| `3d2d7d8` | set list model, play head, stepping, reorder, removal, pruning, bank version 4, set list tests |
| `642c020` | set list stepping, slot actions and head tracking in the app model |
| `da1a85d` | the set list panel and a scrolling window |
| `0fe89b7` | the session and set list write-up in this log and the README |
| `9c6768d` | the set list fixture's bank declared `var`, because stepping it is a mutation |
| `18e0268` | the two set list assertions repaired, verified by run `42729742825` |
| `a1a5e61` | the observed run table and the README updated; verified by run `42730136694` |
| `3e0c3a9` | `tools/bundle_app.sh`, the CI bundle step and `build/` ignored; verified by run `42730684997` |

Earlier analysis commits are listed in the analysis document itself.
