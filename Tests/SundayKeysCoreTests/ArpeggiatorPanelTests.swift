import XCTest
@testable import SundayKeysCore

/// Records what the panel's service emitted, with the instant it said it was
/// due.
private final class PanelSink: NoteEventSink {
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

/// The panel layer the window binds to, driven by a virtual clock.
///
/// The section's controls reach the service only through `ArpeggiatorPanel`, so
/// these cases are what a press of a control actually does: the panel's state
/// and the service's agree, a change lands at the instant the clock says, and
/// the pattern, octave and latch behaviour the service suite pins is unchanged
/// when the same calls arrive through the panel.
///
/// Every instant is on the default grid: 120 bpm, `.eighth`, so a step every
/// 0.25 s and a note off 0.125 s after its note on.
final class ArpeggiatorPanelTests: XCTestCase {
    private func makePanel(
        enabled: Bool = true,
        latched: Bool = false
    ) -> (ManualHostClock, PanelSink, ArpeggiatorPanel) {
        let clock = ManualHostClock(now: 0)
        let sink = PanelSink()
        let service = ArpeggiatorService(
            clock: clock,
            target: SilentTarget(),
            sink: sink,
            isEnabled: enabled,
            isLatched: latched
        )
        return (clock, sink, ArpeggiatorPanel(service: service, clock: clock))
    }

    private func step(
        _ clock: ManualHostClock,
        _ panel: ArpeggiatorPanel,
        _ times: [TimeInterval]
    ) {
        for time in times {
            clock.now = time
            panel.tick()
        }
    }

    func testThePanelStartsOffOnTheDefaultGrid() {
        let (_, _, panel) = makePanel(enabled: false)

        XCTAssertFalse(panel.isEnabled)
        XCTAssertFalse(panel.isLatched)
        XCTAssertEqual(panel.pattern, .up)
        XCTAssertEqual(panel.octaves, 1)
        XCTAssertEqual(panel.beatsPerMinute, 120)
        XCTAssertEqual(panel.division, .eighth)
        XCTAssertEqual(
            panel.statusLine,
            "Arp off, latch off, Up, 1 octave, 120 bpm, eighth"
        )
    }

    func testTheLatchToggleChangesTheServiceStateBothWays() {
        let (_, _, panel) = makePanel()

        panel.toggleLatch()

        XCTAssertTrue(panel.isLatched)
        XCTAssertTrue(panel.service.isLatched)
        XCTAssertEqual(panel.latchLabel, "Latch on")

        panel.toggleLatch()

        XCTAssertFalse(panel.isLatched)
        XCTAssertFalse(panel.service.isLatched)
        XCTAssertEqual(panel.latchLabel, "Latch off")
    }

    func testThePatternAndOctaveControlsReachTheService() {
        let (_, _, panel) = makePanel()

        panel.setPattern(.down)
        panel.setOctaves(3)

        XCTAssertEqual(panel.pattern, .down)
        XCTAssertEqual(panel.service.style, .down)
        XCTAssertEqual(panel.patternLabel, "Down")
        XCTAssertEqual(panel.octaves, 3)
        XCTAssertEqual(panel.service.octaves, 3)
        XCTAssertEqual(panel.octavesLabel, "3 octaves")
        XCTAssertEqual(
            panel.statusLine,
            "Arp on, latch off, Down, 3 octaves, 120 bpm, eighth"
        )
    }

    func testTheOctaveControlIsClampedToOneToFour() {
        let (_, _, panel) = makePanel()

        panel.setOctaves(9)
        XCTAssertEqual(panel.octaves, 4)
        XCTAssertEqual(panel.octavesLabel, "4 octaves")

        panel.setOctaves(0)
        XCTAssertEqual(panel.octaves, 1)
        XCTAssertEqual(panel.octavesLabel, "1 octave")
    }

