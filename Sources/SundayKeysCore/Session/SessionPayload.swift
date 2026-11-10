import Foundation

/// The role the server reports for the signed-in account.
///
/// Recovered as `Networking.UserRoleApi` with the cases `admin` and `customer` (section 13 of
/// `docs/sunday-keys-2.5.2-analysis.md`). A role string this build does not know reads as nil
/// rather than failing the session: the role only adds editing affordances, and refusing a
/// whole session over it would be the worse failure.
public enum UserRole: String, Codable, Equatable, Sendable {
    case admin
    case customer
}

/// One product the account may use, from `Networking.AccessibleProductApi`
/// (`originProductId`, `productId`, `productVersion`, section 13).
public struct AccessibleProduct: Equatable, Sendable {
    public var originProductID: String?
    public var productID: String?
    public var productVersion: String?

    public init(
        originProductID: String? = nil,
        productID: String? = nil,
        productVersion: String? = nil
    ) {
        self.originProductID = originProductID
        self.productID = productID
        self.productVersion = productVersion
    }
}

/// What the session allows: `maxAvailableBackups` and `maxAvailableAudioOutputs` from
/// `Networking.UserSessionApi` (section 13).
///
/// A count the payload did not carry reads as zero, so an unreadable or older session opens no
/// slots instead of every slot. That is the fail-closed direction, and it is the only direction
/// that cannot hand out an entitlement the server did not grant.
public struct SessionEntitlements: Equatable, Sendable {
    public var maxBackups: Int
    public var maxAudioOutputs: Int

    public init(maxBackups: Int, maxAudioOutputs: Int) {
        self.maxBackups = maxBackups
        self.maxAudioOutputs = maxAudioOutputs
    }

    public func backupAllowed(existingBackups: Int) -> Bool {
        existingBackups >= 0 && existingBackups < maxBackups
    }

    public func audioOutputAllowed(index: Int) -> Bool {
        index >= 0 && index < maxAudioOutputs
    }

    public var line: String {
        "\(counted(maxBackups, "backup")), \(counted(maxAudioOutputs, "audio output"))"
    }
}

private func counted(_ count: Int, _ singular: String) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
}

/// The `/api/v1/auth/session` payload: the five fields recovered from
/// `Networking.UserSessionApi` (section 12), in the order its synthesized decoder reads them.
public struct SessionPayload: Equatable, Sendable {
    public var maxAvailableBackups: Int
    public var maxAvailableAudioOutputs: Int
    public var role: UserRole?
    public var licence: LicenceReading
    public var accessibleProducts: [AccessibleProduct]

    public init(
        maxAvailableBackups: Int = 0,
        maxAvailableAudioOutputs: Int = 0,
        role: UserRole? = nil,
        licence: LicenceReading = .absent,
        accessibleProducts: [AccessibleProduct] = []
    ) {
        self.maxAvailableBackups = maxAvailableBackups
        self.maxAvailableAudioOutputs = maxAvailableAudioOutputs
        self.role = role
        self.licence = licence
        self.accessibleProducts = accessibleProducts
    }
}

/// Everything a session body said, reduced to what the window needs to obey.
public struct SessionStanding: Equatable, Sendable {
    public let licence: LicenceStanding
    public let entitlements: SessionEntitlements
    public let accessibleProductCount: Int

    public init(
        licence: LicenceStanding,
        entitlements: SessionEntitlements,
        accessibleProductCount: Int
    ) {
        self.licence = licence
        self.entitlements = entitlements
        self.accessibleProductCount = accessibleProductCount
    }
}

public enum SessionScope {
    /// Applies the licence rule and the entitlement counts to one decoded payload.
    public static func standing(for payload: SessionPayload, at now: Date = Date()) -> SessionStanding {
        SessionStanding(
            licence: LicenceScope.standing(
                for: payload.licence,
                accessibleProductCount: payload.accessibleProducts.count,
                at: now
            ),
            entitlements: SessionEntitlements(
                maxBackups: payload.maxAvailableBackups,
                maxAudioOutputs: payload.maxAvailableAudioOutputs
            ),
            accessibleProductCount: payload.accessibleProducts.count
        )
    }
}

