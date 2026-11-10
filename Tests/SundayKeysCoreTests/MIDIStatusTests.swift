import XCTest
import SundayKeysCore

/// The window shows one of these lines, so the wording is part of the behaviour:
/// a refused client, a refused port, a refused source and a machine with no
/// controller must not read the same, and the board must not lose any of them.
final class MIDIStatusTests: XCTestCase {
    private func source(
        _ id: Int32,
        name: String? = "Source",
        online: Bool = true
    ) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: UInt32(id),
            uniqueID: id,
            name: name,
            manufacturer: "Acme",
            online: online
        )
    }

    private func verdict(
        connected: [Int32],
        sources: [MIDIEndpointDescription],
        failures: [MIDIStartFailure] = []
    ) -> MIDIStartVerdict {
        .running(MIDIStartReport(
            inventory: MIDIInventory(sources: sources),
            connected: connected,
            failures: failures
        ))
    }

    func testNoStartIsReportedAsNotStarted() {
        XCTAssertEqual(MIDIStatus.notStarted.text, "MIDI not started")
        XCTAssertFalse(MIDIStatus.notStarted.isFailure)
    }

    func testAClientWithNoSourcesSaysSoRatherThanZeroOfZero() {
        let status = MIDIStatus(verdict: verdict(connected: [], sources: []))

        XCTAssertEqual(status, .ready(connected: 0, available: 0))
        XCTAssertEqual(status.text, "MIDI ready, no sources found")
        XCTAssertFalse(status.isFailure)
    }

    func testEveryOnlineSourceConnectedIsCounted() {
        let status = MIDIStatus(verdict: verdict(
            connected: [1, 2],
            sources: [source(1), source(2)]
        ))

        XCTAssertEqual(status, .ready(connected: 2, available: 2))
        XCTAssertEqual(status.text, "MIDI ready, 2 of 2 source(s) connected")
    }

    func testEnumeratedSourcesThatNoneConnectedToReadAsZero() {
        let status = MIDIStatus(verdict: verdict(
            connected: [],
            sources: [source(1, online: false), source(2, online: false)]
        ))

        XCTAssertEqual(status, .ready(connected: 0, available: 2))
        XCTAssertEqual(status.text, "MIDI ready, 0 of 2 source(s) connected")
    }

    func testARefusedConnectKeepsItsReasonAndItsStatus() {
        let failure = MIDIStartFailure.connectionFailed(sourceName: "Keystation 61", status: -10830)
        let status = MIDIStatus(verdict: verdict(
            connected: [],
            sources: [source(1, name: "Keystation 61")],
            failures: [failure]
        ))

        XCTAssertEqual(status, .degraded(connected: 0, available: 1, failure: failure))
        XCTAssertEqual(
            status.text,
            "MIDI ready, 0 of 1 source(s) connected; could not connect source \"Keystation 61\" (status -10830)"
        )
        // A refused source is not a refused client: the client works, one source
        // did not, and the line says which.
        XCTAssertFalse(status.isFailure)
    }

    func testAMissingClientNamesTheCallAndTheStatus() {
        let status = MIDIStatus(verdict: .refused(.clientCreationFailed(status: -50)))

        XCTAssertEqual(status, .unavailable(.clientCreationFailed(status: -50)))
        XCTAssertEqual(status.text, "MIDI unavailable: MIDIClientCreate failed with status -50")
        XCTAssertTrue(status.isFailure)
    }

    func testAMissingPortNamesItsOwnCallAndStatus() {
        let status = MIDIStatus(verdict: .refused(.inputPortCreationFailed(status: -10833)))

        XCTAssertEqual(status.text, "MIDI unavailable: MIDIInputPortCreate failed with status -10833")
        XCTAssertTrue(status.isFailure)
    }

    func testEveryOutcomeReadsDifferentlyAndNoneIsGeneric() {
        let texts = [
            MIDIStatus.notStarted.text,
            MIDIStatus.ready(connected: 0, available: 0).text,
            MIDIStatus.ready(connected: 2, available: 2).text,
            MIDIStatus.ready(connected: 0, available: 2).text,
            MIDIStatus.unavailable(.clientCreationFailed(status: -50)).text,
            MIDIStatus.unavailable(.inputPortCreationFailed(status: -50)).text,
            MIDIStatus.degraded(
                connected: 0,
                available: 1,
                failure: .connectionFailed(sourceName: "A", status: -50)
            ).text,
        ]

        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertFalse(texts.contains { $0.isEmpty })
        XCTAssertFalse(texts.contains { $0.lowercased().contains("midi failed") })
    }

    func testTheBoardRetainsARefusedStart() {
        var board = MIDIStatusBoard()
        XCTAssertEqual(board.status, .notStarted)

        let recorded = board.record(.refused(.clientCreationFailed(status: -50)))

        XCTAssertEqual(recorded, .unavailable(.clientCreationFailed(status: -50)))
        XCTAssertEqual(board.status, recorded)
        XCTAssertEqual(board.status.text, "MIDI unavailable: MIDIClientCreate failed with status -50")
        XCTAssertTrue(board.status.isFailure)
    }

    func testTheBoardReplacesAStatusWithTheNextVerdictAndClears() {
        var board = MIDIStatusBoard()
        board.record(.refused(.clientCreationFailed(status: -50)))

        board.record(verdict(connected: [1], sources: [source(1)]))
        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))
        XCTAssertFalse(board.status.isFailure)

        board.reset()
        XCTAssertEqual(board.status, .notStarted)
    }

    func testTheStatusIsAppendedToTheExistingLineAndOnlyWhenThereIsOne() {
        let base = "Engine running at 48000 Hz"

        XCTAssertEqual(MIDIStatus.notStarted.message(base: base), base)
        XCTAssertEqual(
            MIDIStatus.ready(connected: 0, available: 0).message(base: base),
            "Engine running at 48000 Hz \u{00b7} MIDI ready, no sources found"
        )
        XCTAssertEqual(
            MIDIStatus.unavailable(.clientCreationFailed(status: -50)).message(base: base),
            "Engine running at 48000 Hz \u{00b7} MIDI unavailable: MIDIClientCreate failed with status -50"
        )
    }

    func testTheFirstRefusedConnectIsTheOneShown() {
        let first = MIDIStartFailure.connectionFailed(sourceName: "A", status: -1)
        let second = MIDIStartFailure.connectionFailed(sourceName: "B", status: -2)
        let status = MIDIStatus(verdict: verdict(
            connected: [],
            sources: [source(1, name: "A"), source(2, name: "B")],
            failures: [first, second]
        ))

        XCTAssertEqual(status, .degraded(connected: 0, available: 2, failure: first))
    }
}
