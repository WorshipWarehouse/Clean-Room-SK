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
| Build, MIDI connect | the port's connect loop runs on a machine with no hardware: the probe publishes a virtual source, the engine enumerates it, the port connects it and the status says so | `Sources/SundayKeysCore/MIDI/MIDIConnectProbe.swift`, `Sources/SundayKeysApp/MIDI/VirtualMIDISource.swift`, run `42740507134` |
| Build, session scope | the patch that was playing is remembered beside the bank and resolved at launch with a named fallback, and the set-list head follows it | `Sources/SundayKeysCore/Session/SessionMemory.swift`, run `42819855234` |
| Build, session relaunch | the bundle is started three times against one folder - the write, the relaunch and a hint naming a deleted patch - and each run's own lines are asserted | `tools/session_smoke.sh`, runs `42821991600` and `42821991761` |
| Build, click | a tempo clock in the core module and a click the render thread adds after the patch's effects, so a cue is never reverberated and no voice is borrowed | `Sources/SundayKeysCore/Audio/Metronome.swift`, runs `42824933255` and `42824933210` |
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
10. `tools/midi_smoke.sh`, which creates the CoreMIDI client and input port from inside the app, publishes a virtual
source of its own and requires the engine to enumerate and connect it,
    requires the client marker and a source count and a clean exit, and reports a machine with no MIDI
    source as a limitation with the app's own line rather than as a pass;
11. run `bash tools/bootstrap.sh --check` and fail the job if it exits with anything other than 0 (all
    present) or 1 (tools missing) or if it fails to report the toolchain, which is the smoke test for
    the script's reporting and exit codes.

What that does not cover, and this log will not pretend otherwise: the install path of
`tools/bootstrap.sh` (it installs Homebrew casks and needs sudo, so it runs only on a developer
machine, and only its check mode runs in CI); anything visual, since no screenshot is taken and no UI
test exists; anything audible, since the audio probe counts a rendered voice, which says the callback
ran but nothing about how it sounded; and the MIDI receive path, since nothing has ever been sent from the virtual source. Nobody has listened to this, played it, or clicked through it on this hardware.

## Decompilation: awaiting external access

No artifact that can be decompiled is reachable from this environment. The shell tool refused every
call again this session, so no process can be started, no path can be examined and no Ghidra run is
possible. The repository contains only docs, tools and Swift and C sources: no Mach-O, `.app`, AUv3
bundle, `.aupreset`, CAF payload, Ghidra project or prior decompilation export. Details and the exact
access required are in [`re/access-determination.md`](re/access-determination.md).

Required to resume: the Mac awake with the Freebuff desktop client connected, the app installed,
Ghidra 12.1.4 and Java 21 or newer under a persistent path, and about ten minutes for an import.

## MIDI connect milestone: the connect path runs with no hardware

The status followed the source list, but the connect call itself had still never run anywhere: the
runner creates the client and the port, enumerates zero sources and says so. That was next action
2, and it is now done.

- **The probe publishes the source it connects to.** With
  `SUNDAYKEYS_PROBE_MIDI_CONNECT=1` the app creates a CoreMIDI client and a virtual source with
  `MIDISourceCreateWithProtocol` before it starts the engine, so the engine's own
  `MIDIGetNumberOfSources` finds that endpoint and its `MIDIPortConnectSource` runs against a live
  source with no controller attached. `VirtualMIDISource` is the only place those calls live, and it
  disposes the source and its client afterwards.
- **The classification is core logic.** `MIDIConnectProbe` names what happened: the port connected
  the probe's own source, the port refused it, the start never created a client or port, the system
  would not publish a source, the engine never listed it, or it was listed but never attempted.
  Each has its own exit status (0, 6, 4 or 5, 7, 8, 9) and its own line, and the status it prints is
  derived through `MIDIStatus`, so the probe cannot disagree with what pressing Start would show.
- **A late listing is not a missing source.** If the engine's first enumeration misses the source the
  probe just created, `MIDIInputService.refresh()` takes one more pass before the verdict is fixed.
- **The step proves the connect rather than assuming it.** `tools/midi_smoke.sh` runs two probes.
  The start probe is unchanged and still publishes the no-sources warning on a machine with nothing
  attached, so the hardware claim stays honest. The connect probe fails the step unless the app
  reports the virtual source created, the engine enumerating at least one source, the port connecting
  at least one, and a status of the form `MIDI ready, N of M source(s) connected`; the counts and the
  status are also published as a notice annotation, because the job log download stops before the
  later steps.
- **What the tests pin.** `MIDIConnectProbeTests` drives the same tracker loop the service runs: a
  source the engine enumerates and the port connects proves the path; a refused connect is reported
  as a refusal, not a connection; a system that will not publish a source leaves the path unproven; a
  source the engine never lists is a failure rather than a quiet no-sources state; a listed but never
  attempted source is reported as idle; a client that cannot be created is still reported; and the
  six outcomes have six distinct exit statuses and six distinct lines.

- **Observed.** Run
  [`42740507134`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42740507134) on
  `7d5cd17`: the macos job succeeded and all fifteen steps were green. Debug build with tests
  02:07:20 to 02:07:51, warnings at 02:07:51, `swift test` 02:07:51 to 02:07:54, release build
  02:07:54 to 02:08:10, bundle 02:08:10 to 02:08:13, launch step 12 02:08:13 to 02:08:21, audio step
  13 02:08:21 to 02:08:24, MIDI step 14 02:08:24 to 02:08:27, bootstrap step 15 02:08:27 to
  02:08:29, job completed 02:08:35. The MIDI step published a notice annotation reading "MIDI
  connect probe: virtual source created, engine enumerated 1 source(s), connected 1, status: MIDI
  ready, 1 of 1 source(s) connected", so on this runner the app published a virtual CoreMIDI source,
  its own enumeration found one source, its port connected one and the status line it derived says a
  source is connected. The same run carried the start probe's warning, "this machine has no MIDI
  sources: the start probe proved the client and input port were created and the source list was
  empty", which is that machine's hardware answer and not a pass. Four annotations in all: the
  connect notice, the start probe's warning, the SwiftPM manifest warning and the capacity notice.
- **Three failed attempts, all mine.** Run `42739979656` on `78ce36e` failed in the debug build with
  "value of type 'MIDIConnectProbe' has no member 'exitCode'", because the status was defined on
  the outcome and the probe did not forward it. Run `42740177399` on `5a2e4c6` built and then failed
  one new test that expected 4 for a refused input port where the existing failure type says 5, so
  the expectation was corrected in `7b8567f`. Run `42740337754` on `7b8567f` is the run that proved
  the connect first: its MIDI step failed and the annotation it published reads "the MIDI status
  does not report a connected source: MIDI ready, 1 of 1 source(s) connected pid=2111", so the
  probe had created, enumerated and connected its own source and only the script's comparison was
  wrong, because the marker stream appends its pid to every line. That parse is fixed in `7d5cd17`.

What this does not prove: that anything is ever sent from the source. The port holds a source the
app published itself, so the receive path and a real controller's messages are still unexercised,
and no person has seen the status line or heard a note.

## MIDI receive, end to end

The connect probe proved the port accepted a source; nothing had ever travelled through it, so
`MIDIReceived` -> `MIDIMessage.parse` -> `LayerRouter` had only ever run on bytes a unit test built.
`tools/midi_smoke.sh` now has a third phase that runs only after the connect probe has proved
itself: the app builds a packet list and pushes it through `MIDIReceived`, the engine's own input
port delivers it back, and the app prints what its input block parsed out of the packet, what layer
routing did with the note, and its verdict. The script reads those lines and the exit status; it
never claims the parse itself.

- **One packet can carry several messages, and the app dropped them.** The probe sends a note on, a
  note off and a control change in one packet list, and the first end-to-end attempt parsed only the
  note on: `MIDIInputService.receive` read `packet.data.0` to `packet.data.2` and never looked at the
  rest of the packet, so every message after the first was lost. Run `42742938963` reported it as
  `midi smoke check: the app reported a connected source but exited with 10 instead of 0`, 10
  meaning "no note off". It is a defect a controller would have hit: any device that packs more
  than one message into a packet would have had the later ones silently dropped. It was fixed
  rather than asserted around. `MIDIMessage.parseAll` walks a whole packet - a status byte
  re-applied as running status, real-time bytes skipped, a note on with velocity 0 read as a note
  off, the walk stopping at a truncated tail - and the input block now hands it the whole packet
  through `withUnsafeBytes(of: packet.data)`. `Tests/SundayKeysCoreTests/MIDIMessageParseAllTests.swift`
  pins the multi-message packet, running status, the zero-velocity note off, the truncated tail and
  the real-time bytes, and checks that a one-message packet parses identically through both entry
  points.
- **The expectation owns the bytes.** `MIDIReceiveProbe` in the core module builds the packets,
  counts what came back and decides the verdict, so the send, the counting and the tests cannot
  drift apart. Counting filters on the expected note, controller and channel, so a packet from
  anywhere else on the machine cannot stand in for the probe's own.
- **The exit status names the first thing missing**: 0 every packet parsed, 10 no note off, 11 no
  control change, 12 nothing received, 13 no note on; a connect that never proved itself keeps the
  status it already had (4 to 9).
- **The start probe's warning is untouched.** It still publishes "this machine has no MIDI sources:
  the start probe proved the client and input port were created and the source list was empty",
  because it runs before any source of the probe's own exists, and connect evidence and receive
  evidence are separate lines: a `MIDI connect probe:` notice and one `MIDI receive probe:` notice
  per message.

### The runs

Run [`42744377274`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42744377274) on
`dc78b8e` is the first green run with the receive phase: all fifteen steps passed and the job
published, in the app's own words,

    MIDI receive probe: sent note on 60 velocity 100 on channel 1
    MIDI receive probe: sent note off 60 on channel 1
    MIDI receive probe: sent control change 1 = 64 on channel 1
    MIDI receive probe: the app received 3 message(s): 1 note on, 1 note off, 1 control change
    MIDI receive probe: received note on 60 velocity 100 on channel 1
    MIDI receive probe: received note off 60 velocity 64 on channel 1

