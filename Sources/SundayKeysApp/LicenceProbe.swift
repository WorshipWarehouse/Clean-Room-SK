import Darwin
import Foundation
import SundayKeysCore

/// Runs the app's own launch path against a stubbed session, for real, in the bundle.
///
/// The unit tests prove the seam and the launch decision; they cannot prove that `AppModel`
/// applies the decision, because the package has no test target that can import an executable
/// target. This probe closes that gap the way the session probe closed a similar one: it builds
/// the same `AppModel` the window builds, hands it a `SessionClient` over a stub transport, runs
/// `checkSession`, and asserts the two values the window would read.
///
/// `SUNDAYKEYS_PROBE_LICENCE` selects the payload, and `tools/licence_smoke.sh` runs all six:
///
/// - `active`     an `active` licence: licensed, premium allowed
/// - `grace`      a `grace_period` ending in one day: licensed, countdown shown
/// - `expired`    an `expired` licence: session refused, premium withheld
/// - `absent`     a session with no licence member: unlicensed, and saying which it was
/// - `unreadable` a licence status this build does not know: unlicensed, quoting the value
/// - `failure`    a transport that throws: no verdict, and premium left alone
///
/// Exit status: 0 the model produced the expected line and premium flag, 5 wrong line,
/// 6 wrong premium flag, 7 the probe could not build its model.
@MainActor
enum LicenceProbe {
    /// 2026-01-10T00:00:00Z, so a countdown is a fixed number of seconds rather than the
    /// wall clock at the moment the runner happened to start.
    private static let now = Date(timeIntervalSince1970: 1_768_003_200)

    static func probeIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_LICENCE"],
              !mode.isEmpty,
              mode != "0"
        else { return }

        report("starting in mode \(mode)")
        Task { @MainActor in await run(mode: mode) }
    }

    private static func report(_ line: String) {
        print("licence probe: \(line)")
        fflush(stdout)
    }

    private static func body(for mode: String) -> String? {
        let products = "[{\"originProductId\":\"p1\",\"productId\":\"p1\",\"productVersion\":\"1\"}]"
        switch mode {
        case "active":
            return "{\"data\":{\"maxAvailableBackups\":2,\"maxAvailableAudioOutputs\":1,\"userRole\":\"customer\",\"license\":{\"status\":\"active\"},\"accessibleProducts\":\(products)}}"
        case "grace":
            return "{\"data\":{\"maxAvailableBackups\":2,\"maxAvailableAudioOutputs\":1,\"license\":{\"status\":\"grace_period\",\"gracePeriodEndsAt\":\"2026-01-11T00:00:00Z\"},\"accessibleProducts\":\(products)}}"
        case "expired":
            return "{\"data\":{\"maxAvailableBackups\":0,\"maxAvailableAudioOutputs\":0,\"license\":{\"status\":\"expired\"},\"accessibleProducts\":\(products)}}"
        case "absent":
            return "{\"data\":{\"maxAvailableBackups\":0,\"maxAvailableAudioOutputs\":0,\"accessibleProducts\":\(products)}}"
        case "unreadable":
            return "{\"data\":{\"license\":{\"status\":\"trialing\"},\"accessibleProducts\":\(products)}}"
        case "failure":
            return nil
        default:
            return nil
        }
    }

    private static func run(mode: String) async {
        let transport: any SessionTransport
        if let body = body(for: mode) {
            transport = StubSessionTransport(result: .success(
                SessionResponse(statusCode: 200, body: Data(body.utf8))
            ))
        } else if mode == "failure" {
            transport = StubSessionTransport(result: .failure(.offline))
        } else {
            report("unknown mode \(mode)")
            exit(64)
        }

        let client = SessionClient(
            transport: transport,
            endpoint: SessionEndpoint(url: URL(string: "https://example.invalid/api/v1/auth/session")!)
        )

        let model = AppModel(sessionClient: client)
        await model.checkSession(at: now)

        report("launch: \(model.licenceStatus)")
        report("premium sounds allowed: \(model.launchAllowsPremiumSounds)")

        guard let expected = expectation(for: mode) else { exit(64) }
        guard model.licenceStatus == expected.line else {
            report("expected line \"\(expected.line)\"")
            exit(5)
        }
        guard model.launchAllowsPremiumSounds == expected.premium else {
            report("expected premium \(expected.premium)")
            exit(6)
        }
        report("applied \(mode) as expected")
        exit(0)
    }

    private static func expectation(for mode: String) -> (line: String, premium: Bool)? {
        switch mode {
        case "active":
            return ("Licence active", true)
        case "grace":
            return ("Licence in grace period: 1 day left", true)
        case "expired":
            return ("Session refused: Licence expired: sounds downgraded", false)
        case "absent":
            return ("Session unlicensed: No licence on this session", false)
        case "unreadable":
            return ("Session unlicensed: Licence could not be read: unknown licence status \"trialing\"", false)
        case "failure":
            return ("\(SessionLaunch.unknownPrefix): the network is offline", true)
        default:
            return nil
        }
    }
}

/// A transport that answers with a fixed result, so the probe exercises the same
/// `SessionClient` a real transport would.
struct StubSessionTransport: SessionTransport {
    enum Failure: Error, LocalizedError {
        case offline

        var errorDescription: String? { "the network is offline" }
    }

    let result: Result<SessionResponse, Failure>

    func send(_ request: SessionRequest) async throws -> SessionResponse {
        switch result {
        case let .success(response):
            return response
        case let .failure(failure):
            throw failure
        }
    }
}