    func testAPatternAndSpanChosenThroughThePanelChangeWhatSounds() {
        let (clock, sink, panel) = makePanel()

        clock.now = 0
        panel.keyDown(note: 60, velocity: 100)
        panel.keyDown(note: 64, velocity: 100)
        panel.keyDown(note: 67, velocity: 100)

        panel.setPattern(.upDown)
        panel.setOctaves(2)

        step(clock, panel, [0, 0.25, 0.5, 0.75])

        // Two octaves of 60, 64, 67 walked up turn at 79, so the fourth step is
        // 72 rather than an immediate return to 60.
        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 64 v100",
            "0.5 on 67 v100",
            "0.75 on 72 v100",
        ])
    }

    func testALatchedPatternThroughThePanelKeepsRunningAfterTheKeyComesUp() {
        let (clock, sink, panel) = makePanel(latched: true)

        clock.now = 0
        panel.keyDown(note: 60, velocity: 100)
        panel.tick()

        clock.now = 0.05
        panel.keyUp(note: 60)

        clock.now = 0.75
        panel.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.125 off 60",
            "0.25 on 60 v100",
            "0.375 off 60",
            "0.5 on 60 v100",
            "0.625 off 60",
            "0.75 on 60 v100",
        ])
        XCTAssertTrue(panel.isStepping)
        XCTAssertEqual(panel.heldNotes, [60])
    }

    func testTogglingLatchOffReleasesTheUnheldNoteAtThatInstant() {
        let (clock, sink, panel) = makePanel(latched: true)

        clock.now = 0
        panel.keyDown(note: 60, velocity: 100)
        panel.tick()

        clock.now = 0.05
        panel.keyUp(note: 60)

        clock.now = 0.1
        panel.toggleLatch()

        clock.now = 0.5
        panel.tick()

        XCTAssertEqual(sink.lines, [
            "0.0 on 60 v100",
            "0.1 off 60",
        ])
        XCTAssertFalse(panel.isLatched)
        XCTAssertEqual(panel.heldNotes, [])
        XCTAssertFalse(panel.isStepping)
    }

    func testTogglingLatchOffKeepsTheKeyStillHeld() {
        let (clock, sink, panel) = makePanel(latched: true)

        clock.now = 0
        panel.keyDown(note: 60, velocity: 100)
        panel.keyDown(note: 64, velocity: 100)
        panel.tick()

        clock.now = 0.05
        panel.keyUp(note: 64)

        clock.now = 0.06
        panel.toggleLatch()

        XCTAssertEqual(panel.heldNotes, [60])

        clock.now = 0.5
        panel.tick()

        XCTAssertEqual(sink.noteOns, [
            "0.0 on 60 v100",
            "0.25 on 60 v100",
            "0.5 on 60 v100",
        ])
    }

    func testTheTempoAndDivisionControlsReachTheService() {
        let (_, _, panel) = makePanel()

        panel.setBeatsPerMinute(5000)
        panel.setDivision(.sixteenth)

        XCTAssertEqual(
            panel.beatsPerMinute,
            MetronomeSettings.clampTempo(5000)
        )
        XCTAssertLessThan(panel.beatsPerMinute, 5000)
        XCTAssertEqual(panel.division, .sixteenth)
        XCTAssertEqual(panel.divisionLabel, "sixteenth")
        XCTAssertEqual(
            panel.statusLine,
            "Arp on, latch off, Up, 1 octave, "
                + "\(Int(MetronomeSettings.clampTempo(5000).rounded())) bpm, "
                + "sixteenth"
        )
    }

    func testKeysPassStraightThroughWhileTheArpeggiatorIsOff() {
        let (clock, sink, panel) = makePanel(enabled: false, latched: true)

        clock.now = 0.5
        panel.keyDown(note: 60, velocity: 120)

        clock.now = 1.0
        panel.keyUp(note: 60)

        clock.now = 2
        panel.tick()

        XCTAssertEqual(sink.lines, [
            "0.5 on 60 v120",
            "1.0 off 60",
        ])
        XCTAssertFalse(panel.isStepping)
    }
}
