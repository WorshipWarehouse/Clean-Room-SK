import Foundation

/// Where the step clock gets its time.
///
/// The clock owns no timer, no dispatch source and no audio dependency: whatever advances
/// time asks `tick()`, and the clock reads `now` from here. That is what lets a test run a
/// whole pattern in one call with exact timestamps, and what keeps the scheduling decision
/// out of the render thread.
public protocol HostClock {
    var now: TimeInterval { get }
}

/// A host clock a caller or a test moves by hand.
public final class ManualHostClock: HostClock {
    public var now: TimeInterval

    public init(now: TimeInterval = 0) {
        self.now = now
    }

    public func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

/// Where stepped notes go.
///
/// The message type is `MIDIMessage`, the same value the input port parses into, so the clock
/// adds no second shape to the tree. The time is the instant the message is due; a sink that
/// sits in front of `RealtimeKeysoundEngine` uses it to order and to schedule, and a sink that
/// writes straight through ignores it.
public protocol NoteEventSink {
    func send(_ message: MIDIMessage, at time: TimeInterval)
}

/// How many steps fall in one beat.
///
/// The analysis names quarter through thirtyTwo in `SubdivisionApi` but records no values, so the
/// mapping here is this repository's own and replaceable.
public enum StepDivision: Int, CaseIterable, Sendable {
    case quarter = 1
    case eighth = 2
    case sixteenth = 4
    case thirtySecond = 8

    public var stepsPerBeat: Int { rawValue }
}

/// What the player asked the step clock to do.
///
/// The initialiser clamps, so a slider or a hand-edited value cannot put the clock outside a range
/// it can schedule: the tempo uses the click's own bounds, the gate stays inside its own, and a
/// velocity of zero becomes one because a zero-velocity note on is a note off on the wire.
public struct StepClockSettings: Equatable, Sendable {
    public var isRunning: Bool
    public var beatsPerMinute: Double
    public var division: StepDivision
    public var gateFraction: Double
    public var velocity: UInt8
    public var channel: UInt8

    public init(
        isRunning: Bool = false,
        beatsPerMinute: Double = 120,
        division: StepDivision = .eighth,
        gateFraction: Double = 0.5,
        velocity: UInt8 = 100,
        channel: UInt8 = 0
    ) {
        self.isRunning = isRunning
        self.beatsPerMinute = MetronomeSettings.clampTempo(beatsPerMinute)
        self.division = division
        self.gateFraction = min(max(gateFraction, 0.05), 1)
        self.velocity = min(max(velocity, 1), 127)
        self.channel = min(channel, 15)
    }

    /// Seconds between two steps at the current tempo and division.
    public var stepInterval: TimeInterval {
        60 / beatsPerMinute / Double(division.stepsPerBeat)
    }
}

/// Turns a held chord into stepped note on and note off messages, one step at a time.
///
/// The clock is the `Arpeggiator`'s only caller: it decides when a step is due, asks the pattern
/// which notes sound, and emits each note on followed by a scheduled note off. It holds no timer
/// and never reads a clock of its own, so a caller that owns time drives it by calling `tick()`.
///
/// Ordering
/// --------
/// Events leave in time order, and at equal timestamps the note offs go first, so a pattern that
/// revisits a note releases it before it sounds again.
///
/// Late ticks
/// ----------
/// `tick()` steps while the scheduled time is at or before the host's now. A tick that arrives
/// late therefore produces every step it missed, which keeps the grid aligned to the host instead
/// of drifting a whole interval per late call.
public final class StepClock {
    private let clock: HostClock
    private let sink: NoteEventSink
    private var arpeggiator: Arpeggiator
    private var settings: StepClockSettings
    private var nextStepTime: TimeInterval?
    private var pendingOffs: [(time: TimeInterval, message: MIDIMessage)] = []
    private var sounding: Set<UInt8> = []

    public init(
        clock: HostClock,
        sink: NoteEventSink,
        style: ArpeggiatorStyle = .up,
        octaves: Int = 1,
        settings: StepClockSettings = StepClockSettings()
    ) {
        self.clock = clock
        self.sink = sink
        self.arpeggiator = Arpeggiator(style: style, octaves: octaves)
        self.settings = settings
        if settings.isRunning {
            self.nextStepTime = clock.now
        }
    }

    public var currentSettings: StepClockSettings { settings }
    public var heldNotes: [UInt8] { arpeggiator.held }
    public var isRunning: Bool { settings.isRunning }
    /// How many octaves the pattern spans, as the pattern holds it.
    public var octaves: Int { arpeggiator.octaves }

