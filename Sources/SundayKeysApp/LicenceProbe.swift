import Darwin
import Foundation
import SundayKeysCore

/// Runs the app's own launch path against a stubbed session, for real, in the bundle.
///
/// The unit tests prove the seam and the launch decision; they cannot prove that `AppModel`
/// applies the decision, because the package has no test target that can import an executable
/// target. This probe closes that gap the way the session probe closed a similar one: it builds
/// the same `AppModel` the window builds, hands it a `SessionClient` over a stub transport, runs
/// `checkSession`, and asserts what the app now holds and what happens to a note.
///
/// What it asserts per mode:
///
/// - the launch line the window shows (`licenceStatus`)
/// - the playback gate the model applied (`licenceGate.line`)
/// - the outcome of a real note request through the model's MIDI transport, which is the same
///   path a controller and, through the audio controller, a stepped arpeggiator take. A refused
///   launch records `refused note ...: <gate line>`; a permitted one records `note on ...`
///
/// `SUNDAYKEYS_PROBE_LICENCE` selects the payload, and `tools/licence_smoke.sh` runs all six:
///
/// - `active`     an `active` licence: licensed, playback permitted
/// - `grace`      a `grace_period` ending in one day: licensed, playback permitted
/// - `expired`    an `expired` licence: refused, playback withdrawn
/// - `absent`     a session with no licence member: unlicensed, playback withdrawn
/// - `unreadable` a licence status this build does not know: withdrawn, quoting the value
/// - `failure`    a transport that throws: no verdict, playback left alone
///
/// The engine is never started, so nothing here proves a sound was heard; that is recorded in
/// the milestone doc as not verified rather than implied by a green run.
///
/// Exit status: 0 the model produced the expected line, gate and note outcome, 5 wrong launch
/// line, 6 wrong gate or note outcome, 7 the probe could not build its model, 64 bad mode.
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
        Task { await run(mode: mode) }
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

        // The note request is the playback decision made observable: no engine is started, so
        // a permitted note reaches the controller and stops there, and a refused one never
        // leaves the model.
        model.noteOn(note: 60, velocity: 100, channel: 0)

        report("launch: \(model.licenceStatus)")
        report("gate: \(model.licenceGate.line)")
        report("note: \(model.lastEvent)")

        guard let expected = expectation(for: mode) else { exit(64) }
        guard model.licenceStatus == expected.line else {
            report("expected line \"\(expected.line)\"")
            exit(5)
        }
        guard model.licenceGate.line == expected.gate else {
            report("expected gate \"\(expected.gate)\"")
            exit(6)
        }
        guard model.lastEvent.hasPrefix(expected.notePrefix) else {
            report("expected note to start with \"\(expected.notePrefix)\"")
            exit(6)
        }
        report("applied \(mode) as expected")
        exit(0)
    }

    private static func expectation(for mode: String) -> (line: String, gate: String, notePrefix: String)? {
        let permitted = "licensed playback permitted"
        func refused(_ line: String) -> String { "licensed playback refused: \(line)" }
        switch mode {
        case "active":
            return ("Licence active", permitted, "note on")
        case "grace":
            return ("Licence in grace period: 1 day left", permitted, "note on")
        case "expired":
            let line = "Session refused: Licence expired: sounds downgraded"
            return (line, refused(line), "refused note")
        case "absent":
            let line = "Session unlicensed: No licence on this session"
            return (line, refused(line), "refused note")
        case "unreadable":
            let line = "Session unlicensed: Licence could not be read: unknown licence status \"trialing\""
            return (line, refused(line), "refused note")
        case "failure":
            return ("\(SessionLaunch.unknownPrefix): the network is offline", permitted, "note on")
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
