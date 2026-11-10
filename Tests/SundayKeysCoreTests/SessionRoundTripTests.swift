import XCTest
@testable import SundayKeysCore

/// The session rule has unit tests, but a player's launch goes through two files on disk:
/// the bank it saves and the hint beside it. These tests write those files and read them
/// back through fresh stores, which is what a relaunch is, so the pairing is asserted on
/// real JSON rather than on values built in memory.
final class SessionRoundTripTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysSessionRoundTrip", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func namedPatches() -> [Patch] {
        ["Sunday Keys", "Worship Pad", "Rehearsal Pad"].map {
            Patch(name: $0, layers: KeyLayer.defaultPatch)
        }
    }

    /// Fresh stores over the same folder, which is the state a second launch starts in:
    /// nothing is carried over except the files.
    private func stores(in directory: URL) -> (patches: PatchStore, session: SessionStore) {
        (
            PatchStore(url: directory.appendingPathComponent("patches.json")),
            SessionStore(url: directory.appendingPathComponent("session.json"))
        )
    }

    func testARelaunchReadsBackThePatchTheLastOneSaved() throws {
        let directory = temporaryDirectory()
        let patches = namedPatches()
        let first = stores(in: directory)
        try first.patches.save(PatchBank(patches: patches, setlist: Setlist.bankOrder(patches)))
        try first.session.save(SessionMemory(lastPatchID: patches[2].id))

        let second = stores(in: directory)
        var loaded = try second.patches.load()
        let restore = SessionScope.restore(memory: second.session.load(), patches: loaded.patches)
        loaded.alignSetlistHead(to: restore.patchID ?? UUID())

        XCTAssertEqual(restore, .remembered(patches[2].id, name: "Rehearsal Pad"))
        XCTAssertEqual(loaded.patches.count, 3, "the bank written by the first launch is the bank read back")
        XCTAssertEqual(loaded.setlist.currentEntry?.patchID, patches[2].id, "the head followed the resume")
        XCTAssertEqual(loaded.setlist.currentIndex, 2)
    }

    func testAHintForADeletedPatchFallsBackOnDiskToo() throws {
        let directory = temporaryDirectory()
        let patches = namedPatches()
        let first = stores(in: directory)
        try first.patches.save(PatchBank(patches: patches, setlist: Setlist.bankOrder(patches)))
        try first.session.save(SessionMemory(lastPatchID: UUID()))

        let second = stores(in: directory)
        var loaded = try second.patches.load()
        let restore = SessionScope.restore(memory: second.session.load(), patches: loaded.patches)
        loaded.alignSetlistHead(to: restore.patchID ?? UUID())

        XCTAssertEqual(restore, .fallback(patches[0].id, name: "Sunday Keys", because: .patchMissing))
        XCTAssertEqual(loaded.setlist.currentEntry?.patchID, patches[0].id, "the fallback still stands on a slot")
        XCTAssertEqual(loaded.setlist.currentIndex, 0)
    }

    func testALaunchWithNoHintFallsBackAndKeepsTheBank() throws {
        let directory = temporaryDirectory()
        let patches = namedPatches()
        let first = stores(in: directory)
        try first.patches.save(PatchBank(patches: patches, setlist: Setlist.bankOrder(patches)))
        XCTAssertNil(first.session.load(), "nothing was written for the next launch")

        let second = stores(in: directory)
        let loaded = try second.patches.load()
        let restore = SessionScope.restore(memory: second.session.load(), patches: loaded.patches)

        XCTAssertEqual(restore, .fallback(patches[0].id, name: "Sunday Keys", because: .nothingRemembered))
        XCTAssertEqual(loaded.patches.count, 3, "a missing hint cannot cost the bank")
    }

    func testAHalfWrittenHintCannotCostTheBank() throws {
        let directory = temporaryDirectory()
        let patches = namedPatches()
        let first = stores(in: directory)
        try first.patches.save(PatchBank(patches: patches, setlist: Setlist.bankOrder(patches)))
        try Data("{\"lastPatchID\":".utf8).write(to: first.session.url)

        let second = stores(in: directory)
        let loaded = try second.patches.load()
        let restore = SessionScope.restore(memory: second.session.load(), patches: loaded.patches)

        XCTAssertNil(second.session.load(), "a truncated hint reads as nothing remembered")
        XCTAssertEqual(loaded.patches.count, 3)
        XCTAssertFalse(restore.isRemembered)
    }

    /// The two files have to be able to move apart: a bank copied to a new Mac without the
    /// hint must still open, and the hint must never be the thing the bank depends on.
    func testTheHintLivesInItsOwnFile() throws {
        let directory = temporaryDirectory()
        let patches = namedPatches()
        let first = stores(in: directory)
        try first.patches.save(PatchBank(patches: patches, setlist: Setlist.bankOrder(patches)))
        try first.session.save(SessionMemory(lastPatchID: patches[1].id))
        try FileManager.default.removeItem(at: first.session.url)

        let second = stores(in: directory)
        let loaded = try second.patches.load()

        XCTAssertEqual(loaded.patches.count, 3, "the bank loads without its hint")
        XCTAssertEqual(loaded.setlist.entries.count, 3)
        XCTAssertNil(second.session.load())
    }
}
