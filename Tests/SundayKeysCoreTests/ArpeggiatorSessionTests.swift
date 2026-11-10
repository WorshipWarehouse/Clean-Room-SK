import XCTest
import SundayKeysCore

/// The arpeggiator session: the six panel choices as a value, and the versioned
/// document that carries them across a launch.
///
/// Every case below is driven through `ArpeggiatorPanel` with a `ManualHostClock` and
/// a recording sink, the way the panel and pattern suites are, so nothing here depends
/// on wall time, a window, a disk outside the temporary folder or a note being heard.
final class ArpeggiatorSessionTests: XCTestCase {
    private final class SilentTarget: KeysoundNoteTarget {
        func noteOn(note: UInt8, velocity: UInt8) {}
        func noteOff(note: UInt8) {}
    }

    private final class RecordingSink: NoteEventSink {
        private(set) var events: [(message: MIDIMessage, time: TimeInterval)] = []

        func send(_ message: MIDIMessage, at time: TimeInterval) {
            events.append((message, time))
        }
    }

    private func makePanel(sink: RecordingSink? = nil) -> ArpeggiatorPanel {
        let clock = ManualHostClock()
        let target = SilentTarget()
        guard let sink else {
            return ArpeggiatorPanel(clock: clock, target: target)
        }
        return ArpeggiatorPanel(
            service: ArpeggiatorService(clock: clock, target: target, sink: sink),
            clock: clock
        )
    }

    private func document(_ json: String) throws -> ArpeggiatorSessionDocument {
        try ArpeggiatorSessionDocument(data: Data(json.utf8))
    }

    /// A panel whose six choices are not the defaults, so a round trip has something
    /// to lose if it is wrong.
    private func editedPanel() -> ArpeggiatorPanel {
        let panel = makePanel()
        panel.setPattern(.down)
        panel.setOctaves(2)
        panel.setBeatsPerMinute(140)
        panel.setDivision(.sixteenth)
        panel.setLatched(true)
        panel.setEnabled(true)
        return panel
    }

    // MARK: - Defaults

    func testASessionThatSetNothingIsThePanelsOwnDefaults() {
        let session = ArpeggiatorSession()

        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.isLatched)
        XCTAssertEqual(session.beatsPerMinute, 120)
        XCTAssertEqual(session.division, .eighth)
        XCTAssertEqual(session.pattern, .up)
        XCTAssertEqual(session.octaves, 1)

