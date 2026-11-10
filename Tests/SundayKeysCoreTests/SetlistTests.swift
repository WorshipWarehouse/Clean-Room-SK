import XCTest
@testable import SundayKeysCore

/// The set list is a pure model: ordering, a play head and the rules for both. Every
/// test here drives the same methods the app calls.
final class SetlistTests: XCTestCase {
    private func patch(_ name: String) -> Patch {
        Patch(name: name, layers: KeyLayer.defaultPatch)
    }

    func testAppendKeepsTheOrderAndTheFirstSlotBecomesTheHead() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist()

        XCTAssertNil(list.currentIndex, "a list with no slots has no head")
        list.append(patchID: a.id)
        list.append(patchID: b.id)
        list.append(patchID: c.id)

        XCTAssertEqual(list.entries.map(\.patchID), [a.id, b.id, c.id])
        XCTAssertEqual(list.currentIndex, 0, "the first slot added becomes the head")
        XCTAssertEqual(list.currentEntry?.patchID, a.id)
    }

    func testStepWrapsAtBothEnds() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        let available = Set([a.id, b.id, c.id])

        XCTAssertEqual(list.step(by: 1, available: available)?.patchID, b.id)
        XCTAssertEqual(list.currentIndex, 1)
        XCTAssertEqual(list.step(by: 1, available: available)?.patchID, c.id)
        XCTAssertEqual(list.step(by: 1, available: available)?.patchID, a.id, "past the last slot wraps to the first")
        XCTAssertEqual(list.step(by: -1, available: available)?.patchID, c.id, "before the first slot wraps to the last")
        XCTAssertNil(list.step(by: 0, available: available), "a zero step is not a move")
    }

    func testJumpClampsInsteadOfWrapping() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])

        XCTAssertEqual(list.jump(to: 9)?.patchID, c.id, "past the end clamps to the last slot")
        XCTAssertEqual(list.jump(to: -4)?.patchID, a.id, "before the start clamps to the first slot")
        XCTAssertEqual(list.jump(to: 1)?.patchID, b.id)
        XCTAssertEqual(list.currentIndex, 1)
    }

    func testRemovingTheHeadHandsItToTheFollowingSlot() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        list.jump(to: 1)
        let head = list.entries[1].id

        XCTAssertTrue(list.remove(entryID: head))
        XCTAssertEqual(list.entries.map(\.patchID), [a.id, c.id])
        XCTAssertEqual(list.currentIndex, 1, "the slot that followed takes over")
        XCTAssertEqual(list.currentEntry?.patchID, c.id)
    }

    func testRemovingTheLastSlotWhileItIsTheHeadFallsBackToTheNewLast() {
        let a = patch("A")
        let b = patch("B")
        var list = Setlist.bankOrder([a, b])
        list.jump(to: 1)

        XCTAssertTrue(list.remove(entryID: list.entries[1].id))
        XCTAssertEqual(list.entries.map(\.patchID), [a.id])
        XCTAssertEqual(list.currentIndex, 0)

        XCTAssertTrue(list.remove(entryID: list.entries[0].id))
        XCTAssertTrue(list.entries.isEmpty)
        XCTAssertNil(list.currentIndex, "an empty list has no head")
        XCTAssertNil(list.step(by: 1, available: [a.id, b.id]), "and nothing to step to")
    }

    func testRemovingAnEarlierSlotKeepsTheHeadOnTheSamePatch() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        list.jump(to: 2)
        let headID = list.entries[2].id

        XCTAssertTrue(list.remove(entryID: list.entries[0].id))
        XCTAssertEqual(list.currentEntry?.id, headID, "the head follows its own slot, not a number")
        XCTAssertEqual(list.currentEntry?.patchID, c.id)
        XCTAssertEqual(list.currentIndex, 1)
    }

    func testReorderKeepsTheHeadOnItsOwnSlot() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        list.jump(to: 1)
        let headID = list.entries[1].id

        XCTAssertTrue(list.move(entryID: headID, to: 2))
        XCTAssertEqual(list.entries.map(\.patchID), [a.id, c.id, b.id])
        XCTAssertEqual(list.currentEntry?.id, headID)
        XCTAssertEqual(list.currentIndex, 2)

        XCTAssertTrue(list.move(entryID: headID, by: -2))
        XCTAssertEqual(list.currentIndex, 0, "moving backwards works the same way")
    }

    func testTheSamePatchCanFillTwoSlotsAndSteppingTellsThemApart() {
        let a = patch("A")
        var list = Setlist(entries: [
            SetlistEntry(patchID: a.id),
            SetlistEntry(patchID: a.id),
        ])
        list.jump(to: 0)
        let firstSlot = list.entries[0].id

        let second = list.step(by: 1, available: [a.id])

        XCTAssertEqual(second?.patchID, a.id)
        XCTAssertNotEqual(second?.id, firstSlot, "the two slots stay distinct even though the patch repeats")
        XCTAssertEqual(list.currentIndex, 1)
        XCTAssertEqual(list.firstEntry(forPatch: a.id)?.id, firstSlot)
    }

    func testInsertClampsItsIndex() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist()

        list.insert(patchID: a.id, at: -5)
        list.insert(patchID: b.id, at: 99)
        list.insert(patchID: c.id, at: 1)

        XCTAssertEqual(list.entries.map(\.patchID), [a.id, c.id, b.id])
    }

    func testPruneDropsSlotsWhosePatchIsGoneAndFixesTheHead() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        list.jump(to: 1)

        list.prune(keeping: [a.id, c.id])

        XCTAssertEqual(list.entries.map(\.patchID), [a.id, c.id])
        XCTAssertEqual(list.currentEntry?.patchID, a.id, "a dropped head moves to the first remaining slot")
    }

    func testASlotWhosePatchIsMissingIsSkippedWhileStepping() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var list = Setlist.bankOrder([a, b, c])
        list.jump(to: 0)

        let next = list.step(by: 1, available: [a.id, c.id])

        XCTAssertEqual(next?.patchID, c.id, "a slot that cannot play is stepped over, not played")
        XCTAssertEqual(list.currentIndex, 1)
    }

    func testBankOrderCoversEveryPatchOnceInOrder() {
        let list = Setlist.bankOrder([patch("A"), patch("B"), patch("C")])

        XCTAssertEqual(list.entries.count, 3)
        XCTAssertEqual(list.currentIndex, 0)
    }

    func testABankWithoutASetlistStepsInBankOrder() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var bank = PatchBank(patches: [a, b, c])

        XCTAssertTrue(bank.setlist.isEmpty, "a bank built from patches alone has no set list")
        XCTAssertEqual(bank.stepSetlist(from: a.id, by: 1)?.id, b.id)
        XCTAssertEqual(bank.stepSetlist(from: c.id, by: 1)?.id, a.id, "bank order wraps too")
        XCTAssertEqual(bank.stepSetlist(from: a.id, by: -1)?.id, c.id)
    }

    func testASetlistStepResolvesThePatchTheHeadLandsOn() {
        let a = patch("A")
        let b = patch("B")
        let c = patch("C")
        var bank = PatchBank(patches: [a, b, c], setlist: Setlist.bankOrder([c, a]))

        XCTAssertEqual(bank.stepSetlist(from: c.id, by: 1)?.id, a.id)
        XCTAssertEqual(bank.setlist.currentEntry?.patchID, a.id)
        XCTAssertEqual(bank.stepSetlist(from: a.id, by: 1)?.id, c.id, "the set list wraps, not the bank")
    }
}