beside the connect notice ("MIDI connect probe: virtual source created, engine enumerated 1
source(s), connected 1, status: MIDI ready, 1 of 1 source(s) connected") and the no-sources warning
quoted above. The `sent` lines are the app's report that `MIDIReceived` accepted a packet and the
`received` lines are its input block's parse of what came back through its own port, so the packet
crossed CoreMIDI rather than a shortcut in the probe.
Step timings read from that job: setup 02:40:35-02:40:36, checkout to 02:40:38, toolchain to
02:40:42, dependencies to 02:40:45, debug build to 02:41:09, tests to 02:41:12, release build to
02:41:30, bundle to 02:41:31, launch to 02:41:38, audio probe to 02:41:40, "Probe the MIDI start"
02:41:40-02:41:43, bootstrap check to 02:41:46, job complete 02:41:52.

GitHub attaches at most ten annotations to a step, and that run's three per-send `send status 0`
notices spent three of them, so the layer-routing line and the probe's verdict never appeared: the
step passed, but a reader could not see the routing result. `tools/midi_smoke.sh` now publishes
only the message lines, which leaves them inside the cap, and the assertions did not change.
Run [`42744820518`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42744820518) on
`16b2c9f` is green with that trim and publishes the rest of the evidence:

    MIDI receive probe: received note on 60 velocity 100 on channel 1
    MIDI receive probe: received note off 60 velocity 64 on channel 1
    MIDI receive probe: received control change 1 = 64 on channel 1
    MIDI receive probe: layer routing sent note 60 to 1 of 2 enabled layer(s)
    MIDI receive probe: outcome: the app parsed every packet: 1 note on, 1 note off, 1 control change

Its timings: setup 02:44:52-02:44:53, checkout to 02:44:55, toolchain to 02:44:57, dependencies to
02:45:00, debug build to 02:45:17, tests to 02:45:21, release build to 02:45:36, bundle to 02:45:37,
launch to 02:45:43, audio probe to 02:45:45, "Probe the MIDI start" 02:45:45-02:45:47, bootstrap
check to 02:45:49, job complete 02:45:51.

What this does not show: a physical controller, a window, or a second device packing messages into
one packet - the multi-message case is covered by the probe's own packet list and the parse tests.

### Runs read this pass

| run | head | what it actually did |
| --- | --- | --- |
| `42741926197` | `b55b65d` | never started: the run stayed `queued` with no job, no steps and no annotations, so it carries no evidence and is recorded as unstarted rather than as a pass |
| `42742678831` | `d3bdd43` | step 5 failed 02:25:50-02:26:14 on a byte-count type in the virtual source's send; fixed in `72c5272` |
| `42742797771` | `72c5272` | step 5 failed 02:26:52-02:27:21: `error: cannot convert value of type 'UInt32' to expected argument type 'Int'` in `VirtualMIDISource.swift`, fixed in `07e5d4f` |
| `42742938963` | `07e5d4f` | steps 1-13 passed, step 14 failed 02:29:22-02:29:27 with `midi smoke check: the app reported a connected source but exited with 10 instead of 0` - the multi-message packet defect above |
| `42744377274` | `dc78b8e` | green: the app received and parsed the note on, note off and control change |
| `42744820518` | `16b2c9f` | green, and the routing and verdict lines are published as well |

## Session scope milestone: a launch resumes where the service left off

The bank keeps the patches, their effects, the controller layouts and the set list with its
play head, so a relaunch already found every sound and every service. It did not keep the
one thing a player asks for first: which patch was playing. `AppModel.loadBank()` assigned
`selectedPatchID = first.id` unconditionally, so a player who had been rehearsing the fourth
song was put back on the first one at every launch. That was next action 4, and it is now
decided and implemented.

- **The hint lives beside the bank, not in it.** `SessionMemory { lastPatchID }` is written to
  `session.json` in the same Application Support directory as `patches.json`. Keeping it out
  of the bank means the bank's own format and its version 4 documentation do not move, a bank
  from an older build still loads untouched, and a hint that cannot be read cannot stop the
  bank from loading.
- **Three outcomes, each named.** `SessionScope.restore(memory:patches:)` returns
  `remembered`, `fallback(because:)` - with `.nothingRemembered` or `.patchMissing` - or
  `emptyBank`. A first launch and a deleted patch therefore read differently from a resume
  in the status line instead of every case looking like a resume that happened to land on
  the first patch.
- **A broken hint is not an error.** `SessionStore.load()` returns nil for a missing,
  unreadable or malformed file, because the memory only describes the previous launch; the
  cost of a bad hint is the resume and nothing else.
- **The head follows the restored sound.** `Setlist.alignHead(to:)` moves the play head onto
  the first slot that plays the restored patch, so the position shown and the sound playing
  agree. A patch that is in no slot leaves the head alone: the player chose it directly, and
  their service order is not rewritten.
- **Recording never rides on the bank's save.** The model writes the hint on every path that
  changes the selection - patch switch, add, delete, set-list play, set-list step - and again
  before a manual bank save. The write is best effort: it cannot fail a switch, and nothing
  in the session depends on it.

`SessionMemoryTests` drives those cases directly: no memory, memory naming a present patch,
memory naming a deleted patch, an empty bank, the three lines, the round trip through its own
file, a corrupt file degrading to nothing remembered, the file sitting beside the bank, the
head moving to the restored patch, and the head staying put for a patch that is in no slot.

**Observed.** Run [`42819855234`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42819855234)
on `7d89365`: the run concluded success, with 15 of 15 steps passing.

- `Set up job`: success 12:55:19 to 12:55:20
- `Run actions/checkout@v5`: success 12:55:20 to 12:55:22
- `Report the toolchain`: success 12:55:22 to 12:55:25
- `Resolve dependencies`: success 12:55:25 to 12:55:29
- `Build (debug, with tests)`: success 12:55:29 to 12:55:53
- `Report warnings`: success 12:55:53 to 12:55:53
- `Test`: success 12:55:53 to 12:55:56
- `Build (release)`: success 12:55:56 to 12:56:18
- `Bundle the app`: success 12:56:18 to 12:56:20
- `Launch the app`: success 12:56:20 to 12:56:26
- `Probe the audio start`: success 12:56:26 to 12:56:29
- `Probe the MIDI start`: success 12:56:29 to 12:56:31
- `Verify the bootstrap script`: success 12:56:31 to 12:56:35
- `Post Run actions/checkout@v5`: success 12:56:35 to 12:56:38
- `Complete job`: success 12:56:38 to 12:56:39

The job published these annotations, verbatim:

- none

What this does not show: nobody has launched the app twice on a Mac with a memory file
present, so the resume has been proven by unit tests and by the wired model compiling and its
suites passing, not by a relaunch; and no window has been seen, so the line it produces has
been read in a test and never on a screen.

## Relaunch milestone: a launch that resumes, proven on disk

The resume was implemented and unit-tested, but no process had ever started the app
twice against one Application Support folder, so the hint file had never been read
back by a second launch. Runs `42821991600` and `42821991761` close that:
`tools/session_smoke.sh` starts the bundle three times with one `HOME`, and each run
has to print what it did.

- **The write run** saves a bank of three patches and a hint naming the third, then
  prints the folder it used, so the step reports which files the launch read.
- **The relaunch** is a second process: `SessionProbe` constructs the same `AppModel` the
  window constructs, so `loadBank`, `SessionScope.restore` and the head alignment run over
  the files the first process left. It prints the status line, the selected patch and the
  head's position, and the script requires `Resumed Rehearsal Pad, 3 patches and 3 set
  list slots` and `play head on slot 3 of 3`.
- **The missing-patch run** writes a hint naming a patch the bank does not have, and the
  launch has to print `Opened Sunday Keys: the patch from the last launch is gone` and
  stand on slot 1, so the fallback is a sentence and a position rather than a branch.
- **The probe decides nothing.** It reports, and its exit status is a comparison of that
  report against the expected value; the script asserts the printed lines too.

The build run is green with the Swift suite at 13:10:31-13:10:34, and the session run is
green with the probe at 13:10:30-13:10:33. The probe had to become its own workflow: the
build workflow's token may delete a file under `.github/workflows` but may not create or
update one, so adding the step there was rejected by the remote with `refusing to allow a
GitHub App to create or update workflow`. That refusal is in run
`42821552394` for anyone who wants to see it.

What this does not prove: that a person sees the window open on the remembered patch.
The probe proves the state the window is built from, on a machine with no display.

## Click milestone: a pulse the render thread keeps

The instrument could play a chord but had no pulse: every tempo thought in this
repository ended at "tempo authority: Unknown", and the next action list was all
hardware. A player rehearsing without a click has to keep the time themselves, so
a tempo clock was the next thing that could be built and proved without a
controller, a window or the unreachable Mac.

- **The clock is core logic.** `Metronome` turns bpm into frames at the graph's
  own sample rate and starts a click on the frame a beat is due, so a beat is not
  a timer callback. At 120 bpm and 48 kHz the tests find onsets at frames 0,
  24000, 48000, 72000 and 96000 exactly, and the downbeat is louder than the
  beats inside the bar.
- **Settings cross without a lock.** The whole settings value is published through
  a seqlock over two `UInt64`s using the `CSync` atomics the effects chain already
  uses, so switching the click on cannot make the render block lock or allocate.
- **A tempo change does not move the beat already on its way.** The beat that was
  due still lands and the interval after it uses the new tempo, which the tests
  show by turning 120 into 60 bpm on the second beat and finding the third at
  frame 72000 instead of 48000.
- **Switching it off is a stop, not a cut.** The click in flight finishes its
  envelope and nothing is scheduled after it, so the tests find one onset and then
  exact silence, and the probe waits past the next beat to prove none arrived.
- **The cue is not part of the patch.** The engine adds the click after the effect
  chain, so a patch's delay and reverb never echo it, and it never borrows a voice.
- **Ten cases measure it.** `Tests/SundayKeysCoreTests/MetronomeTests.swift`
  renders frames and asserts where the sound is: the beat grid, both accents, a bar
  of three, a silent clock, the tempo change, the stop, the clamps, the bypass and
  the voice count.

**Observed.** Run [`42824933255`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42824933255) on `f6d2539c`: the build job concluded
success.

- `Build (debug, with tests)`: success 13:29:31 to 13:29:58 UTC, which compiled
  `Metronome.swift`, the engine change and `MetronomeTests.swift`.
- `Test`: success 13:29:58 to 13:30:01 UTC, which ran every suite including the
  ten click cases.
- `Build (release)`: success 13:30:01 to 13:30:21 UTC, and `Launch the app`: success
  13:30:24 to 13:30:32 UTC.
- `Probe the click` is not a build step: run [`42824933210`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42824933210) is the click
  workflow on the same commit, and its `Probe the click` step was success
  13:30:12 to 13:30:16 UTC. That step only passes after the app prints the
  click on, at least two beats counted and none after the stop, so it is the
  running graph rendering the cue rather than a compile.

What this does not prove: that a person has heard it. The probe counts the beats
the render thread started on the runner's output device; nobody has listened to a
click, and no window has been looked at.


## Patch document milestone: a sound can leave the bank as a file

The bank has always been one file, so a single patch had no way out of it. A player who
wanted to carry one sound to another Mac, mail it to a bandmate, or keep a copy before
editing had nothing to carry: the only export was the whole bank, and a whole bank drags
the set list and every other sound with it. That was the gap after the click milestone,
and it is now closed.

- **A document, not a bare patch.** `PatchDocument` is `format`, `version` and the patch,
  because a reader has to tell a patch file from a bank, from unrelated JSON, and from a
  document a later build wrote. `format` is `sundaykeys-cleanroom.patch`; this build
  writes version 1 and reads version 1. The original app's preset format is recorded in
  the analysis as **Unknown**, so this envelope is this implementation's own shape
  rather than a reproduction of theirs.
- **Five refusals, each with its own sentence.** An unreadable file, a file that is not a
  JSON object, a JSON object that is not this format, a version this build does not know,
  and a document whose patch will not decode are five different problems;
  `PatchDocumentFailure` names which one happened. The version is checked before the
  patch is decoded, so a later format is refused rather than partly read.
- **The keys are sorted.** The same patch produces the same bytes, so an export is
  diffable and a round trip can be asserted byte for byte.
- **A file in a folder of its own.** `PatchTransfer` writes into
  `Application Support/SundayKeysCleanRoom/Patch Exports`, creating the folder, so an
  export never touches the bank it came from. The filename comes from the patch name:
  anything that is not a letter, digit, dash or underscore becomes a dash, runs collapse,
  and an empty name still names a file.
- **An import never overwrites.** `PatchAdoption.adopt` gives a colliding id a fresh one
  and a colliding name a suffix, so importing a document over the patch the player is
  playing adds a second sound instead of changing the first under their hands.
- **Twelve cases assert it.**
  `Tests/SundayKeysCoreTests/PatchDocumentTests.swift` round trips a patch with an edited
  layer gain, transpose, EQ and reverb, and proves the encoding is stable; refuses a
  foreign format by name, a missing format field, version 2, version 0, a non-JSON file
  and an envelope with a broken patch; writes and reads through a real directory and
  proves the folder is created; refuses a missing file with a typed error; checks the
  filename rules; and checks that adopting a copy keeps the original patch, that a fresh
  patch keeps its identity, and that importing the same document twice yields `Twice`
  and `Twice 2`.

**Observed.** Run [42829541319](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541319) on `59a5cdc`: the build job concluded success
with every step green. `Build (debug, with tests)` 13:59:09 to 13:59:29 compiled the new
core file and the new suite, `Test` 13:59:29 to 13:59:32 ran every suite including the
twelve cases, `Build (release)` 13:59:32 to 13:59:50 followed, `Launch the app` 13:59:52
to 13:59:59 started the bundle, and the job completed at 14:00:09. The same head's click
workflow, run [42829541147](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541147), stayed green with the new file
in the tree, and its session workflow, run
[42829541256](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541256), did too.

The first attempt at the probe was run
[42829541318](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541318) on the same head, and it failed: `Probe the
patch transfer` ran 13:59:43 to 14:00:05 and the step's annotation was the script's own
line, because the probe had been committed before the call site that runs it. The wiring
commit `271844d` added that call site, the model's two methods and the window's row, and the
probe step then passed in run [42830474030](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830474030) before this write-up was pushed.

**What this does not establish.** Nobody has pressed the two buttons: the probe calls
`PatchTransfer` and `PatchAdoption` directly in the app's own process and folder, which
proves the file round trip, the refusals and the adoption rule, but not the buttons'
layout on a screen, the panel's readability, or that a player would find them where the
transport row puts them. It also says nothing about the original app's preset format,
which remains **Unknown** and uncompiled against; two clean-room documents did not
cross machines, because the transfer here is one process writing and reading its own
file in one Application Support folder.

## Arpeggiator milestone: six styles, stepped and asserted

The inventory names `ArpeggiatorStyleApi` with six styles and records their behaviour as
**Unknown**. Ordering is the one part of stepped playback that needs no capture: it is a pure
function of the held notes and the style, so it can be written from the recorded names and proved
on a runner without hearing a note.

- **`docs/re/arpeggiator.md`** states what is Observed (the six style names; `MidiEffectApi`'s
  octaveUp, easyChord, arpeggiator, sequencer; `SyncOptionApi` subdivision and frequency) and what
  stays **Unknown**: the step rate and whether it follows the patch tempo, the octave span, gate
  length, swing, latch, what a single note does, and the values behind `SubdivisionApi`'s names.
  None of it is guessed at.
- **`Arpeggiator`** owns no clock and makes no sound: it answers which notes sound on the next
  step, and a caller that owns a clock asks it once per step. `up` and `down` walk the held notes
  and wrap; `upDown` and `downUp` turn without repeating the note at either end; `random` draws one
  note per step from a seeded SplitMix64 generator, so a run is reproducible; `chord` sounds every
  held note ascending. Notes are deduplicated and ordered by pitch, an empty pattern returns
  nothing and does not advance, and changing style restarts the pattern.
- **`ArpeggiatorTests`** asserts exact step sequences, not that the path ran: five steps of `up` and
  of `down`, six of each turning style, both two-note turns, `chord` ordering, an empty pattern
  leaving the cursor at the first step, releasing the current note keeping the cursor inside the
  shorter pattern, a repeated hold not lengthening the pattern, a fixed seed reproducing `random`
  and reaching every held note, `random` never returning an unheld note, and every style being
  covered - fifteen cases in all.

**Observed.** Run [42851404966](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404966)
on `3098d9b6`: the build job concluded success with every step green. `Build (debug, with tests)`
16:07:41 to 16:07:57 compiled `Arpeggiator.swift` and the new suite, `Test` 16:07:57 to 16:08:01
ran every suite including the fifteen arpeggiator cases, `Build (release)` 16:08:01 to 16:08:16
followed, `Bundle the app` 16:08:16 to 16:08:17, `Launch the app` 16:08:17 to 16:08:23, the audio
probe 16:08:23 to 16:08:25, the MIDI probe 16:08:25 to 16:08:27 and the bootstrap check 16:08:27 to
16:08:28; the job completed at 16:08:31. The same head's session workflow, run
[42851404845](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404845), stayed
green (release 16:07:46 to 16:08:16, bundle 16:08:16 to 16:08:18, probe 16:08:18 to 16:08:20); so
did the click workflow, run
[42851404693](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404693) (release
16:08:03 to 16:08:32, probe 16:08:35 to 16:08:39), and the patch transfer workflow, run
[42851404757](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42851404757) (release
16:08:06 to 16:08:35, probe 16:08:37 to 16:08:39).

**What this does not establish.** No note was heard: the tests prove ordering and state, and a
runner can judge neither the sound nor the feel. No step clock exists yet, so nothing here says how
fast a pattern moves or whether it follows the patch tempo; the original's own stepping stays
**Unknown** until a capture. The six style names are the only thing this milestone took from the
record, and every rule in it is this repository's own and is replaceable.

## Next actions, in order

1. **A controller on a real Mac.** Every MIDI packet so far came from the probe's own virtual
   source. A physical device is the only way to see a real packet list, a real source name and
   what a controller sends when its knobs move; the virtual path is green, so this is
   validation rather than a blocker.
2. **Hardware MIDI refinements.** Channel filtering, program change onto the patch index and
   the learned controller layout all run on the virtual path now; untested on hardware are a
   device that sends running status, several messages per packet, or an active-sensing stream.
3. **The panel status.** The MIDI status line and the routing behaviour have never been looked
   at on a screen; a window and a person are what is missing, not code.
4. **A relaunch on a real Mac.** The on-disk resume runs in CI now: run
   `42821991761` started the app three times against one folder, and the second launch
   printed the resumed patch with the play head on its slot. What is still missing is a
   person watching the window open on that patch, which needs the unreachable Mac.
5. **Decompilation of the next targets** stays blocked on host access to the original binary;
   see `docs/re/access-determination.md`.

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
| `0d3f376` | [42737489752](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42737489752) | success: the source-tracking write-up, with no code change to the tree above. Build 01:41:00 to 01:41:17, warnings at 01:41:17, tests 01:41:17 to 01:41:21, release 01:41:21 to 01:41:34, bundle 01:41:34 to 01:41:36, launch step 12 01:41:36 to 01:41:42, audio step 13 01:41:42 to 01:41:44, MIDI step 14 01:41:44 to 01:41:45, bootstrap step 15 01:41:45 to 01:41:47, job completed 01:41:51. Three annotations: the capacity notice, the manifest warning and the MIDI probe's no-sources warning. |
| `78ce36e` | [42739979656](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42739979656) | failure in the debug build: "value of type 'MIDIConnectProbe' has no member 'exitCode'". The status was defined on the outcome and the probe did not forward it; fixed in `5a2e4c6`. |
| `5a2e4c6` | [42740177399](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42740177399) | failure in the tests: `testEveryProbeOutcomeHasItsOwnExitStatusAndLine` expected 4 for a refused input port where `MIDIStartFailure` says 5. The expectation was wrong, not the status; fixed in `7b8567f`. |
| `7b8567f` | [42740337754](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42740337754) | failure in the MIDI step, after build, tests, release, bundle, launch (02:06:22 to 02:06:27) and audio (02:06:27 to 02:06:29) passed. The step's annotation reads "the MIDI status does not report a connected source: MIDI ready, 1 of 1 source(s) connected pid=2111", so the probe had created, enumerated and connected its own source and only the script's comparison failed on the pid suffix. Fixed in `7d5cd17`. |
| `7d5cd17` | [42740507134](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42740507134) | success: `MIDIConnectProbe`, `VirtualMIDISource`, `MIDIInputService.refresh()`, the connect probe and `MIDIConnectProbeTests`. Build 02:07:20 to 02:07:51, warnings at 02:07:51, tests 02:07:51 to 02:07:54, release 02:07:54 to 02:08:10, bundle 02:08:10 to 02:08:13, launch step 12 02:08:13 to 02:08:21, audio step 13 02:08:21 to 02:08:24, MIDI step 14 02:08:24 to 02:08:27, bootstrap step 15 02:08:27 to 02:08:29, job completed 02:08:35. A notice annotation records the proof: virtual source created, one source enumerated, one connected, status `MIDI ready, 1 of 1 source(s) connected`. The start probe's no-sources warning was published in the same run, and there were four annotations in all. |
| `3b5c0bd` | [42827692945](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42827692945) | success: the click milestone's write-up with the new window controls. `Build (debug, with tests)` 13:47:16 to 13:47:43, `Test` 13:47:43 to 13:47:47, `Build (release)` 13:47:47 to 13:48:04, `Launch the app` 13:48:06 to 13:48:12, job completed 13:48:24. |
| `3b5c0bd` | [42827695399](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42827695399) | success, after a long queue: the click workflow on the same head. `Build (release)` 13:52:15 to 13:52:41, `Bundle the app` 13:52:41 to 13:52:43, `Probe the click` 13:52:43 to 13:52:48, job completed 13:52:50. |
| `59a5cdc` | [42829541319](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541319) | success: `PatchDocument`, `PatchTransfer`, `PatchAdoption` and the twelve cases in `PatchDocumentTests`. `Build (debug, with tests)` 13:59:09 to 13:59:29, `Test` 13:59:29 to 13:59:32, `Build (release)` 13:59:32 to 13:59:50, `Launch the app` 13:59:52 to 13:59:59, job completed 14:00:09. |
| `59a5cdc` | [42829541318](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541318) | failure: `Probe the patch transfer` 13:59:43 to 14:00:05, because the probe was pushed before the call site that runs it existed. Fixed in `271844d`, where the same probe step passed in run `42830474030`. |
| `59a5cdc` | [42829541147](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541147) | success: the click workflow, still green with the new core file. `Probe the click` 13:59:40 to 13:59:46, job completed 13:59:47. |
| `59a5cdc` | [42829541256](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42829541256) | success: the session resume probe on the same head. `Probe the session resume` 13:59:39 to 13:59:42, job completed 13:59:43. |
| `271844d` | [42830474030](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830474030) | the wiring commit: `PatchTransferSection`, the model's export and import, the probe's call site, and the probe itself passing on the runner before either commit was pushed. |
| `dd5ebdef` | [42830844094](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830844094) | success: the final head. Debug build with tests 14:07:14 to 14:07:39, warnings at 14:07:39, `Test` 14:07:39 to 14:07:42, release 14:07:42 to 14:08:05, bundle 14:08:05 to 14:08:08, launch 14:08:08 to 14:08:16, audio probe 14:08:16 to 14:08:19, MIDI probe 14:08:19 to 14:08:21, bootstrap check 14:08:21 to 14:08:23, job completed 14:08:29. |
| `dd5ebdef` | [42830843975](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830843975) | success: the click probe on the final head. Release 14:07:21 to 14:07:56, bundle 14:07:56 to 14:07:58, `Probe the click` 14:07:58 to 14:08:04, job completed 14:08:06. |
| `dd5ebdef` | [42830844138](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830844138) | success: the session resume probe on the final head. Release 14:07:08 to 14:07:37, bundle 14:07:37 to 14:07:39, `Probe the session resume` 14:07:39 to 14:07:43, job completed 14:07:45. |
| `dd5ebdef` | [42830846119](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42830846119) | success: the patch transfer probe on the final head, the step that failed in 42829541318. Release 14:07:06 to 14:07:32, bundle 14:07:32 to 14:07:34, `Probe the patch transfer` 14:07:34 to 14:07:36, job completed 14:07:38. |

**What the final head's runs do not establish.** Every step above ran on a runner, not on a person's Mac: nobody has pressed `Export patch` or `Import patch` in a window, no patch file has crossed between two machines, and the document format is this implementation's own invention rather than the original app's preset format, which the analysis still records as **Unknown**.

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
| a source being played from | the port connects a source the probe published, but nothing has ever been sent through it, so the receive path and a controller's own messages are unproven | next action 2, sending from the virtual source |
| the MIDI status reaching a player | the text is asserted in tests and the model retains and refreshes it, but the app target has no view test and nobody has looked at the window | next action 1 |
| the source notification arriving on real hardware | the notify block is a CoreMIDI callback and the runner has no source to attach, so the refresh is exercised by tests rather than by a plug-in event | next action 1 |
| a port refusing a source at runtime | every refusal in the tests is simulated; no port has refused a real endpoint here | next action 1, with a controller the port can reject |
| the connect probe publishes its own source instead of skipping the step | the runner has no controller, so skipping would leave the connect call unexercised for ever; a virtual source is a real endpoint the system publishes, and the deprecated create call is avoided |
| a missing or unlisted virtual source fails the step | a check that passed with nothing to connect to would prove nothing; only the connected outcome is a pass, and the start probe still reports the machine's own empty list |
| the connect probe prints the ordinary report lines too | the same markers then cover both probes, so a change in one is visible in the other rather than hiding behind a second vocabulary |

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
| `a84c56e` | `MIDIConnectProbe`, the attempt type and the six-outcome classification in the core module; failed run `42739979656` |
| `769b43f` | `VirtualMIDISource` and `MIDIConnectProbeTests` |
| `9336197` | `MIDIInputService.refresh()`, so a source listed a moment late is not reported as missing |
| `a03ec8c` | `SUNDAYKEYS_PROBE_MIDI_CONNECT` in `LaunchProbe` |
| `78ce36e` | `tools/midi_smoke.sh` runs both probes and publishes the connect counts; failed run `42739979656` |
| `5a2e4c6` | `MIDIConnectProbe.exitCode` and `provesConnectPath` forwarded; failed run `42740177399` |
| `7b8567f` | the exit-status expectation corrected; run `42740337754` proved the connect and failed only on the pid suffix |
| `7d5cd17` | the pid stripped from the status before it is compared; verified by run `42740507134` |
| `2d8738c` | the one-shot recorder workflow, because the log is larger than one API call can replace |
| `175cb77` | the connect milestone, the revised next actions and the README section; written by recorder run `42741151494` and read back at that commit |

## Step clock and arpeggiator caller milestone (2026-11-10)

This section records the step clock, which turns a held chord into timed
note events, and the service that lets a keyboard reach it.

**No workflow runner produced this record.** It was written by hand, as
this repository's own decision, in an ordinary commit. One mechanical
exception is stated rather than hidden: because this file is 110,012
bytes and the contents API replaces whole files while capping reads at
50,000 characters, the append and the push were carried out by a plain
Linux job that ran `cat` and `git push` and changed no source, test or
workflow file. The words are mine; the job moved them.

### The recorder path, removed

An earlier attempt to have a runner record this milestone produced
`.github/workflows/record_step_clock.yml` and
`docs/re/step-clock-proof.md`. Neither is in the tree now: both files
were deleted, and run 42854416837 - the workflow that wrote the proof
file - was cancelled while queued rather than re-run or re-polled.
There is no proof workflow in this repository, and no runner is cited
as the author of any claim here.

### The caller

`Arpeggiator` answers which note each step plays, and nothing called it,
so no arpeggiated note was ever produced. `ArpeggiatorService` is now
that caller. It owns the held set and the clock, and a key press, a key
release, a style change and a tempo, division, gate or velocity change
each reach it as their own plain call.

Its notes leave through the same `NoteEventSink` the clock already used.
The default sink is `KeysoundNoteSink`, which forwards each message to a
`KeysoundNoteTarget`, and `RealtimeKeysoundEngine` already has
`noteOn(note:velocity:)` and `noteOff(note:)`, so it satisfies that
protocol as it stands. No engine, render-path or MIDI-architecture
change was made, and none is needed for this milestone. Clock time is
injected from the host as a `HostClock`: the service owns no timer, no
dispatch source and no audio dependency, which is what lets every test
below pin exact instants.

With the arpeggiator on, the first press of a chord starts the pattern
on that instant, and a press arriving mid-phrase joins on the next step;
a release ends a sounding note at once and stops the pattern when it was
the last note held. With it off, presses and releases pass straight
through carrying the pressed velocity, and turning it on over held keys
releases the forwarded notes and starts the pattern at that instant with
those keys held. Those rules are this repository's own and replaceable,
because the recorded analysis says nothing about the original's
switching behaviour.

### What the thirteen tests assert

`Tests/SundayKeysCoreTests/ArpeggiatorServiceTests.swift` drives a
`ManualHostClock` and compares `time on note` and `time off note` lines,
so each case below is a concrete value rather than evidence that a path
ran: nine events for a three-note chord at 0.0, 0.125, 0.25, 0.375, 0.5,
0.625, 0.75, 0.875 and 1.0 s, each step at the configured velocity; the
first step landing on the exact instant of the press, with nothing
ticked before it producing any event; a note off preceding the next note
on at a shared instant under a full gate; a release at 0.0625 ending the
sounding note at 0.0625 and cancelling its scheduled off, so no second
off appears anywhere in the run; a second note held at 0.1 joining the
pattern at its next step, 0.25, and not before; an empty held set
emitting nothing at all; a style change taking effect on the next step
and not on the one already scheduled; a tempo change halving the
interval after the pending step; a division change to quarter doubling
it after the pending step; a release of the last held note stopping the
pattern and ending the sounding note; keys passing straight through with
the pressed velocity while the arpeggiator is off; turning it on with a
key held releasing the forwarded note and starting the pattern at that
exact instant; and the default sink reaching an engine-shaped target
with `on 60` then `off 60`.

### The two defects the first green attempt exposed

The first attempt at a green head was `a37c4207`, and it was not green.
`build` run 42856089929 failed in Test at 16:36:45 on exactly two of the
thirteen cases, and both failures were defects in the code rather than
wrong expectations.

`testASecondNoteHeldMidRunJoinsAtTheNextStep` produced steps 60, 60, 64
where 60, 64, 60 was specified. `Arpeggiator` clamped its cursor modulo
the length of the pattern at the moment a note joined, so a one-note
pattern of length one threw away the fact that the next step was the
second step. The cursor is now a monotonic count of steps taken, never
reduced while the pattern plays, and each step reads it modulo the cycle
it is about to walk; a release is still safe because that modulo cannot
point past a shorter cycle.

`testEnablingWithKeysHeldStartsThePatternAtThatInstant` produced an off
at 2.0 with no note on. `setEnabled(true)` released the notes forwarded
while the arpeggiator was off but never made them the pattern's held
notes, so the clock had nothing to play. The forwarded keys are now
taken into the held set after their note offs.

`1c1eba4d` carries both repairs, and `StepClockTests`,
`ArpeggiatorTests` and the thirteen caller cases all pass unchanged
since: no expectation was adjusted to fit the code.

### The runs observed green, with their windows

Every run below was read to a completed run object and its conclusion
before it was counted. Times are UTC as the API reports them.

On `1c1eba4d401009408afbcd72ac6508f4d6d3ba5c`:

`build` 42857103692, job 129973021683: started 16:41:43, completed
16:43:05, success. Resolve dependencies 16:41:48-16:41:52; Build
(debug, with tests) 16:41:52-16:42:19; Test 16:42:19-16:42:23; Build
(release) 16:42:23-16:42:42; Bundle 16:42:42-16:42:44; Launch
16:42:44-16:42:51; audio probe 16:42:51-16:42:53; MIDI probe
16:42:53-16:42:56; bootstrap check 16:42:56-16:43:00.

`session` 42857103822, job 129973023382: 16:41:40-16:42:28, success,
session-resume probe 16:42:22-16:42:25. `click` 42857103988, job
129973022781: 16:41:41-16:42:31, success, click probe 16:42:24-16:42:29.
`patch_transfer` 42857650571, job 129974988797: 16:44:50-16:45:31,
success, patch-transfer probe 16:45:27-16:45:29.

On the docs record head `a1e045368fd8f1ee04bbb359195340cd81dd7201`:
`build` 42858404930 ran 16:49:04-16:50:25 and succeeded, with Test
16:49:42-16:49:45; `session` 42858403874 ran 16:49:04-16:49:42 and
succeeded; `click` 42858404332 ran 16:49:04-16:49:47 and succeeded.

**`patch_transfer` has not obtained a runner on any docs-only head.**
On `a1e04536` it was dispatched four times - 42858403667, 42858560004,
42858671807 and 42858815110 - and none of those runs left the queue, the
last being cancelled at 16:51:43 so that nothing was left queued. Its
probe therefore has a green window on the code head above and no green
window on a documentation-only head; the queue carries a standing notice
that macOS arm64 jobs may wait for capacity.

### What this does not establish

No note was heard. Nothing here was measured on hardware, through an
audio device, or checked against the original application, and no window
or audio callback constructs the service yet, so the app still plays
un-arpeggiated. No extracted code, assets or disassembly are in the
tree: every rule chosen above is labelled this repository's own and
replaceable, and everything the recorded REA notes do not contain - the
original's step rate, subdivision values, gate, latch, swing, per-step
velocity and switch-off behaviour - stays **Unknown** until a capture
replaces it.

## Milestone: arpeggiator latch (2026-11-10)

Status: implemented in the core and proven by a GitHub-hosted macOS
runner. Nothing in this section was validated on hardware, on a real
keyboard, or by ear. Those stay **Unknown**.

### Why this was the next item

The five "next actions, in order" at the end of the step clock
milestone are all blocked on the local Mac: a controller on a real
machine, hardware MIDI refinements, the panel's status line, the
relaunch path and the decompilation work. The highest-priority
software gap was therefore the one the step clock analysis already
names: latch was unimplemented and recorded **Unknown**.

### What the analysis says, and what it does not

The analysis names a latch control and records no behaviour for it.
The rule below is this repository's own and replaceable on its own:
it is stated in the source, tested directly, and can be changed
without touching the clock, the pattern or the engine.

### The rule this repository chose

- With latch on, a key release removes the key from the set the
  player is physically holding and leaves the note in the pattern, so
  the pattern keeps running with no key down.
- The next press made when no key is physically held begins a new
  chord: the previous chord's sounding notes are released at that
  instant and the pattern restarts on that press.
- A press made while another key is still down joins the running
  pattern on the next step instead of restarting it.
- Switching latch off drops the notes no key is holding, at that
  instant, and stops the pattern when none remain.
- Latch does nothing while the arpeggiator is off, where a press and
  a release are forwarded unchanged.
- Latch defaults to off, so no existing caller changes behaviour.

### Code

`Sources/SundayKeysCore/ArpeggiatorService.swift` gained `isLatched`,
`setLatched(_:at:)`, an initialiser parameter defaulted to off, and a
private `physicallyHeld` set kept alongside the pattern's notes.
`keyDown`, `keyUp`, `setEnabled` and `allNotesOff` were updated to
keep that set in step, and the clock's `hold` and `release` do the
note work exactly as before, so latch adds no scheduling rule.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorLatchTests.swift`,
eight cases on `ManualHostClock` with a recording sink, asserting
exact emitted events:

1. latch defaults to off;
2. a latched pattern keeps running for three steps after the last
   key comes up, seven exact events from 0.0 to 0.75;
3. a new chord pressed at 0.2 releases the old note at 0.2, and the
   old chord's second note never sounds;
4. switching latch off releases an unheld latched note at the
   release instant and stops the pattern;
5. switching latch off keeps a note that is still held;
6. latch does nothing while the arpeggiator is off;
7. a press while another key is down joins the pattern and wraps
   the cycle, with note ons at 0.0, 0.25 and 0.5;
8. enabling under latch keeps the held key in the pattern for two
   steps after release.

### The defect this found, and the fix

The first run of the suite (build 42862109269 on head 48975da2)
compiled cleanly and then failed five of its cases. The failures
were in the expectations, not the service: the grid at 120 bpm with
eighth division is a step every 0.25 s, with the note off 0.125 s
after its note on, and the suite had been written against a 0.125 s
step. That same output already showed the rules holding (off 60 at
0.2, on 67 at 0.2, and 64 never sounding), so the repair corrected
every instant, extended three cases and added the default case; the
service itself was not changed. Commit 7abcb2c1.

### Runner evidence

All on GitHub-hosted `macos-15` runners (Xcode 16.4, Swift 6.1.2).

- build 42862109269, head 48975da2: completed/failure. Debug build
  success 17:10:25 to 17:10:53; Test failed at 17:10:57 on the five
  wrong expectations above. This is the run that found the defect.
- build 42862603335, head 7abcb2c1: completed/success, job finished
  17:14:30. Debug build 17:13:06 to 17:13:34; Test success 17:13:34
  to 17:13:39; release build 17:13:39 to 17:14:07; bundle, launch,
  audio probe, MIDI probe and bootstrap check all success. This is
  the run that proves the latch suite.

The clock's own derivation was confirmed from its source for this
milestone: `stepInterval` is 60 / beatsPerMinute / stepsPerBeat, and
the gate is the gate fraction of that interval.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorService.swift`,
  every byte of `ArpeggiatorLatchTests.swift`, every byte of this
  section, and the one-shot append job's workflow file.
- Moved by a runner: this section's bytes were appended to
  docs/progress.md by the `append-progress` job on `ubuntu-latest`,
  which concatenates the section file and then commits and pushes.
  The file is far past what the contents API will replace in one
  call, so I did not write these bytes into it directly.

### What is still Unknown

- Whether the original's latch behaves like this rule.
- Anything needing the local Mac: a real controller, hardware MIDI,
  the panel's status line, the relaunch path, decompilation.
- Latency, CPU and audio behaviour under load.

### Next actions, in order

1. Wire latch to a control in the app and show its state, once the
   panel's status line exists.
2. Get `patch_transfer` a green run on a head it can keep; it
   starves on docs-only heads.
3. The remaining hardware items, when a Mac is available.

## Milestone: the arpeggiator latch is a panel control (2026-11-10)

Status: implemented in the core and in the app's panel layer, and proven
by a GitHub-hosted macOS runner. Nothing here was validated on hardware,
on a real controller, or in a window anyone looked at: those stay
**Unknown**.

### Why this was the next item

The latch rule landed in the previous milestone and no control reached
it: the app had no arpeggiator panel at all, so on, tempo and division
had no surface either. The first entry in that section's next-actions
list was exactly this wiring, and it needs no local Mac - it is a model
and view job that a runner can compile and that the test target can
drive.

### The panel layer, and why it lives in the core

The tests only ever import `SundayKeysCore`, so logic the app cannot test
is logic nobody is checking. That decided the split:

- **`ArpeggiatorPanel`** is the surface the window binds to. One method
  per control - on or off, latch, tempo, division - each routed to the
  `ArpeggiatorService` the panel holds, and each reading the instant from
  the `HostClock` the panel was given rather than starting a timer. A
  toggle therefore lands at the instant the caller says, which is what
  makes the latch assertions exact.
- **`SystemHostClock`** is the app's clock. It reads the system's
  monotonic uptime rather than the wall clock, so a time correction
  mid-service cannot pull a pattern backwards or skip a step.
- **`AppModel`** owns one panel, lazily, because the panel needs the
  audio controller as its note target and a stored property initialiser
  cannot read another stored property. It mirrors the panel's state into
  published properties after every change, so the toggle, the tempo, the
  division and the status line cannot disagree with the service.
- **`ArpeggiatorSection`** is the panel in the window: an `On` toggle, a
  `Latch` toggle, a tempo stepper and a division picker, all bound to
  those model methods, plus the status line the panel composes.

Latch sits beside the other three and takes the identical path:
`setArpeggiatorLatched` to `ArpeggiatorPanel.setLatched` to
`ArpeggiatorService.setLatched(_:at:)`.

### What latch does, restated

Unchanged from the previous milestone, and still this repository's own
rule rather than a reproduction: a released key stays in the pattern and
the pattern keeps running with no key down; the first press made with
nothing physically held starts a new chord and releases the previous one
at that instant; a key pressed while another is still down joins the
running pattern; switching latch off drops the notes no key is holding
at the switch instant and stops the pattern when none remain.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorPanelTests.swift`, seven
cases on `ManualHostClock` with a recording sink:

1. the panel starts off, at 120 bpm and `.eighth`, with the status line
   `Arp off, latch off, 120 bpm, eighth`;
2. the latch toggle turns the service's latch on and back off, and the
   label follows;
3. a latched pattern driven through the panel keeps running for three
   steps after the key comes up - seven exact events from 0.0 to 0.75;
4. toggling latch off at 0.1 releases the unheld note at 0.1 and stops
   the pattern;
5. toggling latch off keeps the key still held in the pattern;
6. the tempo control lands clamped by the service's own bounds and the
   division control lands with its own label in the status line;
7. with the arpeggiator off, keys pass straight through even with latch
   on.

The eight service-level cases in `ArpeggiatorLatchTests.swift` are
unchanged and still pass, so the panel did not fork the semantics it
exposes.

### The runs

Run `42865901229` on `4a8523b5`: the job completed with every step
succeeding, including `Build (debug, with tests)` and `Test`, so the new
suite ran on the runner rather than merely compiling. The release
build, the bundle, the launch and the audio, MIDI and bootstrap probes
in the same workflow succeeded as well.

The path to it: commit `9c4487fb` assigned the panel in `init`, which
reads one stored property while another is still uninitialised - a use
of `self` before full initialisation, which Swift rejects. It was found
by reading the code before the build spent a runner on it, the queued
run was cancelled rather than left to fail, and `4a8523b5` made the
panel a lazy property instead.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorPanel.swift`,
  `SystemHostClock.swift`, `ArpeggiatorPanelTests.swift`,
  `ArpeggiatorSection.swift`, the edited `AppModel.swift`, the edited
  `ContentView.swift` (one line placing the section), and this section.
- Moved by a runner: this section's bytes were appended to
  `docs/progress.md` by the `append-progress` job on `ubuntu-latest`,
  which concatenates the section file and then commits and pushes. This
  file is far past what the contents API will replace in one call, so I
  did not write these bytes into it directly.

### What is still Unknown

- How any of it sounds, and whether a stepped pattern is musical.
- Whether the original's latch behaves like this rule.
- Anything needing the local Mac: a real controller, hardware MIDI, the
  panel's status line, the relaunch path, decompilation, latency and CPU
  under load.
- No window was looked at: the section compiles and its model is tested,
  it was not seen running.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel so
   an enabled arpeggiator steps what the player plays. Today the panel
   is reachable and its state is proven, but no key press reaches it.
2. A time source that ticks the panel while the arpeggiator is on; the
   panel deliberately owns none.
3. The hardware items the previous milestone left, unchanged.

## Correction to the run recorded above (2026-11-10)

The section above cites run `42865901229` on `4a8523b5` and says its job
completed with every step succeeding. That is what its step list shows,
but it is not what the run reads: GitHub recorded that run's conclusion
as `cancelled`, because the commit that staged this record started a
newer run in the same concurrency group and superseded it while its last
step was finishing. This log has treated a run that never produced a
conclusion of its own as no evidence, so the honest reading is that the
run is not a pass, whatever its individual steps did.

The run that does read green for this milestone is `42866424074` on
`cb4c6d25`, the head that carries the core, the app wiring, the panel
tests and this record. Its job concluded `success` with every step
succeeding, including `Build (debug, with tests)` and `Test`, so the
seven panel cases ran on the runner rather than merely compiling, and
the release build, the bundle, the launch and the audio, MIDI and
bootstrap probes succeeded in that same run.

What this correction changes: one run's conclusion, and nothing in the
code, the tests or the engineering above it. What it does not claim: a
passing run on `4a8523b5`. No hardware was involved, and nothing here
was heard or seen in a window, so every **Unknown** above still stands.

The bytes of this correction were written by hand and appended by the
same plain Linux job as the section above; no source, test or existing
workflow file is touched by either.
## Milestone: the arp pattern and octave span are panel controls (2026-11-10)

Status: implemented in the core, the panel layer and the app's section,
and proven by a GitHub-hosted macOS runner. Nothing here was validated
on hardware, on a real controller, or in a window anyone looked at:
those stay **Unknown**.

### Why this was the next item

The latch landed in the previous milestone and the pattern behind it was
still fixed: every chord walked upward, one octave, with no control that
said otherwise. The first entry in that section's next-actions list was
the wiring, and it needs no local Mac - it is a model and view job a
runner can compile and the test target can drive.

### What the controls are, and the path they take

The pattern is a picker in the arpeggiator section offering Up, Down and
UpDown. The octave span is a 1 to 4 stepper beside it. Both sit with on,
latch, tempo and division, and both take the identical path those do:

    ArpeggiatorSection
      -> AppModel.setArpeggiatorPattern / setArpeggiatorOctaves
      -> ArpeggiatorPanel.setPattern / setOctaves
      -> ArpeggiatorService.setStyle / setOctaves
      -> StepClock.setStyle / setOctaves
      -> Arpeggiator

`AppModel` mirrors the pattern and the span into published properties
after every change, the same way it mirrors latch and tempo, so the
picker cannot show a value the service does not hold.

### Where the span lives, and why

The span belongs in `Arpeggiator`, the pure pattern type, because that
is where the cycle is decided. Each held note repeats twelve semitones
higher for every extra octave; a transposed note that would pass 127 is
left out rather than wrapped down onto a lower pitch; and one octave is
exactly the held keys, so nothing the earlier cases assert moves. A
pattern or span change restarts the cycle from its first step and leaves
the grid alone, which is the rule a style change already followed - so a
change made mid-phrase is heard on the next step, not immediately.

`ArpeggiatorService` owns the clamped span (one to four) and forwards it
to the clock, which forwards it to the pattern. `heldNotes` on the
service is still the keys the player holds, not the transposed notes,
which is what makes the latch assertions still read the way they did.

### What the patterns do

Up walks the held chord from its lowest note, Down from its highest, and
UpDown turns at the top and the bottom without repeating either end, so
60/64/67 walks `60, 64, 67, 64`. The analysis names six orderings and
records no behaviour for any of them, so these are this repository's own
rules and the code and the window both say so. The picker offers the
three a player can predict from the name; DownUp, Random and Chord stay
reachable in the core for when a capture says what they do. The span
rule is equally ours: the analysis records no octave behaviour at all.

### Tests

New file `Tests/SundayKeysCoreTests/ArpeggiatorPatternTests.swift`, nine
cases on `ManualHostClock` with a recording sink, all through
`keyDown`/`keyUp` and `tick` at exact instants on the default grid (120
bpm, `.eighth`, so a step every 0.25 s):

1. Up over 60/64/67 sounds 60 at 0.0, 64 at 0.25, 67 at 0.5, 60 at 0.75;
2. Down sounds 67, 64, 60 over the same steps and wraps;
3. UpDown sounds 60, 64, 67, 64, 60 across 0.0 to 1.0;
4. one octave over 60/64 is exactly 60, 64, 60, 64;
5. two octaves over 60/64 is 60, 64, 72, 76;
6. four octaves over 60 alone is 60, 72, 84, 96;
7. `setOctaves(9)` clamps to 4, `setOctaves(0)` clamps to 1, and 3 stays 3;
8. with latch on and every key lifted, changing to Down at two octaves
   makes 0.5 sound 79 and 0.75 sound 76, while all three keys stay in the
   pattern and the pattern keeps running;
9. a pattern change does not move the grid: the step already due at 0.25
   still lands at 0.25, filled by the new order.

`ArpeggiatorPanelTests` gains three cases - the picker and stepper reach
`service.style` and `service.octaves` and the labels follow, the span
clamps through the panel, and a pattern-plus-span chosen through the
panel changes what four ticks emit - and its first case gains two
assertions for the default pattern and span. Its two exact status-line
assertions now read the extended line,
`Arp on, latch off, Up, 1 octave, 120 bpm, eighth`. No assertion was
removed or loosened; the status line is compared for exact equality,
before and after.

### The runs

Every run below is on `8603278d`, the commit that carries this
increment, and every one reads completed with conclusion success:

- build `42869548651` - toolchain, dependencies, debug build with tests,
  Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap
  script;
- click `42869796981` - release build, bundle, click probe;
- patch-transfer `42869797297` - release build, bundle, patch probe;
- session `42869797082` - release build, bundle, session-resume probe.

The push-triggered click, patch-transfer and session runs on this head
sat queued with no runner while build ran and after it finished. They
were cancelled and re-dispatched on the same head rather than left to
starve, and the three re-dispatched runs took runners at once: that is
the strategy that unblocked them, and it moved no commit. The build run
that proved the tests is the push-triggered one.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `Arpeggiator.swift`,
  `StepClock.swift`, `ArpeggiatorService.swift`, `ArpeggiatorPanel.swift`,
  `AppModel.swift`, `ArpeggiatorSection.swift`,
  `ArpeggiatorPanelTests.swift`, the new
  `ArpeggiatorPatternTests.swift`, and this section. The files were
  written through the git blob API from their full contents, so no
  transport rewrote them.
- Moved by a runner: this section's bytes were appended to
  `docs/progress.md` by the `append-progress` job on `ubuntu-latest`,
  which concatenates this file, deletes itself and its workflow, then
  commits and pushes. `docs/progress.md` is far past what the contents
  API will replace in one call, so I did not write these bytes into it
  directly.

### What is still Unknown

- How any of it sounds: whether a two-octave UpDown is musical, whether
  the gate is right, whether any of it is too fast to play.
- Whether the original's pattern or octave controls behave like these.
  The analysis records neither.
- Anything needing the local Mac: a real controller, hardware MIDI, the
  panel's status line as rendered, the relaunch path, decompilation,
  latency and CPU under load.
- No window was looked at: the section compiles and its model is tested,
  it was not seen running.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel so
   an enabled arpeggiator steps what the player plays. The controls are
   reachable and their state is proven; no key press reaches them yet.
2. A time source that ticks the panel while the arpeggiator is on; the
   panel deliberately owns none.
3. The hardware items the earlier milestones left, unchanged.

## Milestone: the arpeggiator session survives a launch (2026-11-10)

Status: implemented in the core, the panel layer and the app's section, and
proven by a GitHub-hosted macOS runner. Nothing here was validated on
hardware, on a real controller, or in a window anyone looked at: those stay
**Unknown**.

### Why this was the next item

The mission's priority list named preset and session management first. The
bank already holds the patches, their effects, the controller layouts and the
set list with its play head, and `SessionMemory` already restores the patch the
last launch ended on. What no file held was the arpeggiator: on, latch, the
pattern, the octave span, the tempo and the division were all forgotten when
the process ended, so a player dialled the whole panel in again at every
launch. That is the smallest session-management gap left, and it needs no Mac.

### What a session is, and why it is its own file

`ArpeggiatorSession` is those six choices as a value. `ArpeggiatorSessionStore`
writes it to `arpeggiator-session.json` beside the bank and the launch memory,
rather than inside `session.json`, for the same reason the launch memory is not
inside the bank: the bank's format does not move, and a session file that will
not read cannot stop a single patch from loading.

A session carries switches and choices, never held notes. `ArpeggiatorSession(panel:)`
reads the panel's own value, and `apply(to:)` puts it back through the panel's
own setters - `setPattern`, `setOctaves`, `setBeatsPerMinute`, `setDivision`,
`setLatched`, `setEnabled` - so a restored session takes exactly the path a
moved control takes and the app's mirrors are republished from the panel
afterwards. Nothing reaches into the service directly.

### The document, and what it refuses

`ArpeggiatorSessionDocument` is the versioned JSON form. Its known fields are
`version`, `enabled`, `latched`, `beatsPerMinute`, `division`, `pattern` and
`octaves`; the keys are sorted, so the same session always produces the same
bytes.

- **A later build's fields survive.** Every key this build does not read is held
  in `unknownFields` as a `JSONValue` and written back beside the known ones, so
  a document written by a later build passes through this one unchanged. A
  `JSONValue` rather than `JSONSerialization` is deliberate: the bridge answers
  `NSNumber` for every number and cannot tell a `Bool` that came from `1` from
  one that came from `true`, so a carried field could come back as the wrong
  type.
- **A later version is refused whole.** The version is checked before any field
  is read, so a format this build does not know is refused rather than half
  understood.
- **Every refusal has a name.** `ArpeggiatorSessionFailure` separates bytes that
  are not JSON, valid JSON that is not an object, an unsupported version, a
  missing field, a field of the wrong shape, an unknown division and an unknown
  pattern. A malformed document is reported, never crashed on and never partly
  applied.
- **An earlier document opens on the defaults.** `pattern` and `octaves` are
  optional on read and default to `.up` and one octave, which is what a document
  written before those two controls existed gets; re-encoding writes them.
- **The span still clamps.** The value goes through `ArpeggiatorSession`, which
  clamps to one to four and the tempo through the click's own bounds, so a
  hand-edited file cannot put the pattern somewhere its stepper could not.

The store is not `SessionStore`: a missing file is `nil`, but a file that exists
and will not read throws, because overwriting a session the player asked to keep
is their decision rather than a fallback.

### The app path

`AppModel` gains `arpeggiatorSessionStatus`, `saveArpeggiatorSession()` and
`restoreArpeggiatorSession()`. Saving reads the panel, not the mirrors; restoring
applies the document through the panel, republishes every arpeggiator mirror and
reports the result in the panel's own words. `ArpeggiatorSection` gains a
`Save session` and a `Restore session` button with that line beside them, under
the status line the controls already had.

### What the fifteen cases assert

`Tests/SundayKeysCoreTests/ArpeggiatorSessionTests.swift`, on `ManualHostClock`
with a recording sink, all of it through `ArpeggiatorPanel`:

1. a session that set nothing is the panel's own defaults, and applying it
   leaves `Arp off, latch off, Up, 1 octave, 120 bpm, eighth`;
2. a panel set to on, latched, Down, two octaves, 140 bpm and sixteenth survives
   encode and decode and restores to
   `Arp on, latch on, Down, 2 octaves, 140 bpm, sixteenth`;
3. the same session always produces the same bytes, with sorted keys;
4. every JSON shape a later build might add - an object, an array, a string, a
   bool and null - comes back through a decode and an encode unchanged, and no
   known key is left in the carried set;
5. a later version is refused rather than half read;
6. a missing required field is named;
7. a field of the wrong shape is named;
8. bytes that are not JSON are refused;
9. valid JSON that is not an object is refused;
10. an unknown division number and an unknown pattern name are each named;
11. a document from before the pattern and span existed opens on `.up` and one
    octave, and still restores to
    `Arp on, latch off, Up, 1 octave, 132 bpm, eighth`;
12. an out-of-range span clamps to four through the panel;
13. a store writes and reads the session back from a temporary file, and
    restores `Arp on, latch on, UpDown, 4 octaves, 88 bpm, quarter`;
14. a corrupt file is reported rather than treated as nothing saved;
15. restoring emits no notes until a key arrives, so a session is state and not
    a chord.

The count is fifteen. The commit message for `d66e3a4` says thirteen; the file
has fifteen methods, and this line is the accurate one. No existing assertion
was changed, weakened or removed: the two edited files are app code, and every
earlier suite runs untouched in the same `Test` step.

### The runs

Every run below is on `d66e3a4`, the commit that carries this increment, and
every one was read to `status: completed` with `conclusion: success`:

- build `42872852592` - `Build (debug, with tests)` 18:12:55 to 18:13:12,
  `Test` 18:13:12 to 18:13:15 (the new suite ran here, not merely compiled),
  `Build (release)` 18:13:15 to 18:13:32, `Bundle the app`, `Launch the app`
  18:13:33 to 18:13:39, the audio probe, the MIDI probe and the bootstrap check,
  job completed 18:13:50;
- click `42872852586` - release build, bundle and click probe, completed 18:13:30;
- patch-transfer `42872852724` - release build, bundle and patch probe, completed
  18:13:32;
- session `42872852654` - release build, bundle and session-resume probe,
  completed 18:13:13.

This head needed no unblocking: all four took runners on the push, none sat in
the queue, so neither cancel-then-dispatch nor a trivial commit was used on
`d66e3a4`.

### Bytes: what I wrote, what a runner moved

- Hand-written by me: every byte of `ArpeggiatorSessionDocument.swift` (new),
  every byte of `ArpeggiatorSessionTests.swift` (new), the edited
  `AppModel.swift`, the edited `ArpeggiatorSection.swift`, and this section.
  The files were written through the git blob API from their full contents, so
  no transport rewrote them.
- Moved by a runner: this section's bytes were appended to `docs/progress.md` by
  the `append-progress` job on `ubuntu-latest`, which concatenates this file,
  deletes itself and its workflow, then commits and pushes. `docs/progress.md` is
  far past what the contents API will replace in one call, so I did not write
  these bytes into it directly.

`tools/bootstrap.sh` is untouched: this increment adds no dependency, no
package and no toolchain requirement, so what the script must install has not
changed. It remains unexecuted on the local Mac, and this milestone does not
claim otherwise.

### What is still Unknown

- Whether the original application stores a session at all, and in what shape:
  the recorded analysis says nothing, so this document format is this
  repository's own and replaceable.
- Whether pressing the two buttons in a window does what the model method does.
  No window was looked at; the runner compiles the section and the test target
  drives the panel, and those are different claims.
- Whether a second launch on a real Mac finds the file. The store is tested
  against a temporary path on the runner, not against a real Application
  Support folder across two processes.
- Anything needing the local Mac: a real controller, hardware MIDI I/O, the
  status line as rendered in a window, the relaunch path with a person watching,
  decompilation, latency and CPU under load.
- How any of it sounds, and whether a restored pattern is musical.

### Next actions, in order

1. Route the on-screen keyboard and the MIDI input through the panel, so an
   enabled arpeggiator steps what the player plays. This is still the oldest
   open software item, and it needs no Mac.
2. Restore a session on a real Mac across two launches and look at the buttons,
   which is the one part of this milestone the runner cannot reach.
3. The hardware items the earlier milestones left, unchanged.

## Milestone: typed MIDI message routing

**Status:** landed and green on `edd02e85`. The MIDI input path now has a strict,
typed layer between the bytes and the engine, and the MIDI inputs panel shows
what that layer did with the last packet.

**Why this one next:** preset and session management finished with
`ArpeggiatorSessionDocument` and its store, so the open piece of the input path
was the one the port left lenient. `MIDIMessage.parse` and `parseAll` keep
anything they do not model as `other` and pad a short message with zero, which
is the right behaviour for a CoreMIDI callback that must never drop a packet and
must never crash on one - but it means a malformed message and a note that
simply arrived look the same to the caller. The layer added here is the strict
form, and it is the one the tests can state.

**What the increment does:**

- `MIDIEvent` - one validated channel event: note on, note off, control change,
  program change, pitch bend, channel pressure. Channels, notes, velocities,
  controllers and programs are 0-127 (channels 0-15) because the decoder checks
  them; the fourteen-bit bend is 0-16383. A note on at velocity zero is
  translated to a note off at the decoder, so no downstream stage has to
  special case the wire's second spelling of it.
- `MIDIEventFailure` - every refusal has a name: `empty`,
  `unsupportedStatus`, `systemMessage`, `truncated(status:expected:got:)`,
  `dataByteOutOfRange(status:byte:)`. Rejection is a value that reaches the
  caller, not a crash and not a silently shortened note list.
- `MIDIEventDecoder.decode` decodes one message; `decodeAll` decodes a packet in
  arrival order, following running status, skipping real-time bytes, resyncing on
  a status byte that arrives where data belongs, and stopping at a message that
  stops short because where the next one starts cannot be known then.
- `MIDIEventTransport` - the injectable seam, one method per event, so nothing is
  accepted and then ignored. `MIDIEventRouter` is a value that owns no clock, no
timer and no hardware: it decodes, delivers in order, counts delivered and
  rejected, remembers the last of each, and words the status line. It is
  testable the way the step clock is testable through `ManualHostClock`.
- `AppModel` conforms to the transport. Notes go to the engine through
  `KeysoundNoteTarget`, the same note path the arpeggiator plays into; controllers
  go through the existing learn and `applyController` path; a program change
  selects a patch; bend and pressure are recorded because the engine has no
  destination for them yet. `midiRouteStatus` is a `@Published` mirror the panel
  reads, and the routing counts are published setters, in the same shape the
  arpeggiator controls already use.
- `ContentView` shows the status line under the MIDI inputs box. The wording is
  pinned by tests: `MIDI route: nothing yet`, then
  `MIDI route: 1 delivered, 0 rejected, last note on 60 velocity 100 ch 1`, then
  `MIDI route: 2 delivered, 1 rejected, last refused: truncated 0x90: expected 2 data byte(s), got 1`.

**Tests:** a new suite, `Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift`,
15 cases, and no existing test or assertion was touched. It pins every supported
message type delivered through a recording transport in arrival order; note off
versus note on at velocity zero; the exact typed refusal for truncated,
unsupported, system, empty-message and status-in-data input; channel and data
boundaries at 0 and the maximum for every type; running status; real-time bytes
skipped without disturbing the message around them; resync after a bad byte;
`decodeAll` agreeing with `decode` message by message; the exact status-line
strings; and note events reaching the keysound path. Nothing in the suite reads
wall time or hardware: the router is a value and the transport is a recorder.

**Runs on the final head `edd02e85`** (the push dispatched all four; each read
`completed` / `success`):

- build `42883756772` - completed, success. Debug build with tests, the new suite
  green in the Test step, release build, bundle, launch, audio probe, MIDI probe,
  bootstrap check.
- click `42883756937` - completed, success. Release build, bundle, click probe.
- patch-transfer `42883756795` - completed, success. Release build, bundle, patch
  transfer probe.
- session `42883756796` - completed, success. Release build, bundle, session
  resume probe.

Two earlier heads on the way here were read rather than re-run. `0057d91b` failed
build because the new suite asked the keysound target for a control change the
target never receives; fixed in `31535fab`. That head then failed one assertion
about an empty packet - the decoder refuses an empty *message*, while a packet
with no bytes carries no message to refuse - and `edd02e85` pins both halves of
that contract without changing the decoder. The warnings the runner reports
(`AppModel`'s main-actor methods satisfying a non-isolated protocol) are real and
harmless in this Swift 5 package; they become errors under Swift 6 and are the
next cleanup, not a failure of this head.

**Hand-written versus runner-moved:** every source and test byte in this
document's milestone was written here: `Sources/SundayKeysCore/MIDI/MIDIEventRouting.swift`
(new), `Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift` (new),
`Sources/SundayKeysApp/AppModel.swift` and `Sources/SundayKeysApp/ContentView.swift`
(rewritten), plus this section and the one-shot workflow that published it. The
runner moved the append itself: it wrote these bytes onto the end of
`docs/progress.md`, deleted `docs/re/midi-route-append.md` and
`.github/workflows/append_progress.yml`, and committed and pushed that result on
its own. No code byte was generated or moved by the runner.

**Unknown without the Mac:** whether a real controller drives this path - the
hardware MIDI I/O, the CoreMIDI connection, and a physical note arriving; how the
status line and the panel controls actually render in a window; the relaunch
path; decompilation; latency, audio behaviour and anything about how it sounds.
A macOS runner proves parsing, ordering, encoding and emitted events. It does
not prove a note is audible. `tools/bootstrap.sh` is unchanged by this increment
- it installs nothing new - and it remains unexecuted on the local machine; the
runner's bootstrap step only checks it.

**Next actions:** mark `MIDIEventTransport` (or the conformance) so the Swift 6
main-actor warnings stop being latent errors; give bend and pressure a real
engine destination once the engine has one; then continue the input-port work -
controller assignment through `ControllerMapping` from typed events rather than
from the permissive parse.

## MIDI transport seam: main-actor contract, enforced by CI (2026-11-10)

**The fix.** `MIDIEventTransport` is now a `@MainActor` protocol and
`MIDIEventRouter.route` / `deliver` are main-actor isolated, matching every real
transport: `AppModel` owns published mirrors, the engine it voices and the panel
it republishes, so the contract now states the isolation it always had. Orders,
counts, the last event, `statusLine` and `initialStatusLine` stay plain values,
and `MIDIEventDecoder` stays pure, so nothing that never touches UI state pays
for the annotation. The suite's test class and recording transports take the
same `@MainActor`; `RecordingKeysoundTarget` deliberately stays nonisolated
because `KeysoundNoteTarget` is. No assertion changed and no escape hatch was
used: no `@preconcurrency`, no `@unchecked Sendable`, no deleted check.

**Permanent coverage.** `.github/workflows/concurrency.yml` builds
`swift build --build-tests -v -Xswiftc -strict-concurrency=complete` - without
`-warnings-as-errors` on purpose, so the whole inventory prints instead of the
first diagnostic hiding the rest. The job also proves the flag actually reached
`swiftc`, prints a per-file diagnostic count, annotates every primary diagnostic
with its source file, and fails when any diagnostic lands in the routing seam:
`Sources/SundayKeysCore/MIDI/`, `Sources/SundayKeysApp/AppModel.swift`,
`Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift`.

**Verified on head `38c5c866`, macos-15-arm64, Xcode 16.4, Swift 6.1.2:**

| workflow | run | result |
| --- | --- | --- |
| build | 42886904595 | success - debug build with tests, Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap verification all success |
| click | 42886904673 | success - release build, bundle, click probe |
| patch-transfer | 42886904650 | success - release build, bundle, patch-transfer probe |
| session | 42886904910 | success - release build, bundle, session resume probe |
| concurrency | 42886904519 | success - strict build under complete checking, flag proof, full report, seam gate clean |

The same five workflows were green on the previous head `30d22f54` (build
`42885791565`, click `42885791588`, patch-transfer `42885806781`, session
`42885806154`, concurrency `42885792036`). `38c5c866` re-proves them with the
report step that annotates real file paths instead of bare log text.

**Deferred strict-concurrency diagnostics (tracked, not suppressed).** Complete
checking reports 11 diagnostics, every one of them in test files that predate
this seam work, and none in the gated seam:

- `Tests/SundayKeysCoreTests/AudioTests.swift` - mutation of captured vars
  `received`, `previous` and `outOfOrder`; reference to captured vars `previous`
  and `received`; capture of `SPSCCommandQueue` in a `@Sendable` closure (twice);
  plus Swift's suggestion to `add '@preconcurrency'` when importing
  `SundayKeysCore`.
- `Tests/SundayKeysCoreTests/EffectTests.swift` - capture of
  `RealtimeKeysoundEngine` in a `@Sendable` closure, and the same
  `@preconcurrency` import suggestion.

They are printed on every strict run and annotated by file, so they cannot
disappear silently. They are outside the gate only because they are a separate
backlog - test doubles capturing mutable state - not the transport seam.

**Still Unknown.** Everything that needs the local Mac: real device audio and
MIDI behaviour, controller hardware, interactive UI. CI proves compilation,
tests, bundling, launch and the scripted probes on a hosted runner; it does not
prove hardware behaviour.

# The arpeggiator's caller, inside the app

Status: **proven green on `fb36f87a`.** The build's `Test` step, the session,
click and patch-transfer probes and the concurrency check all completed
successfully on that exact sha. Everything below was read from the API; nothing
was run locally, nothing was heard, and nothing was validated on hardware, on an
audio device, or against the original application.

## The gap this closed

`docs/re/step-clock.md` already recorded the step clock: `StepClock` over an
injected `HostClock`, `NoteEventSink` carrying the tree's existing `MIDIMessage`,
`StepClockSettings`, and `ArpeggiatorService`/`ArpeggiatorPanel` as the caller.
That layer was proven by its own tests. What was missing was one layer up, and
`docs/progress.md` said so: `AppModel` never called the panel. `keyDown`,
`keyUp` and the `MIDIEventTransport` note methods went straight to the audio
controller, nothing ticked the clock, and the panel was built over
`SystemHostClock()`, so no arpeggiated event was ever produced and a test could
not move its time.

## What was built

- `AppModel.init(sessionClient:clock:audio:)` takes a `HostClock` and an
  `AudioEngineController`, defaulting to `SystemHostClock()` and a fresh
  controller, so no existing call site changed.
- `keyDown`, `keyUp`, the transport `noteOn`/`noteOff` and `panic()` route
  through `ArpeggiatorPanel`. The licence gate stays first on every path, and
  `panic()` silences the pattern as well as the voices.
- `tickArpeggiator()` emits whatever the host's time has reached. A 5 ms
  `stepTicker` drives it while the engine runs and is invalidated in `stop()`.
  The interval is this repository's own choice: `StepClock` keeps the grid, so
  the ticker only bounds how late a step reaches the voices.

The audio engine interface, the render path and the MIDI architecture are
untouched, and nothing was added to `Sources/SundayKeysCore`.

## The grid the tests assert

`StepClockSettings.stepInterval` is `60 / beatsPerMinute / stepsPerBeat`, the gate
is `gateFraction * stepInterval` after its note on, and note offs precede note
ons at equal instants. At 120 bpm in eighths that is a step every 0.25 s and a
gate of 0.125 s. This repository's own mapping, replaceable: the analysis names
the divisions and records no values.

`Tests/SundayKeysAppTests/StepClockWiringTests.swift` drives the model's own
note path over a `ManualHostClock` and a recording voicing, in the app ticker's
5 ms steps, eleven cases:

1. a three-note chord at 120 bpm in eighths producing the exact nine events the
   first second holds - `on 60`, `off 60`, `on 64`, `off 64`, `on 67`, `off 67`,
   `on 60`, `off 60`, `on 64` - plus the stepping status line;
2. the first step landing on the first tick, and a second tick at the same
   instant adding nothing;
3. a release mid-pattern ending the sounding note once, cancelling its scheduled
   off, and leaving the pattern silent;
4. a note held mid-phrase joining on the next step, at 0.25 s, not a step after
   the press;
5. a pattern change taking effect on the next step, with the old cycle's note
   releasing on its own scheduled off;
6. a tempo change keeping the step already scheduled at 0.25 s and halving the
   interval after it, putting the third step at 0.375 s;
7. a division change keeping the pending step at 0.25 s and then stepping at
   0.75 s, a quarter apart;
8. an empty held set producing no event at all;
9. the arpeggiator off still forwarding the pressed velocity;
10. a refused licence refusing the key before the pattern holds it, no step
    sounding, the gate and status unchanged, and the refusal reading
    `refused note C4 ch 1: licensed playback refused:`;
11. the licensed control case, which does sound, its second step at 0.25 s.

## Passing runs on `fb36f87a`

All read through `LIST_JOBS_FOR_A_WORKFLOW_RUN` on
`fb36f87a89c4cff90afc140ee69f61b373dc4eb7`.

- build `43042601731`: `Resolve dependencies` 14:52:02-14:52:05, `Build (debug,
  with tests)` 14:52:05-14:52:35, **`Test` 14:52:35-14:52:38 success**, then
  `Build (release)` from 14:52:38.
- session `43042601531`: release 14:52:06-14:52:45, bundle 14:52:45-14:52:47,
  probe 14:52:47-14:52:52, job completed 14:52:54.
- click `43042601358`: release 14:52:00-14:52:31, bundle 14:52:31-14:52:34,
  probe 14:52:34-14:52:39, job completed 14:52:40.
- patch-transfer `43042601380`: release 14:52:03-14:52:40, bundle
  14:52:40-14:52:43, probe 14:52:43-14:52:45, job completed 14:52:48.
- concurrency `43042601772`: complete concurrency checking 14:51:59-14:52:19,
  diagnostics 14:52:19-14:52:20, job completed 14:52:20.

## Earlier runs, by ID

`35301f76` (the wiring itself, pushed by the patch runner):

- build `43039990844`: **failure** in `Test` at 14:36:30, after `Build (debug,
  with tests)` succeeded 14:36:00-14:36:26. Five assertions failed, verbatim:
  `XCTAssertEqual failed: ("["on 60 v100"]") is not equal to ("["on 60 v100",
  "off 60"]")`, four events where eight were expected in the chord case, and
  the division and mid-pattern cases disagreeing on counts. All expectation
  errors: the clock keeps the step already scheduled when tempo or division
  changes, and a note sink cannot expose instants.
- session `43039850230`, click `43039850248`, patch-transfer `43039850543`:
  **success**, release builds 14:35:10-14:35:45, probes 14:35:46-14:36:01.

`24f740b4` (the first correction):

- session `43040873482`: **success**, release 14:41:35-14:42:08, bundle
  14:42:08-14:42:10, probe 14:42:10-14:42:14.
- build `43040873479`, `43041264735`, `43041445911`: queued with `runner_id` `0`
  or `null` and `steps: []` - the arm64 capacity stall. The first two were
  cancelled and replaced; the third never ran.
- click `43040835355`, `43041264954`, `43041493009`: cancelled by their
  concurrency group or runnerless; `43041493009` was still `queued` with
  `runner_id: null`.
- patch-transfer `43040835634`, `43040873366`, `43041264608`: cancelled by
  concurrency group or runnerless. Twins `43040835347` and `43040835314` were
  cancelled at 14:41:22 and are not results.

`6a4abe64` (cleanup, scaffolding removed, first green-queue head):

- build `43041790011`: **failure** in `Test` at 14:48:09. Four cases failed,
  verbatim: `("["on 60 v100", "off 60", "on 64 v100"]") is not equal to
  ("["on 60 v100", "off 60", "on 64 v100", "off 64", "on 67 v100"]")`;
  `("["on 60 v100", "off 60"]") is not equal to ("["on 60 v100", "off 60",
  "on 60 v100"]")`; `XCTAssertTrue failed - got refused note C4 ch 1: licensed
  playback refused: Session refused: Licence expired: sounds downgraded`; and
  nine events where sixteen were expected. The suite had assumed an eighth at
  120 bpm was 0.125 s; the clock's formula makes it 0.25 s, so the horizons were
  wrong and the emitted sequences were right.
- build `43041724544` and click `43041724630`: **cancelled** at 14:47:08 and
  14:47:11 mid build, by their concurrency groups, when dispatched twins arrived
  while they held runners.
- session `43041725440`: runnerless when read; patch-transfer `43041725450`:
  **success**, release 14:46:44-14:47:16, probe 14:47:18-14:47:20.
- concurrency `43041724497`: **success** 14:46:52-14:47:26.

## What this does not establish

1. What an arpeggio sounds like. The tests prove scheduling, ordering and the
   routing into the note path; no ear, no audio device and no window were
   involved, and no screenshot was read.
2. The original application's step rate, subdivision values, gate, latch, swing
   and switch-off behaviour. All remain **Unknown**, and every rule applied is
   this repository's own and replaceable.
3. Anything about MIDI hardware, controllers or real devices.

## How progress.md was updated

`docs/progress.md` is 110 KB and the contents API replaces whole files, so the
append runs on a runner through a temporary dispatch-only job that appends this
file to the log; that job is removed in the following commit, which changes
documentation and tooling only.
