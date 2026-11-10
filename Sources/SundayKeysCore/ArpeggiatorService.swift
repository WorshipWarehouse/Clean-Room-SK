import Foundation

/// The note path a stepped pattern plays into.
///
/// `RealtimeKeysoundEngine` already has exactly these two methods, so it
/// conforms as it stands and the engine's interface is not touched. The
/// caller emits into the path that exists rather than a parallel one.
public protocol KeysoundNoteTarget: AnyObject {
    func noteOn(note: UInt8, velocity: UInt8)
    func noteOff(note: UInt8)
}

extension RealtimeKeysoundEngine: KeysoundNoteTarget {}

/// Turns the step clock's note events into calls on the keysound path.
///
/// The instant a `NoteEventSink` is handed is what a scheduler needs and
/// what a live engine does not: the clock calls this on the tick that is
/// due, so forwarding at once is the whole of the work. A message that is
/// not a note is ignored rather than guessed at.
public final class KeysoundNoteSink: NoteEventSink {
    private let target: KeysoundNoteTarget

    public init(target: KeysoundNoteTarget) {
        self.target = target
    }

    public func send(_ message: MIDIMessage, at time: TimeInterval) {
        switch message {
        case let .noteOn(note, velocity, _):
            target.noteOn(note: note, velocity: velocity)
        case let .noteOff(note, _, _):
            target.noteOff(note: note)
        case .controlChange, .programChange, .pitchBend, .other:
            break
        }
    }
}

/// The arpeggiator's caller: held keys in, scheduled note events out.
///
/// The service owns the held set and the `StepClock`, so every change a
/// player makes is one call: a key press, a key release, a style change, a
/// tempo or division change. It holds no timer of its own - the caller
/// that owns time asks it to `tick()` - and it makes no sound: the notes
/// leave through a `NoteEventSink`, which by default is the keysound path.
///
/// With the arpeggiator off, a press and a release are forwarded
/// unchanged, so the keyboard still plays. Switching it off releases the
/// pattern, and a key still held is not retriggered: it sounds again when
/// it is pressed again. Both rules are this repository's own; the analysis
/// records nothing about what the original does when the effect is
/// switched.
///
/// Latch is ours as well. The analysis records latch as **Unknown**, so
/// the rule here is this repository's own and replaceable: with latch on,
/// a released key stays in the pattern and the pattern keeps running with
/// no key down; the next press made with nothing physically held begins a
/// new chord and releases the previous one at that same instant, so
/// lifting your hands and playing again cannot leave the old notes
/// sounding. A key pressed while another is still down joins the running
/// pattern instead. Latch does nothing while the arpeggiator is off,
/// where keys pass straight through.
public final class ArpeggiatorService {
    public private(set) var style: ArpeggiatorStyle
    public private(set) var isEnabled: Bool
    public private(set) var isLatched: Bool
    public private(set) var beatsPerMinute: Double
    public private(set) var division: StepDivision
    public private(set) var gateFraction: Double
    public private(set) var velocity: UInt8
    public private(set) var channel: UInt8

    private let sink: NoteEventSink
    private let stepClock: StepClock
    /// The notes the pattern plays. With latch on this outlives the keys.
    private var held: Set<UInt8> = []
    /// The keys the player is physically holding, which is what latch
    /// measures a release against.
    private var physicallyHeld: Set<UInt8> = []
    /// Notes forwarded while the arpeggiator is off, so the matching
    /// release reaches the same path.
    private var forwarded: Set<UInt8> = []

    public init(
        clock: HostClock,
        target: KeysoundNoteTarget,
        sink: NoteEventSink? = nil,
        style: ArpeggiatorStyle = .up,
        isEnabled: Bool = false,
        isLatched: Bool = false,
        beatsPerMinute: Double = 120,
        division: StepDivision = .eighth,
        gateFraction: Double = 0.5,
        velocity: UInt8 = 100,
        channel: UInt8 = 0
    ) {
        let noteSink = sink ?? KeysoundNoteSink(target: target)
        let settings = StepClockSettings(
            isRunning: isEnabled,
            beatsPerMinute: beatsPerMinute,
            division: division,
            gateFraction: gateFraction,
            velocity: velocity,
            channel: channel
        )

        self.sink = noteSink
        self.style = style
        self.isEnabled = isEnabled
        self.isLatched = isLatched
        self.beatsPerMinute = settings.beatsPerMinute
        self.division = settings.division
        self.gateFraction = settings.gateFraction
        self.velocity = settings.velocity
        self.channel = settings.channel
        self.stepClock = StepClock(
            clock: clock,
            sink: noteSink,
            style: style,
            settings: settings
        )
    }

    /// The notes the pattern plays, ascending and deduplicated. With latch
    /// on these stay after the keys that started them come up.
    public var heldNotes: [UInt8] { held.sorted() }

    /// True while the pattern is running, which it is only with the
    /// arpeggiator on and a note in the pattern.
    public var isStepping: Bool { isEnabled && !held.isEmpty }

