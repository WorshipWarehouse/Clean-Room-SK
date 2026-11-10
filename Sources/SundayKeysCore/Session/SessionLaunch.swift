import Foundation

/// What a launch may do, decided from one `SessionClientOutcome`.
///
/// The five cases are the launch behaviour this repository chooses. They are written here, and
/// in `docs/re/licence-session-milestone.md`, because the analysis records the vocabulary
/// (`active`, `grace_period`, `expired`) and the downgrade-instead-of-lockout product rule
/// (section 4), but not what the client does at launch with each one.
public enum SessionLaunch: Equatable, Sendable {
    /// `active`: the launch proceeds with the licence's full access.
    case licensed(LicenceStanding)
    /// `grace_period` with time left: the launch proceeds with full access and a countdown.
    case grace(LicenceStanding)
    /// `expired`: the licensed session is refused. The app still opens - the documented
    /// behaviour is a downgraded library, not a lock-out - but it opens without premium sounds.
    case refused(LicenceStanding)
    /// The payload carried no licence, or a licence this build cannot read. The session is not
    /// licensed, and the difference between the two stays in the line.
    case unlicensed(LicenceStanding)
    /// No verdict: no client, a refused token, a transport fault, an unexpected status or an
    /// unreadable body. This is deliberately not `refused` - an unreachable server says nothing
    /// about the licence.
    case unknown(String)

    /// The prefix every no-verdict line carries, so a reader cannot mistake one for a verdict.
    public static let unknownPrefix = "Session not checked, not a licence verdict"

    public static func resolve(_ outcome: SessionClientOutcome) -> SessionLaunch {
        switch outcome {
        case let .session(payload, standing):
            // The launch obeys the licence half of the session standing. The entitlement
            // counts are used where a backup or an output is asked for, not at launch.
            let licenceStanding = standing.licence
            // A payload with no readable licence is `unlicensed`: the session answered, and
            // its answer was that this account has no licence this build can see.
            guard let licence = payload.licence.licence else {
                return .unlicensed(licenceStanding)
            }
            switch licence.status {
            case .active:
                return .licensed(licenceStanding)
            case .gracePeriod:
                return .grace(licenceStanding)
            case .expired:
                return .refused(licenceStanding)
            }
        case .unauthorised:
            // Section 12 records `access_token_expired_error`, and the refresh handshake that
            // would follow it is Unknown. A token the server would not accept is therefore a
            // failed check, not a licence the player does not have.
            return .unknown("the token was not accepted")
        case let .failed(status):
            return .unknown("the request returned HTTP \(status)")
        case let .unreachable(reason):
            return .unknown(reason)
        case let .malformed(error):
            return .unknown("the body could not be read - \(error.line)")
        }
    }

    /// The standing behind the verdict, when there was one.
    public var standing: LicenceStanding? {
        switch self {
        case let .licensed(standing), let .grace(standing), let .refused(standing),
             let .unlicensed(standing):
            return standing
        case .unknown:
            return nil
        }
    }

    /// Whether the licensed sound set is available. A no-verdict launch keeps the local bank
    /// working and does not remove a licence the player may hold; only a verdict can.
    public var allowsPremiumSounds: Bool {
        switch self {
        case .licensed, .grace, .unknown:
            return true
        case .refused, .unlicensed:
            return false
        }
    }

    /// Whether the launch refused the licensed session: `expired`, or no licence at all.
    public var refusesLicensedSession: Bool {
        switch self {
        case .refused, .unlicensed:
            return true
        case .licensed, .grace, .unknown:
            return false
        }
    }

    /// The one line a window can show without re-deriving any of the above.
    public var line: String {
        switch self {
        case let .licensed(standing), let .grace(standing):
            return standing.line
        case let .refused(standing):
            return "Session refused: \(standing.line)"
        case let .unlicensed(standing):
            return "Session unlicensed: \(standing.line)"
        case let .unknown(reason):
            return "\(Self.unknownPrefix): \(reason)"
        }
    }
}

extension SessionDecodingError {
    /// One line for a status that has to say why the body was refused.
    var line: String {
        switch self {
        case let .notJSON(reason):
            return "the body is not JSON: \(reason)"
        case .noDataEnvelope:
            return "the body carried no data envelope"
        case .dataIsNotAnObject:
            return "the data envelope was not an object"
        case let .serverError(message):
            return "the server reported an error: \(message)"
        }
    }
}
