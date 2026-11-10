import Foundation

/// What a running MIDI client currently holds, kept across enumerations.
///
/// CoreMIDI can tell a port to connect an endpoint but says nothing about what
/// it already holds, and the notify block fires for changes that may not concern
/// sources at all. That means the app has to remember two things itself: which
/// endpoints the port accepted, and which ones it refused. Both live here, as
/// pure logic, so the rules a refresh depends on are asserted by `swift test`
/// instead of being discovered by plugging a controller in.
///
/// The rules, in one place:
///
/// - only online endpoints that the port does not already hold are attempted;
/// - a refusal is kept while its source is still enumerated and still not
///   connected, so a hot-plug notification cannot silently erase a real fault;
/// - a refusal is cleared when that source connects, so a device that recovers is
///   not reported as refused for ever;
/// - a refusal is forgotten when the source disappears, because there is no
///   longer anything the port could connect;
/// - connected endpoints are keyed by endpoint, so a source enumerated twice
///   cannot be counted twice.
public struct MIDISourceTracker: Equatable, Sendable {
    /// The endpoints the port accepted, in the order they were connected.
    public private(set) var connectedEndpoints: [UInt32]
    /// Refusals by endpoint, kept until the source connects or disappears.
    public private(set) var refusals: [UInt32: MIDIStartFailure]

    public init() {
        connectedEndpoints = []
        refusals = [:]
    }

    /// The online endpoints the port does not hold yet, in enumeration order.
    /// An offline source is never attempted: a refused connect there would say
    /// nothing about the machine.
    public func endpointsToConnect(in inventory: MIDIInventory) -> [UInt32] {
        inventory.online
            .map(\.endpoint)
            .filter { !connectedEndpoints.contains($0) }
    }

    /// Records an accepted endpoint, which also retires any refusal for it.
    public mutating func recordConnected(endpoint: UInt32) {
        if !connectedEndpoints.contains(endpoint) {
            connectedEndpoints.append(endpoint)
        }
        refusals[endpoint] = nil
    }

    /// Records a refused endpoint. The refusal stands until the source connects
    /// or leaves the inventory.
    public mutating func recordRefused(endpoint: UInt32, name: String, status: Int32) {
        refusals[endpoint] = .connectionFailed(sourceID: endpoint, sourceName: name, status: status)
    }

    /// Forgets what is no longer enumerated, and anything the port already holds
    /// that is also listed as refused.
    public mutating func prune(keeping inventory: MIDIInventory) {
        let present = Set(inventory.sources.map(\.endpoint))
        connectedEndpoints.removeAll { !present.contains($0) }
        refusals = refusals.filter { endpoint, _ in
            present.contains(endpoint) && !connectedEndpoints.contains(endpoint)
        }
    }

    /// The report for the current state. Connected ids follow enumeration order
    /// and come from the inventory, so a stale endpoint cannot be reported and a
    /// repeated one cannot be counted twice. Refusals are in enumeration order
    /// too, which is the order the status shows the first of.
    public func report(for inventory: MIDIInventory) -> MIDIStartReport {
        let connectedIDs = inventory.sources
            .filter { connectedEndpoints.contains($0.endpoint) }
            .map(\.uniqueID)
        let failures = inventory.sources.compactMap { refusals[$0.endpoint] }
        return MIDIStartReport(inventory: inventory, connected: connectedIDs, failures: failures)
    }
}