/// Why a session body could not be read.
public enum SessionDecodingError: Error, Equatable, Sendable {
    /// The body was not JSON, or was not a JSON object.
    case notJSON(String)
    /// No `data` member: the success envelope is missing.
    case noDataEnvelope
    /// `data` was present but was not an object.
    case dataIsNotAnObject
    /// The body carried `error` instead of `data`, with the server's own text when there is one.
    case serverError(String)
}

/// Reads the enveloped session document.
///
/// Section 13 records the envelope itself: successes carry `data`, failures carry `error`, as
/// `APIResponse` and `ErrorApi` store exactly one of those. The key casing and the date strategy
/// are Unknown (section 12), so this reader accepts both the camelCase property names the
/// metadata records and their snake_case spellings, and accepts the four date shapes recorded
/// in `LicenceDate`. All of that is an assumption with a name, not a guess hidden in the code:
/// when a capture arrives, this reader is replaced by a configured `JSONDecoder`.
public enum SessionDocument {
    public static func decode(_ data: Data) -> Result<SessionPayload, SessionDecodingError> {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .failure(.notJSON("the body is not JSON"))
        }
        guard let object = root as? [String: Any] else {
            return .failure(.notJSON("the body is not a JSON object"))
        }
        let reader = FieldReader(object: object)
        if let error = reader.value(in: ["error"]) {
            return .failure(.serverError(serverText(error)))
        }
        guard let body = reader.value(in: ["data"]) else {
            return .failure(.noDataEnvelope)
        }
        guard let payload = body as? [String: Any] else {
            return .failure(.dataIsNotAnObject)
        }
        return .success(read(payload))
    }

    static func read(_ payload: [String: Any]) -> SessionPayload {
        let reader = FieldReader(object: payload)
        let products = reader.objects("accessibleProducts", "accessible_products").map { entry in
            let product = FieldReader(object: entry)
            return AccessibleProduct(
                originProductID: product.string("originProductId", "origin_product_id"),
                productID: product.string("productId", "product_id"),
                productVersion: product.string("productVersion", "product_version")
            )
        }
        let role = reader
            .string("userRole", "user_role")
            .flatMap(UserRole.init(rawValue:))
        return SessionPayload(
            maxAvailableBackups: reader.int("maxAvailableBackups", "max_available_backups") ?? 0,
            maxAvailableAudioOutputs: reader.int("maxAvailableAudioOutputs", "max_available_audio_outputs") ?? 0,
            role: role,
            licence: LicenceReading.read(from: reader.value(in: ["license", "licence"])),
            accessibleProducts: products
        )
    }

    static func serverText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            let reader = FieldReader(object: object)
            if let message = reader.string("message", "reason", "code") { return message }
        }
        return "the server reported an error"
    }
}

/// Field lookup that tolerates both spellings of every key.
///
/// A variadic forwarder would have to splat; taking an array keeps the call sites terse without
/// relying on that, and `null` is filtered here so a JSON `null` reads like an absent key.
struct FieldReader {
    let object: [String: Any]

    init(object: [String: Any]) {
        self.object = object
    }

    func value(in keys: [String]) -> Any? {
        for key in keys {
            guard let value = object[key] else { continue }
            if value is NSNull { continue }
            return value
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        guard let raw = value(in: keys) else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    func string(_ keys: String...) -> String? {
        guard let raw = value(in: keys) else { return nil }
        return raw as? String
    }

    func objects(_ keys: String...) -> [[String: Any]] {
        guard let raw = value(in: keys) as? [Any] else { return [] }
        return raw.compactMap { $0 as? [String: Any] }
    }
}
