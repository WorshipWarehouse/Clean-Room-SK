import Foundation

/// One validated MIDI 1.0 channel event.
///
/// `MIDIMessage` is the permissive shape the input port parses into: it keeps
/// anything it does not model as `other` rather than losing the bytes. This is
/// the strict shape a router can act on, and it exists so a malformed or
/// unhandled message can be *reported* instead of dropped on the floor.
///
/// Every value here is already inside what the wire can carry - channels 0 to
/// 15, data bytes 0 to 127 and a fourteen-bit bend - because the decoder checks
/// the ranges rather than trusting them. A caller therefore cannot hand the
/// router an event the wire could not have sent.
public enum MIDIEvent: Equatable, Sendable {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, velocity: UInt8, channel: UInt8)
    case controlChange(controller: UInt8, value: UInt8, channel: UInt8)
    case programChange(program: UInt8, channel: UInt8)
    case pitchBend(value: UInt16, channel: UInt8)
    case channelPressure(pressure: UInt8, channel: UInt8)

    /// The channel this event arrived on, zero based as the wire carries it.
    public var channel: UInt8 {
        switch self {
        case let .noteOn(_, _, channel),
             let .noteOff(_, _, channel),
             let .controlChange(_, _, channel),
             let .programChange(_, channel),
             let .pitchBend(_, channel),
             let .channelPressure(_, channel):
            return channel
        }
    }

    /// The event in the window's own words. The channel is shown one based
    /// because that is how a controller's front panel numbers it.
    public var label: String {
        switch self {
        case let .noteOn(note, velocity, channel):
            return "note on \(note) velocity \(velocity) ch \(channel + 1)"
        case let .noteOff(note, velocity, channel):
            return "note off \(note) velocity \(velocity) ch \(channel + 1)"
        case let .controlChange(controller, value, channel):
            return "cc \(controller) = \(value) ch \(channel + 1)"
        case let .programChange(program, channel):
            return "program \(program) ch \(channel + 1)"
        case let .pitchBend(value, channel):
            return "bend \(value) ch \(channel + 1)"
        case let .channelPressure(pressure, channel):
            return "pressure \(pressure) ch \(channel + 1)"
        }
    }

    /// Converts a message the input port already parsed.
    ///
    /// The port's parser is deliberately lenient - it fills short messages with
    /// zero - so the values are clamped here to the ranges the strict decoder
    /// enforces too. `other` has no typed event to become: it is whatever this
    /// layer does not model, and saying so is better than inventing a case for
    /// it.
    public init?(message: MIDIMessage) {
        switch message {
        case let .noteOn(note, velocity, channel):
            self = .noteOn(
                note: min(note, 127),
                velocity: min(velocity, 127),
                channel: min(channel, 15)
            )
        case let .noteOff(note, velocity, channel):
            self = .noteOff(
                note: min(note, 127),
                velocity: min(velocity, 127),
                channel: min(channel, 15)
            )
        case let .controlChange(controller, value, channel):
            self = .controlChange(
                controller: min(controller, 127),
                value: min(value, 127),
                channel: min(channel, 15)
            )
        case let .programChange(program, channel):
            self = .programChange(program: min(program, 127), channel: min(channel, 15))
        case let .pitchBend(value, channel):
            self = .pitchBend(value: min(value, 16_383), channel: min(channel, 15))
        case .other:
            return nil
        }
    }
}

/// Why a message could not become an event.
///
/// Every refusal has a name, so the caller can say what arrived rather than
/// dropping it or crashing on it: an empty message, a status byte this layer
/// does not carry, a system message, a message that stopped short, or a byte
/// that should have been data and was not.
public enum MIDIEventFailure: Error, Equatable, Sendable {
    case empty
    case unsupportedStatus(UInt8)
    case systemMessage(UInt8)
    case truncated(status: UInt8, expected: Int, got: Int)
    case dataByteOutOfRange(status: UInt8, byte: UInt8)

    /// The refusal in the window's own words. Hex is used for the byte, because
    /// that is how a status byte is written in every MIDI document.
    public var description: String {
        switch self {
        case .empty:
            return "empty message"
        case .unsupportedStatus(let status):
            return "unsupported status \(Self.hex(status))"
        case .systemMessage(let status):
            return "system message \(Self.hex(status)) is not routed"
        case let .truncated(status, expected, got):
            return "truncated \(Self.hex(status)): expected \(expected) data byte(s), got \(got)"
        case let .dataByteOutOfRange(status, byte):
            return "data byte \(Self.hex(byte)) out of range after \(Self.hex(status))"
        }
    }

