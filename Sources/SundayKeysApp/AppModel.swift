import XCTest
import Foundation
@testable import SundayKeysCore

/// 2026-01-10T00:00:00Z, the instant every countdown below is measured from.
private let licenceNow = Date(timeIntervalSince1970: 1_768_003_200)

/// A transport that answers with one fixed result and remembers what it was asked.
///
/// An actor, so the recorded requests are safe to read after the client has awaited the call
/// and nothing here needs `@unchecked Sendable`. This is the whole stub: the seam is one method,
/// which is what makes every failure branch reachable without a server.
private actor StubTransport: SessionTransport {
    enum Answer {
        case response(SessionResponse)
        case failure(StubFailure)
    }

    private let answer: Answer
    private var requests: [SessionRequest] = []

    init(_ answer: Answer) {
        self.answer = answer
    }

    func send(_ request: SessionRequest) async throws -> SessionResponse {
        requests.append(request)
        switch answer {
        case let .response(response):
            return response
        case let .failure(failure):
            throw failure
        }
    }

    var lastRequest: SessionRequest? { requests.last }
}

private enum StubFailure: Error, LocalizedError {
    case offline

    var errorDescription: String? { "the network is offline" }
}

private func sessionBody(_ json: String) -> SessionResponse {
    SessionResponse(statusCode: 200, body: Data(json.utf8))
}

private func clientOver(_ transport: any SessionTransport) -> SessionClient {
    SessionClient(
        transport: transport,
        endpoint: SessionEndpoint(
            url: URL(string: "https://example.invalid/api/v1/auth/session")!,
            bearerToken: "token-1"
        )
    )
}

/// The client seam: what one attempt at the session becomes, and what the launch does with it.
///
/// Every case below goes through the same `SessionClient.fetch` the app calls, so a branch that
/// passes here is a branch the app can take. Nothing here contacts a server; the bytes are the
/// shapes recorded in analysis sections 12 and 13.
final class SessionClientTests: XCTestCase {
    func testRequestCarriesTheRecordedMethodPathAndToken() async {
        let transport = StubTransport(.response(sessionBody("{\"data\":{}}")))

        _ = await clientOver(transport).fetch(at: licenceNow)

        let request = await transport.lastRequest
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://example.invalid/api/v1/auth/session")
        XCTAssertEqual(request?.bearerToken, "token-1")
        XCTAssertEqual(request?.timeout, 5)
    }

