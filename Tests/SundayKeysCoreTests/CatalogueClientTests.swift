import Foundation
import XCTest
import SundayKeysCore

/// The catalogue as a run sees it: the real `CatalogueClient` building a real `SessionRequest`,
/// handing it to a stub transport, and reducing the reply through the real reader.
///
/// Nothing here re-implements the decoding or asserts a model flag: the assertions are about
/// what the reader produced from bytes, and about the request the client actually built.
final class CatalogueClientTests: XCTestCase {
    // MARK: - Stubs

    /// Holds the requests the client sent, so the request shape is asserted rather than assumed.
    private actor Recorder {
        private var requests: [SessionRequest] = []

        func record(_ request: SessionRequest) {
            requests.append(request)
        }

        func first() -> SessionRequest? {
            requests.first
        }
    }

    private struct StubTransport: SessionTransport {
        let status: Int
        let body: String
        let recorder: Recorder?

        init(status: Int = 200, body: String, recorder: Recorder? = nil) {
            self.status = status
            self.body = body
            self.recorder = recorder
        }

        func send(_ request: SessionRequest) async throws -> SessionResponse {
            await recorder?.record(request)
            return SessionResponse(statusCode: status, body: Data(body.utf8))
        }
    }

    private struct FailingTransport: SessionTransport {
        func send(_ request: SessionRequest) async throws -> SessionResponse {
            throw URLError(.notConnectedToInternet)
        }
    }

    // MARK: - Fixtures

    /// One `ProductDataApi`, spelled the way the Swift metadata records the properties
    /// (section 13), with every collection it names populated.
    private let camelProduct = """
    {"id":"p1","originProductId":"o1","title":"Sunday Keys","totalSize":1048576,\
    "image":"https://example.invalid/p1.png","updatedAt":"2026-01-10T00:00:00Z",\
    "productVersion":"2.5.2",\
    "instruments":[{"id":"i1"},{"id":"i2"}],\
    "sounds":[{"id":"s1"},{"id":"s2"},{"id":"s3"}],\
    "presets":[{"id":"r1"}],\
    "padPresets":[{"id":"a1"},{"id":"a2"}],\
    "patches":[{"id":"c1"},{"id":"c2"},{"id":"c3"},{"id":"c4"}],\
    "setlists":[{"id":"l1"}],\
    "soundPaths":["Samples/A.caf","Samples/B.caf"],\
    "patchPaths":["Patches/A.json"],\
    "tagTypes":[{"id":"t1"},{"id":"t2"},{"id":"t3"}]}
    """

    /// The same document in snake_case. Section 12 leaves the key strategy Unknown, so both
    /// spellings must read the same rather than one silently winning.
    private let snakeProduct = """
    {"id":"p1","origin_product_id":"o1","title":"Sunday Keys","total_size":1048576,\
    "image":"https://example.invalid/p1.png","updated_at":"2026-01-10T00:00:00Z",\
    "product_version":"2.5.2",\
    "instruments":[{"id":"i1"},{"id":"i2"}],\
    "sounds":[{"id":"s1"},{"id":"s2"},{"id":"s3"}],\
    "presets":[{"id":"r1"}],\
    "pad_presets":[{"id":"a1"},{"id":"a2"}],\
    "patches":[{"id":"c1"},{"id":"c2"},{"id":"c3"},{"id":"c4"}],\
    "setlists":[{"id":"l1"}],\
    "sound_paths":["Samples/A.caf","Samples/B.caf"],\
    "patch_paths":["Patches/A.json"],\
    "tag_types":[{"id":"t1"},{"id":"t2"},{"id":"t3"}]}
    """

    private let expectedProduct = CatalogueProduct(
        id: "p1",
        originProductID: "o1",
        title: "Sunday Keys",
        totalSize: 1_048_576,
        image: "https://example.invalid/p1.png",
        updatedAt: "2026-01-10T00:00:00Z",
        productVersion: "2.5.2"
    )

    private func documents(_ outcome: CatalogueOutcome) -> [ProductDocument]? {
        guard case let .catalogue(documents) = outcome else {
            XCTFail("expected a catalogue, got \(outcome)")
            return nil
        }
        return documents
    }

    // MARK: - The bulk document

    func testABulkListPopulatesEveryRecordedCollection() async {
        let client = CatalogueClient(transport: StubTransport(body: "{\"data\":[\(camelProduct)]}"))

        guard let parsed = documents(await client.fetchProducts()) else { return }

        XCTAssertEqual(parsed.count, 1)
        let document = parsed[0]
        XCTAssertEqual(document.product, expectedProduct)
        XCTAssertEqual(document.instrumentCount, 2)
        XCTAssertEqual(document.soundCount, 3)
        XCTAssertEqual(document.presetCount, 1)
        XCTAssertEqual(document.padPresetCount, 2)
        XCTAssertEqual(document.patchCount, 4)
        XCTAssertEqual(document.setlistCount, 1)
        XCTAssertEqual(document.tagTypeCount, 3)
        XCTAssertEqual(document.soundPaths, ["Samples/A.caf", "Samples/B.caf"])
        XCTAssertEqual(document.patchPaths, ["Patches/A.json"])
    }

