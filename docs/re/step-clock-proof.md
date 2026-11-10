## Step clock milestone: the arpeggiator now has a caller

`Arpeggiator` answers *which notes on the next step*; nothing called it, so no arpeggiated note was
ever produced. This milestone adds the layer that owns the timing and emits the events.

- **`docs/re/step-clock.md`** records what the analysis actually says: `ArpeggiatorStyleApi`'s six
  style names, `MidiEffectApi`'s arpeggiator as a per-patch effect, `SyncOptionApi` subdivision and
  frequency, `SubdivisionApi` quarter through thirtyTwo, and `MetronomeApi`/`tempo`/
  `_timeSignature` with the clock source recorded as **Unknown**. It marks the step rate, whether
  the original follows the patch tempo, the values behind the subdivision names, gate length and
  note-off behaviour, swing, latch and what a tempo change does mid-phrase as **Unknown**. Every
  rule the clock applies is labelled this repository's own and replaceable.
- **`StepClock`** takes its time from an injected `HostClock` and owns no timer, no dispatch source
  and no audio dependency. `tick()` repeats the step while the scheduled time is at or before the
  host's now, so a late tick produces the steps it missed instead of drifting a whole interval per
  call. The interval is `60 / bpm / stepsPerBeat`, with quarter, eighth, sixteenth and thirtySecond
  mapping to 1, 2, 4 and 8 steps per beat; the tempo is clamped by `MetronomeSettings.clampTempo`,
  so the step clock and the click agree on their range.
- **It emits the tree's existing note type.** Each step sends `MIDIMessage` note ons to a
  `NoteEventSink` at the instant they are due, with a note off scheduled at step time plus the gate
  fraction of the interval. Events leave in time order and, at equal timestamps, the offs precede
  the ons, so a pattern that revisits a note releases it before it sounds again. The audio engine
  interface is untouched: wiring the sink to `RealtimeKeysoundEngine.noteOn/noteOff` stays a
  caller's decision.
- **A tempo or division change applies after the step already scheduled**, so no step is pulled
  backwards into the past or skipped. Releasing a sounding note ends it at the release time and
  cancels its scheduled off, so a released key cannot hang. While nothing is held the clock emits
  nothing and holds its grid at the host's now, so the first note lands on the tick that sees it.
- **`StepClockTests`** drives a `ManualHostClock` and asserts exact `time on note` and
  `time off note` lines, twelve cases: the 120 bpm eighth-note grid at 0.0, 0.125, 0.25, 0.375, 0.5,
  0.625, 0.75, 0.875 and 1.0 second; offs before ons at a shared instant under a full gate; event
  times never going backwards; releasing the sounding note ending it at the release time and the
  pattern continuing with what remains; a style change taking effect on the next step; a tempo
  change halving the interval after the pending step and a division change doubling it; an empty
  held set producing no events with the first note landing immediately; a tick exactly on the first
  step producing exactly one step and no duplicate; the gate fraction moving the off; `stop`
  releasing the sounding note and ending the pattern; and a chord style emitting every note at one
  timestamp in pitch order.

**Observed.** The code and tests landed in `3a76ccdf` and four workflows read success on that exact
sha. Build run
[42853822439](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42853822439) completed
success at 16:23:45: setup 16:22:14 to 16:22:15, checkout 16:22:15 to 16:22:17, toolchain
16:22:17 to 16:22:21, dependency resolution 16:22:21 to 16:22:25, `Build (debug, with tests)`
16:22:25 to 16:22:53, `Report warnings` 16:22:53, `Test` 16:22:53 to 16:22:58 - the step that ran
the twelve new cases - `Build (release)` 16:22:58 to 16:23:24, `Bundle the app` 16:23:24 to
16:23:26, `Launch the app` 16:23:26 to 16:23:33, the audio probe 16:23:33 to 16:23:35, the MIDI
probe 16:23:35 to 16:23:37, the bootstrap check 16:23:37 to 16:23:40, and the job completed at
16:23:45. Session run
[42853822199](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42853822199) completed
success at 16:23:04 (release 16:22:21 to 16:22:53, bundle 16:22:53 to 16:22:55, probe 16:22:55 to
16:22:59); patch-transfer run
[42853821754](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42853821754) completed
success at 16:22:57 (release 16:22:20 to 16:22:52, bundle 16:22:52 to 16:22:54, probe 16:22:54 to
16:22:55); click run
[42853322733](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/42853322733) completed
success at 16:19:56 (release 16:19:21 to 16:19:46, bundle 16:19:46 to 16:19:48, probe 16:19:48 to
16:19:52).

**Obstacle, stated plainly.** The three runs the push itself triggered - build 42853323235, session
42853323261 and patch-transfer 42853322884 - sat queued with no runner assigned from 16:19:13 and
never ran a single step, while the click job from the same push was granted one immediately and
finished at 16:19:56. After I dispatched build, session and patch-transfer against `main` at
16:22:07, those three were cancelled at 16:22:08 to 16:22:10 without ever having started, and the
dispatched runs - 42853822439, 42853822199 and 42853821754 - are the ones read above. All of them
carried the same sha and the same tree: the cancellations were a runner-allocation outcome, not a
red build, and no step of those three ever executed.

**This write-up commit changes documentation only.** It inserts this section into `docs/progress.md`
and removes the proof file and the one-shot recorder that inserted it, so the text lives in the
write-up alone. It carries no run of its own by design; the runs cited above are on `3a76ccdf`.

**What this does not establish.** No note was heard: the tests prove scheduling and ordering, not
sound, and a runner can judge neither. The clock is not yet wired to the engine, so a player still
cannot hold a chord and hear a pattern. Every timing rule above is this repository's own decision,
and the original's step rate, subdivision values, gate, latch and swing stay **Unknown** until a
capture replaces them.
