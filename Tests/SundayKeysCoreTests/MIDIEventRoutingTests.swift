import XCTest
import SundayKeysCore

/// The MIDI routing layer: bytes in, typed events out, delivered to a transport
/// this suite supplies.
///
/// Nothing here waits on hardware or on wall time. The router is a value, the
/// transport is a recording object, and the only thing that moves is the byte
/// array the test hands in, so the order of delivery and the exact refusal are
/// both things the test can state.
final class MIDIEventRoutingTests: XCTestCase {
    func testEverySupportedMessageTypeIsDeliveredInOrder() {
        let transport = RecordingTransport()
        var router = MIDIEventRouter()

        let failures = router.route(
            [
                0x90, 60, 100,       // note on
                0x80, 60, 64,        // note off
                0xB0, 1, 64,         // control change
                0xC0, 3,             // program change
                0xE0, 0, 64,         // pitch bend
                0xD0, 40,            // channel pressure
            ],
            to: transport
        )

        XCTAssertEqual(failures, [])
        XCTAssertEqual(transport.events, [
            .noteOn(note: 60, velocity: 100, channel: 0),
            .noteOff(note: 60, velocity: 64, channel: 0),
            .controlChange(controller: 1, value: 64, channel: 0),
            .programChange(program: 3, channel: 0),
            .pitchBend(value: UInt16(0 | (64 << 7)), channel: 0),
            .channelPressure(pressure: 40, channel: 0),
        ])
        XCTAssertEqual(router.delivered, 6)
        XCTAssertEqual(router.rejected, 0)
        XCTAssertEqual(router.lastDelivered, .channelPressure(pressure: 40, channel: 0))
    }

    func testNoteOffAndNoteOnAtZeroVelocityBothArriveAsNoteOff() {
        let transport = RecordingTransport()
        var router = MIDIEventRouter()

        router.route([0x80, 60, 64, 0x90, 60, 0, 0x90, 60, 1], to: transport)

        XCTAssertEqual(transport.events, [
            .noteOff(note: 60, velocity: 64, channel: 0),
            .noteOff(note: 60, velocity: 0, channel: 0),
            .noteOn(note: 60, velocity: 1, channel: 0),
        ])
        XCTAssertEqual(router.delivered, 3)
    }

