import XCTest
import SundayKeysCore

/// These are the transitions the window has to follow while the app is running.
/// Each case is something a player can actually do to the computer - plug a
/// controller in, pull it out, plug in a second one - and each one used to leave
/// the status frozen at whatever the first Start found.
final class MIDISourceTrackerTests: XCTestCase {
    private func source(
        _ endpoint: UInt32,
        uniqueID: Int32? = nil,
        name: String? = nil,
        online: Bool = true
    ) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: endpoint,
            uniqueID: uniqueID ?? Int32(endpoint),
            name: name,
            manufacturer: "Acme",
            online: online
        )
    }

    private func inventory(_ sources: [MIDIEndpointDescription]) -> MIDIInventory {
        MIDIInventory(sources: sources)
    }

    /// What the service does on a start or a refresh, without CoreMIDI: ask the
    /// tracker what to connect, answer as the port would, then report.
    private func attempt(
        _ tracker: inout MIDISourceTracker,
        _ inventory: MIDIInventory,
        refusing refused: Set<UInt32> = []
    ) -> MIDIStartVerdict {
        for endpoint in tracker.endpointsToConnect(in: inventory) {
            let name = inventory.sources.first { $0.endpoint == endpoint }?.displayName ?? "unnamed source"
            if refused.contains(endpoint) {
                tracker.recordRefused(endpoint: endpoint, name: name, status: -10830)
            } else {
                tracker.recordConnected(endpoint: endpoint)
            }
        }
        tracker.prune(keeping: inventory)
        return .running(tracker.report(for: inventory))
    }

    func testASourceThatAppearsAfterStartIsConnectedOnTheNextRefresh() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()

        board.record(attempt(&tracker, inventory([])))
        XCTAssertEqual(board.status, .ready(connected: 0, available: 0))
        XCTAssertEqual(board.status.text, "MIDI ready, no sources found")

        board.refresh(with: attempt(&tracker, inventory([source(1, uniqueID: 7, name: "Keystation 61")])).report!)

        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))
        XCTAssertEqual(board.status.text, "MIDI ready, 1 of 1 source(s) connected")
        XCTAssertEqual(tracker.connectedEndpoints, [1])
    }

    func testLosingTheLastSourceReturnsToTheNoSourcesState() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()

        board.record(attempt(&tracker, inventory([source(1, name: "Keystation 61")])))
        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))

        board.record(attempt(&tracker, inventory([])))

        XCTAssertEqual(board.status, .ready(connected: 0, available: 0))
        XCTAssertEqual(board.status.text, "MIDI ready, no sources found")
        XCTAssertTrue(tracker.connectedEndpoints.isEmpty)
    }

    func testAnotherSourceArrivingLeavesTheFirstConnected() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()

        board.record(attempt(&tracker, inventory([source(1, name: "Keys"), source(2, name: "Pad")])))
        board.record(attempt(&tracker, inventory([source(1, name: "Keys")])))
        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))

        board.record(attempt(&tracker, inventory([
            source(1, name: "Keys"),
            source(2, name: "Pad"),
        ])))

        XCTAssertEqual(board.status, .ready(connected: 2, available: 2))
        XCTAssertEqual(board.status.text, "MIDI ready, 2 of 2 source(s) connected")
        XCTAssertEqual(tracker.endpointsToConnect(in: inventory([source(1), source(2)])), [])
    }

    func testARefusalSurvivesARefreshThatStillCannotConnect() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()
        let only = inventory([source(1, name: "Keystation 61")])

        board.record(attempt(&tracker, only, refusing: [1]))
        XCTAssertEqual(
            board.status.text,
            "MIDI ready, 0 of 1 source(s) connected; could not connect source \"Keystation 61\" (status -10830)"
        )

        // A notification fires and nothing has changed: the refusal must still be
        // there rather than quietly cleared by the refresh.
        board.refresh(with: attempt(&tracker, only, refusing: [1]).report!)

        XCTAssertEqual(
            board.status.text,
            "MIDI ready, 0 of 1 source(s) connected; could not connect source \"Keystation 61\" (status -10830)"
        )
        XCTAssertEqual(tracker.refusals.keys.sorted(), [1])
    }

    func testASourceThatConnectsLaterIsNoLongerReportedAsRefused() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()
        let only = inventory([source(1, name: "Keystation 61")])

        board.record(attempt(&tracker, only, refusing: [1]))
        XCTAssertEqual(board.status, .degraded(
            connected: 0,
            available: 1,
            failure: .connectionFailed(sourceID: 1, sourceName: "Keystation 61", status: -10830)
        ))

        board.refresh(with: attempt(&tracker, only).report!)

        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))
        XCTAssertEqual(board.status.text, "MIDI ready, 1 of 1 source(s) connected")
        XCTAssertTrue(tracker.refusals.isEmpty)
    }

    func testARefusalForASourceThatDisappearsIsForgotten() {
        var tracker = MIDISourceTracker()
        var board = MIDIStatusBoard()

        board.record(attempt(&tracker, inventory([source(1, name: "Keystation 61")]), refusing: [1]))
        board.record(attempt(&tracker, inventory([])))

        XCTAssertTrue(tracker.refusals.isEmpty)
        XCTAssertEqual(board.status, .ready(connected: 0, available: 0))
    }

    func testAnOfflineSourceIsNeverAttempted() {
        var tracker = MIDISourceTracker()
        let sleeping = inventory([source(1, name: "Sleepy", online: false)])

        XCTAssertEqual(tracker.endpointsToConnect(in: sleeping), [])

        let verdict = attempt(&tracker, sleeping)

        XCTAssertEqual(verdict.exitCode, 0)
        XCTAssertEqual(tracker.connectedEndpoints, [])
        XCTAssertEqual(MIDIStatus(verdict: verdict), .ready(connected: 0, available: 1))
    }

    func testAConnectedSourceIsNotConnectedTwice() {
        var tracker = MIDISourceTracker()
        let one = inventory([source(1, name: "Keys")])

        _ = attempt(&tracker, one)
        _ = attempt(&tracker, one)

        XCTAssertEqual(tracker.connectedEndpoints, [1])
        XCTAssertEqual(tracker.report(for: one).connected, [1])
    }

    func testTheBoardUpdatesFromARefreshWithoutASecondStart() {
        var board = MIDIStatusBoard()
        board.record(.running(MIDIStartReport(inventory: MIDIInventory(sources: []), connected: [], failures: [])))
        XCTAssertEqual(board.status.text, "MIDI ready, no sources found")

        let report = MIDIStartReport(
            inventory: MIDIInventory(sources: [source(1, name: "Keys")]),
            connected: [1],
            failures: []
        )
        let refreshed = board.refresh(with: report)

        XCTAssertEqual(refreshed, .ready(connected: 1, available: 1))
        XCTAssertEqual(board.status, .ready(connected: 1, available: 1))
        XCTAssertEqual(board.status.text, "MIDI ready, 1 of 1 source(s) connected")
    }

    func testTheReportKeepsFailuresInEnumerationOrder() {
        var tracker = MIDISourceTracker()
        let both = inventory([source(1, name: "A"), source(2, name: "B")])

        _ = attempt(&tracker, both, refusing: [2, 1])
        let report = tracker.report(for: both)

        XCTAssertEqual(report.failures.compactMap(\.sourceID), [1, 2])
    }
}
