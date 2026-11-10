import Foundation

/// One product from the bulk pull, from `Networking.ProductApi` (section 13 of
/// `docs/sunday-keys-2.5.2-analysis.md`): `id`, `originProductId`, `title`, `totalSize`,
/// `image`, `updatedAt`, `productVersion`.
///
/// The wire spelling of those names is not settled - section 12 leaves the key strategy
/// Unknown, and `LicenseStatusApi.grace_period` shows the wire is not always the property
/// name - so the reader accepts both the camelCase names the metadata records and their
/// snake_case spellings, exactly as `SessionDocument` does.
public struct CatalogueProduct: Equatable, Sendable {
    public var id: String?
    public var originProductID: String?
    public var title: String?
    public var totalSize: Int?
    public var image: String?
    /// Kept verbatim. The server sends this as a date and which date strategy governs it is
    /// Unknown (section 12), so this build stores the text rather than inventing a parse.
    public var updatedAt: String?
    public var productVersion: String?

    public init(
        id: String? = nil,
        originProductID: String? = nil,
        title: String? = nil,
        totalSize: Int? = nil,
        image: String? = nil,
        updatedAt: String? = nil,
        productVersion: String? = nil
    ) {
        self.id = id
        self.originProductID = originProductID
        self.title = title
        self.totalSize = totalSize
        self.image = image
        self.updatedAt = updatedAt
        self.productVersion = productVersion
    }
}

/// The `ProductDataApi` document: one product plus the library it ships (section 13).
///
/// Section 13 records the collection names (`instruments`, `sounds`, `presets`, `padPresets`,
/// `patches`, `setlists`, `soundPaths`, `patchPaths`, `tagTypes`) but not the shape of the
/// objects inside them, so this reader keeps the two collections that are plainly strings and
/// counts the rest. Counting a recorded collection needs no invented field, and it still
/// proves the bulk document was read whole rather than skimmed for its title.
public struct ProductDocument: Equatable, Sendable {
    public var product: CatalogueProduct
    public var instrumentCount: Int
    public var soundCount: Int
    public var presetCount: Int
    public var padPresetCount: Int
    public var patchCount: Int
    public var setlistCount: Int
    public var soundPaths: [String]
    public var patchPaths: [String]
    public var tagTypeCount: Int

    public init(
        product: CatalogueProduct,
        instrumentCount: Int = 0,
        soundCount: Int = 0,
        presetCount: Int = 0,
        padPresetCount: Int = 0,
        patchCount: Int = 0,
        setlistCount: Int = 0,
        soundPaths: [String] = [],
        patchPaths: [String] = [],
        tagTypeCount: Int = 0
    ) {
        self.product = product
        self.instrumentCount = instrumentCount
        self.soundCount = soundCount
        self.presetCount = presetCount
        self.padPresetCount = padPresetCount
        self.patchCount = patchCount
        self.setlistCount = setlistCount
        self.soundPaths = soundPaths
        self.patchPaths = patchPaths
        self.tagTypeCount = tagTypeCount
    }
}

/// Why a catalogue body could not be read.
///
/// Separate from `SessionDecodingError` because the two documents fail differently: a session
/// body must be one object, while the product pull may be one product or a list of them, and a
/// single shared error type would blur which reader rejected what.
public enum CatalogueDecodingError: Error, Equatable, Sendable {
    /// The body was not JSON, or was not a JSON object.
    case notJSON(String)
    /// No `data` member: the success envelope is missing.
    case noDataEnvelope
    /// `data` was present but was neither an object nor an array of objects.
    case unexpectedData(String)
    /// The body carried `error` instead of `data`, with the server's own text when there is one.
    case serverError(String)
}

