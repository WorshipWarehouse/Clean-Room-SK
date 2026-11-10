import Foundation

/// What one CoreMIDI source looks like, in a form that can be tested without
/// CoreMIDI being present.
///
/// The reader in the app target fills these in. Everything below it — the
/// summary, the per-source line and the exit status — is pure, so the probe's
/// verdict is asserted by unit tests rather than only by whatever hardware a
/// runner happens to have.
public struct MIDIEndpointDescription: Equatable, Sendable {
    /// The endpoint reference a port connects to.
    public let endpoint: UInt32
    /// CoreMIDI's identifier for the endpoint, stable across launches.
    public let uniqueID: Int32
    /// `kMIDIPropertyDisplayName`, when the endpoint publishes one.
    public let name: String?
    /// `kMIDIPropertyManufacturer`, when the endpoint publishes one.
    public let manufacturer: String?
    /// False when `kMIDIPropertyOffline` says the endpoint cannot be used.
    public let online: Bool

    public init(
        endpoint: UInt32,
        uniqueID: Int32,
        name: String? = nil,
        manufacturer: String? = nil,
        online: Bool = true
    ) {
        self.endpoint = endpoint
        self.uniqueID = uniqueID
        self.name = name
        self.manufacturer = manufacturer
        self.online = online
    }

    /// The name to show. A source with no name still has to be distinguishable
    /// from the next unnamed one, so its unique id stands in for it.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "unnamed source \(uniqueID)"
    }

    public var manufacturerName: String {
        if let manufacturer, !manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manufacturer
        }
        return "unknown manufacturer"
    }

    /// One report line, with a 1-based position so two entries stay
    /// distinguishable even when their names are not.
    public func summaryLine(position: Int, total: Int) -> String {
        let state = online ? "online" : "offline"
        return "MIDI: source \(position) of \(total): \"\(displayName)\" by \(manufacturerName), \(state)"
    }
}

/// The sources one enumeration returned, split into what a port can connect and
/// what it cannot.
public struct MIDIInventory: Equatable, Sendable {
    public let sources: [MIDIEndpointDescription]

    public init(sources: [MIDIEndpointDescription]) {
        self.sources = sources
    }

    public var count: Int { sources.count }

    /// The sources a port is expected to accept.
    public var online: [MIDIEndpointDescription] { sources.filter(\.online) }

    public var offline: [MIDIEndpointDescription] { sources.filter { !$0.online } }

    public var onlineCount: Int { online.count }

    /// The line the smoke script reads to learn how many sources exist, including
    /// the zero case a runner with no controller shows.
    public var summaryLine: String {
        "MIDI: \(count) source(s): \(onlineCount) online, \(offline.count) offline"
    }

    public func summaryLines() -> [String] {
        var lines = [summaryLine]
        for (index, source) in sources.enumerated() {
            lines.append(source.summaryLine(position: index + 1, total: count))
        }
        return lines
    }
}

/// Why the MIDI start could not finish, and the exit status that says which part
/// failed.
public enum MIDIStartFailure: Error, Equatable, Sendable {
    case clientCreationFailed(status: Int32)
    case inputPortCreationFailed(status: Int32)
    case connectionFailed(sourceName: String, status: Int32)

    public var description: String {
        switch self {
        case .clientCreationFailed(let status):
            return "MIDIClientCreate failed with status \(status)"
        case .inputPortCreationFailed(let status):
            return "MIDIInputPortCreate failed with status \(status)"
        case .connectionFailed(let name, let status):
            return "could not connect source \"\(name)\" (status \(status))"
        }
    }

    /// 4 the client was never created, 5 the client exists but no input port, 6 a
    /// source was enumerated and the port refused it.
    public var exitCode: Int32 {
        switch self {
        case .clientCreationFailed: return 4
        case .inputPortCreationFailed: return 5
        case .connectionFailed: return 6
        }
    }
}

/// The result of a start whose client and port were created.
public struct MIDIStartReport: Equatable, Sendable {
    public let inventory: MIDIInventory
    /// The unique ids of the sources the port accepted.
    public let connected: [Int32]
    /// The sources the port refused, in enumeration order.
    public let failures: [MIDIStartFailure]

    public init(inventory: MIDIInventory, connected: [Int32], failures: [MIDIStartFailure]) {
        self.inventory = inventory
        self.connected = connected
        self.failures = failures
    }

    public var isClean: Bool { failures.isEmpty }

    /// What the probe prints. The first line is the marker the smoke script
    /// asserts, and the second is the one it reads the source count from.
    public var lines: [String] {
        var lines = ["MIDI: client created"]
        lines.append(contentsOf: inventory.summaryLines())
        lines.append("MIDI: connected \(connected.count) of \(inventory.onlineCount) online source(s)")
        for failure in failures {
            lines.append("MIDI: \(failure.description)")
        }
        return lines
    }
}

/// What a start did, and the status the probe exits with.
public enum MIDIStartVerdict: Equatable, Sendable {
    case running(MIDIStartReport)
    case refused(MIDIStartFailure)

    /// 0 the client and port were created and every online source connected, 4
    /// no client, 5 no port, 6 a source would not connect. A zero-source machine
    /// is a 0: an empty source list is a fact about the hardware, not a failure.
    public var exitCode: Int32 {
        switch self {
        case .running(let report): return report.isClean ? 0 : 6
        case .refused(let failure): return failure.exitCode
        }
    }

    public var report: MIDIStartReport? {
        if case .running(let report) = self { return report }
        return nil
    }

    public var failure: MIDIStartFailure? {
        if case .refused(let failure) = self { return failure }
        return nil
    }

    public var lines: [String] {
        switch self {
        case .running(let report): return report.lines
        case .refused(let failure): return ["MIDI: start refused: \(failure.description)"]
        }
    }
}