    private static func hex(_ value: UInt8) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + (digits.count == 1 ? "0" + digits : digits)
    }
}

/// Turns bytes into typed events.
///
/// The rules are the ones MIDI 1.0 defines for channel messages, and nothing
/// else: a status byte in 0x80 to 0xEF with the data bytes that status requires,
/// each data byte below 0x80. A note on with velocity zero is the conventional
/// note off and is translated here, so no downstream stage has to special case
/// it. System messages are refused rather than guessed at, because they vary in
/// length and this layer has no use for them.
public enum MIDIEventDecoder {
    /// Decodes one complete message. Extra bytes past the message are ignored,
    /// so a caller who hands in a whole packet still gets its first message.
    public static func decode(_ bytes: [UInt8]) -> Result<MIDIEvent, MIDIEventFailure> {
        guard let status = bytes.first else { return .failure(.empty) }
        guard status >= 0x80 else { return .failure(.unsupportedStatus(status)) }
        guard status < 0xF0 else { return .failure(.systemMessage(status)) }

        let type = status & 0xF0
        let channel = status & 0x0F
        let expected = dataCount(for: type)
        let data = Array(bytes.dropFirst())

        guard data.count >= expected else {
            return .failure(.truncated(status: status, expected: expected, got: data.count))
        }

        if let offending = data.prefix(expected).first(where: { $0 >= 0x80 }) {
            return .failure(.dataByteOutOfRange(status: status, byte: offending))
        }

        switch type {
        case 0x80:
            return .success(.noteOff(note: data[0], velocity: data[1], channel: channel))
        case 0x90:
            // Velocity zero on a note on is the wire's other spelling of a
            // note off, and treating it as one here keeps the engine from
            // holding a voice that can never be released.
            if data[1] == 0 {
                return .success(.noteOff(note: data[0], velocity: 0, channel: channel))
            }
            return .success(.noteOn(note: data[0], velocity: data[1], channel: channel))
        case 0xB0:
            return .success(
                .controlChange(controller: data[0], value: data[1], channel: channel)
            )
        case 0xC0:
            return .success(.programChange(program: data[0], channel: channel))
        case 0xD0:
            return .success(.channelPressure(pressure: data[0], channel: channel))
        case 0xE0:
            let value = UInt16(data[0]) | (UInt16(data[1]) << 7)
            return .success(.pitchBend(value: value, channel: channel))
        default:
            // 0xA0 is polyphonic aftertouch, and this layer does not carry it.
            return .failure(.unsupportedStatus(status))
        }
    }

    /// Decodes every message in one packet's worth of bytes, in the order they
    /// arrived.
    ///
    /// Running status, several messages in one packet and real-time bytes
    /// between them are all legal on the wire, and CoreMIDI delivers them that
    /// way. Each message is reported on its own: one malformed message does not
    /// hide the ones around it, and the caller sees the refusal instead of a
    /// shorter list it cannot explain. A message that stops short ends the pass,
    /// because where the next one starts cannot be known.
    public static func decodeAll(_ bytes: [UInt8]) -> [Result<MIDIEvent, MIDIEventFailure>] {
        var results: [Result<MIDIEvent, MIDIEventFailure>] = []
        var index = 0
        var runningStatus: UInt8?

        while index < bytes.count {
            let byte = bytes[index]

            // Real-time bytes are one byte long, may sit inside another message
            // and leave the running status alone. Nothing consumes them yet.
            if byte >= 0xF8 {
                index += 1
                continue
            }

            let status: UInt8
            var dataStart = index

            if byte >= 0x80 {
                status = byte
                runningStatus = byte
                dataStart = index + 1
            } else if let running = runningStatus {
                status = running
            } else {
                // Data with no status to apply it to is a fragment, not a message.
                results.append(.failure(.unsupportedStatus(byte)))
                index += 1
                continue
            }

            if status >= 0xF0 {
                results.append(.failure(.systemMessage(status)))
                runningStatus = nil
                index = dataStart
                continue
            }

            let expected = dataCount(for: status & 0xF0)
            let end = dataStart + expected

            guard end <= bytes.count else {
                results.append(
                    .failure(
                        .truncated(
                            status: status,
                            expected: expected,
                            got: bytes.count - dataStart
                        )
                    )
                )
                return results
            }

            if let offending = bytes[dataStart..<end].firstIndex(where: { $0 >= 0x80 }) {
                // A status byte where data belongs. Resyncing on it keeps the
                // messages after it in the same packet parseable.
                results.append(
                    .failure(.dataByteOutOfRange(status: status, byte: bytes[offending]))
                )
                index = offending
                continue
            }

            results.append(decode([status] + Array(bytes[dataStart..<end])))
            index = end
        }

        return results
    }

