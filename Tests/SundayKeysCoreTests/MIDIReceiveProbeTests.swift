import XCTest
import SundayKeysCore

/// The receive probe exists because the connect probe stops at a held endpoint:
/// the port accepted a source, but nothing was ever sent through it, so
/// `MIDIMessage.parse` had never run on a packet outside these tests. These cases
/// cover every way the receive path can fall short, so the CI step's exit status
/// has a meaning that was asserted on a machine with no MIDI at all.
final class MIDIReceiveProbeTests: XCTestCase {
    private func source(endpoint: UInt32 = 12, uniqueID: Int32 = 900) -> MIDIEndpointDescription {
        MIDIEndpointDescription(
            endpoint: endpoint,
            uniqueID: uniqueID,
            name: "SundayKeys Virtual Source",
            manufacturer: "WorshipWarehouse",
            online: true
        )
    }

    /// A connect probe whose port holds its own source, built by the same tracker
    /// loop the service runs.
    private func connected() -> MIDIConnectProbe {
        let source = source()
        var tracker = MIDISourceTracker()
        let inventory = MIDIInventory(sources: [source])
        for endpoint in tracker.endpointsToConnect(in: inventory) {
            tracker.recordConnected(endpoint: endpoint)
        }
        return MIDIConnectProbe(attempt: .created(source), verdict: .running(tracker.report(for: inventory)))
    }

    /// A connect probe that never saw its own source listed.
    private func notConnected() -> MIDIConnectProbe {
        MIDIConnectProbe(
            attempt: .created(source()),
            verdict: .running(MIDISourceTracker().report(for: MIDIInventory(sources: [])))
        )
    }

    private func probe(
        received: [MIDIMessage],
        connect: MIDIConnectProbe? = nil,
        routedLayers: Int? = nil,
        enabledLayers: Int? = nil
    ) -> MIDIReceiveProbe {
        MIDIReceiveProbe(
            expectation: MIDIReceiveExpectation(),
            connect: connect ?? connected(),
            received: received,
            routedLayers: routedLayers,
            enabledLayers: enabledLayers
        )
    }

    private var everyPacket: [MIDIMessage] {
        [
            .noteOn(note: 60, velocity: 100, channel: 0),
            .noteOff(note: 60, velocity: 64, channel: 0),
            .controlChange(controller: 1, value: 64, channel: 0),
        ]
    }

    func testEveryPacketParsingProvesTheReceivePath() {
        let probe = probe(received: everyPacket, routedLayers: 1, enabledLayers: 2)

        XCTAssertEqual(probe.outcome, .received(noteOns: 1, noteOffs: 1, controlChanges: 1))
        XCTAssertTrue(probe.provesReceivePath)
        XCTAssertEqual(probe.exitCode, 0)
        XCTAssertEqual(
            probe.lines,
            [
                "MIDI receive probe: sent note on 60 velocity 100 on channel 1",
                "MIDI receive probe: sent note off 60 on channel 1",
                "MIDI receive probe: sent control change 1 = 64 on channel 1",
                "MIDI receive probe: the app received 3 message(s): 1 note on, 1 note off, 1 control change",
                "MIDI receive probe: layer routing sent note 60 to 1 of 2 enabled layer(s)",
                "MIDI receive probe: outcome: the app parsed every packet: 1 note on, 1 note off, 1 control change",
            ]
        )
    }

    func testTheBytesSentParseBackToTheMessagesTheyAreCountedAs() {
        let expectation = MIDIReceiveExpectation()
        let parsed = expectation.packets.map(MIDIMessage.parse)

        XCTAssertEqual(
            parsed,
            [
                .noteOn(note: 60, velocity: 100, channel: 0),
                .noteOff(note: 60, velocity: 64, channel: 0),
                .controlChange(controller: 1, value: 64, channel: 0),
            ]
        )
        // The expectation the probe asserts is therefore the one its own packets
        // decode to, not a second description of them.
        XCTAssertEqual(parsed, everyPacket)
    }

    func testAMissingNoteOffIsReportedRatherThanCountedAsSuccess() {
        let probe = probe(received: [
            .noteOn(note: 60, velocity: 100, channel: 0),
            .controlChange(controller: 1, value: 64, channel: 0),
        ])

        XCTAssertEqual(probe.outcome, .noteOffMissing(noteOns: 1, controlChanges: 1))
        XCTAssertEqual(probe.exitCode, 10)
        XCTAssertFalse(probe.provesReceivePath)
    }

