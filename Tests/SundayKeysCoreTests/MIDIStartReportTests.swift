import XCTest
import SundayKeysCore

/// The MIDI probe's verdict is decided here rather than on the runner, so these
/// cases are what a regression has to break before the smoke step could pass for
/// the wrong reason.
final class MIDIStartReportTests: XCTestCase {
    private func source(
        endpoint: UInt32,
        uniqueID: Int32,
        name: String? = nil,
        manufacturer: String? = nil,
        online: Bool = true
    ) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: endpoint,
            uniqueID: uniqueID,
            name: name,
            manufacturer: manufacturer,
            online: online
        )
    }

    func testAnUnnamedSourceFallsBackToItsUniqueID() {
        let unnamed = source(endpoint: 1, uniqueID: 42)
        XCTAssertEqual(unnamed.displayName, "unnamed source 42")
        XCTAssertEqual(unnamed.manufacturerName, "unknown manufacturer")
    }

    func testABlankNameIsTreatedAsAMissingOne() {
        XCTAssertEqual(source(endpoint: 1, uniqueID: 7, name: "   ").displayName, "unnamed source 7")
    }

    func testTwoUnnamedSourcesRemainDistinguishable() {
        let first = source(endpoint: 1, uniqueID: 11)
        let second = source(endpoint: 2, uniqueID: 12)
        XCTAssertNotEqual(first.displayName, second.displayName)
    }

    func testTheSummaryCountsOnlineAndOfflineSources() {
        let inventory = MIDIInventory(sources: [
            source(endpoint: 1, uniqueID: 1, name: "Keystation 61", manufacturer: "M-Audio"),
            source(endpoint: 2, uniqueID: 2, name: "Pad", manufacturer: "Acme"),
            source(endpoint: 3, uniqueID: 3, name: "Sleepy", manufacturer: "Acme", online: false),
        ])

        XCTAssertEqual(inventory.count, 3)
        XCTAssertEqual(inventory.onlineCount, 2)
        XCTAssertEqual(inventory.summaryLine, "MIDI: 3 source(s): 2 online, 1 offline")
        XCTAssertEqual(inventory.online.map(\.uniqueID), [1, 2])
        XCTAssertEqual(inventory.offline.map(\.uniqueID), [3])
    }

    func testAnEmptyInventoryReportsZeroSourcesAndStillSucceeds() {
        let report = MIDIStartReport(inventory: MIDIInventory(sources: []), connected: [], failures: [])

        XCTAssertEqual(report.inventory.summaryLine, "MIDI: 0 source(s): 0 online, 0 offline")
        XCTAssertEqual(report.lines, [
            "MIDI: client created",
            "MIDI: 0 source(s): 0 online, 0 offline",
            "MIDI: connected 0 of 0 online source(s)",
        ])
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(MIDIStartVerdict.running(report).exitCode, 0)
    }

    func testTheReportNamesEachSourceInEnumerationOrder() {
        let inventory = MIDIInventory(sources: [
            source(endpoint: 1, uniqueID: 1, name: "Keystation 61", manufacturer: "M-Audio"),
            source(endpoint: 2, uniqueID: 2, name: "Pad", manufacturer: "Acme"),
        ])
        let report = MIDIStartReport(inventory: inventory, connected: [1, 2], failures: [])

        XCTAssertEqual(report.lines, [
            "MIDI: client created",
            "MIDI: 2 source(s): 2 online, 0 offline",
            "MIDI: source 1 of 2: \"Keystation 61\" by M-Audio, online",
            "MIDI: source 2 of 2: \"Pad\" by Acme, online",
            "MIDI: connected 2 of 2 online source(s)",
        ])
    }

    func testAnOfflineSourceIsNotCountedAsConnected() {
        let inventory = MIDIInventory(sources: [
            source(endpoint: 1, uniqueID: 1, name: "Live", manufacturer: "Acme"),
            source(endpoint: 2, uniqueID: 2, name: "Gone", manufacturer: "Acme", online: false),
        ])
        let report = MIDIStartReport(inventory: inventory, connected: [1], failures: [])

        XCTAssertTrue(report.isClean)
        XCTAssertTrue(report.lines.contains("MIDI: connected 1 of 1 online source(s)"))
        XCTAssertEqual(MIDIStartVerdict.running(report).exitCode, 0)
    }

    func testAFailedConnectIsNamedAndExitsSix() {
        let inventory = MIDIInventory(sources: [
            source(endpoint: 1, uniqueID: 1, name: "Keystation 61", manufacturer: "M-Audio"),
        ])
        let failure = MIDIStartFailure.connectionFailed(sourceName: "Keystation 61", status: -10830)
        let report = MIDIStartReport(inventory: inventory, connected: [], failures: [failure])

        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.lines.contains("MIDI: could not connect source \"Keystation 61\" (status -10830)"))
        XCTAssertEqual(MIDIStartVerdict.running(report).exitCode, 6)
        XCTAssertEqual(failure.exitCode, 6)
    }

    func testAMissingClientExitsFourAndSaysWhichCallFailed() {
        let verdict = MIDIStartVerdict.refused(.clientCreationFailed(status: -50))

        XCTAssertEqual(verdict.exitCode, 4)
        XCTAssertNil(verdict.report)
        XCTAssertEqual(verdict.lines, ["MIDI: start refused: MIDIClientCreate failed with status -50"])
    }

    func testAMissingPortExitsFive() {
        let verdict = MIDIStartVerdict.refused(.inputPortCreationFailed(status: -50))

        XCTAssertEqual(verdict.exitCode, 5)
        XCTAssertNil(verdict.report)
        XCTAssertEqual(verdict.lines, ["MIDI: start refused: MIDIInputPortCreate failed with status -50"])
    }
}
