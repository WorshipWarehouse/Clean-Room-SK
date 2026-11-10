import CoreMIDI
import Foundation
import SundayKeysCore

/// Reads CoreMIDI's source list into the core's descriptions.
///
/// Kept apart from `MIDIInputService` so the service's state changes are not
/// interleaved with property queries, and so an unnamed or offline endpoint is
/// described in one place.
enum MIDIEndpointReader {
    /// Every source the MIDI server currently reports, in enumeration order.
    static func currentSources() -> [MIDIEndpointDescription] {
        let count = MIDIGetNumberOfSources()
        var sources: [MIDIEndpointDescription] = []
        sources.reserveCapacity(count)

        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            sources.append(description(of: endpoint))
        }

        return sources
    }

    static func description(of endpoint: MIDIEndpointRef) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: endpoint,
            uniqueID: uniqueID(of: endpoint),
            name: name(of: endpoint),
            manufacturer: string(of: endpoint, kMIDIPropertyManufacturer),
            online: !isOffline(endpoint)
        )
    }

    /// The unique id when CoreMIDI publishes one, otherwise the endpoint
    /// reference, which is still distinct per source for this launch.
    private static func uniqueID(of endpoint: MIDIEndpointRef) -> Int32 {
        var value: Int32 = 0
        if MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value) == noErr {
            return value
        }
        return Int32(bitPattern: endpoint)
    }

    /// The display name is the one a player recognises, but not every driver
    /// publishes it, so the plain name is the fallback.
    private static func name(of endpoint: MIDIEndpointRef) -> String? {
        string(of: endpoint, kMIDIPropertyDisplayName) ?? string(of: endpoint, kMIDIPropertyName)
    }

    private static func string(of endpoint: MIDIEndpointRef, _ property: CFString) -> String? {
        var raw: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, property, &raw) == noErr,
              let value = raw?.takeRetainedValue()
        else { return nil }
        return value as String
    }

    private static func isOffline(_ endpoint: MIDIEndpointRef) -> Bool {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
