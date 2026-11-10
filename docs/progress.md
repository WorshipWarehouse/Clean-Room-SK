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
| Launch, CI | the runner starts the bundle, reaches its run loop and exits 0 | `tools/launch_smoke.sh`, run `42731763842` |
| Build, audio start | the graph starts on the runner's output device, renders a voice and stops; a missing device is a typed error instead of a crash | `AudioStartPlan.swift`, `AudioEngineController.start()`, `tools/audio_smoke.sh`, run `42733100695` |
| Build, MIDI start | the client and input port are created on the runner and the source list is enumerated and reported; a missing client, a missing port and a refused connect are typed errors with their own exit status | `MIDIStartReport.swift`, `MIDIInputService.start()`, `tools/midi_smoke.sh`, run `42734422204` |
| Build, MIDI status | the verdict is turned into one status line in the core module and the model retains it, so a refused client or port, a refused connect and an empty source list each read differently in the window | `Sources/SundayKeysCore/MIDI/MIDIStatus.swift`, run `42735872524` |
| Build, MIDI status tracking | the status follows the source list for as long as the client lives: a source appearing, disappearing or recovering updates it without pressing Start, and a refusal is kept only while it still applies | `Sources/SundayKeysCore/MIDI/MIDISourceTracker.swift`, `MIDIStatusBoard.refresh(with:)`, run `42737094402` |
| Test | queue stress, envelope, release, bounded stealing, patch persistence and switching, effects DSP, effect persistence, controller mapping, set list ordering and set-list switching, audio start planning, MIDI start reporting, MIDI status wording and retention, MIDI source tracking across refreshes | `Tests/SundayKeysCoreTests/` |

This is a working instrument with a working patch system, an original effects chain, a learned
controller layout, a playable set list, a bundle that CI assembles, verifies and launches, an audio
graph that CI starts and renders through, a MIDI client that CI creates and enumerates, and a MIDI
status that follows the source list and says which of those actually happened. What is still missing
is everything that needs eyes and ears, and everything that needs a controller: no person has seen the
window or read that status line, nothing has been listened to, and no controller has ever been plugged
in, because the Mac that would do it is unreachable and the runner has no MIDI source.

## Audio milestone: what the instrument actually is

- **Sound source.** No sample assets exist in this repository and none from the original app may be
  used, so the keysounds are synthesised at startup into two 2048-sample tables: an additive keys
  table (twelve harmonic partials, even partials attenuated) and a two-operator FM bell. This is a
  wavetable synthesiser, not a sampled instrument, and the code says so.
- **Polyphony.** Thirty-two voices by default, sixteen per layer. Allocation prefers retriggering
  the same note on the same layer, then a free voice, then the quietest releasing voice in the
  layer, then the oldest voice in the layer.
- **The render block never blocks.** It drains every queued command and then renders. A full ring
  makes the *producer* spin, at most one buffer period, which is 10.7 ms at 48 kHz with 512-frame
  blocks.
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
  decay and damping 0 to 1, chorus rate and depth, delay time and feedback, and both EQ gains, so
  the panel, the tests and the mapping all read the same numbers.
- **EQ.** A low shelf and a high shelf split with one-pole filters at 3 kHz, so the two bands sum
  back to the input at unity and a flat setting is transparent rather than approximate.
- **Chorus.** A 50 ms line read at a 12 ms base delay swept up to 8 ms by a sine LFO, mixed with the
  dry signal. Rate and depth are the two controls.
- **Delay.** A 1.2 s line with a 30 ms glide to the target time, so moving the control on a held note
  bends the echo instead of clicking; feedback is clamped so repeats always decay.
- **Reverb.** Four combs and two allpasses per side, with decay and damping controls.
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
EQ band lifting and cutting without moving the other band; a chorus and a delay each audibly changing
the signal without clipping; a patch switch to a dry patch leaving the voice mix exactly zero after
release; an effect change on a held note that neither releases the voice nor drops it to silence; a
patch switch that replaces the settings and does not inherit the previous tail; effect updates from
another thread while the render loop runs; and the whole chain surviving a bank round trip while a
bank written before effects existed loads dry.

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
  its own, so the same patch can appear twice and the two slots stay distinct. The play head is an
  entry id rather than a position, so reordering or removing an earlier slot never moves the head
  onto a different sound.
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

## Launch milestone: the bundle starts

A bundle that assembles is not an app that runs, and until run `42731763842` nobody and no machine had
started this one. Two marks are needed to say anything honest about a launch: that the app reached its
run loop, and that it left through a normal exit rather than a signal.

- **The app reports its own startup.** `Sources/SundayKeysApp/LaunchProbe.swift` prints
  `SundayKeysApp: did finish launching pid=...` from `applicationDidFinishLaunching` and
  `SundayKeysApp: window ready` once the root view is installed.