    func testSnakeCaseSpellingsReadTheSameAsCamelCase() async {
        let camel = CatalogueClient(transport: StubTransport(body: "{\"data\":[\(camelProduct)]}"))
        let snake = CatalogueClient(transport: StubTransport(body: "{\"data\":[\(snakeProduct)]}"))

        guard
            let camelDocuments = documents(await camel.fetchProducts()),
            let snakeDocuments = documents(await snake.fetchProducts())
        else { return }

        XCTAssertEqual(snakeDocuments, camelDocuments)
        XCTAssertEqual(snakeDocuments.first?.product, expectedProduct)
    }

    /// The analysis does not settle whether the list route answers with one document or an array
    /// of them, so a single object has to read as a catalogue of one rather than as a failure.
    func testASingleProductObjectReadsAsACatalogueOfOne() async {
        let client = CatalogueClient(transport: StubTransport(body: "{\"data\":\(camelProduct)}"))

        guard let parsed = documents(await client.fetchProducts()) else { return }

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.product, expectedProduct)
    }

    func testATwoProductListKeepsTheServerOrder() async {
        let second = camelProduct.replacingOccurrences(of: "\"p1\"", with: "\"p2\"")
        let body = "{\"data\":[\(camelProduct),\(second)]}"
        let client = CatalogueClient(transport: StubTransport(body: body))

        guard let parsed = documents(await client.fetchProducts()) else { return }

        XCTAssertEqual(parsed.map(\.product.id), ["p1", "p2"])
    }

    // MARK: - The request

    func testTheRequestCarriesTheRecordedRouteAndTheToken() async {
        let recorder = Recorder()
        let client = CatalogueClient(
            transport: StubTransport(body: "{\"data\":\(camelProduct)}", recorder: recorder),
            endpoint: .products(token: "t0ken"),
            timeout: 9
        )

        _ = await client.fetchProducts()

        let request = await recorder.first()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://production.sundaysounds.com/api/v1/products"
        )
        XCTAssertEqual(request?.bearerToken, "t0ken")
        XCTAssertEqual(request?.timeout, 9)
    }

    func testAnEndpointWithoutATokenSendsNoBearer() async {
        let recorder = Recorder()
        let client = CatalogueClient(
            transport: StubTransport(body: "{\"data\":\(camelProduct)}", recorder: recorder),
            endpoint: .products()
        )

        _ = await client.fetchProducts()

        XCTAssertNil(await recorder.first()?.bearerToken)
    }

    // MARK: - Failures

    func testAnErrorEnvelopeIsReportedWithTheServerText() async {
        let client = CatalogueClient(
            transport: StubTransport(body: "{\"error\":{\"message\":\"products unavailable\"}}")
        )

        XCTAssertEqual(
            await client.fetchProducts(),
            .malformed(.serverError("products unavailable"))
        )
    }

    func testARefusedTokenIsUnauthorised() async {
        let client = CatalogueClient(transport: StubTransport(status: 401, body: ""))

        XCTAssertEqual(await client.fetchProducts(), .unauthorised)
    }

    func testAServerFaultIsReportedWithItsStatus() async {
        let client = CatalogueClient(transport: StubTransport(status: 503, body: ""))

        XCTAssertEqual(await client.fetchProducts(), .failed(status: 503))
    }

    func testAnUnreachableTransportIsNotACatalogue() async {
        let client = CatalogueClient(transport: FailingTransport())

        guard case let .unreachable(reason) = await client.fetchProducts() else {
            return XCTFail("expected unreachable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testANonJSONBodyIsReportedAsNotJSON() async {
        let client = CatalogueClient(transport: StubTransport(body: "not json at all"))

        guard case let .malformed(.notJSON(message)) = await client.fetchProducts() else {
            return XCTFail("expected a notJSON failure")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testADataMemberThatIsNeitherObjectNorArrayIsReportedAsUnexpected() async {
        let client = CatalogueClient(transport: StubTransport(body: "{\"data\":7}"))

        guard case let .malformed(.unexpectedData(message)) = await client.fetchProducts() else {
            return XCTFail("expected an unexpectedData failure")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testAMissingDataEnvelopeIsReported() async {
        let client = CatalogueClient(transport: StubTransport(body: "{\"products\":[]}"))

        XCTAssertEqual(await client.fetchProducts(), .malformed(.noDataEnvelope))
    }
}