    private static func dataCount(for type: UInt8) -> Int {
        type == 0xC0 || type == 0xD0 ? 1 : 2
    }
}

/// Where a routed event goes.
///
/// One method per event the decoder produces, so every event has a destination
/// and none can be accepted and then silently ignored. The engine is reachable
/// from here through `KeysoundNoteTarget`, the same note path the arpeggiator
/// plays into; the app model is the transport the window's MIDI input uses, and
/// the tests pass a transport that records what it was handed.
public protocol MIDIEventTransport: AnyObject {
    func noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    func noteOff(note: UInt8, velocity: UInt8, channel: UInt8)
    func controlChange(controller: UInt8, value: UInt8, channel: UInt8)
    func programChange(program: UInt8, channel: UInt8)
    func pitchBend(value: UInt16, channel: UInt8)
    func channelPressure(pressure: UInt8, channel: UInt8)
}

/// Decodes a packet and hands each event to a transport, keeping count.
///
/// The router owns no clock, no timer and no hardware: it is a value that takes
/// bytes and a transport, delivers in arrival order, and remembers what
/// happened. That is what makes the whole path testable through an injected
/// transport, in the same way the step clock is testable through an injected
/// host clock.
public struct MIDIEventRouter: Equatable {
    /// How many events reached the transport.
    public private(set) var delivered = 0
    /// How many bytes were refused.
    public private(set) var rejected = 0
    public private(set) var lastDelivered: MIDIEvent?
    public private(set) var lastFailure: MIDIEventFailure?

    /// The line before anything has arrived. Kept as one constant so the router
    /// and the model cannot word it differently.
    public static let initialStatusLine = "MIDI route: nothing yet"

    public init() {}

    /// Decodes a packet and delivers every event in order, returning the
    /// refusals so the caller can report them.
    @discardableResult
    public mutating func route(
        _ bytes: [UInt8],
        to transport: MIDIEventTransport
    ) -> [MIDIEventFailure] {
        var failures: [MIDIEventFailure] = []
        for result in MIDIEventDecoder.decodeAll(bytes) {
            switch result {
            case .success(let event):
                deliver(event, to: transport)
            case .failure(let failure):
                rejected += 1
                lastFailure = failure
                failures.append(failure)
            }
        }
        return failures
    }

    /// Hands one already decoded event to the transport and counts it.
    public mutating func deliver(_ event: MIDIEvent, to transport: MIDIEventTransport) {
        switch event {
        case let .noteOn(note, velocity, channel):
            transport.noteOn(note: note, velocity: velocity, channel: channel)
        case let .noteOff(note, velocity, channel):
            transport.noteOff(note: note, velocity: velocity, channel: channel)
        case let .controlChange(controller, value, channel):
            transport.controlChange(controller: controller, value: value, channel: channel)
        case let .programChange(program, channel):
            transport.programChange(program: program, channel: channel)
        case let .pitchBend(value, channel):
            transport.pitchBend(value: value, channel: channel)
        case let .channelPressure(pressure, channel):
            transport.channelPressure(pressure: pressure, channel: channel)
        }
        delivered += 1
        lastDelivered = event
    }

    /// What the panel shows. The wording is pinned by tests, and a refusal is
    /// named rather than counted, so a malformed packet does not read like a
    /// note that simply arrived.
    public var statusLine: String {
        guard delivered > 0 || rejected > 0 else { return Self.initialStatusLine }
        var line = "MIDI route: \(delivered) delivered, \(rejected) rejected"
        if let lastFailure {
            line += ", last refused: \(lastFailure.description)"
        } else if let lastDelivered {
            line += ", last \(lastDelivered.label)"
        }
        return line
    }
}