- **It can be asked to quit.** With `SUNDAYKEYS_PROBE_EXIT_AFTER=<seconds>` the app schedules a
  one-shot timer that calls `NSApp.terminate(nil)`. A timer that fires is evidence the run loop is
  being serviced, and the resulting status 0 is a normal exit. Without the variable nothing changes,
  so a player launching the app never sees probe behaviour.
- **The check probes the session before it blames the app.** `tools/launch_smoke.sh` prints the OS
  version, `launchctl managername`, whether `WindowServer` is running, whether `gui/<uid>` is
  reachable and whether the job is over SSH, then launches the bundle's own executable with the probe
  armed and a 20 second budget for the two markers.
- **It fails on the four real failures.** A dead process, a missing marker, a process still running
  after the probe asked it to quit, and a non-zero exit each fail the step and print the last 120
  lines of the app's own output as an annotation, so a red run names the obstacle instead of hiding
  it. A zombie is not mistaken for a hang: liveness is read from `ps -o state=`, because an exited
  child still answers `kill -0` until it is reaped.
- **LaunchServices is supplementary, never the pass.** The script also runs `open -n` on the bundle
  and reports whether a process appeared and stayed alive, then terminates it. That path cannot carry
  the probe environment or be captured on stdout, and it ends in a signal rather than a clean exit, so
  it is evidence and not the criterion.
- **Observed.** Run [`42731763842`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42731763842)
  on `7cb9a17`: the macos job succeeded, and its step 12, "Launch the app", passed in seven seconds
  (00:55:17 to 00:55:24). Debug build with tests, all suites, warnings, the release build, the bundle
  step, the launch step and the bootstrap smoke step all passed on that same run. The only annotations
  were the macOS capacity notice and the SwiftPM manifest warning; no compiler or test warning came
  from this change.

What the step proves: the bundle's executable loads, AppKit finishes launching, SwiftUI installs the
root view, the run loop services a timer, and the process exits with status 0 through
`NSApplication.terminate`. Because the script only exits 0 after asserting those markers and that
status, a green step means all of them held.

What it does not prove: that a person can see a window, that the window is the right size or on
screen, that audio reaches an output device, that a controller is seen, or that the audio graph and
MIDI client start at all - the app only creates those when the player presses Start, and no launch
check presses it. The job log for this run came back truncated before the launch step's own printed
lines, so the session string and the LaunchServices result were not read in this session; the pass is
reported from the step's status and the script's exit conditions, not from a quoted log line. No
startup defect surfaced: the attempt found no crash on init, no force-unwrap failure, no missing
resource and no audio or MIDI abort with no controller and no device started, so nothing needed
repair for this milestone.

## Audio start milestone: the graph starts and renders

The launch check ended where playback starts: nobody had ever pressed Start, so whether `AVAudioEngine`
could open an output device, build the graph and run the render block was unknown. That was next
action 2 at the time, and it is done.

- **The start path had a real hazard.** `AudioEngineController.start()` read
  `engine.outputNode.inputFormat(forBus: 0)` before knowing a device existed. On a Mac with no output
  device that raises an Objective-C exception, which Swift cannot catch, so pressing Start would have
  taken the process down instead of reporting anything. `DefaultOutputDevice.exists()` now asks
  CoreAudio for `kAudioHardwarePropertyDefaultOutputDevice` first, and a missing device becomes an
  error the app can show.
- **The decision is in the core module and is tested.** `AudioStartPlanner.plan(forReportedSampleRate:)`
  turns what the device reported into a plan or a refusal: no device is
  `AudioStartFailure.noOutputDevice`; a rate of zero, which is what macOS reports before the engine
  runs, falls back to 48 kHz rather than failing; a negative or non-finite rate is
  `unsupportedFormat`; anything else is kept as reported. The plan is always stereo, because the
  render block computes one buffer and copies it to the remaining channels.
- **Equality had to be written out.** `AudioStartFailure` carries a `Double` that can be NaN, and NaN
  is never equal to itself, so synthesised equality made a rejected NaN rate impossible to compare at
  all. Two rejections are equal when their rates have the same bit pattern, and a test pins that rule.
- **The probe presses Start itself.** `SUNDAYKEYS_PROBE_START_ENGINE=1` starts the same
  `AudioEngineController.start()` the button runs, plays note 69, waits half a second, reports
  `engine started at N Hz` and the voice count the render block actually produced, stops the graph and
  exits. A voice only exists once the audio callback has drained the command ring, so a non-zero count
  is evidence the render thread ran, not just that the engine opened.
- **Its exit status is the verdict.** 0 means started and rendered, 4 means the start was refused,
  5 means it started but produced no voice, 6 means the probe lost the graph it created.
  `tools/audio_smoke.sh` reads those and the markers.