    func testChannelAndDataBoundariesAreAcceptedAtBothEnds() {
        XCTAssertEqual(
            MIDIEventDecoder.decode([0x90, 0, 127]),
            .success(.noteOn(note: 0, velocity: 127, channel: 0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0x9F, 127, 127]),
            .success(.noteOn(note: 127, velocity: 127, channel: 15))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xE0, 0, 0]),
            .success(.pitchBend(value: 0, channel: 0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xEF, 127, 127]),
            .success(.pitchBend(value: 16_383, channel: 15))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xD0, 0]),
            .success(.channelPressure(pressure: 0, channel: 0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xDF, 127]),
            .success(.channelPressure(pressure: 127, channel: 15))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xC0, 0]),
            .success(.programChange(program: 0, channel: 0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xCF, 127]),
            .success(.programChange(program: 127, channel: 15))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xBF, 0, 0]),
            .success(.controlChange(controller: 0, value: 0, channel: 15))
        )
    }

    func testEmptyInputIsRefusedWithATypedError() {
        XCTAssertEqual(MIDIEventDecoder.decode([]), .failure(.empty))

        let transport = RecordingTransport()
        var router = MIDIEventRouter()
        XCTAssertEqual(router.route([], to: transport), [.empty])
        XCTAssertEqual(transport.events, [])
        XCTAssertEqual(router.delivered, 0)
        XCTAssertEqual(router.rejected, 1)
    }

    func testATruncatedMessageNamesWhatWasMissing() {
        XCTAssertEqual(
            MIDIEventDecoder.decode([0x90, 60]),
            .failure(.truncated(status: 0x90, expected: 2, got: 1))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xC0]),
            .failure(.truncated(status: 0xC0, expected: 1, got: 0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xE0, 1]),
            .failure(.truncated(status: 0xE0, expected: 2, got: 1))
        )
    }

    func testAStatusByteWhereDataBelongsIsRefused() {
        XCTAssertEqual(
            MIDIEventDecoder.decode([0x90, 60, 0x80]),
            .failure(.dataByteOutOfRange(status: 0x90, byte: 0x80))
        )

        // The same packet resyncs on the status byte, so the message behind the
        // broken one is not lost as well.
        let transport = RecordingTransport()
        var router = MIDIEventRouter()
        let failures = router.route([0x90, 60, 0x80, 60, 64], to: transport)

        XCTAssertEqual(failures, [.dataByteOutOfRange(status: 0x90, byte: 0x80)])
        XCTAssertEqual(transport.events, [.noteOff(note: 60, velocity: 64, channel: 0)])
        XCTAssertEqual(router.delivered, 1)
        XCTAssertEqual(router.rejected, 1)
    }

    func testAnUnsupportedStatusIsNamedRatherThanGuessed() {
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xA0, 60, 64]),
            .failure(.unsupportedStatus(0xA0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decode([0xF0, 1, 2, 3]),
            .failure(.systemMessage(0xF0))
        )
        XCTAssertEqual(
            MIDIEventDecoder.decodeAll([0xF1, 0x90, 60, 100]),
            [
                .failure(.systemMessage(0xF1)),
                .success(.noteOn(note: 60, velocity: 100, channel: 0)),
            ]
        )
    }

    func testRealTimeBytesAreSkippedAndLeaveTheMessagesAlone() {
        XCTAssertEqual(
            MIDIEventDecoder.decodeAll([0xF8, 0x90, 60, 100, 0xFE]),
            [.success(.noteOn(note: 60, velocity: 100, channel: 0))]
        )
    }

    func testDataWithNoStatusIsRefused() {
        XCTAssertEqual(MIDIEventDecoder.decode([60]), .failure(.unsupportedStatus(60)))
        XCTAssertEqual(
            MIDIEventDecoder.decodeAll([60, 100]),
            [.failure(.unsupportedStatus(60)), .failure(.unsupportedStatus(100))]
        )
    }

    func testTheRouterDeliversNothingWhenThePacketIsMalformed() {
        let transport = RecordingTransport()
        var router = MIDIEventRouter()

        let failures = router.route([0x90, 60], to: transport)

        XCTAssertEqual(failures, [.truncated(status: 0x90, expected: 2, got: 1)])
        XCTAssertEqual(transport.events, [])
        XCTAssertEqual(router.delivered, 0)
        XCTAssertEqual(router.rejected, 1)
    }

    func testTheStatusLineCountsAndNamesWhatHappened() {
        var router = MIDIEventRouter()
        XCTAssertEqual(router.statusLine, "MIDI route: nothing yet")

        let transport = RecordingTransport()
        router.route([0x90, 60, 100], to: transport)
        XCTAssertEqual(
            router.statusLine,
            "MIDI route: 1 delivered, 0 rejected, last note on 60 velocity 100 ch 1"
        )

        router.route([0xC0, 3], to: transport)
        XCTAssertEqual(
            router.statusLine,
            "MIDI route: 2 delivered, 0 rejected, last program 3 ch 1"
        )

        router.route([0x90, 60], to: transport)
        XCTAssertEqual(
            router.statusLine,
            "MIDI route: 2 delivered, 1 rejected, last refused: "
                + "truncated 0x90: expected 2 data byte(s), got 1"
        )
    }

    func testDecodeAllAgreesWithDecodeForEverySingleMessage() {
        let packets: [[UInt8]] = [
            [0x90, 60, 100],
            [0x80, 60, 0],
            [0xB0, 7, 127],
            [0xC0, 0],
            [0xE7, 0, 127],
            [0xD5, 12],
        ]

        for packet in packets {
            XCTAssertEqual(MIDIEventDecoder.decodeAll(packet), [MIDIEventDecoder.decode(packet)])
        }
    }

    func testRunningStatusCarriesTheMessageOn() {
        XCTAssertEqual(
            MIDIEventDecoder.decodeAll([0x90, 60, 100, 62, 100]),
            [
                .success(.noteOn(note: 60, velocity: 100, channel: 0)),
                .success(.noteOn(note: 62, velocity: 100, channel: 0)),
            ]
        )
    }

    func testAParsedMessageConvertsWithoutLosingItsChannel() {
        XCTAssertEqual(
            MIDIEvent(message: .noteOn(note: 60, velocity: 100, channel: 2)),
            .noteOn(note: 60, velocity: 100, channel: 2)
        )
        XCTAssertEqual(
            MIDIEvent(message: .pitchBend(value: 8192, channel: 9)),
            .pitchBend(value: 8192, channel: 9)
        )
        XCTAssertNil(MIDIEvent(message: .other(status: 0xA0, data: [60, 64])))
    }

    func testNoteEventsReachTheKeysoundPathTheArpeggiatorUses() {
        let keys = RecordingKeysoundTarget()
        let transport = KeysoundTransport(target: keys)
        var router = MIDIEventRouter()

        router.route([0x90, 64, 96, 0x80, 64, 0, 0xB0, 1, 64], to: transport)

        XCTAssertEqual(keys.notes, ["on 64 96", "off 64"])
        XCTAssertEqual(
            transport.others,
            [.controlChange(controller: 1, value: 64, channel: 0)]
        )
        XCTAssertEqual(router.delivered, 3)
    }
}

