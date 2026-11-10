import XCTest
@testable import SundayKeysCore

/// Milestone M1 of `docs/clean-room-implementation.md`: the licence state machine and the
/// session payload, asserted against the vocabulary and shapes recorded in analysis sections
/// 4, 12 and 13. Every expected value here comes from that record or from a rule named in
/// `docs/re/licence-session-milestone.md`; nothing is asserted about a live server.
final class LicenceStatusTests: XCTestCase {
    func testStatusRawValuesMatchTheRecoveredWireStrings() {
        XCTAssertEqual(LicenceStatus.active.rawValue, "active")
        XCTAssertEqual(LicenceStatus.gracePeriod.rawValue, "grace_period")
        XCTAssertEqual(LicenceStatus.expired.rawValue, "expired")
    }

    func testGracePeriodDecodesFromItsWireSpelling() throws {
        let status = try JSONDecoder().decode(LicenceStatus.self, from: Data("\"grace_period\"".utf8))
        XCTAssertEqual(status, .gracePeriod)
    }

    func testWarningVocabularyMatchesTheRecoveredCases() {
        XCTAssertEqual(
            Set(LicenceWarning.allCases.map(\.rawValue)),
            Set(["gracePeriod", "expired", "expiredSoft"])
        )
    }
}

final class SessionDocumentTests: XCTestCase {
    private func result(_ json: String) -> Result<SessionPayload, SessionDecodingError> {
        SessionDocument.decode(Data(json.utf8))
    }

    func testCamelCasePayloadDecodesEveryField() throws {
        let payload = try result("""
        {"data":{"maxAvailableBackups":3,"maxAvailableAudioOutputs":2,"userRole":"admin","license":{"status":"active"},"accessibleProducts":[{"originProductId":"origin-1","productId":"prod-1","productVersion":"7"}]}}
        """).get()

        XCTAssertEqual(payload.maxAvailableBackups, 3)
        XCTAssertEqual(payload.maxAvailableAudioOutputs, 2)
        XCTAssertEqual(payload.role, .admin)
        XCTAssertEqual(payload.licence, .read(Licence(status: .active)))
        XCTAssertEqual(payload.accessibleProducts.count, 1)
        XCTAssertEqual(payload.accessibleProducts.first?.originProductID, "origin-1")
        XCTAssertEqual(payload.accessibleProducts.first?.productID, "prod-1")
        XCTAssertEqual(payload.accessibleProducts.first?.productVersion, "7")
    }

    func testSnakeCasePayloadDecodesEveryField() throws {
        let payload = try result("""
        {"data":{"max_available_backups":1,"max_available_audio_outputs":0,"user_role":"customer","license":{"status":"expired","grace_period_ends_at":null},"accessible_products":[]}}
        """).get()

        XCTAssertEqual(payload.maxAvailableBackups, 1)
        XCTAssertEqual(payload.maxAvailableAudioOutputs, 0)
        XCTAssertEqual(payload.role, .customer)
        XCTAssertEqual(payload.licence, .read(Licence(status: .expired)))
        XCTAssertTrue(payload.accessibleProducts.isEmpty)
    }

    func testMissingLicenceReadsAsAbsentRatherThanExpired() throws {
        let payload = try result("""
        {"data":{"maxAvailableBackups":0,"maxAvailableAudioOutputs":0}}
        """).get()

        XCTAssertEqual(payload.licence, .absent)
        XCTAssertNil(payload.role)
    }

    func testMalformedLicenceLeavesTheRestOfTheSessionReadable() throws {
        let payload = try result("""
        {"data":{"maxAvailableBackups":4,"maxAvailableAudioOutputs":1,"license":{"status":"trialing"},"accessibleProducts":[{"productId":"prod-9"}]}}
        """).get()

        XCTAssertEqual(payload.licence, .unreadable("unknown licence status \"trialing\""))
        XCTAssertEqual(payload.maxAvailableBackups, 4)
        XCTAssertEqual(payload.accessibleProducts.first?.productID, "prod-9")
    }

    func testLicenceWithoutStatusIsUnreadable() throws {
        let payload = try result("""
        {"data":{"license":{"gracePeriodEndsAt":null}}}
        """).get()

        XCTAssertEqual(payload.licence, .unreadable("the licence carries no status"))
    }