final class SetlistPersistenceTests: XCTestCase {
    private func temporaryStore() -> PatchStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysSetlistTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PatchStore(url: directory.appendingPathComponent("patches.json"))
    }

    func testTheSetListRoundTripsThroughTheBank() throws {
        let a = Patch(name: "A", layers: KeyLayer.defaultPatch)
        let b = Patch(name: "B", layers: KeyLayer.defaultPatch)
        var list = Setlist.bankOrder([a, b], name: "Sunday AM")
        list.jump(to: 1)

        let bank = PatchBank(patches: [a, b], setlist: list)
        let store = temporaryStore()
        try store.save(bank)
        let loaded = try store.load()

        XCTAssertEqual(loaded, bank)
        XCTAssertEqual(loaded.setlist.name, "Sunday AM")
        XCTAssertEqual(loaded.setlist.currentIndex, 1, "the play head survives a relaunch")
        XCTAssertEqual(loaded.setlist.currentEntry?.patchID, b.id)
        XCTAssertEqual(loaded.version, PatchBank.currentVersion)
    }

    func testABankWrittenBeforeSetlistsExistedLoadsWithoutOne() throws {
        let json = """
        {
          "version": 3,
          "patches": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "name": "Legacy",
              "layers": [
                { "id": 0, "name": "Keys", "range": { "lower": 36, "upper": 96 }, "transpose": 0, "gain": 0.8, "timbre": "keys", "enabled": true }
              ]
            }
          ]
        }
        """

        // var, because stepping the set list is a mutation: this test drives the same
        // call the app makes, including the bank-order fallback.
        var bank = try JSONDecoder().decode(PatchBank.self, from: Data(json.utf8))

        XCTAssertEqual(bank.version, 3, "the stored version is reported as written")
        XCTAssertEqual(bank.patches.count, 1)
        XCTAssertTrue(bank.setlist.isEmpty, "an old bank must not invent a set list")
        XCTAssertNil(bank.setlist.currentIndex)
        XCTAssertEqual(
            bank.stepSetlist(from: bank.patches[0].id, by: 1)?.id,
            bank.patches[0].id,
            "and stepping falls back to bank order, which wraps onto the only patch"
        )
    }

    func testABankSavedWithoutASetListStillDecodes() throws {
        let a = Patch(name: "A", layers: KeyLayer.defaultPatch)
        let bank = PatchBank(patches: [a])
        let store = temporaryStore()
        try store.save(bank)

        let loaded = try store.load()

        XCTAssertEqual(loaded, bank)
        XCTAssertTrue(loaded.setlist.isEmpty)
    }

    func testTheStarterBankOpensOnAPlayableSlot() {
        XCTAssertEqual(PatchBank.starter.setlist.entries.count, 1)
        XCTAssertEqual(PatchBank.starter.setlist.currentIndex, 0)
        XCTAssertEqual(PatchBank.starter.setlist.currentEntry?.patchID, Patch.starterID)
    }
}

