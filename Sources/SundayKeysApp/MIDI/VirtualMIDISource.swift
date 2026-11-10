import CoreMIDI
import Foundation
import SundayKeysCore

/// A CoreMIDI source this process publishes itself.
///
/// A runner has no controller, so the engine's connect path never ran there: the
/// source list was empty and there was nothing to connect. Publishing a source
/// from inside the probe gives the engine a real endpoint to find without any
/// hardware. Creating and disposing it are the only CoreMIDI calls in this probe;
/// what the result means is decided by `MIDIConnectProbe` in the core module, so
/// every outcome is asserted by `swift test` on a machine with no MIDI.
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
