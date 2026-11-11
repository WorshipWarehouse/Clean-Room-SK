import Foundation
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The arpeggiator's path through the app model, with time moved by hand.
///
/// These cases drive the model the window drives - its MIDI transport note methods,
/// which is the same note path a controller reaches - a tick at a time, the way the
/// app's own ticker does. Before this wiring existed a note press went straight to
/// the voices and nothing but that one note ever arrived, so the sequences below
/// fail on the model as it was.
///
/// Nothing here starts an engine, opens a device or contacts a server: the controller
/// is built over a recorder and the clock is a `ManualHostClock`.
@MainActor
final class StepClockWiringTests: XCTestCase {
    /// Ticker step. The app ticks every 5 ms, so a test that does the same asks the
    /// clock the question the running app asks it.
    private let tickStep = 0.005

    /// Records what reached the voices, in order.
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

    private func hold(_ model: AppModel, _ notes: [UInt8]) {
        for note in notes {
            model.noteOn(note: note, velocity: 100, channel: 0)
        }
    }

    /// Ticks from the clock's current instant up to `end` in ticker-sized steps.
    private func drive(_ model: AppModel, clock: ManualHostClock, to end: TimeInterval) {
        var time = clock.now
        while time < end - 1e-9 {
            time += tickStep
            clock.now = time
            model.tickArpeggiator()
        }
    }

    // MARK: - The sequence

    /// Three held notes at 120 bpm in eighths: a step every 0.125 s, gate of half a
    /// step, so eight steps fall in the first second and each sounds then releases.
    /// `up` walks 60, 64, 67 and wraps. A wrong interval changes the count; a wrong
    /// order changes the values.
    func testAChordSteppedThroughTheModelProducesTheExactSequence() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60, 64, 67])
        drive(model, clock: clock, to: 1.0)

        XCTAssertEqual(
            voices.lines,
            [
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
                "on 67 v100", "off 67",
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
                "on 67 v100", "off 67",
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
            ]
        )
        XCTAssertTrue(
            model.arpeggiatorStatus.hasPrefix("Arp stepping"),
            "got \(model.arpeggiatorStatus)"
        )
    }

    /// The first step lands at once, and a second tick at the same instant adds
    /// nothing: the grid has not reached the next step yet.
    func testTheFirstStepIsOneStepAndASecondTickAtTheSameInstantAddsNothing() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        model.tickArpeggiator()
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
        model.tickArpeggiator()
        XCTAssertEqual(voices.lines, ["on 60 v100"])

        clock.now = 0.02
        model.noteOff(note: 60, velocity: 0, channel: 0)
        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])

        drive(model, clock: clock, to: 1.0)
        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60"],
            "the cancelled off must not arrive later and no step may sound"
        )
    }

    /// A second key pressed mid-phrase joins the pattern, and the grid does not move
    /// because of it: the next step is still the one the grid had scheduled.
    func testANoteHeldMidPatternJoinsOnTheNextStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        model.tickArpeggiator()

        clock.now = 0.1
        model.noteOn(note: 67, velocity: 100, channel: 0)

        drive(model, clock: clock, to: 0.25)

        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 67 v100"]
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
        model.tickArpeggiator()
        drive(model, clock: clock, to: 0.125)
        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60"])

        model.setArpeggiatorPattern(.down)
        drive(model, clock: clock, to: 0.25)

        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 67 v100"],
            "down starts from the highest held note"
        )
    }

    /// A tempo change lands after the step already scheduled, so the next step keeps
    /// its instant and the interval after it halves at 240 bpm.
    func testATempoChangeAppliesAfterThePendingStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60, 64, 67])
        model.tickArpeggiator()

        clock.now = 0.02
        model.setArpeggiatorBeatsPerMinute(240)

        drive(model, clock: clock, to: 0.25)
        XCTAssertEqual(
            voices.lines,
            [
                "on 60 v100", "off 60",
                "on 64 v100", "off 64",
                "on 67 v100",
            ],
            "the pending step keeps 0.125 s and the next lands 0.0625 s later"
        )
    }

    /// A division change to quarters takes effect after the step already scheduled:
    /// that step still lands, and the one after it is half a second later.
    func testADivisionChangeAppliesAfterThePendingStep() {
        let clock = ManualHostClock(now: 0)
        let voices = RecordingVoicing()
        let model = makeModel(clock: clock, voices: voices)
        model.setArpeggiatorEnabled(true)

        hold(model, [60])
        model.tickArpeggiator()
        model.setArpeggiatorDivision(.quarter)

        drive(model, clock: clock, to: 0.5)
        XCTAssertEqual(
            voices.lines,
            ["on 60 v100", "off 60", "on 60 v100", "off 60"],
            "the pending step at 0.125 s still lands; the quarter step does not"
        )

        drive(model, clock: clock, to: 0.75)
        XCTAssertEqual(
            voices.lines,
            [
                "on 60 v100", "off 60",
                "on 60 v100", "off 60",
                "on 60 v100",
            ],
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

        drive(model, clock: clock, to: 1.0)

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
        drive(model, clock: clock, to: 1.0)

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
        drive(model, clock: clock, to: 0.2)

        XCTAssertEqual(voices.lines, ["on 60 v100", "off 60", "on 60 v100"])
        XCTAssertTrue(model.launchAllowsPremiumSounds)
    }
}