- **A machine with no output device is reported, not hidden.** If the app prints the typed
  `No audio output device is available` failure and exits 4, the script publishes a warning annotation
  with that line and still exits 0, because refusing cleanly is the correct behaviour there and the
  run should say what the hardware was. Any other failure - a crash, a hang, an engine that refuses to
  start for another reason, or a start with no voice - fails the step with the app's own output.
- **Observed.** Run [`42733100695`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42733100695)
  on `e6ae994`: the macos job succeeded and its step 13, "Probe the audio start", passed in three
  seconds (01:05:51 to 01:05:54). Debug build with tests, warnings, all suites, the release build, the
  bundle step, the launch step, the audio step and the bootstrap smoke step all passed on that run.
  The job published no warning annotation, and the no-device path always publishes one, so the graph
  started and rendered at least one voice on the runner's default output device. The rate and voice
  count the probe printed are not quoted here: the job log download truncates before the later steps,
  so those lines were not read, and the pass is reported from the step's status and the script's exit
  conditions.

The first attempt at this milestone was run `42732896895` on `de6a1b6`, and it failed for two reasons
of my own making, both fixed rather than tested around: `AudioStartPlanTests` could not compare a
rejection carrying a NaN rate, and the launch probe captured the audio graph in a `@Sendable` timer
closure, which the compiler reported as a warning. The comparison is now on bit patterns and the timer
reaches the graph through a main-actor reference; both are in `e6ae994`.

## MIDI start milestone: a client is created and the source list is read

The audio probe ended where MIDI begins. `MIDIInputService.start()` created the client and the input
port but threw away every `OSStatus`, so a client that could not be created and a machine with no
controller looked identical from the outside: an empty source list and no explanation. That was next
action 2, and it is now done.

- **The start path reported nothing before this.** `start()` now returns a `MIDIStartVerdict` - either
  `refused(MIDIStartFailure)` or `running(MIDIStartReport)` - and `lastVerdict` holds the latest one.
  A second call returns the first verdict instead of creating a second client, and `stop()` disposes
  the client, the port and every connection it made.
- **The verdict is core logic and is tested.** `Sources/SundayKeysCore/MIDI/MIDIStartReport.swift`
  holds `MIDIEndpointDescription`, `MIDIInventory`, `MIDIStartFailure`, `MIDIStartReport` and
  `MIDIStartVerdict`. The app target only fills the descriptions in from CoreMIDI, so every rule the
  probe relies on is asserted by `swift test` on any machine, with no controller and no MIDI server.
- **What is reported.** A source with no name, a blank name or no manufacturer still gets a distinct
  line: the unique id stands in for the name and "unknown manufacturer" for the vendor, so two
  unnamed endpoints cannot be confused. Each line carries its 1-based position and count. The
  inventory summary is `MIDI: N source(s): X online, Y offline`, and the report adds
  `MIDI: client created` before it and `MIDI: connected X of Y online source(s)` after.
- **Only online endpoints are connected.** `kMIDIPropertyOffline` is read for each source; an offline
  endpoint is listed and counted but not connected, because a refused connect says nothing about the
  machine. A connect that fails on an online source is a `connectionFailed` carrying the source's
  name and the `OSStatus`.
- **The probe presses Start itself.** `SUNDAYKEYS_PROBE_START_MIDI=1` runs the same
  `MIDIInputService()` and `start()` the Start button runs, prints the report through the same probe
  marker, disposes the client and exits.
- **Its exit status is the verdict.** 0 means the client and port were created and every online
  source connected - a zero-source list is still 0, because that is a fact about the hardware, not a
  failure - 4 means no client, 5 means no input port, 6 means a source would not connect. The number
  is computed by `MIDIStartVerdict.exitCode` and pinned by tests, not by the script.
- **A machine with no controller is reported, not hidden.** `tools/midi_smoke.sh` publishes a warning
  annotation with the app's own line and exits 0 when the reported count is zero, and fails the step
  on a missing client marker, a missing count, a non-zero status or a timeout. It reads liveness from
  `ps -o state=` for the same reason the audio script does: an exited child still answers `kill -0`.
- **Observed.** Run [`42734422204`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42734422204)
  on `2464172`: the macos job succeeded, and its step 14, "Probe the MIDI start", passed in two
  seconds (01:16:14 to 01:16:16). Every step was green on that run: debug build with tests, warnings,
  the tests, the release build, the bundle step, launch step 12 (01:16:05 to 01:16:11), audio step 13
  (01:16:11 to 01:16:14), the MIDI step and the bootstrap smoke step, which completed at 01:16:21.
  The job published three annotations: the macOS capacity notice, the SwiftPM manifest warning, and
  this probe's own warning, "this machine has no MIDI sources: the probe proved the client and input
  port were created and the source list was empty". The script only reaches that line after finding
  `SundayKeysApp: MIDI: client created`, reading a source count and seeing the process exit 0, so the
  runner created a CoreMIDI client and an input port and read `MIDIGetNumberOfSources` as zero. The
  connect path was not exercised, because there was nothing to connect.