    func testGraceEndDecodesFromEveryRecordedShape() {
        let shapes = [
            "\"2026-01-10T00:00:00Z\"",
            "\"2026-01-10T00:00:00.000Z\"",
            "\"2026-01-10\"",
            "1768003200"
        ]

        for shape in shapes {
            let body = "{\"data\":{\"license\":{\"status\":\"grace_period\",\"gracePeriodEndsAt\":" + shape + "}}}"
            let payload: SessionPayload
            do {
                payload = try SessionDocument.decode(Data(body.utf8)).get()
            } catch {
                XCTFail("failed to decode \(shape): \(error)")
                continue
            }
            let endsAt = payload.licence.licence?.gracePeriodEndsAt
            XCTAssertNotNil(endsAt, "no grace end read from \(shape)")
            XCTAssertEqual(endsAt?.timeIntervalSince1970 ?? 0, 1_768_003_200, accuracy: 1, "shape \(shape)")
        }
    }

    func testServerErrorEnvelopeIsATypedFailure() {
        switch result("{\"error\":{\"message\":\"unauthorized\"}}") {
        case let .failure(error):
            XCTAssertEqual(error, .serverError("unauthorized"))
        case .success:
            XCTFail("an error envelope decoded as a session")
        }
    }

    func testBodyWithoutDataEnvelopeIsATypedFailure() {
        switch result("{\"result\":1}") {
        case let .failure(error):
            XCTAssertEqual(error, .noDataEnvelope)
        case .success:
            XCTFail("a body with no envelope decoded as a session")
        }
    }

    func testNonJSONBodyIsATypedFailure() {
        switch result("not json at all") {
        case .failure(.notJSON):
            break
        case let .failure(error):
            XCTFail("expected notJSON, got \(error)")
        case .success:
            XCTFail("plain text decoded as a session")
        }
    }

    func testNonObjectDataIsATypedFailure() {
        switch result("{\"data\":5}") {
        case let .failure(error):
            XCTAssertEqual(error, .dataIsNotAnObject)
        case .success:
            XCTFail("a number decoded as a session payload")
        }
    }
}

final class LicenceStandingTests: XCTestCase {
    /// 2026-01-10T00:00:00Z, the instant every countdown below is measured from.
    private let now = Date(timeIntervalSince1970: 1_768_003_200)

    func testActiveLicenceIsFullAccessWithNoWarning() {
        let standing = LicenceScope.standing(for: Licence(status: .active), at: now)

        XCTAssertEqual(standing.access, .full)
        XCTAssertNil(standing.warning)
        XCTAssertNil(standing.graceRemaining)
        XCTAssertEqual(standing.line, "Licence active")
        XCTAssertTrue(standing.allowsPremiumSounds)
    }

    func testGracePeriodKeepsFullAccessAndCountsDown() {
        let endsAt = now.addingTimeInterval(129_600) // 36 hours
        let standing = LicenceScope.standing(
            for: Licence(status: .gracePeriod, gracePeriodEndsAt: endsAt),
            at: now
        )

        XCTAssertEqual(standing.access, .full)
        XCTAssertEqual(standing.warning, .gracePeriod)
        XCTAssertEqual(standing.graceRemaining ?? 0, 129_600, accuracy: 0.001)
        XCTAssertEqual(standing.gracePeriodEndsAt, endsAt)
        XCTAssertEqual(standing.line, "Licence in grace period: 1 day left")
    }

    func testGracePeriodEndedDowngradesAndSaysSo() {
        let endsAt = now.addingTimeInterval(-60)
        let standing = LicenceScope.standing(
            for: Licence(status: .gracePeriod, gracePeriodEndsAt: endsAt),
            at: now
        )

        XCTAssertEqual(standing.access, .downgraded)
        XCTAssertEqual(standing.warning, .expiredSoft)
        XCTAssertEqual(standing.graceRemaining, 0)
        XCTAssertEqual(standing.line, "Grace period ended: sounds downgraded")
    }

    func testGracePeriodWithoutAnEndStillReadsAsGrace() {
        let standing = LicenceScope.standing(
            for: Licence(status: .gracePeriod),
            at: now
        )

        XCTAssertEqual(standing.access, .full)
        XCTAssertEqual(standing.warning, .gracePeriod)
        XCTAssertNil(standing.graceRemaining)
        XCTAssertEqual(standing.line, "Licence in grace period")
    }