// MARK: - Recording doubles

/// A transport that remembers every call, in order, so a test can compare the
/// whole delivery against a literal array.
private final class RecordingTransport: MIDIEventTransport {
    private(set) var events: [MIDIEvent] = []

    func noteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        events.append(.noteOn(note: note, velocity: velocity, channel: channel))
    }

    func noteOff(note: UInt8, velocity: UInt8, channel: UInt8) {
        events.append(.noteOff(note: note, velocity: velocity, channel: channel))
    }

    func controlChange(controller: UInt8, value: UInt8, channel: UInt8) {
        events.append(.controlChange(controller: controller, value: value, channel: channel))
    }

    func programChange(program: UInt8, channel: UInt8) {
        events.append(.programChange(program: program, channel: channel))
    }

    func pitchBend(value: UInt16, channel: UInt8) {
        events.append(.pitchBend(value: value, channel: channel))
    }

    func channelPressure(pressure: UInt8, channel: UInt8) {
        events.append(.channelPressure(pressure: pressure, channel: channel))
    }
}

/// The note path the arpeggiator plays into, recorded the same way.
private final class RecordingKeysoundTarget: KeysoundNoteTarget {
    private(set) var notes: [String] = []

    func noteOn(note: UInt8, velocity: UInt8) {
        notes.append("on \(note) \(velocity)")
    }

    func noteOff(note: UInt8) {
        notes.append("off \(note)")
    }
}

/// Sends the two note events to a keysound target and records the rest, which is
/// the arrangement the app model uses: notes reach the engine, everything else
/// reaches the service that acts on it.
private final class KeysoundTransport: MIDIEventTransport {
    private let target: KeysoundNoteTarget
    private(set) var others: [MIDIEvent] = []

    init(target: KeysoundNoteTarget) {
        self.target = target
    }

    func noteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        target.noteOn(note: note, velocity: velocity)
    }

    func noteOff(note: UInt8, velocity: UInt8, channel: UInt8) {
        target.noteOff(note: note)
    }

    func controlChange(controller: UInt8, value: UInt8, channel: UInt8) {
        others.append(.controlChange(controller: controller, value: value, channel: channel))
    }

    func programChange(program: UInt8, channel: UInt8) {
        others.append(.programChange(program: program, channel: channel))
    }

    func pitchBend(value: UInt16, channel: UInt8) {
        others.append(.pitchBend(value: value, channel: channel))
    }

    func channelPressure(pressure: UInt8, channel: UInt8) {
        others.append(.channelPressure(pressure: pressure, channel: channel))
    }
}
