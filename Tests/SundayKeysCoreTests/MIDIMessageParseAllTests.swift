import XCTest
import SundayKeysCore

/// `parseAll` exists because of what the receive probe found: a note on, a note
/// off and a control change arrived as one packet, and reading only the first
/// three bytes kept the note on and lost the other two.
final class MIDIMessageParseAllTests: XCTestCase {
    func testThreeMessagesInOnePacketAreAllParsed() {
        let packet = MIDIReceiveExpectation().packets.flatMap { $0 }

        XCTAssertEqual(
            MIDIMessage.parseAll(packet),
            [
                .noteOn(note: 60, velocity: 100, channel: 0),
                .noteOff(note: 60, velocity: 64, channel: 0),
                .controlChange(controller: 1, value: 64, channel: 0),
            ]
        )
    }

    func testRunningStatusCarriesTheMessageOn() {
        XCTAssertEqual(
            MIDIMessage.parseAll([0x90, 60, 100, 62, 100]),
            [
                .noteOn(note: 60, velocity: 100, channel: 0),
                .noteOn(note: 62, velocity: 100, channel: 0),
            ]
        )
    }

    func testNoteOnWithZeroVelocityInsideAPacketIsANoteOff() {
        XCTAssertEqual(
            MIDIMessage.parseAll([0x90, 60, 100, 60, 0, 0xB0, 1, 64]),
            [
                .noteOn(note: 60, velocity: 100, channel: 0),
                .noteOff(note: 60, velocity: 0, channel: 0),
                .controlChange(controller: 1, value: 64, channel: 0),
            ]
        )
    }

    func testATruncatedMessageAtTheEndIsDropped() {
        XCTAssertEqual(
            MIDIMessage.parseAll([0x90, 60, 100, 0x80, 60]),
            [.noteOn(note: 60, velocity: 100, channel: 0)]
        )
    }

    func testRealTimeBytesLeaveTheMessagesAroundThemIntact() {
        XCTAssertEqual(
            MIDIMessage.parseAll([0xF8, 0x90, 60, 100, 0xFE]),
            [.noteOn(note: 60, velocity: 100, channel: 0)]
        )
    }

    func testDataWithNoStatusToApplyItToIsIgnored() {
        XCTAssertEqual(MIDIMessage.parseAll([60, 100]), [])
    }

    func testEachPacketOnItsOwnParsesTheSameAsParse() {
        for packet in MIDIReceiveExpectation().packets {
            XCTAssertEqual(
                MIDIMessage.parseAll(packet),
                MIDIMessage.parse(packet).map { [$0] } ?? []
            )
        }
    }
}
