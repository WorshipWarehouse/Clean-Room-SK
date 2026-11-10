import Foundation

/// The three packets a receive probe sends, and the messages they should parse to.
///
/// The bytes live here rather than in the app so one value drives the send, the
/// counting and the tests. A probe that sent one thing and asserted another would
/// prove nothing, and a channel that drifted between the two would quietly stop
/// matching.
public struct MIDIReceiveExpectation: Equatable, Sendable {
    public let note: UInt8
    public let channel: UInt8
    public let controller: UInt8
    public let velocity: UInt8
    public let controllerValue: UInt8

    public init(
        note: UInt8 = 60,
        channel: UInt8 = 0,
        controller: UInt8 = 1,
        velocity: UInt8 = 100,
        controllerValue: UInt8 = 64
    ) {
        self.note = note
        self.channel = channel
        self.controller = controller
        self.velocity = velocity
        self.controllerValue = controllerValue
    }

    public var noteOnPacket: [UInt8] {
        [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
    }

    public var noteOffPacket: [UInt8] {
        [0x80 | (channel & 0x0F), note & 0x7F, 0x40]
    }

    public var controlChangePacket: [UInt8] {
        [0xB0 | (channel & 0x0F), controller & 0x7F, controllerValue & 0x7F]
    }

    /// Sent in this order: the note on, the note off, then the control change.
    public var packets: [[UInt8]] {
        [noteOnPacket, noteOffPacket, controlChangePacket]
    }

    /// What each packet is, in the words the probe prints, counting the channel
    /// the way a player does.
    public var packetDescriptions: [String] {
        [
            "note on \(note) velocity \(velocity) on channel \(Int(channel) + 1)",
            "note off \(note) on channel \(Int(channel) + 1)",
            "control change \(controller) = \(controllerValue) on channel \(Int(channel) + 1)",
        ]
    }
}

/// What sending and receiving the expectation established.
public enum MIDIReceiveOutcome: Equatable, Sendable {
    /// Every packet reached the app and was parsed as the message it was sent as.
    /// This is the only outcome that proves the receive path ran.
    case received(noteOns: Int, noteOffs: Int, controlChanges: Int)
    /// The note off and the control change arrived but the note on did not.
    case noteOnMissing(noteOffs: Int, controlChanges: Int)
    /// The note on and the control change arrived but the note off did not.
    case noteOffMissing(noteOns: Int, controlChanges: Int)
    /// Both notes arrived but the control change did not.
    case controlChangeMissing(noteOns: Int, noteOffs: Int)
    /// Nothing the probe could attribute arrived, which is what a port that is
    /// connected but not receiving looks like.
    case nothingReceived
    /// Nothing was sent, because the connect path had not proved itself first.
    case notAttempted(connect: MIDIConnectProbeOutcome)

    /// True only for the one outcome that shows packets being received and parsed.
    public var provesReceivePath: Bool {
        if case .received = self { return true }
        return false
    }

    /// 0 every packet parsed, 10 no note off, 11 no control change, 12 nothing at
    /// all, 13 no note on. The connect status is reused when nothing was sent, so
    /// the step's exit status names the first thing that failed.
    public var exitCode: Int32 {
        switch self {
        case .received: return 0
        case .noteOffMissing: return 10
        case .controlChangeMissing: return 11
        case .nothingReceived: return 12
        case .noteOnMissing: return 13
        case let .notAttempted(connect): return connect.exitCode
        }
    }

