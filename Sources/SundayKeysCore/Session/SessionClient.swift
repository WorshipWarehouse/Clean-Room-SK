import Foundation

/// A request to the session endpoint.
///
/// The shape is the one the analysis records: `POST /api/v1/auth/session` on
/// `https://production.sundaysounds.com` with bearer authentication (sections 3 and 12).
/// The request deliberately carries no JSON body: the recorded `UserSessionApi` decoder shows
/// what the server answers, and the request body, headers beyond the bearer token, and any
/// token-refresh handshake are **Unknown**. This type carries only what is documented.
public struct SessionRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var bearerToken: String?
    /// The transport's own deadline. No value for this endpoint is recorded in the
    /// analysis, so it is configuration with a documented default rather than a constant
    /// presented as recovered behaviour.
    public var timeout: TimeInterval

    public init(method: String, url: URL, bearerToken: String?, timeout: TimeInterval) {
        self.method = method
        self.url = url
        self.bearerToken = bearerToken
        self.timeout = timeout
    }
}

/// What a transport hands back: a status and the bytes it received.
public struct SessionResponse: Equatable, Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The seam.
///
/// Everything above it is Foundation-free and testable with a stub; everything below it is
/// the platform's business. `Sendable` because the client is handed to a main-actor model and
/// a transport may hop threads inside its own implementation.
public protocol SessionTransport: Sendable {
    func send(_ request: SessionRequest) async throws -> SessionResponse
}

/// Where the session lives and who is asking.
public struct SessionEndpoint: Equatable, Sendable {
    public var url: URL
    public var bearerToken: String?

    public init(url: URL, bearerToken: String? = nil) {
        self.url = url
        self.bearerToken = bearerToken
    }

    /// The base URL and path the analysis records (sections 1 and 3).
    public static func production(token: String? = nil) -> SessionEndpoint {
        let url = URL(string: "https://production.sundaysounds.com/api/v1/auth/session")
        return SessionEndpoint(url: url ?? URL(fileURLWithPath: "/"), bearerToken: token)
    }
}

/// What one attempt at the session produced.
///
/// Each failure is its own case because the launch decision treats them differently from a
/// licence verdict: a network failure, a refused token, an unexpected status and a body this
/// build cannot read are all "the licence was not checked", never "the licence expired".
public enum SessionClientOutcome: Equatable, Sendable {
    /// A decoded payload and the standing computed from it at the instant of the request.
    case session(SessionPayload, SessionStanding)
    /// 401 or 403. Section 12 records an `access_token_expired_error` path, so a refused token
    /// is a real outcome of this endpoint rather than a transport fault.
    case unauthorised
    /// Any other non-200 status.
    case failed(status: Int)
    /// The transport threw: offline, DNS, connection reset, deadline.
    case unreachable(String)
    /// 200 with a body that is not the documented envelope or payload.
    case malformed(SessionDecodingError)
}

/// Fetches the session document and reduces it to one outcome.
///
/// The client owns no networking of its own: it builds a `SessionRequest`, hands it to the
/// injected transport, and maps the reply through `SessionDocument.decode` and
/// `SessionGate.standing`. That keeps every branch reachable from a test with three lines of
/// stub, and keeps Foundation's URL loading out of the core target entirely.
public struct SessionClient: Sendable {
    public let transport: any SessionTransport
    public let endpoint: SessionEndpoint
    public let timeout: TimeInterval

    public init(
        transport: any SessionTransport,
        endpoint: SessionEndpoint,
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func fetch(at now: Date = Date()) async -> SessionClientOutcome {
        let request = SessionRequest(
            method: "POST",
            url: endpoint.url,
            bearerToken: endpoint.bearerToken,
            timeout: timeout
        )

        let response: SessionResponse
        do {
            response = try await transport.send(request)
        } catch {
            return .unreachable(error.localizedDescription)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            return .unauthorised
        }
        guard response.statusCode == 200 else {
            return .failed(status: response.statusCode)
        }

        switch SessionDocument.decode(response.body) {
        case let .success(payload):
            return .session(payload, SessionGate.standing(for: payload, at: now))
        case let .failure(error):
            return .malformed(error)
        }
    }
}
