import XCTest
@testable import SundayKeysCore

/// Records what the caller emitted, with the instant it said it was due.
private final class LatchSink: NoteEventSink {
    private(set) var lines: [String] = []

    func send(_ message: MIDIMessage, at time: TimeInterval) {
        switch message {
        case let .noteOn(note, velocity, _):
            lines.append("\(time) on \(note) v\(velocity)")
        case let .noteOff(note, _, _):
            lines.append("\(time) off \(note)")
        default:
            lines.append("\(time) other")
        }
    }

    var noteOns: [String] { lines.filter { $0.contains(" on ") } }
}

/// A target that goes nowhere: these cases read the sink, not the engine.
private final class SilentTarget: KeysoundNoteTarget {
    func noteOn(note: UInt8, velocity: UInt8) {}
    func noteOff(note: UInt8) {}
}

/// Latch, driven by a virtual clock so every assertion is an exact instant.
///
/// The analysis records latch as **Unknown**, so the behaviour tested here is
/// this repository's own and replaceable: a released key stays in the pattern,
/// the pattern keeps running with no key down, and the first press made with
/// nothing physically held starts a new chord.
final class ArpeggiatorLatchTests: XCTestCase {
    private func makeService(
        enabled: Bool = true,
        latched: Bool = false
    ) -> (ManualHostClock, LatchSink, ArpeggiatorService) {
        let clock = ManualHostClock(now: 0)
        let sink = LatchSink()
        let service = ArpeggiatorService(
            clock: clock,
            target: SilentTarget(),
            sink: sink,
            isEnabled: enabled,
            isLatched: latched
        )
        return (clock, sink, service)
    }

    func testALatchedPatternKeepsRunningAfterTheLastKeyComesUp() {
        let (clock, sink, service) = makeService(latched: true)
        service.keyDown(note: 60, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 60, at: 0.05)

        clock.now = 0.25
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
            "0.125 on 60 v100",
            "0.1875 off 60",
            "0.25 on 60 v100",
        ])
        XCTAssertTrue(service.isStepping)
        XCTAssertEqual(service.heldNotes, [60])
    }

    func testPressingANewChordWithNothingHeldReleasesTheOldOne() {
        let (clock, sink, service) = makeService(latched: true)
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 60, at: 0.05)
        service.keyUp(note: 64, at: 0.05)

        clock.now = 0.1
        service.tick()

        service.keyDown(note: 67, velocity: 100, at: 0.2)
        clock.now = 0.2
        service.tick()
        clock.now = 0.325
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
            "0.2 on 67 v100",
            "0.2625 off 67",
            "0.325 on 67 v100",
        ])
        XCTAssertEqual(service.heldNotes, [67])
    }

    func testTurningLatchOffReleasesTheNotesNoKeyHolds() {
        let (clock, sink, service) = makeService(latched: true)
        service.keyDown(note: 60, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 60, at: 0.05)
        service.setLatched(false, at: 0.1)

        clock.now = 0.5
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.1 off 60",
        ])
        XCTAssertEqual(service.heldNotes, [])
        XCTAssertFalse(service.isStepping)
    }

    func testTurningLatchOffKeepsTheNotesStillHeld() {
        let (clock, sink, service) = makeService(latched: true)
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 64, at: 0.05)
        service.setLatched(false, at: 0.06)

        XCTAssertEqual(service.heldNotes, [60])

        clock.now = 0.25
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
            "0.125 on 60 v100",
            "0.1875 off 60",
            "0.25 on 60 v100",
        ])
    }

    func testLatchDoesNothingWhileTheArpeggiatorIsOff() {
        let (clock, sink, service) = makeService(enabled: false, latched: true)

        clock.now = 0.5
        service.keyDown(note: 60, velocity: 120, at: 0.5)
        clock.now = 1.0
        service.keyUp(note: 60, at: 1.0)
        clock.now = 2
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.5 on 60 v120",
            "1.0 off 60",
        ])
    }

    func testAKeyPressedWhileAnotherIsDownJoinsTheRunningPattern() {
        let (clock, sink, service) = makeService(latched: true)
        service.keyDown(note: 60, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyDown(note: 64, velocity: 100, at: 0.1)

        clock.now = 0.25
        service.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.125 on 64 v100",
            "0.25 on 60 v100",
        ])
        XCTAssertEqual(service.heldNotes, [60, 64])
    }

    func testEnablingUnderLatchKeepsTheHeldKeyInThePattern() {
        let (clock, sink, service) = makeService(
            enabled: false,
            latched: true
        )

        clock.now = 0
        service.keyDown(note: 60, velocity: 120, at: 0)
        service.setEnabled(true, at: 1.0)

        clock.now = 1.0
        service.tick()
        service.keyUp(note: 60, at: 1.05)

        clock.now = 1.125
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v120",
            "1.0 off 60",
            "1.0 on 60 v100",
            "1.0625 off 60",
            "1.125 on 60 v100",
        ])
        XCTAssertEqual(service.heldNotes, [60])
        XCTAssertTrue(service.isStepping)
    }
}
