import Foundation
import SundayKeysCore

/// The one place Foundation's networking lives.
///
/// The core target defines the seam and never imports URL loading; this target supplies the
/// production side of it. Nothing in the test suite touches this type, and no run has exercised
/// it against the real server either - there are no credentials in this repository and no
/// captured session to replay - so its behaviour over the wire is **not verified**. What is
/// verified is everything it feeds: `SessionClient` and `SessionLaunch` are tested against a
/// stub transport.
struct URLSessionSessionTransport: SessionTransport {
    func send(_ request: SessionRequest) async throws -> SessionResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = request.bearerToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return SessionResponse(statusCode: status, body: data)
    }
}

/// How the app decides whether it has a session to ask about.
///
/// The sign-in flow is not reconstructed: section 10 lists the session request and response
/// schemas as Unknown, and nothing here invents a login screen or a keychain item. The app
/// therefore runs local-first, and takes part in the session seam only when a token is supplied
/// in the environment. That is a deliberate, replaceable choice, written down in
/// `docs/re/licence-session-milestone.md` rather than hidden in a default argument.
enum SessionConfiguration {
    static func endpoint(in environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionEndpoint? {
        guard let token = environment["SUNDAYKEYS_SESSION_TOKEN"], !token.isEmpty else {
            return nil
        }
        guard let base = environment["SUNDAYKEYS_API_BASE"], !base.isEmpty else {
            return .production(token: token)
        }
        guard let url = URL(string: base + "/api/v1/auth/session") else { return nil }
        return SessionEndpoint(url: url, bearerToken: token)
    }

    static func client(in environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionClient? {
        guard let endpoint = endpoint(in: environment) else { return nil }
        return SessionClient(transport: URLSessionSessionTransport(), endpoint: endpoint)
    }
}