What this does not prove: that a source can be connected and played from. The runner has no MIDI
source, so the connect loop never ran against a real endpoint, and no controller has been attached to
anything. Enumerating and describing a non-empty list is covered by the unit tests, not by the runner.

## MIDI status milestone: a refusal is now something the window can say

The MIDI probe ended one step short. `AppModel.start()` called `midi.start()` and discarded the
verdict, so the work above proved a client existed and then threw the answer away at the only point a
player could see it: a refused client, a refused port and an empty source list all left the app
running with no explanation. That was next action 2, and it is now done.

- **The status is one core value derived from one verdict.** `Sources/SundayKeysCore/MIDI/MIDIStatus.swift`
  holds `MIDIStatus` - `notStarted`, `ready(connected:available:)`,
  `degraded(connected:available:failure:)` and `unavailable(failure)` - with `init(verdict:)`, `text`,
  `isFailure` and `message(base:)`. The app target contributes nothing to the wording, which is why
  `swift test` can assert it on any machine.
- **Every refusal names the call that failed and its status.** A missing client reads
  `MIDI unavailable: MIDIClientCreate failed with status -50`; a missing port reads
  `MIDI unavailable: MIDIInputPortCreate failed with status -10833`; a refused connect keeps the
  source and keeps its `OSStatus`,
  `MIDI ready, 0 of 1 source(s) connected; could not connect source "Keystation 61" (status -10830)`.
  A test asserts that all seven outcome lines are distinct and that none contains a generic
  "MIDI failed", so two different faults cannot collapse into one sentence.
- **A client with no sources is described, not blamed.** It reads `MIDI ready, no sources found` and
  `isFailure` is false, which is the distinction that started this work: the runner's empty list is a
  fact about the hardware, while a refused client is a fault. Sources that were enumerated but not
  connected read `MIDI ready, 0 of 2 source(s) connected`, which is different again.
- **The model retains the status.** `AppModel` owns a `MIDIStatusBoard`, exposes
  `@Published private(set) var midiStatus`, records the verdict from `start()` and appends the line to
  the status message the window already shows; `stop()` resets the board. `record(_:)` returns the new
  status as well as storing it, and a test proves the board keeps a refused start and replaces it with
  the next verdict, which is the property the old code lacked: the value was read once and dropped.
- **The wiring is deliberately small.** The line rides on the existing status message rather than a
  new view, because the app target has no tests and a new panel could not be asserted; `midiStatus` is
  published so the MIDI panel can show it once there is a way to test that. This is the honest half of
  the fix, and the next action said so.
- **Observed.** Run [`42735872524`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42735872524)
  on `38f55d5`: the macos job succeeded and every step was green. Debug build with tests compiled the
  new core file and the rewritten model in 29 seconds (01:27:26 to 01:27:55); warnings at 01:27:55;
  `swift test` at 01:27:55 to 01:27:59; the release build 01:27:59 to 01:28:19; the bundle 01:28:19 to
  01:28:21; launch step 12 01:28:21 to 01:28:28; audio step 13 01:28:28 to 01:28:31; MIDI step 14
  01:28:31 to 01:28:32; bootstrap step 15 01:28:32 to 01:28:35; the job completed at 01:28:40. The
  three annotations were the capacity notice, the SwiftPM manifest warning, and the MIDI probe's own
  no-sources warning, so the existing probes behaved exactly as they had before the change.

What this does not prove: that anyone has read the line. The status text is asserted by
`MIDIStatusTests`, but the app target still has no test that the view shows it, and no person has
looked at the window. It also does not prove that a real client or port ever refuses: the runner's
client is always created, so the two unavailable lines are exercised by tests and not by hardware.

## MIDI status tracking milestone: the line follows the source list

The status above was computed once, when Start was pressed. A controller plugged in afterwards
refreshed the source list but left the line saying `MIDI ready, no sources found`, and a source that
had once refused stayed refused for ever, or vanished from the status while the port still held it.
That was next action 2, and it is now done.

- **A refusal now names the endpoint it refused.** `MIDIStartFailure.connectionFailed` carries
  `sourceID` as well as the name and the `OSStatus`, with a `sourceID` accessor that is nil for the two
  creation failures. Without that identity a refresh could not tell a refusal that still applies from
  one about a source that has since gone or connected; matching on a display name would have made two
  unnamed endpoints indistinguishable, which is exactly the case the report was built for.
