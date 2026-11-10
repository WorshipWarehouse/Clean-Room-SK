import Foundation

/// The licence model the shipped client receives, rebuilt from the recorded analysis and not
/// from its code.
///
/// Evidence: `Networking.LicenseApi` stores `status` and `gracePeriodEndsAt`, and the
/// `LicenseStatusApi` hashing witness yields the wire strings `active`, `grace_period` and
/// `expired` (sections 4 and 12 of `docs/sunday-keys-2.5.2-analysis.md`). `Storage.License`
/// mirrors that payload one-to-one, which is why this is a plain value with no store attached.
///
/// Only the wire vocabulary is Observed. Every rule below that turns a status into access is
/// this repository's own reading of the documented product behaviour - the sound library is
/// downgraded after expiry instead of the app locking out (section 4) - and each one is
/// replaceable once a capture exists. They are listed in
/// `docs/re/licence-session-milestone.md`.
public enum LicenceStatus: String, Codable, Equatable, Sendable, CaseIterable {
    /// `active` on the wire.
    case active
    /// `grace_period` on the wire: the one status whose serialised spelling differs from its
    /// Swift case name, which is why the raw value is written out.
    case gracePeriod = "grace_period"
    /// `expired` on the wire.
    case expired
}

/// The warning state kept beside the status.
///
/// `Domain.LicenseWarning` decomposes into `gracePeriod`, `expired` and `expiredSoft`
/// (section 12). What separates the hard expiry from the soft one is not recovered; this
/// implementation reads the soft case as "expired, but the library is still downgraded rather
/// than removed", which is what section 4 documents.
public enum LicenceWarning: String, Equatable, Sendable, CaseIterable {
    case gracePeriod
    case expired
    case expiredSoft
}

/// One licence payload: a status and, when the server sends one, the instant its grace period
/// ends. `gracePeriodEndsAt` is optional here because the payload can omit it, and the grace
/// duration is Unknown (section 10), so this type never invents one.
public struct Licence: Equatable, Sendable {
    public var status: LicenceStatus
    public var gracePeriodEndsAt: Date?

    public init(status: LicenceStatus, gracePeriodEndsAt: Date? = nil) {
        self.status = status
        self.gracePeriodEndsAt = gracePeriodEndsAt
    }
}

/// What a session body said about the licence.
///
/// The session decoder reads the licence with a present-check rather than a required decode
/// (section 12: `license` is decoded through `decodeIfPresent`), so "no licence" and "a
/// licence this build cannot read" are separate outcomes from "a licence" - and both of the
/// former are reported instead of being folded into `expired` silently.
public enum LicenceReading: Equatable, Sendable {
    case read(Licence)
    case absent
    case unreadable(String)

    /// The licence itself, when the payload carried a readable one.
    public var licence: Licence? {
        guard case let .read(licence) = self else { return nil }
        return licence
    }
}

/// What the player is allowed to do, decided from a reading at one instant.
public struct LicenceStanding: Equatable, Sendable {
    public enum Access: String, Equatable, Sendable {
        /// Everything the licence covers.
        case full
        /// The app runs, the sound library is reduced.
        case downgraded
    }

    public let access: Access
    public let warning: LicenceWarning?
    /// The end of a grace period, when one was read.
    public let gracePeriodEndsAt: Date?
    /// Seconds of grace left at the instant this standing was made; nil when there is none.
    public let graceRemaining: TimeInterval?
    /// The line the window shows, so a downgrade is visible rather than implied.
    public let line: String

    public init(
        access: Access,
        warning: LicenceWarning?,
        gracePeriodEndsAt: Date?,
        graceRemaining: TimeInterval?,
        line: String
    ) {
        self.access = access
        self.warning = warning
        self.gracePeriodEndsAt = gracePeriodEndsAt
        self.graceRemaining = graceRemaining
        self.line = line
    }

    public var allowsPremiumSounds: Bool {
        access == .full
    }
}

/// The rule itself, separate from the transport and the window: what a reading means now.
public enum LicenceScope {
    /// - Parameters:
    ///   - reading: what the session body carried.
    ///   - accessibleProductCount: how many products the session still lists, which decides
    ///     whether an expired licence downgrades the library or leaves nothing to downgrade.
    ///   - now: the instant to judge a grace period against, so the rule is testable.
    public static func standing(
        for reading: LicenceReading,
        accessibleProductCount: Int = 0,
        at now: Date = Date()
    ) -> LicenceStanding {
        switch reading {
        case let .read(licence):
            return standing(for: licence, accessibleProductCount: accessibleProductCount, at: now)
        case .absent:
            return LicenceStanding(
                access: .downgraded,
                warning: .expired,
                gracePeriodEndsAt: nil,
                graceRemaining: nil,
                line: "No licence on this session"
            )
        case let .unreadable(reason):
            return LicenceStanding(
                access: .downgraded,
                warning: .expired,
                gracePeriodEndsAt: nil,
                graceRemaining: nil,
                line: "Licence could not be read: \(reason)"
            )
        }
    }

