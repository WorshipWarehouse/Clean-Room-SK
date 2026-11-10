import XCTest
@testable import SundayKeysCore

/// Records what the step clock emitted, in the order it emitted it.
private final class RecordingSink: NoteEventSink {
    private(set) var times: [TimeInterval] = []
    private(set) var messages: [MIDIMessage] = []

    func send(_ message: MIDIMessage, at time: TimeInterval) {
        times.append(time)
        messages.append(message)
    }

    /// One line per event: the exact time, then what happened.
    var lines: [String] {
        zip(times, messages).map { time, message in
            switch message {
            case let .noteOn(note, velocity, _):
                return "\(time) on \(note) v\(velocity)"
            case let .noteOff(note, _, _):
                return "\(time) off \(note)"
            default:
                return "\(time) other"
            }
        }
    }

    var noteOnTimes: [TimeInterval] {
        zip(times, messages).compactMap { time, message in
            if case .noteOn = message { return time }
            return nil
        }
    }

    var noteOnNotes: [UInt8] {
        messages.compactMap { message in
            if case let .noteOn(note, _, _) = message { return note }
            return nil
        }
    }

    var noteOffNotes: [UInt8] {
        messages.compactMap { message in
            if case let .noteOff(note, _, _) = message { return note }
            return nil
        }
    }
}

/// The step clock, driven by a virtual host clock so every assertion is an exact instant.
final class StepClockTests: XCTestCase {
    private func makeClock(
        running: Bool = true,
        beatsPerMinute: Double = 120,
        division: StepDivision = .eighth,
        gate: Double = 0.5,
        style: ArpeggiatorStyle = .up
    ) -> (ManualHostClock, RecordingSink, StepClock) {
        let clock = ManualHostClock(now: 0)
        let sink = RecordingSink()
        let stepClock = StepClock(
            clock: clock,
            sink: sink,
            style: style,
            settings: StepClockSettings(
                isRunning: running,
                beatsPerMinute: beatsPerMinute,
                division: division,
                gateFraction: gate
            )
        )
        return (clock, sink, stepClock)
    }

    func testStepsLandOnTheExactGrid() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)
        stepClock.hold(67, at: 0)

        clock.now = 1
        stepClock.tick()

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
    }

    func testNoteOffsPrecedeNoteOnsAtTheSameInstant() {
        let (clock, sink, stepClock) = makeClock(gate: 1.0)
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)
        stepClock.hold(67, at: 0)

        clock.now = 0.5
        stepClock.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.25 off 60",
            "0.25 on 64 v100",
            "0.5 off 64",
            "0.5 on 67 v100",
        ])
    }

    func testEventTimesNeverGoBackwards() {
        let (clock, sink, stepClock) = makeClock(gate: 0.25)
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 1
        stepClock.tick()

        XCTAssertEqual(sink.times, sink.times.sorted())
        XCTAssertEqual(sink.times.count, 9)
    }

    func testReleasingTheSoundingNoteEndsItAtOnce() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 0
        stepClock.tick()
        stepClock.release(60, at: 0.0625)

        clock.now = 0.25
        stepClock.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
            "0.25 on 64 v100",
        ])
        XCTAssertEqual(stepClock.heldNotes, [64])
    }

    func testStyleChangeTakesEffectOnTheNextStep() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)
        stepClock.hold(67, at: 0)

        clock.now = 0
        stepClock.tick()
        stepClock.setStyle(.down)

        clock.now = 0.5
        stepClock.tick()

        XCTAssertEqual(sink.noteOnNotes, [60, 67, 64])
        XCTAssertEqual(sink.noteOnTimes, [0.0, 0.25, 0.5])
    }

    func testTempoChangeAppliesAfterThePendingStep() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 0.25
        stepClock.tick()
        stepClock.apply(StepClockSettings(isRunning: true, beatsPerMinute: 240, division: .eighth), at: 0.25)

        clock.now = 0.5
        stepClock.tick()
        clock.now = 0.625
        stepClock.tick()

        XCTAssertEqual(sink.noteOnTimes, [0.0, 0.25, 0.5, 0.625])
    }

    func testDivisionChangeAppliesAfterThePendingStep() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 0.25
        stepClock.tick()
        stepClock.apply(StepClockSettings(isRunning: true, beatsPerMinute: 120, division: .quarter), at: 0.25)

        clock.now = 1.0
        stepClock.tick()

        XCTAssertEqual(sink.noteOnTimes, [0.0, 0.25, 0.5, 1.0])
    }

    func testEmptyHeldSetProducesNoEventsAndTheFirstNoteLandsAtOnce() {
        let (clock, sink, stepClock) = makeClock()

        clock.now = 1.0
        stepClock.tick()
        XCTAssertEqual(sink.lines, [])

        stepClock.hold(60, at: 1.0)
        stepClock.tick()

        XCTAssertEqual(sink.lines, ["1.0 on 60 v100"])
    }

    func testATickExactlyOnTheFirstStepProducesOneStep() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 0
        stepClock.tick()
        XCTAssertEqual(sink.noteOnTimes, [0.0])

        stepClock.tick()
        XCTAssertEqual(sink.noteOnTimes, [0.0])
    }

    func testGateFractionStretchesTheNoteOff() {
        let (clock, sink, stepClock) = makeClock(gate: 0.25)
        stepClock.hold(60, at: 0)

        clock.now = 0
        stepClock.tick()
        XCTAssertEqual(sink.lines, ["0.0 on 60 v100"])

        clock.now = 0.0625
        stepClock.tick()
        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
        ])
    }

    func testStopReleasesTheSoundingNoteAndEndsThePattern() {
        let (clock, sink, stepClock) = makeClock()
        stepClock.hold(60, at: 0)

        clock.now = 0
        stepClock.tick()
        stepClock.stop(at: 0.0625)

        clock.now = 2
        stepClock.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0625 off 60",
        ])
        XCTAssertFalse(stepClock.isRunning)
        XCTAssertEqual(stepClock.heldNotes, [])
    }

    func testChordStyleEmitsEveryNoteAtOneTimestamp() {
        let (clock, sink, stepClock) = makeClock(style: .chord)
        stepClock.hold(67, at: 0)
        stepClock.hold(60, at: 0)
        stepClock.hold(64, at: 0)

        clock.now = 0
        stepClock.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.0 on 64 v100",
            "0.0 on 67 v100",
        ])

        clock.now = 0.125
        stepClock.tick()

        XCTAssertEqual(sink.noteOffNotes, [60, 64, 67])
        XCTAssertEqual(Array(sink.times.suffix(3)), [0.125, 0.125, 0.125])
    }
}
