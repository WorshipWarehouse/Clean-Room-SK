import XCTest
import SundayKeysCore

/// The instrument catalogue and the engine path it feeds.
///
/// These tests drive `RealtimeKeysoundEngine.renderStereo` — the path a live patch
/// takes — rather than a table or a command in isolation, so a layer whose
/// instrument stops reaching the render thread fails here even though every table
/// still renders on its own.
final class InstrumentCatalogueTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    // MARK: - The catalogue

    func testCatalogueEntriesAreDistinctAndResolve() {
        let catalogue = InstrumentCatalogue.builtIn
        XCTAssertGreaterThanOrEqual(catalogue.count, 5, "the catalogue should offer more than the two legacy tables")

        var ids = Set<String>()
        var rungs = Set<Int>()
        for instrument in catalogue {
            XCTAssertTrue(ids.insert(instrument.id).inserted, "duplicate instrument id \(instrument.id)")
            XCTAssertFalse(instrument.name.isEmpty, "\(instrument.id) has no name")
            XCTAssertFalse(instrument.character.isEmpty, "\(instrument.id) has no description")
            XCTAssertTrue(
                rungs.insert(InstrumentCatalogue.rung(for: instrument.id)).inserted,
                "\(instrument.id) shares a table rung with another instrument"
            )
            XCTAssertEqual(instrument.table().size, 2_048, "\(instrument.id) is not the strip size")
        }

        XCTAssertEqual(InstrumentCatalogue.tableCount, catalogue.count)
        XCTAssertEqual(InstrumentCatalogue.rung(for: InstrumentCatalogue.defaultID), 0)
        XCTAssertTrue(InstrumentCatalogue.contains(id: "organ"))
        XCTAssertFalse(InstrumentCatalogue.contains(id: "no-such-voice"))
    }

    func testUnknownInstrumentFallsBackToTheDefault() {
        XCTAssertEqual(InstrumentCatalogue.instrument(id: "no-such-voice").id, InstrumentCatalogue.defaultID)
        XCTAssertEqual(InstrumentCatalogue.rung(for: "no-such-voice"), 0)

        let layer = KeyLayer(id: 3, name: "Odd", range: NoteRange(0, 127), instrument: "no-such-voice")
        XCTAssertEqual(layer.instrument, "no-such-voice", "an unknown id should be kept so a save does not destroy it")
        XCTAssertEqual(layer.instrumentRung, 0, "an unknown id should play the default rung")
    }

    func testLegacyTimbreSelectsAndReadsTheSameField() {
        let bell = KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), timbre: .bell)
        XCTAssertEqual(bell.instrument, "bell")
        XCTAssertEqual(bell.timbre, .bell)

        var layer = KeyLayer(id: 2, name: "Pad", range: NoteRange(0, 127), instrument: "pad")
        XCTAssertEqual(layer.timbre, .keys, "a non-bell instrument reads as keys through the legacy view")
        layer.timbre = .bell
        XCTAssertEqual(layer.instrument, "bell", "writing the legacy view should select its instrument")
    }

    // MARK: - Persistence

    func testInstrumentSurvivesABankRoundTrip() throws {
        let patch = Patch(name: "Pads", layers: [
            KeyLayer(id: 0, name: "Pad", range: NoteRange(36, 96), gain: 0.6, instrument: "pad")
        ])
        let bank = PatchBank(patches: [patch], setlist: Setlist())
        let data = try JSONEncoder().encode(bank)
        let decoded = try JSONDecoder().decode(PatchBank.self, from: data)

        XCTAssertEqual(decoded.patches.count, 1)
        XCTAssertEqual(decoded.patches[0].layers.count, 1)
        XCTAssertEqual(decoded.patches[0].layers[0].instrument, "pad")
        XCTAssertEqual(decoded.patches[0].layers[0].gain, 0.6, accuracy: 1e-6)
    }

    func testALayerWithoutAnInstrumentDecodesFromItsTimbre() throws {
        let bell = KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), timbre: .bell)
        let restoredBell = try JSONDecoder().decode(KeyLayer.self, from: try legacyJSON(for: bell))
        XCTAssertEqual(restoredBell.instrument, "bell", "a pre-catalogue bank's bell layer should still be a bell")

        let keys = KeyLayer(id: 0, name: "Keys", range: NoteRange(36, 96), gain: 0.85)
        let restoredKeys = try JSONDecoder().decode(KeyLayer.self, from: try legacyJSON(for: keys))
        XCTAssertEqual(restoredKeys.instrument, InstrumentCatalogue.defaultID)
    }

    // MARK: - The render path

    func testEveryInstrumentRendersADifferentTone() throws {
        var shapes: [String: [Float]] = [:]
        var peaks: [String: Float] = [:]

        for instrument in InstrumentCatalogue.builtIn {
            let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patchLayers(instrument: instrument.id))
            engine.setPatch(patch(instrument: instrument.id), releasingVoices: true)
            engine.noteOn(note: 60, velocity: 100)
            let samples = render(engine)

            var peak: Float = 0
            for value in samples {
                XCTAssertTrue(value.isFinite, "\(instrument.id) rendered a non-finite sample")
                peak = max(peak, abs(value))
            }
            XCTAssertGreaterThan(peak, 0.01, "\(instrument.id) rendered silence")
            peaks[instrument.id] = peak
            shapes[instrument.id] = shape(samples)
        }

        let ids = InstrumentCatalogue.builtIn.map { $0.id }
        var first = 0
        while first < ids.count {
            var second = first + 1
            while second < ids.count {
                let one = try XCTUnwrap(shapes[ids[first]])
                let other = try XCTUnwrap(shapes[ids[second]])
                let difference = largestDifference(one, other)
                XCTAssertGreaterThan(
                    difference,
                    0.05,
                    "\(ids[first]) and \(ids[second]) render the same tone: largest normalised difference \(difference)"
                )
                second += 1
            }
            first += 1
        }

        XCTAssertEqual(peaks.count, ids.count)
    }

    /// An engine that starts on the keys strip and is retargeted by `setPatch` must
    /// render exactly what an engine that started on the organ strip renders. If
    /// `setPatch` stopped publishing the instrument's rung, the first engine would keep
    /// the keys table and this comparison would fail sample by sample.
    func testSetPatchPublishesTheInstrumentRung() throws {
        let retargeted = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patchLayers(instrument: "keys"))
        retargeted.setPatch(patch(instrument: "organ"), releasingVoices: true)
        retargeted.noteOn(note: 60, velocity: 100)
        let afterPatch = render(retargeted)

        let native = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patchLayers(instrument: "organ"))
        native.setPatch(patch(instrument: "organ"), releasingVoices: true)
        native.noteOn(note: 60, velocity: 100)
        let expected = render(native)

        XCTAssertEqual(afterPatch.count, expected.count)
        var index = 0
        while index < afterPatch.count {
            XCTAssertEqual(
                afterPatch[index],
                expected[index],
                accuracy: 1e-6,
                "sample \(index) differs: setPatch did not retarget the layer's instrument"
            )
            index += 1
        }

        let keys = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patchLayers(instrument: "keys"))
        keys.setPatch(patch(instrument: "keys"), releasingVoices: true)
        keys.noteOn(note: 60, velocity: 100)
        let keysRender = render(keys)
        XCTAssertGreaterThan(
            largestDifference(shape(afterPatch), shape(keysRender)),
            0.05,
            "the retargeted engine still renders the keys tone"
        )
    }

    /// The contract `setPatch(releasingVoices: false)` makes: an instrument change under
    /// a held chord changes the tone and does not cut the note. A release-everything
    /// command added to that path would fail this.
    func testLiveEditKeepsTheHeldVoice() {
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patchLayers(instrument: "keys"))
        engine.setPatch(patch(instrument: "keys"), releasingVoices: true)
        engine.noteOn(note: 60, velocity: 100)
        _ = render(engine)
        XCTAssertEqual(engine.voiceCount, 1, "the held note should be sounding before the edit")

        engine.setPatch(patch(instrument: "pad"), releasingVoices: false)
        _ = render(engine)
        XCTAssertEqual(engine.voiceCount, 1, "a live instrument change released the held note")
    }

    // MARK: - Helpers

    private func patchLayers(instrument: String) -> [KeyLayer] {
        [KeyLayer(id: 0, name: "Tone", range: NoteRange(0, 127), gain: 1, instrument: instrument)]
    }

    private func patch(instrument: String) -> Patch {
        Patch(name: "Catalogue \(instrument)", layers: patchLayers(instrument: instrument))
    }

    /// Eight 512-frame blocks at 48 kHz, which is long enough to leave the 8 ms attack
    /// behind and short enough that the comparison test stays quick.
    private func render(_ engine: RealtimeKeysoundEngine) -> [Float] {
        let frames = block * 8
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                var start = 0
                while start < frames {
                    let leftBlock = UnsafeMutableBufferPointer(rebasing: leftBuffer[start..<(start + block)])
                    let rightBlock = UnsafeMutableBufferPointer(rebasing: rightBuffer[start..<(start + block)])
                    var frame = 0
                    while frame < block {
                        leftBlock[frame] = 0
                        rightBlock[frame] = 0
                        frame += 1
                    }
                    engine.renderStereo(intoLeft: leftBlock, intoRight: rightBlock, frameCount: block)
                    start += block
                }
            }
        }
        return left
    }

    /// The window after the attack, scaled to its own peak, so two instruments played at
    /// the same note compare on timbre rather than on level.
    private func shape(_ samples: [Float]) -> [Float] {
        guard samples.count >= 4_096 else { return samples }
        let window = Array(samples[1_024..<4_096])
        var peak: Float = 0
        for value in window {
            if !value.isFinite {
                return window
            }
            peak = max(peak, abs(value))
        }
        guard peak > 0 else { return window }
        return window.map { $0 / peak }
    }

    private func largestDifference(_ first: [Float], _ second: [Float]) -> Float {
        var worst: Float = 0
        let count = min(first.count, second.count)
        var index = 0
        while index < count {
            worst = max(worst, abs(first[index] - second[index]))
            index += 1
        }
        return worst
    }

    /// A layer as a bank written before the catalogue encoded it: every key it has today
    /// except `instrument`.
    private func legacyJSON(for layer: KeyLayer) throws -> Data {
        let encoded = try JSONEncoder().encode(layer)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw InstrumentCatalogueTestError.notAnObject
        }
        object.removeValue(forKey: "instrument")
        return try JSONSerialization.data(withJSONObject: object)
    }
}

enum InstrumentCatalogueTestError: Error {
    case notAnObject
}
