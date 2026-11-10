import XCTest
@testable import SundayKeysCore

/// Session memory is a hint about the last launch, so every case here is about what a
/// launch does when the hint is absent, right, or points at something that is gone.
final class SessionMemoryTests: XCTestCase {
    private func patch(_ name: String) -> Patch {
        Patch(name: name, layers: KeyLayer.defaultPatch)
    }

    private func temporaryStore() -> SessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SessionStore(url: directory.appendingPathComponent("session.json"))
    }

    func testABankWithNoMemoryOpensOnItsFirstPatch() {
        let a = patch("A")
        let b = patch("B")

        let restore = SessionScope.restore(memory: nil, patches: [a, b])

        XCTAssertEqual(restore, .fallback(a.id, name: "A", because: .nothingRemembered))
        XCTAssertEqual(restore.patchID, a.id)
        XCTAssertFalse(restore.isRemembered, "a first launch is not a resume")
    }

    func testTheRememberedPatchIsTheOneThatOpens() {
        let a = patch("A")
        let b = patch("B")
        let memory = SessionMemory(lastPatchID: b.id)

        let restore = SessionScope.restore(memory: memory, patches: [a, b])

        XCTAssertEqual(restore, .remembered(b.id, name: "B"))
        XCTAssertEqual(restore.patchID, b.id)
        XCTAssertTrue(restore.isRemembered)
    }

    func testAMissingRememberedPatchFallsBackAndSaysSo() {
        let a = patch("A")
        let b = patch("B")
        let deleted = patch("Deleted")
        let memory = SessionMemory(lastPatchID: deleted.id)

        let restore = SessionScope.restore(memory: memory, patches: [a, b])

        XCTAssertEqual(restore, .fallback(a.id, name: "A", because: .patchMissing))
        XCTAssertFalse(restore.isRemembered, "a resume that could not happen must not read like one")
    }

    func testAnEmptyBankHasNothingToOpen() {
        let restore = SessionScope.restore(memory: SessionMemory(lastPatchID: UUID()), patches: [])

        XCTAssertEqual(restore, .emptyBank)
        XCTAssertNil(restore.patchID)
        XCTAssertFalse(restore.isRemembered)
    }

    func testTheLinesNameWhichCaseHappened() {
        let a = patch("Worship Pad")

        XCTAssertEqual(
            SessionScope.restore(memory: SessionMemory(lastPatchID: a.id), patches: [a]).line,
            "Resumed Worship Pad"
        )
        XCTAssertEqual(
            SessionScope.restore(memory: nil, patches: [a]).line,
            "Opened Worship Pad: nothing was remembered from the last launch"
        )
        XCTAssertEqual(
            SessionScope.restore(memory: SessionMemory(lastPatchID: UUID()), patches: [a]).line,
            "Opened Worship Pad: the patch from the last launch is gone"
        )
        XCTAssertEqual(SessionScope.restore(memory: nil, patches: []).line, "The bank has no patches")
    }

    func testTheMemoryRoundTripsThroughItsOwnFile() throws {
        let a = patch("A")
        let store = temporaryStore()

        XCTAssertNil(store.load(), "a store with no file has remembered nothing")

        try store.save(SessionMemory(lastPatchID: a.id))
        let relaunched = SessionStore(url: store.url)
        let memory = relaunched.load()

        XCTAssertEqual(memory, SessionMemory(lastPatchID: a.id))
    }

    /// A corrupt hint has to read exactly like a first launch, which means resolving it
    /// against the same patch the first launch would see. Building a second patch for the
    /// comparison would mint a fresh random id and could never be equal to the first.
    func testAFileThatCannotBeReadIsTreatedAsNothingRemembered() throws {
        let a = patch("A")
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a session".utf8).write(to: store.url)

        XCTAssertNil(store.load(), "a corrupt hint costs the resume and nothing else")

        let shown = SessionScope.restore(memory: store.load(), patches: [a])
        let firstLaunch = SessionScope.restore(memory: nil, patches: [a])
        XCTAssertEqual(shown.patchID, firstLaunch.patchID)
        XCTAssertEqual(shown, firstLaunch, "a corrupt file must read exactly like a first launch")
    }

    func testTheSessionFileSitsBesideTheBank() {
        let session = SessionStore.defaultURL()

        XCTAssertEqual(session.lastPathComponent, "session.json")
        XCTAssertEqual(
            session.deletingLastPathComponent().standardizedFileURL,
            PatchStore.defaultURL().deletingLastPathComponent().standardizedFileURL,
            "the hint lives with the bank it describes"
        )
    }

    func testRestoringMovesThePlayHeadToTheRestoredPatchesSlot() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])

        let landed = list.alignHead(to: b.id)

        XCTAssertEqual(landed?.patchID, b.id)
        XCTAssertEqual(list.currentEntry?.patchID, b.id, "the position shown has to be the sound playing")
        XCTAssertEqual(list.currentIndex, 1)
    }

    func testAPatchInNoSlotLeavesTheHeadWhereItWas() {
        let a = patch("A")
        let b = patch("B")
        let loose = patch("Not in the service")
        var list = Setlist.bankOrder([a, b])
        let before = list.currentEntry?.id

        let landed = list.alignHead(to: loose.id)

        XCTAssertNil(landed, "a patch the service does not use moves nothing")
        XCTAssertEqual(list.currentEntry?.id, before)
        XCTAssertEqual(list.entries.map(\.patchID), [a.id, b.id], "and the order is not rewritten")
    }

    func testAligningToTheHeadIsNotAMove() {
        let a = patch("A")
        let b = patch("B")
        var list = Setlist.bankOrder([a, b])
        let ids = list.entries.map(\.id)

        let landed = list.alignHead(to: a.id)

        XCTAssertEqual(landed?.id, ids[0], "the slot it was already on is reported, not rebuilt")
        XCTAssertEqual(list.entries.map(\.id), ids)
        XCTAssertEqual(list.currentIndex, 0)
    }
}
