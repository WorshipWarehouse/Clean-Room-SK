import Foundation

/// Whether the probe managed to publish a source of its own.
///
/// Creating a virtual source is the only CoreMIDI call the connect probe needs,
/// and it stays in the app target. Everything that decides what the answer means
/// lives here, so a machine with no MIDI at all can assert every branch.
public enum MIDIVirtualSourceAttempt: Equatable, Sendable {
    /// The system accepted the source, described as it will be enumerated.
    case created(MIDIEndpointDescription)
    /// `MIDISourceCreate` refused, with its own status.
    case refused(status: Int32)

    /// The source that was created, when there is one.
    public var source: MIDIEndpointDescription? {
        if case let .created(source) = self { return source }
        return nil
    }
}

/// What the connect probe established, in one value.
public enum MIDIConnectProbeOutcome: Equatable, Sendable {
    /// The engine enumerated the probe's own source and its port accepted it.
    /// This is the only outcome that proves the connect path ran.
    case connected(uniqueID: Int32)
    /// The engine listed the source and the port refused it.
    case connectRefused(failure: MIDIStartFailure)
    /// The client or the port could not be created, so nothing was attempted.
    case startRefused(failure: MIDIStartFailure)
    /// The system created the source and the engine's own enumeration missed it.
    case virtualSourceNotEnumerated(uniqueID: Int32)
    /// The engine listed the source but neither connected nor refused it, which
    /// is what an endpoint it considered offline would do.
    case virtualSourceIdle(uniqueID: Int32)
    /// No source was published, so the connect path was not exercised at all.
    case noVirtualSource(status: Int32)

    /// True only for the one outcome that shows a source being connected.
    public var provesConnectPath: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 0 the port accepted the probe's own source, 4 no client or 5 no port, 6
    /// the port refused it, 7 the system would not publish a source, 8 the engine
    /// never listed it, 9 it was listed but nothing was attempted.
    public var exitCode: Int32 {
        switch self {
        case .connected: return 0
        case let .connectRefused(failure), let .startRefused(failure):
            return failure.exitCode
        case .noVirtualSource: return 7
        case .virtualSourceNotEnumerated: return 8
        case .virtualSourceIdle: return 9
        }
    }

    public var description: String {
        switch self {
        case let .connected(uniqueID):
            return "the port connected the probe's own source (unique id \(uniqueID))"
        case let .connectRefused(failure):
            return "the port refused the probe's own source: \(failure.description)"
        case let .startRefused(failure):
            return "the MIDI start was refused: \(failure.description)"
        case let .virtualSourceNotEnumerated(uniqueID):
            return "a source was created but the engine's enumeration did not list it (unique id \(uniqueID))"
        case let .virtualSourceIdle(uniqueID):
            return "the engine listed the source but neither connected nor refused it (unique id \(uniqueID))"
        case let .noVirtualSource(status):
            return "MIDISourceCreate failed with status \(status), so the connect path was not exercised"
        }
    }
}

/// A source the probe published itself, and the report the engine produced from
/// its own enumeration and its own connect.
///
/// The classification is what makes the CI step citable: a source the port
/// accepted reads differently from one the port refused, one the engine never
/// listed and one that was never created, and each of those has its own exit
/// status, so a green step cannot mean anything but a connect.
public struct MIDIConnectProbe: Equatable, Sendable {
    public let attempt: MIDIVirtualSourceAttempt
    public let verdict: MIDIStartVerdict

    public init(attempt: MIDIVirtualSourceAttempt, verdict: MIDIStartVerdict) {
        self.attempt = attempt
        self.verdict = verdict
    }

    /// The line the window would show, derived exactly as a start is.
    public var status: MIDIStatus { MIDIStatus(verdict: verdict) }

    public var report: MIDIStartReport? { verdict.report }

    public var outcome: MIDIConnectProbeOutcome {
        switch (attempt, verdict) {
        case let (_, .refused(failure)):
            return .startRefused(failure: failure)
        case let (.refused(status), _):
            return .noVirtualSource(status: status)
        case let (.created(source), .running(report)):
            guard let enumerated = report.inventory.sources.first(where: { $0.endpoint == source.endpoint })
                ?? report.inventory.sources.first(where: { $0.uniqueID == source.uniqueID })
            else {
                return .virtualSourceNotEnumerated(uniqueID: source.uniqueID)
            }
            if report.connected.contains(enumerated.uniqueID) {
                return .connected(uniqueID: enumerated.uniqueID)
            }
            if let failure = report.failures.first(where: { $0.sourceID == enumerated.endpoint }) {
                return .connectRefused(failure: failure)
            }
            return .virtualSourceIdle(uniqueID: enumerated.uniqueID)
        }
    }

    /// What the probe prints. The report lines are the ones a plain start prints,
    /// so the script reads the same markers, and the `MIDI probe:` lines say what
    /// the virtual source did.
    public var lines: [String] {
        var lines: [String] = []
        switch attempt {
        case let .created(source):
            lines.append("MIDI probe: virtual source created \"\(source.displayName)\" (unique id \(source.uniqueID))")
        case let .refused(status):
            lines.append("MIDI probe: virtual source refused: MIDISourceCreate failed with status \(status)")
        }
        lines.append(contentsOf: verdict.lines)
        if let report {
            lines.append("MIDI probe: engine enumerated \(report.inventory.count) source(s)")
            lines.append("MIDI probe: connected \(report.connected.count) of \(report.inventory.onlineCount) online source(s)")
        }
        lines.append("MIDI probe: status: \(status.text)")
        lines.append("MIDI probe: outcome: \(outcome.description)")
        return lines
    }
}
