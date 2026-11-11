import Foundation
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The arpeggiator's path through the app model, with time moved by hand.
///
/// These cases drive the model the window drives - its MIDI transport note methods,
/// which is the same note path a controller reaches - and assert the exact notes that
/// reach the voices, at the exact instants the step clock chose. Before this wiring
/// existed, a note press went straight to the voices and nothing but that one note
/// ever arrived, so every sequence below fails on the model as it was.
///
/// Nothing here starts an engine, opens a device or contacts a server: the controller
/// is built over a recorder and the clock is a `ManualHostClock`.
@MainActor
final class StepClockWiringTests: XCTestCase {
    /// Records what reached the voices, so "stepped" means these calls arrived rather
    /// than that a flag said so.
    private final class RecordingVoicing: KeysoundVoicing {
        private(set) var lines: [String] = []

        func noteOn(note: UInt8, velocity: UInt8) {
            lines.append("on \(note) v\(velocity)")
        }

        func noteOff(note: UInt8) {
            lines.append("off \(note)")
        }

        func allNotesOff() {
            lines.append("all off")
        }
    }

    private struct StubTransport: SessionTransport {
        let body: String

        func send(_ request: SessionRequest) async throws -> SessionResponse {
            SessionResponse(statusCode: 200, body: Data(body.utf8))
        }
    }

    /// 2026-01-10T00:00:00Z, so the licence cases read a fixed instant.
    private let now = Date(timeIntervalSince1970: 1_768_003_200)
    private let products =
        "[{\"originProductId\":\"p1\",\"productId\":\"p1\",\"productVersion\":\"1\"}]"

    private func makeModel(
        clock: ManualHostClock,
        voices: RecordingVoicing,
        sessionClient: SessionClient? = nil
    ) -> AppModel {
        AppModel(
            sessionClient: sessionClient,
            clock: clock,
            audio: AudioEngineController(voice: voices)
        )
    }

    /// Moves the host clock to an instant and ticks once, which is what the app's
    /// ticker does when the run loop reaches that instant.
    private func tick(_ model: AppModel, clock: ManualHostClock, to time: TimeInterval) {
        clock.now = time
        model.tickArpeggiator()
    }

    private func hold(_ model: AppModel, _ notes: [UInt8]) {
        for note in notes {
            model.noteOn(note: note, velocity: 100, channel: 0)
        }
    }

    // MARK: - The sequence

