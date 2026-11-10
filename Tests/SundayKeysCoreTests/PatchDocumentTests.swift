import XCTest
import SundayKeysCore

/// The patch document is the only path by which a sound leaves this app as a file, so
/// what it accepts and what it refuses is behaviour, not formatting: every case here
/// asserts a state change or a typed refusal.
final class PatchDocumentTests: XCTestCase {
    private func patch(named name: String) -> Patch {
        var copy = Patch.starter
        copy.id = UUID()
        copy.name = name
        return copy
    }

    private func temporaryURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-document-tests-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent(name)
    }

    func testRoundTripKeepsTheSoundAndItsLayout() throws {
        var original = patch(named: "Round Trip")
        original.layers[0].gain = 0.42
        original.layers[0].transpose = -3
        original.effects.eq.lowGain = 2.5
        original.effects.reverb.mix = 0.4

        let decoded = try PatchDocument.decode(PatchDocument(patch: original).encoded()).patch

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.layers.count, original.layers.count)
        XCTAssertEqual(decoded.layers[0].gain, 0.42)
        XCTAssertEqual(decoded.layers[0].transpose, -3)
        XCTAssertEqual(decoded.effects.eq.lowGain, 2.5)
        XCTAssertEqual(decoded.effects.reverb.mix, 0.4)
    }

    func testEncodingIsStableForTheSamePatch() throws {
        let one = patch(named: "Stable")
        XCTAssertEqual(try PatchDocument(patch: one).encoded(), try PatchDocument(patch: one).encoded())
    }

    func testForeignFormatIsRefusedByName() {
        let data = Data(#"{"format":"some-other-instrument","version":1,"patch":{}}"#.utf8)
        XCTAssertThrowsError(try PatchDocument.decode(data)) { error in
            XCTAssertEqual(error as? PatchDocumentFailure, .foreignFormat("some-other-instrument"))
        }
    }

    func testAFileWithNoFormatFieldIsRefused() {
        let data = Data(#"{"version":1,"patch":{}}"#.utf8)
        XCTAssertThrowsError(try PatchDocument.decode(data)) { error in
            XCTAssertEqual(error as? PatchDocumentFailure, .foreignFormat("no format field"))
        }
    }

    func testNewerVersionIsRefusedRatherThanPartlyRead() {
        let data = Data(#"{"format":"sundaykeys-cleanroom.patch","version":2,"patch":{}}"#.utf8)
        XCTAssertThrowsError(try PatchDocument.decode(data)) { error in
            XCTAssertEqual(error as? PatchDocumentFailure, .unsupportedVersion(2))
        }
    }

    func testVersionZeroIsRefused() {
        let data = Data(#"{"format":"sundaykeys-cleanroom.patch","version":0,"patch":{}}"#.utf8)
        XCTAssertThrowsError(try PatchDocument.decode(data)) { error in
            XCTAssertEqual(error as? PatchDocumentFailure, .unsupportedVersion(0))
        }
    }

    func testAFileThatIsNotJSONIsRefused() {
        XCTAssertThrowsError(try PatchDocument.decode(Data("not a patch".utf8))) { error in
            XCTAssertEqual(error as? PatchDocumentFailure, .notJSONDocument)
        }
    }

    func testAnEnvelopeWithABrokenPatchIsRefused() {
        let data = Data(#"{"format":"sundaykeys-cleanroom.patch","version":1,"patch":{"id":"not-a-uuid"}}"#.utf8)
        XCTAssertThrowsError(try PatchDocument.decode(data)) { error in
            guard case .malformedPatch = error as? PatchDocumentFailure else {
                return XCTFail("expected a malformed patch failure, got \(error)")
            }
        }
    }

    func testWriteAndReadThroughARealFile() throws {
        var original = patch(named: "On Disk")
        original.effects.reverb.mix = 0.33
        original.layers[0].gain = 0.5
        let url = temporaryURL(PatchTransfer.fileName(for: original.name))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try PatchTransfer.write(original, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let back = try PatchTransfer.read(from: url)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.name, "On Disk")
        XCTAssertEqual(back.layers[0].gain, 0.5)
        XCTAssertEqual(back.effects.reverb.mix, 0.33)
    }

    func testWritingCreatesTheFolderItIsGiven() throws {
        let url = temporaryURL("nested/folder/Pad.\(PatchTransfer.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try PatchTransfer.write(patch(named: "Nested"), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAMissingFileIsATypedRefusal() {
        let url = temporaryURL("absent.\(PatchTransfer.fileExtension)")
        XCTAssertThrowsError(try PatchTransfer.read(from: url)) { error in
            guard case .unreadableFile = error as? PatchDocumentFailure else {
                return XCTFail("expected an unreadable file failure, got \(error)")
            }
        }
    }

    func testFileNamesAreSafeAndAlwaysNameAFile() {
        XCTAssertEqual(PatchTransfer.fileName(for: "Worship Pad"), "Worship-Pad.\(PatchTransfer.fileExtension)")
        XCTAssertEqual(PatchTransfer.fileName(for: "Worship Pad / Lead"), "Worship-Pad-Lead.\(PatchTransfer.fileExtension)")
        XCTAssertEqual(PatchTransfer.fileName(for: "   "), "patch.\(PatchTransfer.fileExtension)")
        XCTAssertLessThanOrEqual(PatchTransfer.fileName(for: String(repeating: "a", count: 200)).count, 80)
    }

    func testAdoptingACopyGivesItANewIdentityAndKeepsTheOriginal() {
        var bank = PatchBank.starter
        let existing = bank.patches[0]
        let before = bank.patches.count

        let adopted = PatchAdoption.adopt(existing, into: &bank)

        XCTAssertEqual(bank.patches.count, before + 1)
        XCTAssertEqual(bank.patches[0].id, existing.id)
        XCTAssertEqual(bank.patches[0].name, existing.name)
        XCTAssertNotEqual(adopted.id, existing.id)
        XCTAssertEqual(adopted.name, existing.name + " 2")
        XCTAssertEqual(bank.patches[before].id, adopted.id)
        XCTAssertEqual(bank.patches[before].name, adopted.name)
    }

    func testAdoptingAFreshPatchKeepsItsOwnName() {
        var bank = PatchBank.starter
        let incoming = patch(named: "Carried Over")

        let adopted = PatchAdoption.adopt(incoming, into: &bank)

        XCTAssertEqual(adopted.id, incoming.id)
        XCTAssertEqual(adopted.name, "Carried Over")
    }

    func testASecondImportOfTheSameDocumentGetsTheNextSuffix() {
        var bank = PatchBank.starter
        let incoming = patch(named: "Twice")

        let first = PatchAdoption.adopt(incoming, into: &bank)
        let second = PatchAdoption.adopt(incoming, into: &bank)

        XCTAssertEqual(first.name, "Twice")
        XCTAssertEqual(second.name, "Twice 2")
        XCTAssertNotEqual(first.id, second.id)
    }
}