        let panel = makePanel()
        XCTAssertEqual(ArpeggiatorSession(panel: panel), session)
        session.apply(to: panel)
        XCTAssertEqual(panel.statusLine, "Arp off, latch off, Up, 1 octave, 120 bpm, eighth")
    }

    // MARK: - Round trip

    func testARoundTripRestoresEveryChoiceExactly() throws {
        let panel = editedPanel()
        let session = ArpeggiatorSession(panel: panel)

        XCTAssertTrue(session.isEnabled)
        XCTAssertTrue(session.isLatched)
        XCTAssertEqual(session.beatsPerMinute, 140)
        XCTAssertEqual(session.division, .sixteenth)
        XCTAssertEqual(session.pattern, .down)
        XCTAssertEqual(session.octaves, 2)

        let encoded = try ArpeggiatorSessionDocument(session: session).encoded()
        let decoded = try ArpeggiatorSessionDocument(data: encoded)
        XCTAssertEqual(decoded.session, session)
        XCTAssertTrue(decoded.unknownFields.isEmpty)

        let restored = makePanel()
        decoded.apply(to: restored)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.isLatched)
        XCTAssertEqual(restored.beatsPerMinute, 140)
        XCTAssertEqual(restored.division, .sixteenth)
        XCTAssertEqual(restored.pattern, .down)
        XCTAssertEqual(restored.octaves, 2)
        XCTAssertEqual(restored.statusLine, "Arp on, latch on, Down, 2 octaves, 140 bpm, sixteenth")
    }

    func testTheSameSessionAlwaysProducesTheSameBytes() throws {
        let document = ArpeggiatorSessionDocument(session: ArpeggiatorSession(panel: editedPanel()))
        XCTAssertEqual(try document.encoded(), try document.encoded())

        let text = try XCTUnwrap(String(data: document.encoded(), encoding: .utf8))
        let division = try XCTUnwrap(text.range(of: "\"division\""))
        let enabled = try XCTUnwrap(text.range(of: "\"enabled\""))
        XCTAssertLessThan(division.lowerBound, enabled.lowerBound)
    }

    // MARK: - Fields this build does not know

    func testAFieldALaterBuildAddedSurvivesTheRoundTrip() throws {
        let json = #"{"version":1,"enabled":true,"latched":false,"beatsPerMinute":96,"division":4,"pattern":"upDown","octaves":3,"futureShape":{"depth":[1,2],"writtenBy":"a later build"},"futureFlag":true,"futureNothing":null}"#
        let document = try self.document(json)

        XCTAssertEqual(document.session.pattern, .upDown)
        XCTAssertEqual(document.session.octaves, 3)
        XCTAssertEqual(document.session.division, .sixteenth)
        XCTAssertEqual(document.unknownFields.count, 3)

        let reencoded = try document.encoded()
        let redecoded = try ArpeggiatorSessionDocument(data: reencoded)

        XCTAssertEqual(redecoded.session, document.session)
        XCTAssertEqual(
            redecoded.unknownFields["futureShape"],
            .object([
                "depth": .array([.number(1), .number(2)]),
                "writtenBy": .string("a later build")
            ])
        )
        XCTAssertEqual(redecoded.unknownFields["futureFlag"], .bool(true))
        XCTAssertEqual(redecoded.unknownFields["futureNothing"], .null)
        XCTAssertNil(redecoded.unknownFields["pattern"])
        XCTAssertNil(redecoded.unknownFields["version"])
    }

    // MARK: - Refusals

    func testALaterVersionIsRefusedRatherThanHalfRead() {
        XCTAssertThrowsError(
            try document(#"{"version":2,"enabled":true,"latched":false,"beatsPerMinute":120,"division":2}"#)
        ) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .unsupportedVersion(2))
        }
    }

    func testAMissingRequiredFieldIsNamed() {
        XCTAssertThrowsError(
            try document(#"{"version":1,"enabled":true,"latched":false,"division":2}"#)
        ) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .missingField("beatsPerMinute"))
        }
    }

    func testAFieldOfTheWrongShapeIsNamed() {
        XCTAssertThrowsError(
            try document(#"{"version":1,"enabled":"yes","latched":false,"beatsPerMinute":120,"division":2}"#)
        ) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .fieldHasWrongType("enabled"))
        }
    }

    func testBytesThatAreNotJSONAreRefused() {
        XCTAssertThrowsError(try document("{not json")) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .notJSON)
        }
    }

    func testValidJSONThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(try document("[1,2,3]")) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .notAnObject)
        }
    }

    func testAnUnknownDivisionOrPatternIsNamed() {
        XCTAssertThrowsError(
            try document(#"{"version":1,"enabled":true,"latched":false,"beatsPerMinute":120,"division":3}"#)
        ) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .unknownDivision(3))
        }

        XCTAssertThrowsError(
            try document(#"{"version":1,"enabled":true,"latched":false,"beatsPerMinute":120,"division":2,"pattern":"sideways"}"#)
        ) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .unknownPattern("sideways"))
        }
    }

    // MARK: - Earlier documents

    func testADocumentFromBeforeThePatternAndSpanExistedOpensOnTheDefaults() throws {
        let json = #"{"version":1,"enabled":true,"latched":false,"beatsPerMinute":132,"division":2}"#
        let document = try self.document(json)

        XCTAssertEqual(document.session.pattern, .up)
        XCTAssertEqual(document.session.octaves, 1)
        XCTAssertEqual(document.session.beatsPerMinute, 132)

        let panel = makePanel()
        document.apply(to: panel)
        XCTAssertTrue(panel.isEnabled)
        XCTAssertEqual(panel.statusLine, "Arp on, latch off, Up, 1 octave, 132 bpm, eighth")

        // Re-encoding writes both fields, and the document still reads back the same.
        let redecoded = try ArpeggiatorSessionDocument(data: try document.encoded())
        XCTAssertEqual(redecoded.session, document.session)
        XCTAssertTrue(redecoded.unknownFields.isEmpty)
    }

    func testAnOutOfRangeSpanIsClampedTheWayThePanelClampsIt() throws {
        let json = #"{"version":1,"enabled":false,"latched":false,"beatsPerMinute":120,"division":2,"octaves":9}"#
        let document = try self.document(json)

        XCTAssertEqual(document.session.octaves, 4)
        let panel = makePanel()
        document.apply(to: panel)
        XCTAssertEqual(panel.octaves, 4)
    }

    // MARK: - The store

    func testTheStoreWritesAndReadsTheSessionBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arpeggiator-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ArpeggiatorSessionStore(url: url)
        XCTAssertNil(try store.load())

        let session = ArpeggiatorSession(
            isEnabled: true,
            isLatched: true,
            beatsPerMinute: 88,
            division: .quarter,
            pattern: .upDown,
            octaves: 4
        )
        try store.save(session)

        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.session, session)

        let restored = makePanel()
        loaded.apply(to: restored)
        XCTAssertEqual(restored.statusLine, "Arp on, latch on, UpDown, 4 octaves, 88 bpm, quarter")
    }

    func testACorruptFileIsReportedRatherThanTreatedAsNothingSaved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arpeggiator-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[]".utf8).write(to: url)

        let store = ArpeggiatorSessionStore(url: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ArpeggiatorSessionFailure, .notAnObject)
        }
    }

    // MARK: - What a restore does not do

    func testRestoringEmitsNoNotesUntilAKeyArrives() throws {
        let sink = RecordingSink()
        let panel = makePanel(sink: sink)
        let json = #"{"version":1,"enabled":true,"latched":true,"beatsPerMinute":120,"division":2,"pattern":"down","octaves":2}"#

        let document = try self.document(json)
        document.apply(to: panel)
        panel.tick()

        XCTAssertTrue(sink.events.isEmpty)
        XCTAssertTrue(panel.isEnabled)
        XCTAssertTrue(panel.isLatched)
        XCTAssertEqual(panel.statusLine, "Arp on, latch on, Down, 2 octaves, 120 bpm, eighth")
    }
}
