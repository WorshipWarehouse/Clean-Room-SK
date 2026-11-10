import XCTest
@testable import SundayKeysCore

/// Records what the caller emitted, with the instant it said it was due.
private final class RecordingSink: NoteEventSink {
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
    var noteOffs: [String] { lines.filter { $0.contains(" off ") } }
}

/// A stand-in for the keysound path, so a test can see what reaches the engine.
private final class RecordingTarget: KeysoundNoteTarget {
    private(set) var lines: [String] = []

    func noteOn(note: UInt8, velocity: UInt8) {
        lines.append("on \(note) v\(velocity)")
    }

    func noteOff(note: UInt8) {
        lines.append("off \(note)")
    }
}

/// The arpeggiator's caller, driven by a virtual clock so every assertion is an exact instant.
final class ArpeggiatorServiceTests: XCTestCase {
    private func makeService(
        enabled: Bool = true,
        style: ArpeggiatorStyle = .up,
        beatsPerMinute: Double = 120,
        division: StepDivision = .eighth,
        gate: Double = 0.5,
        velocity: UInt8 = 100
    ) -> (ManualHostClock, RecordingSink, RecordingTarget, ArpeggiatorService) {
        let clock = ManualHostClock(now: 0)
        let sink = RecordingSink()
        let target = RecordingTarget()
        let service = ArpeggiatorService(
            clock: clock,
            target: target,
            sink: sink,
            style: style,
            isEnabled: enabled,
            beatsPerMinute: beatsPerMinute,
            division: division,
            gateFraction: gate,
            velocity: velocity
        )
        return (clock, sink, target, service)
    }

    func testAHeldChordStepsThroughTheCallerWithExactInstants() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 110, at: 0)
        service.keyDown(note: 64, velocity: 110, at: 0)
        service.keyDown(note: 67, velocity: 110, at: 0)

        clock.now = 1
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.125 off 60",
            "0.25 on 64 v100",
            "0.375 off 64",
            "0.5 on 67 v100",
            "0.625 off 67",
            "0.75 on 60 v100",
            "0.875 off 60",
            "1.0 on 64 v100",
        ])
        XCTAssertTrue(service.isStepping)
        XCTAssertEqual(service.heldNotes, [60, 64, 67])
    }

    func testTheFirstStepLandsOnTheInstantOfTheKeyPress() {
        let (clock, sink, _, service) = makeService()

        clock.now = 4.9
        service.tick()
        XCTAssertEqual(sink.lines, [])

        clock.now = 5.0
        service.keyDown(note: 60, velocity: 100, at: 5.0)
        service.tick()

        XCTAssertEqual(sink.lines, ["5.0 on 60 v100"])
    }

    func testNoteOffsPrecedeNoteOnsAtASharedInstant() {
        let (clock, sink, _, service) = makeService(gate: 1.0)
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)
        service.keyDown(note: 67, velocity: 100, at: 0)

        clock.now = 0.5
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.25 off 60",
            "0.25 on 64 v100",
            "0.5 off 64",
            "0.5 on 67 v100",
        ])
    }

    func testReleasingTheSoundingNoteEndsItAtOnceAndCancelsItsOff() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 60, at: 0.0625)

        clock.now = 0.25
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
            "0.25 on 64 v100",
        ])
        XCTAssertEqual(sink.noteOffs, ["0.0625 off 60"])
    }

    func testASecondNoteHeldMidRunJoinsAtTheNextStep() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)

        clock.now = 0
        service.tick()

        clock.now = 0.1
        service.keyDown(note: 64, velocity: 100, at: 0.1)

        clock.now = 0.25
        service.tick()
        clock.now = 0.5
        service.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 60 v100",
        ])
    }

    func testAnEmptyHeldSetEmitsNothing() {
        let (clock, sink, _, service) = makeService()

        clock.now = 5
        service.tick()

        XCTAssertEqual(sink.lines, [])
        XCTAssertFalse(service.isStepping)
    }

    func testStyleChangeTakesEffectOnTheNextStep() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)
        service.keyDown(note: 67, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.setStyle(.down)

        clock.now = 0.5
        service.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 67 v100",
            "0.5 on 64 v100",
        ])
        XCTAssertEqual(service.style, .down)
    }

    func testTempoChangeTakesEffectAfterThePendingStep() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        clock.now = 0.25
        service.tick()
        service.setBeatsPerMinute(240, at: 0.25)

        clock.now = 0.5
        service.tick()
        clock.now = 0.625
        service.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 60 v100",
            "0.625 on 64 v100",
        ])
        XCTAssertEqual(service.beatsPerMinute, 240)
    }

    func testSubdivisionChangeTakesEffectAfterThePendingStep() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        clock.now = 0.25
        service.tick()
        service.setDivision(.quarter, at: 0.25)

        clock.now = 1.0
        service.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 60 v100",
            "1.0 on 64 v100",
        ])
        XCTAssertEqual(service.division, .quarter)
    }

    func testReleasingTheLastNoteStopsThePatternAndEndsTheSoundingNote() {
        let (clock, sink, _, service) = makeService()
        service.keyDown(note: 60, velocity: 100, at: 0)

        clock.now = 0
        service.tick()
        service.keyUp(note: 60, at: 0.0625)

        clock.now = 2
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
        ])
        XCTAssertFalse(service.isStepping)
        XCTAssertEqual(service.heldNotes, [])
    }

    func testWithTheArpeggiatorOffKeysPassStraightThrough() {
        let (clock, sink, _, service) = makeService(enabled: false)

        clock.now = 1.0
        service.keyDown(note: 60, velocity: 120, at: 1.0)
        clock.now = 1.5
        service.keyUp(note: 60, at: 1.5)
        clock.now = 5
        service.tick()

        XCTAssertEqual(sink.lines, [
            "1.0 on 60 v120",
            "1.5 off 60",
        ])
    }

    func testEnablingWithKeysHeldStartsThePatternAtThatInstant() {
        let (clock, sink, _, service) = makeService(enabled: false)

        clock.now = 0
        service.keyDown(note: 60, velocity: 120, at: 0)
        service.setEnabled(true, at: 2.0)
        clock.now = 2.0
        service.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v120",
            "2.0 off 60",
            "2.0 on 60 v100",
        ])
    }

    func testTheDefaultSinkReachesTheKeysoundPath() {
        let clock = ManualHostClock(now: 0)
        let target = RecordingTarget()
        let service = ArpeggiatorService(clock: clock, target: target, isEnabled: true)

        service.keyDown(note: 60, velocity: 100, at: 0)
        clock.now = 0
        service.tick()
        clock.now = 0.125
        service.tick()

        XCTAssertEqual(target.lines, [
            "on 60 v100",
            "off 60",
        ])
    }
}
