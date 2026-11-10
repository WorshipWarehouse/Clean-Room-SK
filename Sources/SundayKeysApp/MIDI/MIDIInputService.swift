import CoreMIDI
import Foundation
import SundayKeysCore

/// CoreMIDI input.
///
/// The client and input port are created once and every current source is
/// connected, so hot plugging a controller is picked up through the notify block.
/// Frames arrive on a CoreMIDI thread, so this type holds no UI state: it hands
/// parsed messages to `onMessage` and lets the caller decide how to get back to
/// the main actor.
///
/// `start()` reports what happened instead of failing silently. A client that
/// could not be created and a machine with no controller used to look identical
/// from the outside — both just left the source list empty — and telling those
/// apart is the whole point of `tools/midi_smoke.sh`.
final class MIDIInputService {
    var onMessage: ((MIDIMessage) -> Void)?
    var onSourcesChanged: (([String]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef] = []
    private var started = false

    /// The verdict of the last start or refresh, so a caller that only wants to
    /// know the current state does not have to enumerate again.
    private(set) var lastVerdict: MIDIStartVerdict?

    /// Creates the client and the input port, connects every online source and
    /// returns the verdict. A second call returns the first verdict instead of
    /// creating a second client.
    @discardableResult
    func start() -> MIDIStartVerdict {
        if started, let lastVerdict { return lastVerdict }

        let clientStatus = MIDIClientCreateWithBlock("SundayKeys MIDI" as CFString, &client) { [weak self] _ in
            self?.refreshSources()
        }
        guard clientStatus == noErr else {
            client = MIDIClientRef()
            return record(.refused(.clientCreationFailed(status: clientStatus)))
        }

        let portStatus = MIDIInputPortCreateWithBlock(client, "SundayKeys Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.receive(packetList)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            inputPort = MIDIPortRef()
            return record(.refused(.inputPortCreationFailed(status: portStatus)))
        }

        started = true
        return record(publish(connectCurrentSources()))
    }

    func stop() {
        guard started else { return }
        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources.removeAll()
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        inputPort = MIDIPortRef()
        client = MIDIClientRef()
        started = false
        lastVerdict = nil
        onSourcesChanged?([])
    }

    private func refreshSources() {
        guard started else { return }
        lastVerdict = publish(connectCurrentSources())
    }

    /// Enumerates the sources, connects the online ones the port does not hold
    /// yet, and describes the result.
    private func connectCurrentSources() -> MIDIStartVerdict {
        let inventory = MIDIInventory(sources: MIDIEndpointReader.currentSources())
        var failures: [MIDIStartFailure] = []

        for source in inventory.online where !connectedSources.contains(source.endpoint) {
            let status = MIDIPortConnectSource(inputPort, source.endpoint, nil)
            if status == noErr {
                connectedSources.append(source.endpoint)
            } else {
                failures.append(.connectionFailed(sourceName: source.displayName, status: status))
            }
        }

        let connectedIDs = inventory.online
            .filter { connectedSources.contains($0.endpoint) }
            .map(\.uniqueID)

        return .running(MIDIStartReport(inventory: inventory, connected: connectedIDs, failures: failures))
    }

    /// Tells the observer the source names, and hands the verdict back unchanged.
    private func publish(_ verdict: MIDIStartVerdict) -> MIDIStartVerdict {
        onSourcesChanged?(verdict.report?.inventory.sources.map(\.displayName) ?? [])
        return verdict
    }

    private func record(_ verdict: MIDIStartVerdict) -> MIDIStartVerdict {
        lastVerdict = verdict
        return verdict
    }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        let count = Int(packetList.pointee.numPackets)

        for _ in 0..<count {
            let length = Int(packet.length)
            if length >= 2 {
                var bytes: [UInt8] = [packet.data.0, packet.data.1]
                if length >= 3 {
                    bytes.append(packet.data.2)
                }
                if let message = MIDIMessage.parse(bytes) {
                    onMessage?(message)
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}