/// The switch itself: a set list step is a real patch switch, so it must go through
/// `setPatch` and inherit none of the previous patch's tail.
final class SetlistEngineTests: XCTestCase {
    private let frameCount = 512

    private func render(_ engine: RealtimeKeysoundEngine, blocks: Int) -> [Float] {
        var captured: [Float] = []
        var buffer = [Float](repeating: 0, count: frameCount)
        var block = 0
        while block < blocks {
            buffer.withUnsafeMutableBufferPointer { pointer in
                var index = 0
                while index < pointer.count {
                    pointer[index] = 0
                    index += 1
                }
                engine.render(into: pointer, frameCount: pointer.count)
            }
            captured.append(contentsOf: buffer)
            block += 1
        }
        return captured
    }

    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        for sample in samples {
            value = max(value, abs(sample))
        }
        return value
    }

    private func wetPatch(_ name: String) -> Patch {
        var patch = Patch(name: name, layers: KeyLayer.defaultPatch)
        patch.effects.reverb.enabled = true
        patch.effects.reverb.mix = 0.7
        patch.effects.reverb.decay = 0.7
        return patch
    }

    func testSteppingToADryPatchReleasesTheVoicesAndInheritsNoTail() {
        let wet = wetPatch("Wet")
        let dry = Patch(name: "Dry", layers: KeyLayer.defaultPatch)
        var bank = PatchBank(
            patches: [wet, dry],
            setlist: Setlist.bankOrder([wet, dry])
        )

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: wet.layers)
        engine.setPatch(wet)
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 6)
        engine.noteOff(note: 60)
        XCTAssertGreaterThan(
            peak(Array(render(engine, blocks: 24).suffix(frameCount))),
            1e-5,
            "the first patch leaves a tail to inherit"
        )

        // Exactly the two calls the app makes when the set list steps forward.
        guard let next = bank.stepSetlist(from: wet.id, by: 1) else {
            return XCTFail("the set list must resolve the next slot")
        }
        XCTAssertEqual(next.id, dry.id)
        engine.setPatch(next)
        _ = render(engine, blocks: 24)

        XCTAssertEqual(engine.voiceCount, 0, "a set list step releases what is sounding, like any patch switch")
        XCTAssertEqual(peak(render(engine, blocks: 2)), 0, "and it does not inherit the previous patch's tail")
        XCTAssertEqual(engine.patch.id, dry.id)
        XCTAssertTrue(engine.patch.effects.isDry)
    }

    func testSteppingToAWetterPatchAppliesItsEffects() {
        let dry = Patch(name: "Dry", layers: KeyLayer.defaultPatch)
        let wet = wetPatch("Wet")
        var bank = PatchBank(patches: [dry, wet], setlist: Setlist.bankOrder([dry, wet]))

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: dry.layers)
        engine.setPatch(dry)

        guard let next = bank.stepSetlist(from: dry.id, by: 1) else {
            return XCTFail("the set list must resolve the next slot")
        }
        XCTAssertEqual(next.id, wet.id)
        engine.setPatch(next)

        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 6)
        engine.noteOff(note: 60)
        let tail = render(engine, blocks: 20)

        XCTAssertEqual(engine.voiceCount, 0)
        XCTAssertGreaterThan(
            peak(Array(tail.suffix(frameCount))),
            1e-5,
            "the patch the set list stepped to brings its own reverb, which only happens if its settings were applied"
        )
    }

    func testSteppingThroughAWholeSetlistKeepsTheHeadAndTheSoundInStep() {
        let a = Patch(name: "A", layers: KeyLayer.defaultPatch)
        let b = wetPatch("B")
        let c = Patch(name: "C", layers: KeyLayer.defaultPatch)
        var bank = PatchBank(patches: [a, b, c], setlist: Setlist.bankOrder([a, b, c]))

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: a.layers)
        engine.setPatch(a)
        XCTAssertEqual(bank.setlist.currentIndex, 0)

        var played: [UUID] = [a.id]
        var step = 0
        while step < 3 {
            guard let next = bank.stepSetlist(from: played[played.count - 1], by: 1) else {
                return XCTFail("every slot of a three slot list resolves")
            }
            engine.setPatch(next)
            played.append(next.id)
            XCTAssertEqual(bank.setlist.currentEntry?.patchID, next.id, "the head and the sound agree")
            _ = render(engine, blocks: 2)
            step += 1
        }

        XCTAssertEqual(played, [a.id, b.id, c.id, a.id], "a full cycle comes back to the first slot")
        XCTAssertEqual(engine.patch.id, a.id)
    }
}