    public var description: String {
        switch self {
        case let .received(noteOns, noteOffs, controlChanges):
            return "the app parsed every packet: \(noteOns) note on, \(noteOffs) note off, \(controlChanges) control change"
        case let .noteOnMissing(noteOffs, controlChanges):
            return "the app parsed \(noteOffs) note off and \(controlChanges) control change but no note on"
        case let .noteOffMissing(noteOns, controlChanges):
            return "the app parsed \(noteOns) note on and \(controlChanges) control change but no note off"
        case let .controlChangeMissing(noteOns, noteOffs):
            return "the app parsed \(noteOns) note on and \(noteOffs) note off but no control change"
        case .nothingReceived:
            return "the app parsed none of the packets it was sent"
        case let .notAttempted(connect):
            return "nothing was sent, because the connect path did not prove itself: \(connect.description)"
        }
    }
}

/// The packets a probe sent, and what the app made of them.
///
/// This is the receive half of `MIDIConnectProbe`. The connect probe stops once a
/// source is held, which proves the port accepted an endpoint but says nothing
/// about data; this takes the next step and asks whether a packet sent the way a
/// controller's driver sends one arrives at the engine and parses.
public struct MIDIReceiveProbe: Equatable, Sendable {
    public let expectation: MIDIReceiveExpectation
    public let connect: MIDIConnectProbe
    public let received: [MIDIMessage]
    /// The layers the received note was routed to, when the probe routed it.
    public let routedLayers: Int?
    /// The layers that were enabled in the patch the note was routed through.
    public let enabledLayers: Int?

    public init(
        expectation: MIDIReceiveExpectation,
        connect: MIDIConnectProbe,
        received: [MIDIMessage],
        routedLayers: Int? = nil,
        enabledLayers: Int? = nil
    ) {
        self.expectation = expectation
        self.connect = connect
        self.received = received
        self.routedLayers = routedLayers
        self.enabledLayers = enabledLayers
    }

    /// True only when every packet was parsed as the message it was sent as.
    public var provesReceivePath: Bool { outcome.provesReceivePath }

    public var exitCode: Int32 { outcome.exitCode }

    public var outcome: MIDIReceiveOutcome {
        guard connect.provesConnectPath else {
            return .notAttempted(connect: connect.outcome)
        }

        let counts = counts(in: received)
        if counts.noteOns == 0 && counts.noteOffs == 0 && counts.controlChanges == 0 {
            return .nothingReceived
        }
        if counts.noteOns == 0 {
            return .noteOnMissing(noteOffs: counts.noteOffs, controlChanges: counts.controlChanges)
        }
        if counts.noteOffs == 0 {
            return .noteOffMissing(noteOns: counts.noteOns, controlChanges: counts.controlChanges)
        }
        if counts.controlChanges == 0 {
            return .controlChangeMissing(noteOns: counts.noteOns, noteOffs: counts.noteOffs)
        }
        return .received(noteOns: counts.noteOns, noteOffs: counts.noteOffs, controlChanges: counts.controlChanges)
    }

    /// What the probe prints. The `MIDI receive probe:` prefix keeps this evidence
    /// apart from the connect probe's lines, so a reader of the step output can
    /// tell what was sent, what came back and what the connect proved.
    public var lines: [String] {
        var lines: [String] = []
        if connect.provesConnectPath {
            lines.append(contentsOf: expectation.packetDescriptions.map { "MIDI receive probe: sent \($0)" })
        } else {
            lines.append("MIDI receive probe: nothing was sent, because the connect path did not prove itself")
        }

        let counts = counts(in: received)
        lines.append(
            "MIDI receive probe: the app received \(received.count) message(s): \(counts.noteOns) note on, \(counts.noteOffs) note off, \(counts.controlChanges) control change"
        )

        if let routedLayers, let enabledLayers {
            lines.append(
                "MIDI receive probe: layer routing sent note \(expectation.note) to \(routedLayers) of \(enabledLayers) enabled layer(s)"
            )
        }

        lines.append("MIDI receive probe: outcome: \(outcome.description)")
        return lines
    }

    /// Counts only the messages the probe meant to send, so a stray packet from
    /// anything else on the machine cannot stand in for one of them.
    private func counts(in messages: [MIDIMessage]) -> (noteOns: Int, noteOffs: Int, controlChanges: Int) {
        var noteOns = 0
        var noteOffs = 0
        var controlChanges = 0

        for message in messages {
            switch message {
            case let .noteOn(note, _, channel)
                where note == expectation.note && channel == expectation.channel:
                noteOns += 1
            case let .noteOff(note, _, channel)
                where note == expectation.note && channel == expectation.channel:
                noteOffs += 1
            case let .controlChange(controller, _, channel)
                where controller == expectation.controller && channel == expectation.channel:
                controlChanges += 1
            default:
                break
            }
        }

        return (noteOns, noteOffs, controlChanges)
    }
}
