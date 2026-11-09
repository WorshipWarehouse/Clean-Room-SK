import XCTest
@testable import SundayKeysCore

final class MIDIMessageTests: XCTestCase {
    func testNoteOnIsParsed() {
        let message = MIDIMessage.parse([0x90, 60, 100])
        XCTAssertEqual(message, .noteOn(note: 60, velocity: 100, channel: 0))
    }

    func testNoteOnWithZeroVelocityBecomesNoteOff() {
        let message = MIDIMessage.parse([0x93, 60, 0])
        XCTAssertEqual(message, .noteOff(note: 60, velocity: 0, channel: 3))
    }

    func testNoteOffIsParsed() {
        let message = MIDIMessage.parse([0x82, 48, 64])
        XCTAssertEqual(message, .noteOff(note: 48, velocity: 64, channel: 2))
    }

    func testControlChangeKeepsChannel() {
        let message = MIDIMessage.parse([0xB4, 7, 90])
        XCTAssertEqual(message, .controlChange(controller: 7, value: 90, channel: 4))
    }

    func testPitchBendCombinesBothBytes() {
        let message = MIDIMessage.parse([0xE0, 0x00, 0x40])
        XCTAssertEqual(message, .pitchBend(value: 8192, channel: 0))
    }

    func testDataByteWithoutStatusIsRejected() {
        XCTAssertNil(MIDIMessage.parse([0x40, 0x00]))
    }
}

final class VelocityCurveTests: XCTestCase {
    private let curve = VelocityCurve()

    func testZeroVelocityIsSilent() {
        XCTAssertEqual(curve.gain(forVelocity: 0), 0)
    }

    func testFullVelocityReachesUnity() {
        XCTAssertEqual(curve.gain(forVelocity: 127), 1, accuracy: 0.0001)
    }

    func testSoftVelocityStaysAboveFloor() {
        XCTAssertGreaterThanOrEqual(curve.gain(forVelocity: 1), curve.floor)
    }

    func testCurveIsMonotonic() {
        var previous: Float = -1
        for velocity in UInt8(1)...127 {
            let gain = curve.gain(forVelocity: velocity)
            XCTAssertGreaterThan(gain, previous)
            previous = gain
        }
    }
}

final class NoteRangeTests: XCTestCase {
    func testContainsWithinRange() {
        let range = NoteRange(48, 72)
        XCTAssertTrue(range.contains(60))
        XCTAssertFalse(range.contains(47))
        XCTAssertFalse(range.contains(73))
    }

    func testInvertedRangeStillContains() {
        let range = NoteRange(72, 48)
        XCTAssertTrue(range.isInverted)
        XCTAssertTrue(range.contains(60))
        XCTAssertEqual(range.bounds.low, 48)
        XCTAssertEqual(range.bounds.high, 72)
    }

    func testClampPullsIntoRange() {
        let range = NoteRange(48, 72)
        XCTAssertEqual(range.clamped(30), 48)
        XCTAssertEqual(range.clamped(90), 72)
        XCTAssertEqual(range.clamped(60), 60)
    }
}
