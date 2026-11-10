/// The permission a sounding request needs.
///
/// `SessionLaunch` says what the launch may do in the window's words; this is the same
/// decision reduced to the one question the playback path asks. It exists so that playback
/// reads a decision rather than a Boolean that some other call site also happened to write:
/// an expired or unreadable standing refuses here, and every note path - the on-screen keys,
/// the MIDI transport and the arpeggiator - arrives at this type through
/// `AudioEngineController.noteOn`.
///
/// Which launch outcomes refuse is not a new rule: it is `SessionLaunch.allowsPremiumSounds`,
/// which the milestone doc records as rules 11 to 14. This type only gives that rule a name
/// and a line, so a refusal can be asserted without reading a stored flag.
public enum LicenceGate: Equatable, Sendable {
    /// The licensed sound set may sound: an `active` or `grace_period` verdict, or a launch
    /// with no verdict at all, because an unreachable server is not evidence about a licence.
    case permitted
    /// The licensed sound set must not sound, with the line that says why. The app still
    /// opens and the bank still loads; only the licensed playback is withheld.
    case refused(String)

    /// The gate that follows from a launch decision.
    public init(_ launch: SessionLaunch) {
        if launch.allowsPremiumSounds {
            self = .permitted
        } else {
            self = .refused(launch.line)
        }
    }

    /// Whether a note may start.
    public var permitsPlayback: Bool {
        switch self {
        case .permitted:
            return true
        case .refused:
            return false
        }
    }

    /// Why playback was refused, or `nil` when it was permitted.
    public var refusalLine: String? {
        switch self {
        case .permitted:
            return nil
        case let .refused(line):
            return line
        }
    }

    /// One line for a probe or a status readout, so a test asserts the same words a window
    /// would show instead of comparing against a bool.
    public var line: String {
        switch self {
        case .permitted:
            return "licensed playback permitted"
        case let .refused(line):
            return "licensed playback refused: \(line)"
        }
    }
}
