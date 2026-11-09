import Foundation

/// A parsed MIDI 1.0 channel message.
///
/// Only the messages the engine needs are modelled explicitly; everything else
/// is preserved as `other` so a later stage can decide what to do with it
/// rather than silently dropping bytes at the input port.
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, velocity: UInt8, channel: UInt8)
    case controlChange(controller: UInt8, value: UInt8, channel: UInt8)
    case programChange(program: UInt8, channel: UInt8)
    case pitchBend(value: UInt16, channel: UInt8)
    case other(status: UInt8, data: [UInt8])

    /// Parse up to three bytes of a channel message.
    ///
    /// A note on with velocity zero is the conventional note off, and is
    /// translated here so callers never have to special case it.
    public static func parse(_ bytes: [UInt8]) -> MIDIMessage? {
        guard let status = bytes.first, status >= 0x80 else { return nil }
        let type = status & 0xF0
        let channel = status & 0x0F

        func byte(_ index: Int) -> UInt8 {
            index < bytes.count ? bytes[index] : 0
        }

        switch type {
        case 0x90:
            if byte(2) == 0 {
                return .noteOff(note: byte(1), velocity: 0, channel: channel)
            }
            return .noteOn(note: byte(1), velocity: byte(2), channel: channel)
        case 0x80:
            return .noteOff(note: byte(1), velocity: byte(2), channel: channel)
        case 0xB0:
            return .controlChange(controller: byte(1), value: byte(2), channel: channel)
        case 0xC0:
            return .programChange(program: byte(1), channel: channel)
        case 0xE0:
            let value = UInt16(byte(1)) | (UInt16(byte(2)) << 7)
            return .pitchBend(value: value, channel: channel)
        default:
            return .other(status: status, data: Array(bytes.dropFirst()))
        }
    }
}
