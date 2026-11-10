import CoreMIDI
import Foundation
import SundayKeysCore

/// A CoreMIDI source this process publishes itself.
///
/// A runner has no controller, so the engine's connect path never ran there: the
/// source list was empty and there was nothing to connect. Publishing a source
/// from inside the probe gives the engine a real endpoint to find without any
/// hardware. Creating, emitting from and disposing it are the only CoreMIDI calls
/// in this probe; what the result means is decided by `MIDIConnectProbe` and
/// `MIDIReceiveProbe` in the core module, so every outcome is asserted by
/// `swift test` on a machine with no MIDI.
final class VirtualMIDISource {
    static let defaultName = "SundayKeys Virtual Source"

    /// What the attempt produced, ready for the core probe.
    private(set) var attempt: MIDIVirtualSourceAttempt

    private var client = MIDIClientRef()
    private var endpoint = MIDIEndpointRef()

    init(name: String = VirtualMIDISource.defaultName) {
        // Replaced by whichever outcome the calls below produce.
        attempt = .refused(status: -1)

        let clientStatus = MIDIClientCreateWithBlock(name as CFString, &client) { _ in }
        guard clientStatus == noErr else {
            client = MIDIClientRef()
            attempt = .refused(status: clientStatus)
            return
        }

        // MIDISourceCreate is deprecated in favour of the protocol-taking call, so
        // the probe uses the one that is current rather than shipping a warning.
        let sourceStatus = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &endpoint)
        guard sourceStatus == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            endpoint = MIDIEndpointRef()
            attempt = .refused(status: sourceStatus)
            return
        }

        attempt = .created(MIDIEndpointReader.description(of: endpoint))
    }

    /// Emits one packet from this source, the way a controller's driver would.
    ///
    /// `MIDIReceived` distributes the list to every client connected to the
    /// source, so the bytes reach the probe's own input port through CoreMIDI
    /// rather than being parsed straight into the engine. Returns CoreMIDI's own
    /// status, so a send that failed says so instead of looking like a packet that
    /// was sent and then lost.
    @discardableResult
    func send(packet: [UInt8]) -> Int32 {
        guard endpoint != 0 else { return -1 }
        guard !packet.isEmpty else { return noErr }

        // One packet per list: a single add cannot overflow a buffer sized for it,
        // and the three sends the probe makes are cheap enough not to batch.
        let capacity = MemoryLayout<MIDIPacketList>.size + MemoryLayout<MIDIPacket>.size + packet.count
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let first = MIDIPacketListInit(list)
        packet.withUnsafeBufferPointer { bytes in
            _ = MIDIPacketListAdd(
                list,
                capacity,
                first,
                0,
                bytes.count,
                bytes.baseAddress!
            )
        }

        return MIDIReceived(endpoint, list)
    }

    /// Removes the source and its client, so the engine's list is left as it was
    /// found and nothing outlives the probe.
    func dispose() {
        if endpoint != 0 {
            MIDIEndpointDispose(endpoint)
            endpoint = MIDIEndpointRef()
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = MIDIClientRef()
        }
    }
}