    /// Starts holding a note. A note that arrives mid-phrase joins the pattern on the next step;
    /// a note that arrives into an idle clock sounds on the tick that sees it.
    public func hold(_ note: UInt8, at time: TimeInterval) {
        let wasIdle = arpeggiator.held.isEmpty
        arpeggiator.hold(note)
        if settings.isRunning && wasIdle {
            nextStepTime = time
        }
    }

    /// Releases a note. A note that is currently sounding is ended at once, at the release time,
    /// and its scheduled note off is cancelled, so a released key never hangs.
    public func release(_ note: UInt8, at time: TimeInterval) {
        arpeggiator.release(note)
        guard sounding.remove(note) != nil else { return }
        let off = MIDIMessage.noteOff(note: note, velocity: 0, channel: settings.channel)
        pendingOffs.removeAll { $0.message == off }
        sink.send(off, at: time)
    }

    public func setStyle(_ style: ArpeggiatorStyle) {
        arpeggiator.setStyle(style)
    }

    /// Changes how many octaves the cycle spans. It takes effect on the next step,
    /// because the pattern restarts from its first step: a cursor counted over one
    /// cycle means nothing in another. The span is clamped to one to four by the
    /// pattern itself.
    public func setOctaves(_ octaves: Int) {
        arpeggiator.setOctaves(octaves)
    }

    /// Publishes new settings. Starting anchors the grid at the given time; stopping clears it.
    /// A tempo or division change leaves the step already scheduled where it is and applies the
    /// new interval after it, so no step is pulled backwards or skipped.
    public func apply(_ settings: StepClockSettings, at time: TimeInterval) {
        let wasRunning = self.settings.isRunning
        self.settings = settings
        if settings.isRunning && !wasRunning {
            nextStepTime = time
        } else if !settings.isRunning {
            nextStepTime = nil
        }
    }

    /// Releases everything, cancels every scheduled note off and stops the pattern.
    public func stop(at time: TimeInterval) {
        settings.isRunning = false
        nextStepTime = nil
        pendingOffs.removeAll()
        for note in sounding.sorted() {
            sink.send(.noteOff(note: note, velocity: 0, channel: settings.channel), at: time)
        }
        sounding.removeAll()
        arpeggiator.releaseAll()
    }

    /// Emits every event the host's time has reached, in order.
    public func tick() {
        let now = clock.now

        // Nothing held means no pattern: hold the grid at now so the first note lands at once.
        if arpeggiator.held.isEmpty {
            while let first = pendingOffs.first, first.time <= now {
                emitEarliestOff()
            }
            nextStepTime = now
            return
        }

        while true {
            let stepTime = settings.isRunning ? nextStepTime : nil
            let offTime = pendingOffs.first?.time

            switch (stepTime, offTime) {
            case let (scheduled?, off?):
                if off <= scheduled {
                    guard off <= now else { return }
                    emitEarliestOff()
                } else {
                    guard scheduled <= now else { return }
                    emitStep(at: scheduled)
                    nextStepTime = scheduled + settings.stepInterval
                }
            case let (scheduled?, nil):
                guard scheduled <= now else { return }
                emitStep(at: scheduled)
                nextStepTime = scheduled + settings.stepInterval
            case let (nil, off?):
                guard off <= now else { return }
                emitEarliestOff()
            case (nil, nil):
                return
            }
        }
    }

    // MARK: - Emitting

    private func emitStep(at time: TimeInterval) {
        let notes = arpeggiator.advance()
        guard !notes.isEmpty else { return }
        let gate = settings.gateFraction * settings.stepInterval
        for note in notes {
            sink.send(.noteOn(note: note, velocity: settings.velocity, channel: settings.channel), at: time)
            sounding.insert(note)
            schedule(.noteOff(note: note, velocity: 0, channel: settings.channel), at: time + gate)
        }
    }

    private func emitEarliestOff() {
        let entry = pendingOffs.removeFirst()
        if case let .noteOff(note, _, _) = entry.message {
            sounding.remove(note)
        }
        sink.send(entry.message, at: entry.time)
    }

    private func schedule(_ message: MIDIMessage, at time: TimeInterval) {
        let index = pendingOffs.firstIndex { $0.time > time } ?? pendingOffs.count
        pendingOffs.insert((time, message), at: index)
    }
}