- **The rules live in `MIDISourceTracker` and are pure.** `Sources/SundayKeysCore/MIDI/MIDISourceTracker.swift`
  answers three questions with no CoreMIDI present: which online endpoints the port does not hold yet
  (offline endpoints are never attempted), which endpoints it holds, and which refusals are still
  live. `prune(keeping:)` forgets connections and refusals for sources that are no longer enumerated,
  and a source that connects retires its own refusal, so a device that recovers is not accused for
  ever while a real fault survives a notification that changes nothing.
- **The report cannot double count.** `report(for:)` derives the connected ids from the inventory, so
  a stale endpoint cannot be reported, and an endpoint already held is never connected again. The two
  defects that would have appeared here - a connected flag counted twice after two refreshes, and a
  refusal cleared before the source had actually connected - are pinned by tests rather than left to
  the hardware to reveal.
- **The board refreshes through the same derivation.** `MIDIStatusBoard.refresh(with:)` applies a
  report from the running client through `record(_:)`, so a list change and a fresh start produce the
  same wording; there is no second code path for the status text to drift along.
- **The service is now only calls.** `MIDIInputService` asks the tracker what to connect, performs
  exactly those `MIDIPortConnectSource` calls, records successes and refusals, prunes, and publishes.
  It publishes on the first start and on every refresh, through a new `onVerdictChanged` closure, and
  the notify block from `MIDIClientCreateWithBlock` is what triggers the refresh.
- **The model owns the published status.** `AppModel` records every verdict through
  `MIDIStatusBoard` into `@Published private(set) var midiStatus` and rebuilds the status message
  against the engine line it started with, so a refresh replaces the MIDI half of the message instead
  of appending a second copy of it.
- **What the tests pin.** `MIDISourceTrackerTests` drives the same loop the service runs and asserts:
  a source appearing after start turns `no sources found` into `1 of 1 source(s) connected`; losing the
  last source returns to `no sources found`; a second source arriving leaves the first connected; a
  refusal is still there after a refresh that still cannot connect; the same source connecting later
  removes the refusal; a refusal for a source that disappears is forgotten; an offline source is never
  attempted; a connected source is not connected twice; failures keep enumeration order; and the board
  updates from a refresh alone, with no second `start()` call.
- **Observed.** Run [`42737094402`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42737094402)
  on `8b08b44`: the macos job succeeded and all fifteen steps were green. Debug build with tests
  01:38:01 to 01:38:19, warnings at 01:38:19, `swift test` 01:38:19 to 01:38:22, release build
  01:38:22 to 01:38:35, bundle 01:38:35 to 01:38:36, launch step 12 01:38:36 to 01:38:42, audio step
  13 01:38:42 to 01:38:44, MIDI step 14 01:38:44 to 01:38:46, bootstrap step 15 01:38:46 to 01:38:47,
  job completed 01:38:51. The run published three annotations: the macOS capacity notice, the SwiftPM
  manifest warning, and the MIDI probe's own no-sources warning, so the probes behaved exactly as they
  had before the change and the runner still reports its empty source list rather than failing.

What this does not prove: that a notification ever arrives on real hardware. The notify block is a
CoreMIDI callback, and the runner has no source to plug in, so what the tests prove is the derivation
and the state machine, not that macOS delivers the notification when a controller is attached. It also
does not prove that the line is visible: nobody has looked at the window. And it does not prove the
connect path itself, which still needs a source the runner does not have.

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
8. `tools/launch_smoke.sh`, which starts the bundle, asserts the two startup markers and the probe
   timer and requires a status 0 exit, so a crash, a hang or a signal is a red step;
9. `tools/audio_smoke.sh`, which starts the audio graph from inside the app, requires a rendered voice
   and a clean exit, and reports a machine with no output device as a limitation with the app's own
   line rather than as a pass;
10. `tools/midi_smoke.sh`, which creates the CoreMIDI client and input port from inside the app,
    requires the client marker and a source count and a clean exit, and reports a machine with no MIDI
    source as a limitation with the app's own line rather than as a pass;
11. run `bash tools/bootstrap.sh --check` and fail the job if it exits with anything other than 0 (all
    present) or 1 (tools missing) or if it fails to report the toolchain, which is the smoke test for
    the script's reporting and exit codes.

What that does not cover, and this log will not pretend otherwise: the install path of
`tools/bootstrap.sh` (it installs Homebrew casks and needs sudo, so it runs only on a developer
machine, and only its check mode runs in CI); anything visual, since no screenshot is taken and no UI
test exists; anything audible, since the audio probe counts a rendered voice, which says the callback
ran but nothing about how it sounded; and the MIDI connect path, since the runner has no source to
connect to. Nobody has listened to this, played it, or clicked through it on this hardware.

## Decompilation: awaiting external access