    /// Three held notes at 120 bpm in eighths: one step every 0.125 s, a gate of half a
    /// step, so each note sounds for 0.0625 s. Up walks 60, 64, 67 and wraps.
    func testAChordSteppedThroughTheModelProducesTheExactSequence() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60, 64, 67])

        tick(model, clock: clock, to: 0)
        tick(model, clock: clock, to: 0.0625)
        tick(model, clock: clock, to: 0.125)
        tick(model, clock: clock, to: 0.1875)
        tick(model, clock: clock, to: 0.25)
        tick(model, clock: clock, to: 0.3125)
        tick(model, clock: clock, to: 0.375)
        tick(model, clock: clock, to: 0.4375)

        XCTAssertEqual(
            voices.lines,
            [
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
                "on 67 v100", "off 67",
                "on 60 v100", "off 60",
            ]
        )
        XCTAssertTrue(
            model.arpeggiatorStatus.hasPrefix("Arp stepping"),
            "got \(model.arpeggiatorStatus)"
        )
    }

    /// The first step lands on the instant of the press, and a second tick at that same
    /// instant adds nothing: the grid has not reached the next step yet.
    func testTheFirstStepIsOneStepAndASecondTickAtTheSameInstantAddsNothing() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        tick(model, clock: clock, to: 0)

        XCTAssertEqual(voices.lines, ["on 60 v100"])

        model.tickArpeggiator()

        XCTAssertEqual(voices.lines, ["on 60 v100"])
    }

    // MARK: - Held and released mid-pattern

    /// A release ends the sounding note at the release instant and cancels its
    /// scheduled off, and the pattern stops with nothing left to play.
    func testAReleaseMidPatternEndsTheNoteOnceAndStopsThePattern() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        tick(model, clock: clock, to: 0)
        XCTAssertEqual(voices.lines, ["on 60 v100"])

        clock.now = 0.02
        model.noteOff(note: 60, velocity: 0, channel: 0)
        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])

        tick(model, clock: clock, to: 0.5)
        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60"],
            "the cancelled off must not arrive later and no step may sound"
        )
    }

    /// A second key pressed mid-phrase joins the pattern on the next step, and the grid
    /// does not move because of it.
    func testANoteHeldMidPatternJoinsOnTheNextStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        tick(model, clock: clock, to: 0)

        clock.now = 0.1
        model.noteOn(note: 67, velocity: 100, channel: 0)

        tick(model, clock: clock, to: 0.125)
        tick(model, clock: clock, to: 0.1875)

        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 67 v100", "off 67"]
        )
    }

    // MARK: - Changes mid-run

    /// Changing the pattern restarts its cycle, so the step after the change is the
    /// first note of the new ordering.
    func testAPatternChangeTakesEffectOnTheNextStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60, 64, 67])
        tick(model, clock: clock, to: 0)
        tick(model, clock: clock, to: 0.0625)
        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])

        model.setArpeggiatorPattern(.down)
        tick(model, clock: clock, to: 0.125)

        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 67 v100"],
            "down starts from the highest held note"
        )
    }

    /// A tempo change lands after the step already scheduled: the next step stays on its
    /// instant and the interval after it halves at 240 bpm.
    func testATempoChangeAppliesAfterThePendingStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60, 64, 67])
        tick(model, clock: clock, to: 0)

        clock.now = 0.02
        model.setArpeggiatorBeatsPerMinute(240)

        tick(model, clock: clock, to: 0.125)
        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 64 v100"],
            "the step already scheduled keeps its instant"
        )

        tick(model, clock: clock, to: 0.1875)
        tick(model, clock: clock, to: 0.25)
        XCTAssertEqual(
            voices.lines,
            [
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
                "on 67 v100",
            ],
            "the interval after the pending step is 0.0625 s, not 0.125 s"
        )
    }

    /// A division change to quarters doubles the interval after the pending step.
    func testADivisionChangeAppliesAfterThePendingStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        tick(model, clock: clock, to: 0)
        model.setArpeggiatorDivision(.quarter)

        tick(model, clock: clock, to: 0.4)
        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])

        tick(model, clock: clock, to: 0.5)
        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 60 v100"],
            "a quarter at 120 bpm is one step every 0.5 s"
        )
    }

    // MARK: - Empty and off

    /// Nothing held means no pattern: a whole second of ticks produces no event at all.
    func testAnEmptyHeldSetProducesNoEvents() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        for step in 0...8 {
            tick(model, clock: clock, to: Double(step) * 0.125)
        }

        XCTAssertEqual(voices.lines, [])
        XCTAssertFalse(model.arpeggiatorStatus.hasPrefix("Arp stepping"))
    }

    /// With the arpeggiator off, a controller note passes straight through and carries
    /// the pressed velocity, which is the behaviour the app had before this wiring.
    func testAnOffArpeggiatorStillForwardsThePressedNote() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)

        model.noteOn(note: 64, velocity: 90, channel: 0)
        model.noteOff(note: 64, velocity: 0, channel: 0)

        XCTAssertEqual(voices.lines, ["on 64 v90", "off 64"])
    }

    // MARK: - The licence gate stays ahead of the pattern

    /// A refused launch refuses the key before the pattern holds it, so no step reaches
    /// the voices and the gate reads exactly as it did before the wiring.
    func testARefusedLaunchRefusesTheKeyBeforeThePatternSeesIt() async {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let body = "{\"data\":{\"license\":{\"status\":\"expired\"},\"accessibleProducts\":\(products)}}"
        let client = SessionClient(
            transport: StubTransport(body: body),
            endpoint: SessionEndpoint(
                url: URL(string: "https://example.invalid/api/v1/auth/session")!
            )
        )
        let model = makeModel(clock: clock, voices: voices, sessionClient: client)
        await model.checkSession(at: now)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        for step in 0...4 {
            tick(model, clock: clock, to: Double(step) * 0.125)
        }

        XCTAssertEqual(voices.lines, [], "a refused launch may not sound a step")
        XCTAssertFalse(model.launchAllowsPremiumSounds)
        XCTAssertEqual(
            model.licenceStatus,
            "Session refused: Licence expired: sounds downgraded"
        )
        XCTAssertTrue(
            model.lastEvent.hasPrefix("refused note 60"),
            "got \(model.lastEvent)"
        )
    }

    /// The control: the same pattern with a licensed launch does sound, so the case
    /// above is proving the gate rather than proving the wiring is silent.
    func testALicensedLaunchStepsThroughTheSamePath() async {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let body = "{\"data\":{\"license\":{\"status\":\"active\"},\"accessibleProducts\":\(products)}}"
        let client = SessionClient(
            transport: StubTransport(body: body),
            endpoint: SessionEndpoint(
                url: URL(string: "https://example.invalid/api/v1/auth/session")!
            )
        )
        let model = makeModel(clock: clock, voices: voices, sessionClient: client)
        await model.checkSession(at: now)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        tick(model, clock: clock, to: 0)
        tick(model, clock: clock, to: 0.0625)

        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])
        XCTAssertTrue(model.launchAllowsPremiumSounds)
    }
}
