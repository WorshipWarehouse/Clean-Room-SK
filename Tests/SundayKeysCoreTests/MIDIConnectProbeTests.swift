import XCTest
import SundayKeysCore

/// The connect probe exists because a runner has no controller: the source list
/// was empty, so the connect path never ran anywhere. These cases drive the same
/// loop the service runs, with the source the probe publishes standing in for a
/// controller, so every outcome the CI step reads is asserted without CoreMIDI.
final class MIDIConnectProbeTests: XCTestCase {
    private func virtualSource(
        endpoint: UInt32 = 12,
        uniqueID: Int32 = 900,
        online: Bool = true
    ) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: endpoint,
            uniqueID: uniqueID,
            name: "SundayKeys Virtual Source",
            manufacturer: "WorshipWarehouse",
            online: online
        )
    }

    private func inventory(_ sources: [MIDIEndpointDescription]) -> MIDIInventory {
        MIDIInventory(sources: sources)
    }

    /// What the service does on a start, without CoreMIDI.
    private func verdict(
        for inventory: MIDIInventory,
        refusing refused: Set<UInt32> = []
    ) -> MIDIStartVerdict {
        var tracker = MIDISourceTracker()
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

    func testAVirtualSourceTheEngineEnumeratesAndConnectsProvesTheConnectPath() {
        let source = virtualSource()
        let probe = MIDIConnectProbe(attempt: .created(source), verdict: verdict(for: inventory([source])))

        XCTAssertEqual(probe.outcome, .connected(uniqueID: 900))
        XCTAssertTrue(probe.provesConnectPath)
        XCTAssertEqual(probe.exitCode, 0)
        XCTAssertEqual(probe.status, .ready(connected: 1, available: 1))
        XCTAssertEqual(probe.status.text, "MIDI ready, 1 of 1 source(s) connected")
        XCTAssertTrue(probe.lines.contains { $0.hasPrefix("MIDI probe: virtual source created") })
        XCTAssertTrue(probe.lines.contains("MIDI probe: engine enumerated 1 source(s)"))
        XCTAssertTrue(probe.lines.contains("MIDI probe: connected 1 of 1 online source(s)"))
        XCTAssertTrue(probe.lines.contains("MIDI probe: status: MIDI ready, 1 of 1 source(s) connected"))
    }

    func testAPortThatRefusesTheVirtualSourceIsReportedAsARefusalNotAConnection() {
        let source = virtualSource()
        let probe = MIDIConnectProbe(
            attempt: .created(source),
            verdict: verdict(for: inventory([source]), refusing: [12])
        )

        XCTAssertEqual(probe.outcome, .connectRefused(failure: .connectionFailed(
            sourceID: 12,
            sourceName: "SundayKeys Virtual Source",
            status: -10830
        )))
        XCTAssertFalse(probe.provesConnectPath)
        XCTAssertEqual(probe.exitCode, 6)
        XCTAssertEqual(
            probe.status.text,
            "MIDI ready, 0 of 1 source(s) connected; could not connect source \"SundayKeys Virtual Source\" (status -10830)"
        )
    }

    func testASystemThatWillNotPublishASourceLeavesThePathUnproven() {
        let probe = MIDIConnectProbe(attempt: .refused(status: -50), verdict: verdict(for: inventory([])))

        XCTAssertEqual(probe.outcome, .noVirtualSource(status: -50))
        XCTAssertEqual(probe.exitCode, 7)
        XCTAssertFalse(probe.provesConnectPath)
        XCTAssertEqual(probe.status.text, "MIDI ready, no sources found")
        XCTAssertFalse(probe.status.isFailure)
        XCTAssertTrue(probe.lines.contains { $0.contains("MIDISourceCreate failed with status -50") })
        XCTAssertTrue(probe.lines.contains("MIDI probe: engine enumerated 0 source(s)"))
    }

    func testASourceTheEngineNeverListsIsAFailureRatherThanANoSourceState() {
        let probe = MIDIConnectProbe(attempt: .created(virtualSource()), verdict: verdict(for: inventory([])))

        XCTAssertEqual(probe.outcome, .virtualSourceNotEnumerated(uniqueID: 900))
        XCTAssertEqual(probe.exitCode, 8)
        XCTAssertFalse(probe.provesConnectPath)
    }

    func testASourceTheEngineListsButNeverAttemptsIsReportedAsIdle() {
        let offline = virtualSource(online: false)
        let probe = MIDIConnectProbe(attempt: .created(offline), verdict: verdict(for: inventory([offline])))

        XCTAssertEqual(probe.outcome, .virtualSourceIdle(uniqueID: 900))
        XCTAssertEqual(probe.exitCode, 9)
        XCTAssertFalse(probe.provesConnectPath)
    }

    func testAClientThatCannotBeCreatedIsStillReportedThroughTheProbe() {
        let probe = MIDIConnectProbe(
            attempt: .refused(status: -1),
            verdict: .refused(.clientCreationFailed(status: -50))
        )

        XCTAssertEqual(probe.outcome, .startRefused(failure: .clientCreationFailed(status: -50)))
        XCTAssertEqual(probe.exitCode, 4)
        XCTAssertTrue(probe.status.isFailure)
        XCTAssertEqual(probe.status.text, "MIDI unavailable: MIDIClientCreate failed with status -50")
    }

    func testEveryProbeOutcomeHasItsOwnExitStatusAndLine() {
        let outcomes: [MIDIConnectProbeOutcome] = [
            .connected(uniqueID: 900),
            .connectRefused(failure: .connectionFailed(sourceID: 12, sourceName: "SundayKeys Virtual Source", status: -10830)),
            .startRefused(failure: .inputPortCreationFailed(status: -10833)),
            .virtualSourceNotEnumerated(uniqueID: 900),
            .virtualSourceIdle(uniqueID: 900),
            .noVirtualSource(status: -50),
        ]

        XCTAssertEqual(Set(outcomes.map(\.description)).count, outcomes.count)
        // 0 connected, 5 no input port, 6 refused connect, 7 no virtual source,
        // 8 never enumerated, 9 listed but never attempted. A missing client is
        // a 4 on its own, asserted by the case above.
        XCTAssertEqual(Set(outcomes.map(\.exitCode)), Set<Int32>([0, 5, 6, 7, 8, 9]))
        XCTAssertEqual(outcomes.filter(\.provesConnectPath), [.connected(uniqueID: 900)])
    }
}