No artifact that can be decompiled is reachable from this environment. The shell tool refused every
call again this session, so no process can be started, no path can be examined and no Ghidra run is
possible. The repository contains only docs, tools and Swift and C sources: no Mach-O, `.app`, AUv3
bundle, `.aupreset`, CAF payload, Ghidra project or prior decompilation export. Details and the exact
access required are in [`re/access-determination.md`](re/access-determination.md).

Required to resume: the Mac awake with the Freebuff desktop client connected, the app installed,
Ghidra 12.1.4 and Java 21 or newer under a persistent path, and about ten minutes for an import.

## Next actions, in order

1. Launch `SundayKeys.app` on the Mac and do the first hardware validation: see the window, read the
   MIDI status line, press Start against a real output device, plug in a controller, watch the status
   and the source list change, click through the patch, set list, effects and mapping panels, and
   listen to the effects chain. This is the only step that needs a person listening, and it is the
   only way to know that macOS actually delivers the source notification.
2. Prove the MIDI connect path on CI. The runner creates the client and the port and enumerates zero
   sources, so the connect loop has never run against an endpoint. The app can create a virtual
   source of its own with `MIDISourceCreate` and then connect to it, which would exercise the success
   branch and the tracker's connected state on a machine with no hardware; a probe that does that and
   reports the source it connected to is the next hardware-independent step.
3. MIDI refinements that need hardware: relative encoders, a foot switch, a controller that sends on
   several channels, and a controller refused by the port at runtime, which is the one refusal path
   the tracker's tests can only simulate.
4. Put the published `midiStatus` on the MIDI panel itself, so the panel says the status next to the
   source names. This waits for a way to test the view; the model already publishes the value.
5. Session scope beyond one ordered list, once there is evidence for it: the original app's session
   contents are **Unknown**, so the next step is a capture or a decompiled session type, not a guess.