    func testActiveSessionDecodesAndLicensesTheLaunch() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"maxAvailableBackups":2,"maxAvailableAudioOutputs":1,"userRole":"customer","license":{"status":"active"},"accessibleProducts":[{"productId":"prod-1"}]}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(payload, standing) = outcome else {
            return XCTFail("an active body did not become a session: \(outcome)")
        }
        XCTAssertEqual(payload.licence, .read(Licence(status: .active)))
        XCTAssertEqual(standing.licence.access, .full)
        XCTAssertEqual(standing.entitlements.maxBackups, 2)

        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .licensed(standing))
        XCTAssertEqual(launch.line, "Licence active")
        XCTAssertTrue(launch.allowsPremiumSounds)
        XCTAssertFalse(launch.refusesLicensedSession)
        XCTAssertEqual(launch.standing, standing.licence)
    }

    func testGracePeriodProceedsWithTheCountdownSurfaced() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"license":{"status":"grace_period","gracePeriodEndsAt":"2026-01-11T00:00:00Z"},"accessibleProducts":[]}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(_, standing) = outcome else {
            return XCTFail("a grace body did not become a session: \(outcome)")
        }
        XCTAssertEqual(standing.licence.warning, .gracePeriod)
        XCTAssertEqual(standing.licence.graceRemaining ?? 0, 86_400, accuracy: 0.001)

        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .grace(standing))
        XCTAssertEqual(launch.line, "Licence in grace period: 1 day left")
        XCTAssertTrue(launch.allowsPremiumSounds)
        XCTAssertFalse(launch.refusesLicensedSession)
    }

    func testExpiredSessionIsRefusedAndWithholdsPremiumSounds() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"license":{"status":"expired"},"accessibleProducts":[{"productId":"prod-1"}]}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(_, standing) = outcome else {
            return XCTFail("an expired body did not become a session: \(outcome)")
        }
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .refused(standing))
        XCTAssertEqual(launch.line, "Session refused: Licence expired: sounds downgraded")
        XCTAssertFalse(launch.allowsPremiumSounds)
        XCTAssertTrue(launch.refusesLicensedSession)
    }

    func testAbsentLicenceTakesTheUnlicensedBranchAndSaysWhich() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"maxAvailableBackups":0,"accessibleProducts":[]}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(payload, standing) = outcome else {
            return XCTFail("a body with no licence did not decode: \(outcome)")
        }
        XCTAssertEqual(payload.licence, .absent)

        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .unlicensed(standing))
        XCTAssertEqual(launch.line, "Session unlicensed: No licence on this session")
        XCTAssertFalse(launch.allowsPremiumSounds)
        XCTAssertTrue(launch.refusesLicensedSession)
        XCTAssertNotEqual(launch.line, "Session refused: Licence expired")
    }

    func testUnreadableLicenceTakesTheUnlicensedBranchAndQuotesTheValue() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"license":{"status":"trialing"},"accessibleProducts":[{"productId":"prod-1"}]}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(payload, standing) = outcome else {
            return XCTFail("an unknown status failed the whole session: \(outcome)")
        }
        XCTAssertEqual(payload.licence, .unreadable("unknown licence status \"trialing\""))

        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .unlicensed(standing))
        XCTAssertEqual(
            launch.line,
            "Session unlicensed: Licence could not be read: unknown licence status \"trialing\""
        )
        XCTAssertFalse(launch.allowsPremiumSounds)
    }

    func testRefusedTokenIsNoVerdictRatherThanAnExpiry() async {
        let transport = StubTransport(.response(SessionResponse(statusCode: 401, body: Data(
            "{\"error\":{\"message\":\"access_token_expired_error\"}}".utf8
        ))))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .unauthorised)
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .unknown("the token was not accepted"))
        XCTAssertTrue(launch.line.hasPrefix(SessionLaunch.unknownPrefix))
        XCTAssertTrue(launch.allowsPremiumSounds)
        XCTAssertFalse(launch.refusesLicensedSession)
        XCTAssertNil(launch.standing)
    }

    func testServerErrorStatusIsItsOwnOutcome() async {
        let transport = StubTransport(.response(SessionResponse(statusCode: 500, body: Data())))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .failed(status: 500))
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .unknown("the request returned HTTP 500"))
        XCTAssertTrue(launch.allowsPremiumSounds)
    }

    func testTransportFailureLandsInTheNoVerdictBranch() async {
        let transport = StubTransport(.failure(.offline))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .unreachable("the network is offline"))
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch, .unknown("the network is offline"))
        XCTAssertEqual(
            launch.line,
            "Session not checked, not a licence verdict: the network is offline"
        )
        XCTAssertFalse(launch.refusesLicensedSession)
    }

    func testUnparseableSuccessBodyIsTypedRatherThanExpired() async {
        let transport = StubTransport(.response(sessionBody("not json at all")))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .malformed(.notJSON("the body is not JSON")))
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertTrue(launch.line.hasPrefix(SessionLaunch.unknownPrefix))
        XCTAssertTrue(launch.allowsPremiumSounds)
        XCTAssertFalse(launch.refusesLicensedSession)
    }

    func testErrorEnvelopeIsMalformedRatherThanASession() async {
        let transport = StubTransport(.response(sessionBody("{\"error\":{\"message\":\"unauthorized\"}}")))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .malformed(.serverError("unauthorized")))
        XCTAssertFalse(SessionLaunch.resolve(outcome).refusesLicensedSession)
    }

    func testBodyWithoutDataEnvelopeIsTyped() async {
        let transport = StubTransport(.response(sessionBody("{\"result\":1}")))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        XCTAssertEqual(outcome, .malformed(.noDataEnvelope))
    }

    func testClientIsTheOnlyPlaceTimeoutIsChosen() async {
        let transport = StubTransport(.response(sessionBody("{\"data\":{}}")))
        let configured = SessionClient(
            transport: transport,
            endpoint: SessionEndpoint(
                url: URL(string: "https://example.invalid/api/v1/auth/session")!,
                bearerToken: nil
            ),
            timeout: 12
        )

        _ = await configured.fetch(at: licenceNow)

        let request = await transport.lastRequest
        XCTAssertEqual(request?.timeout, 12)
        XCTAssertNil(request?.bearerToken)
    }

    /// A `grace_period` whose end has passed is still a session, and the launch reads the
    /// standing's downgrade rather than the label: the end is honoured over the status.
    func testGraceWhoseEndHasPassedIsNotFullAccess() async {
        let transport = StubTransport(.response(sessionBody("""
        {"data":{"license":{"status":"grace_period","gracePeriodEndsAt":"2026-01-09T00:00:00Z"}}}
        """)))

        let outcome = await clientOver(transport).fetch(at: licenceNow)

        guard case let .session(_, standing) = outcome else {
            return XCTFail("a closed grace window did not decode: \(outcome)")
        }
        XCTAssertEqual(standing.licence.access, .downgraded)
        XCTAssertEqual(standing.licence.graceRemaining, 0)
        let launch = SessionLaunch.resolve(outcome)
        XCTAssertEqual(launch.line, "Session refused: Grace period ended: sounds downgraded")
        XCTAssertFalse(launch.allowsPremiumSounds)
    }
}
