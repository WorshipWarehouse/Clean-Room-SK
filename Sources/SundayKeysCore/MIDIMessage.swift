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
    /// A note on with velocity zero is the conventional note off, and it is
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

    /// Parse every complete message in one packet's worth of bytes.
    ///
    /// A MIDI 1.0 packet is not one message. Running status, several messages in
    /// one packet and real-time bytes between them are all legal on the wire, and
    /// CoreMIDI does deliver them that way: a note on, a note off and a control
    /// change sent back to back can arrive as a single packet. Parsing only the
    /// first three bytes of such a packet keeps the note on and silently loses the
    /// rest, which is the defect the receive probe caught in run 42742938963.
    public static func parseAll(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var index = 0
        var runningStatus: UInt8?

        while index < bytes.count {
            let byte = bytes[index]

            // Real-time messages are one byte and may sit inside another message.
            // Nothing consumes them yet, and they leave the running status alone.
            if byte >= 0xF8 {
                index += 1
                continue
            }

            var status = byte
            var start = index

            if byte >= 0x80 {
                runningStatus = byte
                start = index + 1
            } else if let running = runningStatus {
                status = running
            } else {
                // Data with no status to apply it to is a fragment, not a message.
                index += 1
                continue
            }

            if status >= 0xF0 {
                // System common messages vary in length and the engine has no use
                // for them. Dropping the status keeps the channel messages after it
                // in the same packet parseable.
                runningStatus = nil
                index += 1
                continue
            }

            let type = status & 0xF0
            let dataCount = type == 0xC0 || type == 0xD0 ? 1 : 2
            let end = start + dataCount

            guard end <= bytes.count, bytes[start..<end].allSatisfy({ $0 < 0x80 })
            else {
                // Truncated, or a status byte where data should be: the rest of the
                // packet cannot be trusted, and a partial message is not a message.
                break
            }

            if let message = parse([status] + Array(bytes[start..<end])) {
                messages.append(message)
            }
            index = end
        }

        return messages
    }
}