    public static func standing(
        for licence: Licence,
        accessibleProductCount: Int = 0,
        at now: Date = Date()
    ) -> LicenceStanding {
        switch licence.status {
        case .active:
            return LicenceStanding(
                access: .full,
                warning: nil,
                gracePeriodEndsAt: nil,
                graceRemaining: nil,
                line: "Licence active"
            )
        case .gracePeriod:
            guard let endsAt = licence.gracePeriodEndsAt else {
                // The server says grace, and did not say until when. The duration is Unknown,
                // so the countdown is reported as absent rather than invented.
                return LicenceStanding(
                    access: .full,
                    warning: .gracePeriod,
                    gracePeriodEndsAt: nil,
                    graceRemaining: nil,
                    line: "Licence in grace period"
                )
            }
            let remaining = endsAt.timeIntervalSince(now)
            guard remaining > 0 else {
                // The server-authoritative status still says grace, but the window it gave has
                // closed. The end it sent is honoured over the label it sent.
                return LicenceStanding(
                    access: .downgraded,
                    warning: .expiredSoft,
                    gracePeriodEndsAt: endsAt,
                    graceRemaining: 0,
                    line: "Grace period ended: sounds downgraded"
                )
            }
            return LicenceStanding(
                access: .full,
                warning: .gracePeriod,
                gracePeriodEndsAt: endsAt,
                graceRemaining: remaining,
                line: "Licence in grace period: \(describe(remaining)) left"
            )
        case .expired:
            if accessibleProductCount > 0 {
                return LicenceStanding(
                    access: .downgraded,
                    warning: .expiredSoft,
                    gracePeriodEndsAt: nil,
                    graceRemaining: nil,
                    line: "Licence expired: sounds downgraded"
                )
            }
            return LicenceStanding(
                access: .downgraded,
                warning: .expired,
                gracePeriodEndsAt: nil,
                graceRemaining: nil,
                line: "Licence expired"
            )
        }
    }

    /// Whole units only, so a countdown reads the same in a test as it does in a window.
    static func describe(_ remaining: TimeInterval) -> String {
        let days = Int(remaining / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(remaining / 3_600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = Int(remaining / 60)
        if minutes >= 1 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "less than a minute"
    }
}

extension LicenceReading {
    /// Reads the licence out of a decoded session body.
    ///
    /// `present and null` is `absent`; a present object whose status this build does not know
    /// is `unreadable` with the offending value quoted, because a later server vocabulary must
    /// not be read as a licence the player does not have.
    static func read(from raw: Any?) -> LicenceReading {
        guard let raw else { return .absent }
        guard let object = raw as? [String: Any] else {
            return .unreadable("the licence is not an object")
        }
        let reader = FieldReader(object: object)
        guard let statusText = reader.string("status") else {
            return .unreadable("the licence carries no status")
        }
        guard let status = LicenceStatus(rawValue: statusText) else {
            return .unreadable("unknown licence status \"\(statusText)\"")
        }
        let endsAt = LicenceDate.date(
            from: reader.value(in: ["gracePeriodEndsAt", "grace_period_ends_at"])
        )
        return .read(Licence(status: status, gracePeriodEndsAt: endsAt))
    }
}

/// Reads the grace-period end without knowing which date strategy the wire uses.
///
/// Section 12 records that `gracePeriodEndsAt` is decoded as a real `Date`, that the decoder's
/// date strategy is unresolved, and that `ISO8601`, `yyyy-MM-dd'T'HH:mm:ss`, `yyyy-MM-dd` and
/// `secondsSince1970` all appear elsewhere in the slice. Accepting every one of those shapes is
/// the explicit assumption: a capture replaces this reader with the configured decoder.
/// Formatters are built per call rather than held in a static, so nothing here is shared state.
enum LicenceDate {
    static func date(from raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let text = raw as? String {
            return internetDate(text) ?? calendarDate(text)
        }
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return nil
    }

    static func internetDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func calendarDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
