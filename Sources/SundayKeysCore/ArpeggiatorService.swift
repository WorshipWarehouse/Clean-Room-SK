import Foundation

/// The note path a stepped pattern plays into.
///
/// `RealtimeKeysoundEngine` already has exactly these two methods, so it conforms as it stands and
/// the engine's interface is not touched. The caller emits into the path that exists rather than a
/// parallel one.
public protocol KeysoundNoteTarget: AnyObject {
    func noteOn(note: UInt8, velocity: UInt8)
    func noteOff(note: UInt8)
}

extension RealtimeKeysoundEngine: KeysoundNoteTarget {}

/// Turns the step clock's note events into calls on the keysound path.
///
/// The instant a `NoteEventSink` is handed is what a scheduler needs and what a live engine does
/// not: the clock calls this on the tick that is due, so forwarding at once is the whole of the
/// work. A message that is not a note is ignored rather than guessed at.
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
/// The service owns the held set and the `StepClock`, so every change a player makes is one call:
/// a key press, a key release, a style change, a tempo or division change. It holds no timer of its
/// own - the caller that owns time asks it to `tick()` - and it makes no sound: the notes leave
/// through a `NoteEventSink`, which by default is the keysound path.
///
/// With the arpeggiator off, a press and a release are forwarded unchanged, so the keyboard still
/// plays. Switching it off releases the pattern, and a key still held is not retriggered: it sounds
/// again when it is pressed again. Both rules are this repository's own; the analysis records
/// nothing about what the original does when the effect is switched.
public final class ArpeggiatorService {
    public private(set) var style: ArpeggiatorStyle
    public private(set) var isEnabled: Bool
    public private(set) var beatsPerMinute: Double
    public private(set) var division: StepDivision
    public private(set) var gateFraction: Double
    public private(set) var velocity: UInt8
    public private(set) var channel: UInt8

    private let sink: NoteEventSink
    private let stepClock: StepClock
    private var held: Set<UInt8> = []
    /// Notes forwarded while the arpeggiator is off, so the matching release reaches the same path.
    private var forwarded: Set<UInt8> = []

    public init(
        clock: HostClock,
        target: KeysoundNoteTarget,
        sink: NoteEventSink? = nil,
        style: ArpeggiatorStyle = .up,
        isEnabled: Bool = false,
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
        self.beatsPerMinute = settings.beatsPerMinute
        self.division = settings.division
        self.gateFraction = settings.gateFraction
        self.velocity = settings.velocity
        self.channel = settings.channel
        self.stepClock = StepClock(clock: clock, sink: noteSink, style: style, settings: settings)
    }

    /// The notes the player is holding, ascending and deduplicated.
    public var heldNotes: [UInt8] { held.sorted() }

    /// True while the pattern is running, which it is only with the arpeggiator on and a key down.
    public var isStepping: Bool { isEnabled && !held.isEmpty }

    /// A key press. The first press of a chord starts the pattern on that instant; a press that
    /// arrives mid-phrase joins it on the next step. With the arpeggiator off the press goes
    /// straight to the note path, carrying the pressed velocity.
    public func keyDown(note: UInt8, velocity pressedVelocity: UInt8, at time: TimeInterval) {
        let key = min(note, 127)

        guard isEnabled else {
            guard forwarded.insert(key).inserted else { return }
            sink.send(.noteOn(note: key, velocity: pressedVelocity, channel: channel), at: time)
            return
        }

        guard held.insert(key).inserted else { return }
        stepClock.hold(key, at: time)
        stepClock.apply(settings(isRunning: true), at: time)
    }

    /// A key release. A note that is sounding ends at once and its scheduled note off is cancelled;
    /// releasing the last held note stops the pattern.
    public func keyUp(note: UInt8, at time: TimeInterval) {
        let key = min(note, 127)

        guard isEnabled else {
            guard forwarded.remove(key) != nil else { return }
            sink.send(.noteOff(note: key, velocity: 0, channel: channel), at: time)
            return
        }

        guard held.remove(key) != nil else { return }
        stepClock.release(key, at: time)
        if held.isEmpty {
            stepClock.stop(at: time)
        }
    }

    /// Switches the arpeggiator on or off.
    ///
    /// Switching it on while keys are held starts the pattern on that instant, and releases anything
    /// that was being forwarded so the pattern takes over. Switching it off releases the pattern and
    /// cancels its scheduled note offs; a key still held is left silent until it is pressed again.
    public func setEnabled(_ enabled: Bool, at time: TimeInterval) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            for note in forwarded.sorted() {
                sink.send(.noteOff(note: note, velocity: 0, channel: channel), at: time)
            }
            forwarded.removeAll()
            for note in held.sorted() {
                stepClock.hold(note, at: time)
            }
            stepClock.apply(settings(isRunning: true), at: time)
        } else {
            stepClock.stop(at: time)
            forwarded.removeAll()
        }
    }

    /// The style takes effect on the next step, because the pattern restarts from its first step.
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

    /// The velocity every step carries. The pattern is not tied to one key, so the pressed velocity
    /// of the key that started it is not reused.
    public func setVelocity(_ value: UInt8) {
        velocity = min(max(value, 1), 127)
    }

    /// Emits every event the host's time has reached. The caller that owns time decides when.
    public func tick() {
        stepClock.tick()
    }

    /// Releases everything this service is sounding and stops the pattern.
    public func allNotesOff(at time: TimeInterval) {
        for note in forwarded.sorted() {
            sink.send(.noteOff(note: note, velocity: 0, channel: channel), at: time)
        }
        forwarded.removeAll()
        held.removeAll()
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
