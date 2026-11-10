import Foundation

/// What the MIDI start last did, in a form the window can show.
///
/// `MIDIStartVerdict` is the full answer a caller can inspect; this is the one
/// line derived from it. It lives in the core module so the wording is asserted by
/// tests instead of being decided inside a view, and so a refusal can never be
/// dropped on the way to the window without a test noticing.
public enum MIDIStatus: Equatable, Sendable {
    /// No start has been attempted yet.
    case notStarted
    /// The client and the input port exist. `available` sources were enumerated
    /// and `connected` of them were connected.
    case ready(connected: Int, available: Int)
    /// The client and the port exist, but a source refused the connection.
    case degraded(connected: Int, available: Int, failure: MIDIStartFailure)
    /// No client or no input port, so nothing could be enumerated at all.
    case unavailable(MIDIStartFailure)

    public init(verdict: MIDIStartVerdict) {
        switch verdict {
        case .refused(let failure):
            self = .unavailable(failure)
        case .running(let report):
            let connected = report.connected.count
            let available = report.inventory.count
            if let failure = report.failures.first {
                self = .degraded(connected: connected, available: available, failure: failure)
            } else {
                self = .ready(connected: connected, available: available)
            }
        }
    }

    /// The short line the window shows. The wording is pinned by tests: a client
    /// with no sources reads differently from one with sources that none could be
    /// connected to, and both refusals name the call that failed and its status,
    /// so no two outcomes read the same.
    public var text: String {
        switch self {
        case .notStarted:
            return "MIDI not started"
        case let .ready(connected, available):
            guard available > 0 else { return "MIDI ready, no sources found" }
            return "MIDI ready, \(connected) of \(available) source(s) connected"
        case let .degraded(connected, available, failure):
            return "MIDI ready, \(connected) of \(available) source(s) connected; \(failure.description)"
        case .unavailable(let failure):
            return "MIDI unavailable: \(failure.description)"
        }
    }

    /// True only when nothing usable was created, so a caller can tell a refused
    /// start apart from a client that simply found no controller.
    public var isFailure: Bool {
        if case .unavailable(_) = self { return true }
        return false
    }

    /// The existing status line with this appended, so the surface the window
    /// already has can report a start that never reached CoreMIDI. Before the
    /// first attempt there is nothing to add.
    public func message(base: String) -> String {
        switch self {
        case .notStarted:
            return base
        default:
            return "\(base) \u{00b7} \(text)"
        }
    }
}

/// Holds the latest MIDI status.
///
/// The service returns a verdict to whoever started it, and the app model is that
/// caller. Keeping the last one here means the outcome is a piece of state rather
/// than a value that gets read for one expression and forgotten, which is exactly
/// how the refusal used to disappear. A refresh goes through the same derivation
/// as a start, so the text cannot drift between "pressed Start" and "a controller
/// was just plugged in".
public struct MIDIStatusBoard: Equatable, Sendable {
    public private(set) var status: MIDIStatus

    public init(status: MIDIStatus = .notStarted) {
        self.status = status
    }

    /// Records what a start or refresh returned, and hands it back so the caller
    /// does not have to read `status` twice.
    @discardableResult
    public mutating func record(_ verdict: MIDIStartVerdict) -> MIDIStatus {
        status = MIDIStatus(verdict: verdict)
        return status
    }

    /// Applies a report from the client that is already running, which is what a
    /// source appearing or disappearing produces. It is the same derivation as a
    /// start, so the status follows the actual source list for as long as the
    /// client lives.
    @discardableResult
    public mutating func refresh(with report: MIDIStartReport) -> MIDIStatus {
        record(.running(report))
    }

    public mutating func reset() {
        status = .notStarted
    }
}
