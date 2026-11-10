import Foundation
import Testing
@testable import SundayKeysCore

/// The gate is what the note path asks, so these tests assert the two things a window and an
/// audio controller would see: whether playback is permitted, and the line that says why not.
///
/// Every case goes through the real `SessionClient` over a stub transport, so the gate is
/// derived from the same bytes a launch would receive rather than from a hand-built
/// `SessionLaunch`.
struct LicenceGateTests {
    /// 2026-01-10T00:00:00Z, so a one-day grace window is a fixed number of seconds.
    private static let now = Date(timeIntervalSince1970: 1_768_003_200)

    private static let products = "[{\"originProductId\":\"p1\",\"productId\":\"p1\",\"productVersion\":\"1\"}]"

    private func gate(body: String?, failure: StubTransport.Failure? = nil) async -> LicenceGate {
        let transport = StubTransport(
            response: body.map { SessionResponse(statusCode: 200, body: Data($0.utf8)) },
            failure: failure
        )
        let client = SessionClient(
            transport: transport,
            endpoint: SessionEndpoint(url: URL(string: "https://example.invalid/api/v1/auth/session")!)
        )
        return LicenceGate(SessionLaunch.resolve(await client.fetch(at: Self.now)))
    }

    @Test func activeLicencePermitsPlayback() async {
        let gate = await gate(
            body: "{\"data\":{\"license\":{\"status\":\"active\"},\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(gate == .permitted)
        #expect(gate.permitsPlayback)
        #expect(gate.refusalLine == nil)
        #expect(gate.line == "licensed playback permitted")
    }

    @Test func graceWindowWithTimeLeftPermitsPlayback() async {
        let gate = await gate(
            body: "{\"data\":{\"license\":{\"status\":\"grace_period\",\"gracePeriodEndsAt\":\"2026-01-11T00:00:00Z\"},\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(gate.permitsPlayback)
        #expect(gate.line == "licensed playback permitted")
    }

    @Test func closedGraceWindowRefusesPlayback() async {
        let gate = await gate(
            body: "{\"data\":{\"license\":{\"status\":\"grace_period\",\"gracePeriodEndsAt\":\"2026-01-09T00:00:00Z\"},\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(!gate.permitsPlayback)
        #expect(gate.refusalLine?.contains("Grace period ended") == true)
        #expect(gate.line == "licensed playback refused: Session refused: Grace period ended: sounds downgraded")
    }

    @Test func expiredLicenceRefusesPlayback() async {
        let gate = await gate(
            body: "{\"data\":{\"license\":{\"status\":\"expired\"},\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(!gate.permitsPlayback)
        #expect(gate.refusalLine == "Session refused: Licence expired: sounds downgraded")
        #expect(gate.line == "licensed playback refused: Session refused: Licence expired: sounds downgraded")
    }

    @Test func absentLicenceRefusesPlaybackAndSaysSo() async {
        let gate = await gate(
            body: "{\"data\":{\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(!gate.permitsPlayback)
        #expect(gate.refusalLine == "Session unlicensed: No licence on this session")
        #expect(gate.line == "licensed playback refused: Session unlicensed: No licence on this session")
    }

    @Test func unreadableLicenceRefusesPlaybackAndQuotesTheValue() async {
        let gate = await gate(
            body: "{\"data\":{\"license\":{\"status\":\"trialing\"},\"accessibleProducts\":\(Self.products)}}"
        )
        #expect(!gate.permitsPlayback)
        #expect(gate.refusalLine?.contains("trialing") == true)
        #expect(gate.line.hasPrefix("licensed playback refused: "))
    }

    @Test func refusedTokenPermitsPlaybackBecauseItIsNotAVerdict() async {
        let transport = StubTransport(response: SessionResponse(statusCode: 401, body: Data()), failure: nil)
        let client = SessionClient(
            transport: transport,
            endpoint: SessionEndpoint(url: URL(string: "https://example.invalid/api/v1/auth/session")!)
        )
        let gate = LicenceGate(SessionLaunch.resolve(await client.fetch(at: Self.now)))
        #expect(gate.permitsPlayback)
        #expect(gate.refusalLine == nil)
    }

    @Test func transportFailurePermitsPlaybackBecauseItIsNotAVerdict() async {
        let gate = await gate(body: nil, failure: .offline)
        #expect(gate.permitsPlayback)
        #expect(gate.refusalLine == nil)
    }

    @Test func noVerdictAtAllPermitsPlayback() {
        let gate = LicenceGate(.unknown("no session client was configured"))
        #expect(gate.permitsPlayback)
        #expect(gate.refusalLine == nil)
    }

    /// A transport that answers with one fixed response or one fixed failure, so every case above
    /// exercises the same `SessionClient` a real transport would.
    private struct StubTransport: SessionTransport {
        enum Failure: Error, LocalizedError {
            case offline

            var errorDescription: String? { "the network is offline" }
        }

        let response: SessionResponse?
        let failure: Failure?

        func send(_ request: SessionRequest) async throws -> SessionResponse {
            if let failure { throw failure }
            guard let response else { throw Failure.offline }
            return response
        }
    }
}
