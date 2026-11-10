import Foundation

/// The arpeggiator's panel: the one place the window's controls reach.
///
/// `ArpeggiatorService` is the rule and the state. This type is the
/// surface a view binds to, so the section has no logic of its own: on or
/// off, latch, the pattern, the octave span, tempo, division, a key press
/// and a tick are each one method here, and each one routes to the service
/// the panel was built around.
///
/// Every method reads the instant from the clock the panel was given
/// rather than starting a timer, so a test can move time by hand and
/// assert exactly when a toggle took effect. That is the same arrangement
/// the service uses, one layer up.
///
/// The words are this repository's own. The analysis records the original's
/// panel as **Unknown**, so nothing here claims to reproduce a layout; the
/// controls are named for what they do, and latch, the pattern names the
/// analysis observed, and the octave span are labelled as this
/// repository's own rules.
public final class ArpeggiatorPanel {
    public let service: ArpeggiatorService
    private let clock: HostClock

    public init(service: ArpeggiatorService, clock: HostClock) {
        self.service = service
        self.clock = clock
    }

    /// A panel over a fresh service that plays into `target`.
    public convenience init(clock: HostClock, target: KeysoundNoteTarget) {
        self.init(
            service: ArpeggiatorService(clock: clock, target: target),
            clock: clock
        )
    }

    /// The instant the panel would use for its next change.
    public var now: TimeInterval { clock.now }

    public var isEnabled: Bool { service.isEnabled }
    public var isLatched: Bool { service.isLatched }
    public var pattern: ArpeggiatorStyle { service.style }
    public var octaves: Int { service.octaves }
    public var beatsPerMinute: Double { service.beatsPerMinute }
    public var division: StepDivision { service.division }
    public var heldNotes: [UInt8] { service.heldNotes }
    public var isStepping: Bool { service.isStepping }

    /// The words the section shows for latch, in one place so the toggle and
    /// the status line cannot disagree.
    public var latchLabel: String { isLatched ? "Latch on" : "Latch off" }

    public var divisionLabel: String { Self.label(for: division) }

    public var patternLabel: String { Self.label(for: pattern) }

    /// Singular and plural, because the status line is read by a player
    /// rather than parsed.
    public var octavesLabel: String {
        octaves == 1 ? "1 octave" : "\(octaves) octaves"
    }

    /// The section's one-line report: what the arpeggiator is doing, how it
    /// is walking the chord, how wide a span it covers, whether latch is on
    /// and the grid it is stepping on.
    public var statusLine: String {
        let shape = "\(patternLabel), \(octavesLabel)"
        let grid = "\(Int(beatsPerMinute.rounded())) bpm, \(divisionLabel)"
        if isStepping {
            return "Arp stepping, \(latchLabel.lowercased()), \(shape), \(grid)"
        }
        return "Arp \(isEnabled ? "on" : "off"), "
            + "\(latchLabel.lowercased()), \(shape), \(grid)"
    }

    /// The patterns the section offers. The analysis names six orderings but
    /// records no behaviour for any of them, so the picker shows the three a
    /// player can predict from the word alone; the rest stay reachable in the
    /// core for when a capture says what they do.
    public static let patternChoices: [ArpeggiatorStyle] = [.up, .down, .upDown]

    /// The names this repository uses for the orderings it schedules. The
    /// analysis names the cases and records no values, so the mapping behind
    /// these words is this repository's own and replaceable.
    public static func label(for pattern: ArpeggiatorStyle) -> String {
        switch pattern {
        case .up: return "Up"
        case .down: return "Down"
        case .upDown: return "UpDown"
        case .downUp: return "DownUp"
        case .random: return "Random"
        case .chord: return "Chord"
        }
    }

    /// The names this repository uses for the divisions it schedules. The
    /// analysis names quarter through thirtyTwo and records no values, so the
    /// mapping behind these words is this repository's own and replaceable.
    public static func label(for division: StepDivision) -> String {
        switch division {
        case .quarter: return "quarter"
        case .eighth: return "eighth"
        case .sixteenth: return "sixteenth"
        case .thirtySecond: return "thirty-second"
        }
    }

    // MARK: - Controls

    public func toggleEnabled() { setEnabled(!isEnabled) }

    public func setEnabled(_ enabled: Bool) {
        service.setEnabled(enabled, at: now)
    }

    public func toggleLatch() { setLatched(!isLatched) }

    /// Switching latch off drops the notes no key is holding at this instant,
    /// which is the instant the toggle was pressed.
    public func setLatched(_ latched: Bool) {
        service.setLatched(latched, at: now)
    }

    /// The pattern takes effect on the next step, because the cycle restarts
    /// from its first step.
    public func setPattern(_ pattern: ArpeggiatorStyle) {
        service.setStyle(pattern)
    }

    /// The octave span takes effect on the next step, for the same reason the
    /// pattern does.
    public func setOctaves(_ value: Int) {
        service.setOctaves(value)
    }

    public func setBeatsPerMinute(_ value: Double) {
        service.setBeatsPerMinute(value, at: now)
    }

    public func setDivision(_ value: StepDivision) {
        service.setDivision(value, at: now)
    }

    // MARK: - Playing

    public func keyDown(note: UInt8, velocity pressedVelocity: UInt8) {
        service.keyDown(note: note, velocity: pressedVelocity, at: now)
    }

    public func keyUp(note: UInt8) {
        service.keyUp(note: note, at: now)
    }

    public func tick() { service.tick() }

    public func allNotesOff() { service.allNotesOff(at: now) }
}