    func testAMissingControlChangeIsReported() {
        let probe = probe(received: [
            .noteOn(note: 60, velocity: 100, channel: 0),
            .noteOff(note: 60, velocity: 64, channel: 0),
        ])

        XCTAssertEqual(probe.outcome, .controlChangeMissing(noteOns: 1, noteOffs: 1))
        XCTAssertEqual(probe.exitCode, 11)
        XCTAssertFalse(probe.provesReceivePath)
    }

    func testAMissingNoteOnIsReported() {
        let probe = probe(received: [
            .noteOff(note: 60, velocity: 64, channel: 0),
            .controlChange(controller: 1, value: 64, channel: 0),
        ])

        XCTAssertEqual(probe.outcome, .noteOnMissing(noteOffs: 1, controlChanges: 1))
        XCTAssertEqual(probe.exitCode, 13)
        XCTAssertFalse(probe.provesReceivePath)
    }

    func testAPortThatIsConnectedButReceivesNothingIsItsOwnFailure() {
        let probe = probe(received: [])

        XCTAssertEqual(probe.outcome, .nothingReceived)
        XCTAssertEqual(probe.exitCode, 12)
        XCTAssertFalse(probe.provesReceivePath)
        XCTAssertTrue(probe.lines.contains(
            "MIDI receive probe: the app received 0 message(s): 0 note on, 0 note off, 0 control change"
        ))
    }

    func testASourceThatNeverConnectedMeansNothingWasSent() {
        let probe = probe(received: [], connect: notConnected())

        XCTAssertEqual(probe.outcome, .notAttempted(connect: .virtualSourceNotEnumerated(uniqueID: 900)))
        // The connect status is what the step reports, so the first thing that
        // failed is the thing the exit status names.
        XCTAssertEqual(probe.exitCode, 8)
        XCTAssertFalse(probe.provesReceivePath)
        XCTAssertTrue(probe.lines.contains("MIDI receive probe: nothing was sent, because the connect path did not prove itself"))
        XCTAssertFalse(probe.lines.contains { $0.hasPrefix("MIDI receive probe: sent ") })
    }

    func testMessagesOnAnotherNoteOrChannelDoNotStandInForTheOnesSent() {
        let probe = probe(received: [
            .noteOn(note: 61, velocity: 100, channel: 0),
            .noteOn(note: 60, velocity: 100, channel: 1),
            .controlChange(controller: 7, value: 64, channel: 0),
        ])

        XCTAssertEqual(probe.outcome, .nothingReceived)
        XCTAssertEqual(probe.exitCode, 12)
    }

    func testANoteOnWithZeroVelocityCountsAsTheNoteOffTheParserMadeIt() {
        // 0x90 with velocity 0 is the conventional note off, and `parse` maps it
        // here, so the probe counts it as the off it became.
        XCTAssertEqual(MIDIMessage.parse([0x90, 60, 0]), .noteOff(note: 60, velocity: 0, channel: 0))

        let probe = probe(received: [
            .noteOn(note: 60, velocity: 100, channel: 0),
            .noteOff(note: 60, velocity: 0, channel: 0),
            .controlChange(controller: 1, value: 64, channel: 0),
        ])

        XCTAssertEqual(probe.outcome, .received(noteOns: 1, noteOffs: 1, controlChanges: 1))
        XCTAssertTrue(probe.provesReceivePath)
    }

    func testEveryOutcomeHasItsOwnExitStatusAndLine() {
        let outcomes: [MIDIReceiveOutcome] = [
            .received(noteOns: 1, noteOffs: 1, controlChanges: 1),
            .noteOffMissing(noteOns: 1, controlChanges: 1),
            .controlChangeMissing(noteOns: 1, noteOffs: 1),
            .nothingReceived,
            .noteOnMissing(noteOffs: 1, controlChanges: 1),
            .notAttempted(connect: .virtualSourceIdle(uniqueID: 900)),
        ]

        XCTAssertEqual(Set(outcomes.map(\.description)).count, outcomes.count)
        // 0 every packet, 10 no note off, 11 no control change, 12 nothing,
        // 13 no note on, 9 a source the port never attempted.
        XCTAssertEqual(Set(outcomes.map(\.exitCode)), Set<Int32>([0, 9, 10, 11, 12, 13]))
        XCTAssertEqual(outcomes.filter(\.provesReceivePath), [.received(noteOns: 1, noteOffs: 1, controlChanges: 1)])
    }
}