    /// A key press. The first press of a chord starts the pattern on that
    /// instant; a press that arrives mid-phrase joins it on the next step.
    /// With the arpeggiator off the press goes straight to the note path,
    /// carrying the pressed velocity.
    ///
    /// Under latch, a press made with no key physically held is the first
    /// note of a new chord: the previous chord is released at this instant
    /// and the pattern restarts here.
    public func keyDown(
        note: UInt8,
        velocity pressedVelocity: UInt8,
        at time: TimeInterval
    ) {
        let key = min(note, 127)

        guard isEnabled else {
            guard forwarded.insert(key).inserted else { return }
            sink.send(
                .noteOn(
                    note: key,
                    velocity: pressedVelocity,
                    channel: channel
                ),
                at: time
            )
            return
        }

        let beginsChord = isLatched && physicallyHeld.isEmpty
        physicallyHeld.insert(key)

        if beginsChord {
            // The pattern has been running on notes the player let go of,
            // so this press starts the next chord and ends the old one.
            stepClock.stop(at: time)
            held.removeAll()
        }

        guard held.insert(key).inserted else { return }
        stepClock.hold(key, at: time)
        stepClock.apply(settings(isRunning: true), at: time)
    }

    /// A key release. A note that is sounding ends at once and its
    /// scheduled note off is cancelled; releasing the last held note stops
    /// the pattern. With latch on the release only removes the key from
    /// the set the player is physically holding.
    public func keyUp(note: UInt8, at time: TimeInterval) {
        let key = min(note, 127)

        guard isEnabled else {
            guard forwarded.remove(key) != nil else { return }
            sink.send(
                .noteOff(note: key, velocity: 0, channel: channel),
                at: time
            )
            return
        }

        physicallyHeld.remove(key)
        guard !isLatched else { return }

        guard held.remove(key) != nil else { return }
        stepClock.release(key, at: time)
        if held.isEmpty {
            stepClock.stop(at: time)
        }
    }

    /// Switches latch on or off.
    ///
    /// Switching it on releases nothing: the notes already in the pattern
    /// simply stop leaving it when their keys come up. Switching it off
    /// drops the notes no key is holding at that instant, and stops the
    /// pattern when none remain.
    public func setLatched(_ latched: Bool, at time: TimeInterval) {
        guard latched != isLatched else { return }
        isLatched = latched
        guard !latched else { return }

        let dropped = held.subtracting(physicallyHeld).sorted()
        guard !dropped.isEmpty else { return }
        for note in dropped {
            held.remove(note)
            stepClock.release(note, at: time)
        }
        if held.isEmpty {
            stepClock.stop(at: time)
        }
    }

    /// Switches the arpeggiator on or off.
    ///
    /// Switching it on while keys are held starts the pattern on that
    /// instant: the notes that were being forwarded are released and then
    /// held by the pattern, so the keys the player is already holding are
    /// the first step's notes. Switching it off releases the pattern and
    /// cancels its scheduled note offs; a key still held is left silent
    /// until it is pressed again.
    public func setEnabled(_ enabled: Bool, at time: TimeInterval) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            let carried = forwarded.sorted()
            forwarded.removeAll()
            for note in carried {
                sink.send(
                    .noteOff(note: note, velocity: 0, channel: channel),
                    at: time
                )
            }
            for note in carried {
                held.insert(note)
                physicallyHeld.insert(note)
                stepClock.hold(note, at: time)
            }
            stepClock.apply(settings(isRunning: true), at: time)
        } else {
            stepClock.stop(at: time)
            held.removeAll()
            physicallyHeld.removeAll()
            forwarded.removeAll()
        }
    }

    /// The style takes effect on the next step, because the pattern
    /// restarts from its first step.
    public func setStyle(_ style: ArpeggiatorStyle) {
        self.style = style
        stepClock.setStyle(style)
    }

    /// A tempo change lands after the step already scheduled.
    public func setBeatsPerMinute(_ value: Double, at time: TimeInterval) {
        beatsPerMinute = MetronomeSettings.clampTempo(value)
        stepClock.apply(settings(isRunning: isEnabled), at: time)
    }

    /// A division change lands after the step already scheduled.
    public func setDivision(_ value: StepDivision, at time: TimeInterval) {
        division = value
        stepClock.apply(settings(isRunning: isEnabled), at: time)
    }

    /// A shorter gate moves the note offs earlier from the next step on.
    public func setGateFraction(_ value: Double) {
        gateFraction = min(max(value, 0.05), 1)
    }

    /// The velocity every step carries. The pattern is not tied to one
    /// key, so the pressed velocity of the key that started it is not
    /// reused.
    public func setVelocity(_ value: UInt8) {
        velocity = min(max(value, 1), 127)
    }

    /// Emits every event the host's time has reached. The caller that owns
    /// time decides when.
    public func tick() {
        stepClock.tick()
    }

    /// Releases everything this service is sounding and stops the pattern.
    public func allNotesOff(at time: TimeInterval) {
        for note in forwarded.sorted() {
            sink.send(
                .noteOff(note: note, velocity: 0, channel: channel),
                at: time
            )
        }
        forwarded.removeAll()
        held.removeAll()
        physicallyHeld.removeAll()
        stepClock.stop(at: time)
    }

    private func settings(isRunning running: Bool) -> StepClockSettings {
        StepClockSettings(
            isRunning: running,
            beatsPerMinute: beatsPerMinute,
            division: division,
            gateFraction: gateFraction,
            velocity: velocity,
            channel: channel
        )
    }
}
