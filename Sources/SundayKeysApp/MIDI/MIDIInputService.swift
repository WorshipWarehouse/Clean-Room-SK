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
final class MIDIInputService {
    var onMessage: ((MIDIMessage) -> Void)?
    var onSourcesChanged: (([String]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef] = []
    private var started = false

    func start() {
        guard !started else { return }

        let clientStatus = MIDIClientCreateWithBlock("SundayKeys MIDI" as CFString, &client) { [weak self] _ in
            self?.refreshSources()
        }
        guard clientStatus == noErr else { return }

        let portStatus = MIDIInputPortCreateWithBlock(client, "SundayKeys Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.receive(packetList)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            return
        }

        started = true
        refreshSources()
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
        onSourcesChanged?([])
    }

    private func refreshSources() {
        var names: [String] = []
        let count = MIDIGetNumberOfSources()

        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }

            var displayName: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &displayName) == noErr,
               let value = displayName?.takeRetainedValue() {
                names.append(value as String)
            } else {
                names.append("Source \(index)")
            }

            if !connectedSources.contains(source) {
                if MIDIPortConnectSource(inputPort, source, nil) == noErr {
                    connectedSources.append(source)
                }
            }
        }

        onSourcesChanged?(names)
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