/// Reads the enveloped bulk product document.
///
/// Section 13 records both the envelope (`data` on success, `error` on failure) and that the
/// product sync is **one bulk pull** rather than per-object calls. It does not record whether
/// `/api/v1/products` answers with a single `ProductDataApi` or an array of them, so this
/// reader accepts either and says so here rather than picking one silently.
public enum ProductCatalogueDocument {
    public static func decode(_ data: Data) -> Result<[ProductDocument], CatalogueDecodingError> {
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
        if let entries = body as? [[String: Any]] {
            return .success(entries.map(read))
        }
        if let entry = body as? [String: Any] {
            return .success([read(entry)])
        }
        return .failure(.unexpectedData("data is neither an object nor an array of objects"))
    }

    static func read(_ payload: [String: Any]) -> ProductDocument {
        let reader = FieldReader(object: payload)
        let product = CatalogueProduct(
            id: reader.string("id"),
            originProductID: reader.string("originProductId", "origin_product_id"),
            title: reader.string("title"),
            totalSize: reader.int("totalSize", "total_size"),
            image: reader.string("image"),
            updatedAt: reader.string("updatedAt", "updated_at"),
            productVersion: reader.string("productVersion", "product_version")
        )
        return ProductDocument(
            product: product,
            instrumentCount: reader.objects("instruments").count,
            soundCount: reader.objects("sounds").count,
            presetCount: reader.objects("presets").count,
            padPresetCount: reader.objects("padPresets", "pad_presets").count,
            patchCount: reader.objects("patches").count,
            setlistCount: reader.objects("setlists").count,
            soundPaths: reader.strings("soundPaths", "sound_paths"),
            patchPaths: reader.strings("patchPaths", "patch_paths"),
            tagTypeCount: reader.objects("tagTypes", "tag_types").count
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

/// The route the analysis records for products (section 3).
///
/// Section 3 lists `/api/v1/products` and `/api/v1/products/{id}` alongside the session route,
/// and marks only the session request as `POST`. The verb for this route is therefore not
/// recorded, so `CatalogueClient` uses `GET` as this repository's assumption and says so;
/// when a capture arrives, the verb is configuration, not a rewrite.
extension SessionEndpoint {
    public static func products(token: String? = nil) -> SessionEndpoint {
        let url = URL(string: "https://production.sundaysounds.com/api/v1/products")
        return SessionEndpoint(url: url ?? URL(fileURLWithPath: "/"), bearerToken: token)
    }
}

/// What one attempt at the bulk product pull produced.
public enum CatalogueOutcome: Equatable, Sendable {
    /// The documents the server sent, in the order it sent them.
    case catalogue([ProductDocument])
    /// 401 or 403, the same refusal the session endpoint can give (section 12).
    case unauthorised
    /// Any other non-200 status.
    case failed(status: Int)
    /// The transport threw: offline, DNS, connection reset, deadline.
    case unreachable(String)
    /// 200 with a body that is not the documented envelope or document.
    case malformed(CatalogueDecodingError)
}

/// Fetches the bulk product document over the existing transport seam.
///
/// The client owns no networking: it builds a `SessionRequest`, hands it to the injected
/// transport and reduces the reply to one outcome, so every branch is reachable from a stub
/// and the core target still imports no URL loading of its own.
public struct CatalogueClient: Sendable {
    public let transport: any SessionTransport
    public let endpoint: SessionEndpoint
    public let timeout: TimeInterval

    public init(
        transport: any SessionTransport,
        endpoint: SessionEndpoint = .products(),
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func fetchProducts() async -> CatalogueOutcome {
        let request = SessionRequest(
            method: "GET",
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

        switch ProductCatalogueDocument.decode(response.body) {
        case let .success(documents):
            return .catalogue(documents)
        case let .failure(error):
            return .malformed(error)
        }
    }
}

/// The string collections `ProductDataApi` carries, kept apart from `FieldReader`'s object
/// lookup because these two fields are arrays of plain strings rather than arrays of objects.
extension FieldReader {
    func strings(_ keys: String...) -> [String] {
        guard let raw = value(in: keys) as? [Any] else { return [] }
        return raw.compactMap { $0 as? String }
    }
}
