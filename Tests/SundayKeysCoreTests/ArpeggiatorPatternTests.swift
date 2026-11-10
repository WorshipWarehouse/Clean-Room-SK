import XCTest
@testable import SundayKeysCore

/// Records what the caller emitted, with the instant it said it was due.
private final class PatternSink: NoteEventSink {
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
private final class PatternTarget: KeysoundNoteTarget {
    func noteOn(note: UInt8, velocity: UInt8) {}
    func noteOff(note: UInt8) {}
}

/// Pattern order and octave span, driven by a virtual clock so every
/// assertion is an exact instant.
///
/// The analysis names the six orderings and records no behaviour for any of
/// them and no octave behaviour at all, so the rules pinned here are this
/// repository's own and replaceable: `up` walks the held chord from its
/// lowest note, `down` from its highest, `upDown` turns at the top and the
/// bottom without repeating either end, an octave span repeats every held
/// note twelve semitones higher per extra octave, and one octave is exactly
/// the held keys.
///
/// Every instant is on the default grid: 120 bpm, `.eighth` division, so a
/// step every 0.25 s and a note off 0.125 s after its note on.
final class ArpeggiatorPatternTests: XCTestCase {
    private func makeService(
        style: ArpeggiatorStyle = .up,
        octaves: Int = 1,
        latched: Bool = false
    ) -> (ManualHostClock, PatternSink, ArpeggiatorService) {
        let clock = ManualHostClock(now: 0)
        let sink = PatternSink()
        let service = ArpeggiatorService(
            clock: clock,
            target: PatternTarget(),
            sink: sink,
            style: style,
            octaves: octaves,
            isEnabled: true,
            isLatched: latched
        )
        return (clock, sink, service)
    }

    /// Ticks once per grid instant, in order, so a case reads as the steps it
    /// expects rather than as a loop.
    private func step(
        _ clock: ManualHostClock,
        _ service: ArpeggiatorService,
        _ times: [TimeInterval]
    ) {
        for time in times {
            clock.now = time
            service.tick()
        }
    }

    private func hold6040And67(at time: TimeInterval, on service: ArpeggiatorService) {
        service.keyDown(note: 60, velocity: 100, at: time)
        service.keyDown(note: 64, velocity: 100, at: time)
        service.keyDown(note: 67, velocity: 100, at: time)
    }

    func testUpWalksTheHeldChordFromItsLowestNote() {
        let (clock, sink, service) = makeService(style: .up)
        hold6040And67(at: 0, on: service)

        step(clock, service, [0, 0.25, 0.5, 0.75])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 67 v100",
            "0.75 on 60 v100",
        ])
        XCTAssertEqual(service.style, .up)
    }

    func testDownWalksTheHeldChordFromItsHighestNote() {
        let (clock, sink, service) = makeService(style: .down)
        hold6040And67(at: 0, on: service)

        step(clock, service, [0, 0.25, 0.5, 0.75])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 67 v100",
            "0.25 on 64 v100",
            "0.5 on 60 v100",
            "0.75 on 67 v100",
        ])
        XCTAssertEqual(service.style, .down)
    }

    func testUpDownTurnsWithoutRepeatingEitherEnd() {
        let (clock, sink, service) = makeService(style: .upDown)
        hold6040And67(at: 0, on: service)

        step(clock, service, [0, 0.25, 0.5, 0.75, 1.0])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 67 v100",
            "0.75 on 64 v100",
            "1.0 on 60 v100",
        ])
        XCTAssertEqual(service.style, .upDown)
    }

    func testOneOctavePlaysExactlyTheKeysThePlayerHolds() {
        let (clock, sink, service) = makeService(style: .up, octaves: 1)
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        step(clock, service, [0, 0.25, 0.5, 0.75])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 60 v100",
            "0.75 on 64 v100",
        ])
        XCTAssertEqual(service.octaves, 1)
    }

    func testTwoOctavesRepeatTheHeldChordAnOctaveHigher() {
        let (clock, sink, service) = makeService(style: .up, octaves: 2)
        service.keyDown(note: 60, velocity: 100, at: 0)
        service.keyDown(note: 64, velocity: 100, at: 0)

        step(clock, service, [0, 0.25, 0.5, 0.75])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 72 v100",
            "0.75 on 76 v100",
        ])
        XCTAssertEqual(service.octaves, 2)
    }

    func testFourOctavesSpanThreeOctavesAboveTheLowestKey() {
        let (clock, sink, service) = makeService(style: .up, octaves: 4)
        service.keyDown(note: 60, velocity: 100, at: 0)

        step(clock, service, [0, 0.25, 0.5, 0.75])

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 72 v100",
            "0.5 on 84 v100",
            "0.75 on 96 v100",
        ])
        XCTAssertEqual(service.octaves, 4)
    }

    func testTheOctaveSpanIsClampedToOneToFour() {
        let (_, _, service) = makeService(style: .up)

        service.setOctaves(9)
        XCTAssertEqual(service.octaves, 4)

        service.setOctaves(0)
        XCTAssertEqual(service.octaves, 1)

        service.setOctaves(3)
        XCTAssertEqual(service.octaves, 3)
    }

    func testAPatternAndSpanChangedMidLatchedRunShowOnTheNextStep() {
        let (clock, sink, service) = makeService(latched: true)
        hold6040And67(at: 0, on: service)

        step(clock, service, [0, 0.25])

        // Lift every key: under latch the pattern keeps them, so the change
        // below is one made while nothing is physically held.
        service.keyUp(note: 60, at: 0.3)
        service.keyUp(note: 64, at: 0.3)
        service.keyUp(note: 67, at: 0.3)

        service.setStyle(.down)
        service.setOctaves(2)

        step(clock, service, [0.5, 0.75])

        // Two octaves of 60, 64, 67 walked downward start at 79.
        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 79 v100",
            "0.75 on 76 v100",
        ])
        XCTAssertEqual(service.heldNotes, [60, 64, 67])
        XCTAssertTrue(service.isStepping)
    }

    func testChangingThePatternDoesNotInterruptTheGrid() {
        let (clock, sink, service) = makeService(style: .up)
        hold6040And67(at: 0, on: service)

        step(clock, service, [0])

        service.setStyle(.down)

        step(clock, service, [0.25, 0.5])

        // The step that was already scheduled still lands at 0.25, and the new
        // order is what fills it.
        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 67 v100",
            "0.5 on 64 v100",
        ])
    }
}