6. Reconnect the host, then decompile the queued targets (`Audio.KeyboardVelocityScaling`,
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
| `3e0c3a9` | [42730684997](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42730684997) | success: build, all suites, the release build, the bundle step and the bootstrap smoke step. The bundle step ran the script and passed its plist, executable and strict signature checks. |
| `7cb9a17` | [42731763842](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42731763842) | success: build, all suites, warnings, release build, bundle step, the new launch step and the bootstrap smoke step. The launch step passed in seven seconds, which by the script's own exit conditions means both startup markers were found, the probe timer fired and the app exited 0. Annotations: the macOS capacity notice and the SwiftPM manifest warning. |
| `98e5a41` | [42731121652](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42731121652) | success: the README rows for the bundle, with the launch step not yet present. |
| `dd24771` | [42732331904](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42732331904) | success: build, all suites, warnings, release build, bundle, launch step and bootstrap. The launch step passed in seven seconds (00:59:38 to 00:59:45); the only annotations were the capacity notice and the SwiftPM manifest warning. |
| `de6a1b6` | [42732896895](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42732896895) | failure, one test, before any later step: `testAnImpossibleRateIsRejected` compared a failure carrying a NaN rate with `==`, and NaN is never equal to itself, so the case could not be asserted; the build also warned that the probe captured the audio graph in a `@Sendable` closure. Both were mine and both are fixed in `e6ae994`. |
| `e6ae994` | [42733100695](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42733100695) | success: build, all suites including `AudioStartPlanTests`, warnings, release build, bundle, launch step 12 (01:05:43 to 01:05:51), audio step 13 (01:05:51 to 01:05:54) and bootstrap. No warning annotation, so the no-device branch did not run and the graph started and rendered. |
| `8a071760` | [42733528643](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42733528643) | success: the audio start milestone write-up, with no code change to the tree above; build, all suites, warnings, release build, bundle, launch, audio and bootstrap steps all passed. Two annotations, the macOS capacity notice and the SwiftPM manifest warning. |
| `2464172` | [42734422204](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42734422204) | success: build, all suites including `MIDIStartReportTests`, warnings, release build, bundle, launch step 12 (01:16:05 to 01:16:11), audio step 13 (01:16:11 to 01:16:14), MIDI step 14 (01:16:14 to 01:16:16) and the bootstrap step at 01:16:21. Three annotations: the capacity notice, the manifest warning, and the probe's own no-sources warning, which the script publishes only after finding the client marker and a source count and seeing a 0 exit. |
| `1e71b17` | [42735307410](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42735307410) | success: the README audio and MIDI rows, with no code change to the tree above. Build 01:22:40 to 01:23:05, warnings, tests 01:23:05 to 01:23:09, release 01:23:09 to 01:23:27, bundle 01:23:27 to 01:23:29, launch step 12 01:23:29 to 01:23:36, audio step 13 01:23:36 to 01:23:39, MIDI step 14 01:23:39 to 01:23:41, bootstrap step 15 01:23:41 to 01:23:43, job completed 01:23:48. Same three annotations. |
| `38f55d5` | [42735872524](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42735872524) | success: `MIDIStatus`, `MIDIStatusBoard`, `MIDIStatusTests` and the model wiring. Build 01:27:26 to 01:27:55, warnings at 01:27:55, tests 01:27:55 to 01:27:59, release 01:27:59 to 01:28:19, bundle 01:28:19 to 01:28:21, launch step 12 01:28:21 to 01:28:28, audio step 13 01:28:28 to 01:28:31, MIDI step 14 01:28:31 to 01:28:32, bootstrap step 15 01:28:32 to 01:28:35, job completed 01:28:40. Three annotations: the capacity notice, the manifest warning and the MIDI probe's no-sources warning, so the probes behaved as before. |
| `4e231f5` | [42736399834](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42736399834) | success: the MIDI status write-up, with no code change to the tree above. Build 01:32:04 to 01:32:31, warnings at 01:32:31, tests 01:32:31 to 01:32:35, release 01:32:35 to 01:32:52, bundle 01:32:52 to 01:32:54, launch step 12 01:32:54 to 01:33:00, audio step 13 01:33:00 to 01:33:03, MIDI step 14 01:33:03 to 01:33:04, bootstrap step 15 01:33:04 to 01:33:08, job completed 01:33:14. This run published **no annotations at all** - not the capacity notice, not the manifest warning, not the probe's no-sources warning - even though the MIDI step passed. The cause was not established; the next run carried all three again, so it reads as a per-run reporting gap rather than a change in the probe. |
| `8b08b44` | [42737094402](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42737094402) | success: `MIDISourceTracker`, `MIDIStatusBoard.refresh(with:)`, the endpoint identity on a refused connect, `MIDISourceTrackerTests`, and the model wiring. Build 01:38:01 to 01:38:19, warnings at 01:38:19, tests 01:38:19 to 01:38:22, release 01:38:22 to 01:38:35, bundle 01:38:35 to 01:38:36, launch step 12 01:38:36 to 01:38:42, audio step 13 01:38:42 to 01:38:44, MIDI step 14 01:38:44 to 01:38:46, bootstrap step 15 01:38:46 to 01:38:47, job completed 01:38:51. Three annotations: the capacity notice, the manifest warning and the MIDI probe's no-sources warning. |

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
| whether audio sounds right | a rendered voice count says the callback ran, not that the output is musical | next action 1, with a person listening |
| seeing the window, reading the status line, using a real controller | need the unreachable Mac | next action 1 |
| a MIDI source being connected and played from | the client and port are created on the runner, but the runner has no source, so the connect loop never ran against an endpoint | next action 2, with a virtual source the probe creates itself |
| the MIDI status reaching a player | the text is asserted in tests and the model retains and refreshes it, but the app target has no view test and nobody has looked at the window | next action 1 |
| the source notification arriving on real hardware | the notify block is a CoreMIDI callback and the runner has no source to attach, so the refresh is exercised by tests rather than by a plug-in event | next action 1 |
| a port refusing a source at runtime | every refusal in the tests is simulated; no port has refused a real endpoint here | next action 1, with a controller the port can reject |

## Decisions recorded

| decision | rationale |
| --- | --- |
| unknown licence status decodes to `expired` | fail closed rather than unlock features on an unrecognised wire value |
| module dependency direction is labelled Inferred | section 20 measured co-occurrence, not direction |
| the original sample libraries cannot be reused | proprietary content, so the keysounds are synthesised from original partial sets |
| the render block never allocates, locks or waits | anything that can block on the audio thread becomes a click or a drop, so the queue spins the producer instead |
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
| a test that asserts the voice pool empty renders past the release | 220 ms is 10,560 frames, so a 20-block assertion was 320 frames short of the end |
| the bundle has its own identifier and version | the original is `com.sundaysounds.sundaykeys` 2.5.2 build 3367, and this is 0.5.0 build 5 of its own line, so the two can be installed side by side |
| the bundle is signed ad hoc, not for distribution | Apple silicon will not launch an unsigned bundle and there is no developer certificate here; ad-hoc signing is enough to launch locally and nothing is notarised, which the script states |
| the bundler verifies its own output | a bundle that assembles is not a bundle that is well formed, so the script lints the plist, checks the executable, verifies the signature and fails the run if any check does |
| the launch probe exits through `NSApplication.terminate` | a signal's status 143 says nothing about the run loop, while a fired timer plus status 0 proves the loop is serviced and the exit is normal |
| LaunchServices is evidence, not the pass condition | `open` cannot carry the probe environment or be captured, and it can only be stopped by signal, so a clean exit could not be shown there |
| the start decision lives in the core module | the rule is what needs asserting, and AVFoundation in the app target cannot be exercised by `swift test` on a machine with no device |
| a zero sample rate falls back to 48 kHz | macOS reports zero before the engine runs, and refusing there would make the instrument unusable on hardware that works |
| rejected rates compare by bit pattern | a NaN rate breaks synthesised equality, so the case could not be compared or asserted at all |
| the audio probe exits with its own status | 4 for a refused start, 5 for a start that rendered nothing and 6 for a lost graph let the script tell a clean refusal apart from a silent failure |
| a missing output device is a warning, not a red build | refusing cleanly is correct on a machine with no device, and the run should record the hardware it had rather than pretend either way |
| the MIDI start returns a verdict instead of returning silently | a client that could not be created and a machine with no controller both left the source list empty, so the difference between them had to become a value the caller can inspect |
| the MIDI report and its exit status are built in the core module | the report lines and the status are what a regression would break, and they are assertable without CoreMIDI, a controller or a MIDI server |
| only online MIDI endpoints are connected | an offline endpoint is still listed and counted, but a refused connect says nothing about the machine, so it must not be reported as a failure |
| a runner with no MIDI sources is a warning, not a failure | an empty source list is a fact about the hardware; treating it as a failure would either hide the client-creation proof or turn every runner red |
| the MIDI probe separates a missing client from a missing port | 4 and 5 name the call that failed, so a red step says whether CoreMIDI was unavailable or the input port could not be made |
| an unnamed MIDI source is identified by its unique id | two unnamed endpoints are otherwise indistinguishable in a report, which is exactly when a report is needed |
| the MIDI verdict becomes a status value the model keeps | the verdict was read for one expression and dropped, which is exactly how a refused client vanished; a board makes it state that a test can hold onto |
| the MIDI status wording lives in the core module | here the wording is the behaviour, and the app target cannot be asserted by `swift test` on any machine |
| a client with no sources is not a failure | an empty list is a fact about the hardware; calling it a failure would accuse a working client and hide the one thing the probe proved |
| only the first refused connect is shown in the status | one line cannot list several, and the report already fixes the order, so the first failure is the one the player is told about |
| the status rides on the existing status message | the app target has no tests, so a new panel would ship unverified; the published `midiStatus` is what a later, testable panel will read |
| a refused connect is keyed by endpoint, not by name | a name cannot identify a source that may be unnamed, duplicated or renamed between refreshes, and the tracker has to know which refusal still applies |
| the tracker owns the connect rules, not the service | the rules are what a regression would break, and CoreMIDI in the app target cannot be exercised by `swift test` on a machine with no source |
| a refusal is kept while its source is present and unconnected | a notification that changes nothing must not erase a real fault, and a device that recovers must stop being accused |
| the status is recomputed from a report, not patched in place | one derivation for a start and a refresh means the wording cannot drift between pressing Start and plugging a controller in |

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
| `27b1999` | the bundle milestone in this log and the README; superseded by the next push before its run reported |
| `98e5a41` | README rows for the bundle; verified by run `42731121652` |
| `7cb9a17` | `LaunchProbe`, `tools/launch_smoke.sh` and the CI launch step; verified by run `42731763842` |
| `d464492` | the launch milestone write-up; verified by run `42732331904` |
| `dd24771` | README launch rows and the local run instructions; verified by run `42732331904` |
| `de6a1b6` | `AudioStartPlan`, the device check, `tools/audio_smoke.sh` and the CI audio step; failed run `42732896895` |
| `e6ae994` | bit-pattern equality for rejected rates and the graph out of the sendable timer; verified by run `42733100695` |
| `8a071760` | the audio start milestone in this log and the run rows; verified by run `42733528643` |
| `2464172` | `MIDIStartReport`, the endpoint reader, `start()` returning a verdict, `tools/midi_smoke.sh` and the CI MIDI step; verified by run `42734422204` |
| `f60982c` | the MIDI start milestone in this log; superseded by the README push before its run was read |
| `1e71b17` | README audio and MIDI rows; verified by run `42735307410` |
| `38f55d5` | `MIDIStatus`, `MIDIStatusBoard`, `MIDIStatusTests` and the model wiring that keeps the verdict; verified by run `42735872524` |
| `4e231f5` | the MIDI status milestone in this log and its run rows; verified by run `42736399834` |
| `8b08b44` | `MIDISourceTracker`, the endpoint identity on a refused connect, `MIDIStatusBoard.refresh(with:)`, `MIDISourceTrackerTests` and the service and model wiring; verified by run `42737094402` |

Earlier analysis commits, the toolchain work and the corpus extractors are listed in
[`sunday-keys-2.5.2-analysis.md`](sunday-keys-2.5.2-analysis.md).