    func testExpiredWithProductsDowngradesSoftly() {
        let standing = LicenceScope.standing(
            for: Licence(status: .expired),
            accessibleProductCount: 2,
            at: now
        )

        XCTAssertEqual(standing.access, .downgraded)
        XCTAssertEqual(standing.warning, .expiredSoft)
        XCTAssertEqual(standing.line, "Licence expired: sounds downgraded")
    }

    func testExpiredWithoutProductsIsTheHardExpiry() {
        let standing = LicenceScope.standing(
            for: Licence(status: .expired),
            accessibleProductCount: 0,
            at: now
        )

        XCTAssertEqual(standing.access, .downgraded)
        XCTAssertEqual(standing.warning, .expired)
        XCTAssertEqual(standing.line, "Licence expired")
        XCTAssertFalse(standing.allowsPremiumSounds)
    }

    func testAbsentLicenceDowngradesAndNamesIt() {
        let standing = LicenceScope.standing(for: LicenceReading.absent, at: now)

        XCTAssertEqual(standing.access, .downgraded)
        XCTAssertEqual(standing.warning, .expired)
        XCTAssertEqual(standing.line, "No licence on this session")
    }

    func testUnreadableLicenceDowngradesAndQuotesTheReason() {
        let standing = LicenceScope.standing(
            for: LicenceReading.unreadable("unknown licence status \"trialing\""),
            at: now
        )

        XCTAssertEqual(standing.access, .downgraded)
        XCTAssertEqual(standing.warning, .expired)
        XCTAssertEqual(standing.line, "Licence could not be read: unknown licence status \"trialing\"")
    }
}

final class SessionEntitlementTests: XCTestCase {
    func testBackupsAreGatedByTheCountTheServerSent() {
        let entitlements = SessionEntitlements(maxBackups: 2, maxAudioOutputs: 1)

        XCTAssertTrue(entitlements.backupAllowed(existingBackups: 0))
        XCTAssertTrue(entitlements.backupAllowed(existingBackups: 1))
        XCTAssertFalse(entitlements.backupAllowed(existingBackups: 2))
        XCTAssertFalse(entitlements.backupAllowed(existingBackups: -1))
    }

    func testAudioOutputsAreGatedByIndex() {
        let entitlements = SessionEntitlements(maxBackups: 0, maxAudioOutputs: 2)

        XCTAssertTrue(entitlements.audioOutputAllowed(index: 0))
        XCTAssertTrue(entitlements.audioOutputAllowed(index: 1))
        XCTAssertFalse(entitlements.audioOutputAllowed(index: 2))
        XCTAssertFalse(entitlements.audioOutputAllowed(index: -1))
    }

    func testMissingCountsOpenNothing() {
        let entitlements = SessionEntitlements(maxBackups: 0, maxAudioOutputs: 0)

        XCTAssertFalse(entitlements.backupAllowed(existingBackups: 0))
        XCTAssertFalse(entitlements.audioOutputAllowed(index: 0))
        XCTAssertEqual(entitlements.line, "0 backups, 0 audio outputs")
    }

    func testLineCountsSingularAndPlural() {
        XCTAssertEqual(
            SessionEntitlements(maxBackups: 1, maxAudioOutputs: 3).line,
            "1 backup, 3 audio outputs"
        )
    }
}

final class SessionStandingTests: XCTestCase {
    func testStandingCombinesLicenceAndEntitlements() {
        let payload = SessionPayload(
            maxAvailableBackups: 2,
            maxAvailableAudioOutputs: 1,
            role: .customer,
            licence: .read(Licence(status: .expired)),
            accessibleProducts: [AccessibleProduct(productID: "prod-1")]
        )

        let standing = SessionScope.standing(
            for: payload,
            at: Date(timeIntervalSince1970: 1_768_003_200)
        )

        XCTAssertEqual(standing.accessibleProductCount, 1)
        XCTAssertEqual(standing.licence.access, .downgraded)
        XCTAssertEqual(standing.licence.warning, .expiredSoft)
        XCTAssertTrue(standing.entitlements.backupAllowed(existingBackups: 1))
        XCTAssertFalse(standing.entitlements.audioOutputAllowed(index: 1))
    }
}
