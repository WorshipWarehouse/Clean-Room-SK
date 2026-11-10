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
/// from the outside - both just left the source list empty - and telling those
/// apart is the whole point of `tools/midi_smoke.sh`.
///
/// What the port holds and what it refused is tracked by `MIDISourceTracker` in
/// the core module, so a refresh after a source appears or disappears follows the
/// same rules as the first start. This type only performs the calls.
final class MIDIInputService {
    var onMessage: ((MIDIMessage) -> Void)?
    var onSourcesChanged: (([String]) -> Void)?
    /// Called for the first start and for every later refresh, so the owner's
    /// status follows the actual source list rather than only what Start found.
    var onVerdictChanged: ((MIDIStartVerdict) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var tracker = MIDISourceTracker()
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
        return record(publish(enumerateAndConnect()))
    }

    func stop() {
        guard started else { return }
        for source in tracker.connectedEndpoints {
            MIDIPortDisconnectSource(inputPort, source)
        }
        tracker = MIDISourceTracker()
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        inputPort = MIDIPortRef()
        client = MIDIClientRef()
        started = false
        lastVerdict = nil
        onSourcesChanged?([])
    }

    /// Re-enumerates the current sources and republishes the verdict.
    ///
    /// The notify block calls the same pass when a source appears or disappears.
    /// This entry point exists for the connect probe, which publishes a virtual
    /// source and then wants one more look rather than a second client.
    func refresh() {
        refreshSources()
    }

    /// The notify block lands here, and so does anything else that wants the
    /// current list. It is a thin pass over the tracker's rules.
    private func refreshSources() {
        guard started else { return }
        lastVerdict = publish(enumerateAndConnect())
    }

    /// Enumerates the sources, asks the tracker which endpoints still need a
    /// connect, performs exactly those, then reports what the port holds.
    private func enumerateAndConnect() -> MIDIStartVerdict {
        let inventory = MIDIInventory(sources: MIDIEndpointReader.currentSources())

        for endpoint in tracker.endpointsToConnect(in: inventory) {
            let name = inventory.sources.first { $0.endpoint == endpoint }?.displayName ?? "unnamed source"
            let status = MIDIPortConnectSource(inputPort, endpoint, nil)
            if status == noErr {
                tracker.recordConnected(endpoint: endpoint)
            } else {
                tracker.recordRefused(endpoint: endpoint, name: name, status: status)
            }
        }

        tracker.prune(keeping: inventory)
        return .running(tracker.report(for: inventory))
    }

    /// Tells the observers the source names and the verdict, and hands the verdict
    /// back unchanged.
    private func publish(_ verdict: MIDIStartVerdict) -> MIDIStartVerdict {
        onSourcesChanged?(verdict.report?.inventory.sources.map(\.displayName) ?? [])
        onVerdictChanged?(verdict)
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
