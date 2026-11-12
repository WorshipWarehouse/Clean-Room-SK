import XCTest
@testable import SundayKeysCore

/// The per-layer tone, measured on the stereo render path at 48 kHz / 512 frames.
final class LayerFilterTests: XCTestCase {
    private let frames = 512

    private func layers(
        cutoff: Float = LayerFilter.defaultCutoff,
        resonance: Float = LayerFilter.defaultResonance
    ) -> [KeyLayer] {
        [
            KeyLayer(
                id: 0,
                name: "Lead",
                range: NoteRange(0, 127),
                gain: 1,
                filterCutoff: cutoff,
                filterResonance: resonance
            )
        ]
    }

    private func render(
        _ engine: RealtimeKeysoundEngine,
        blocks: Int
    ) -> (left: [Float], right: [Float]) {
        var leftAll: [Float] = []
        var rightAll: [Float] = []
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for _ in 0..<blocks {
            var index = 0
            while index < frames {
                left[index] = 0
                right[index] = 0
                index += 1
            }
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    engine.renderStereo(
                        intoLeft: leftPointer,
                        intoRight: rightPointer,
                        frameCount: frames
                    )
                }
            }
            leftAll.append(contentsOf: left)
            rightAll.append(contentsOf: right)
        }
        return (leftAll, rightAll)
    }

    private func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(max(1, samples.count))).squareRoot()
    }

    func testOpenFilterIsTheDefaultAndBypasses() {
        let layer = KeyLayer(id: 0, name: "Keys", range: NoteRange(0, 127))
        XCTAssertEqual(
            layer.filterCutoff,
            LayerFilter.maximumCutoff,
            accuracy: 1e-3,
            "a layer that never sets a tone is open"
        )
        XCTAssertEqual(layer.filterResonance, 0, accuracy: 1e-6)
        XCTAssertTrue(layer.filterIsOpen)
        XCTAssertTrue(
            LayerFilter.coefficients(
                cutoff: LayerFilter.maximumCutoff,
                resonance: 0,
                sampleRate: 48_000
            ).bypass
        )
    }

    func testLawClampsAndRoundTripsTheSlider() {
        XCTAssertEqual(LayerFilter.clampCutoff(-5), LayerFilter.minimumCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampCutoff(1e9), LayerFilter.maximumCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampCutoff(.nan), LayerFilter.defaultCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampResonance(-1), 0, accuracy: 1e-6)
        XCTAssertEqual(LayerFilter.clampResonance(4), 1, accuracy: 1e-6)

        let octaves = LayerFilter.octaves(fromCutoff: 1_280)
        XCTAssertEqual(octaves, 6, accuracy: 1e-3, "1.28 kHz is six octaves above 20 Hz")
        XCTAssertEqual(
            LayerFilter.cutoff(fromOctaves: octaves),
            1_280,
            accuracy: 0.5,
            "the slider position reads back as the corner it came from"
        )
    }

    func testAPatchWrittenBeforeTheFieldIsBitIdentical() {
        let defaults = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers()
        )
        defaults.noteOn(note: 60, velocity: 110)
        let open = render(defaults, blocks: 4)

        let explicit = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: LayerFilter.maximumCutoff, resonance: 0)
        )
        explicit.noteOn(note: 60, velocity: 110)
        let stated = render(explicit, blocks: 4)

        XCTAssertEqual(open.left, stated.left)
        XCTAssertEqual(open.right, stated.right)
    }

    func testACornerCutsTheHarmonicsAboveIt() {
        let dryEngine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: layers())
        dryEngine.noteOn(note: 96, velocity: 110)
        let dry = rms(render(dryEngine, blocks: 4).left)

        let filteredEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 300)
        )
        filteredEngine.noteOn(note: 96, velocity: 110)
        let filtered = rms(render(filteredEngine, blocks: 4).left)

        XCTAssertGreaterThan(dry, 0.01, "the dry note has to sound for the comparison to mean anything")
        XCTAssertLessThan(
            filtered,
            dry * 0.5,
            "a 300 Hz corner must take most of a 2 kHz note's energy"
        )
    }

    func testALowNotePassesACornerAboveIt() {
        let dryEngine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: layers())
        dryEngine.noteOn(note: 48, velocity: 110)
        let dry = rms(render(dryEngine, blocks: 4).left)

        let filteredEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_500)
        )
        filteredEngine.noteOn(note: 48, velocity: 110)
        let filtered = rms(render(filteredEngine, blocks: 4).left)

        XCTAssertGreaterThan(
            filtered,
            dry * 0.6,
            "a note well below the corner keeps most of its energy"
        )
    }

    func testResonanceLiftsTheCorner() {
        let plainEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_046, resonance: 0)
        )
        plainEngine.noteOn(note: 84, velocity: 110)
        let plain = rms(render(plainEngine, blocks: 4).left)

        let resonantEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_046, resonance: 1)
        )
        resonantEngine.noteOn(note: 84, velocity: 110)
        let resonant = rms(render(resonantEngine, blocks: 4).left)

        XCTAssertGreaterThan(
            resonant,
            plain * 1.2,
            "full resonance puts back more energy at the corner than none"
        )
    }

    func testToneMovedUnderAHeldNoteKeepsTheVoice() {
        var patch = Patch(name: "Hold", layers: layers())
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: patch.layers)
        engine.noteOn(note: 72, velocity: 110)
        let before = render(engine, blocks: 2)
        let voices = engine.voiceCount
        XCTAssertGreaterThan(voices, 0)

        patch.layers[0].filterCutoff = 400
        patch.layers[0].filterResonance = 0.3
        engine.setPatch(patch, releasingVoices: false)
        XCTAssertEqual(engine.voiceCount, voices, "a tone edit must not cut the chord")
        engine.setLayerFilter(layer: 0, cutoff: 400, resonance: 0.3)
        XCTAssertEqual(engine.voiceCount, voices)

        let after = render(engine, blocks: 4)
        XCTAssertLessThan(
            rms(after.left),
            rms(before.left),
            "the held note gets darker once the corner moves"
        )
    }

    func testBankKeepsTheToneAndDefaultsOldPatches() throws {
        let patch = Patch(name: "Dark", layers: layers(cutoff: 800, resonance: 0.4))
        let encoded = try JSONEncoder().encode(PatchBank(patches: [patch]))
        let loaded = try JSONDecoder().decode(PatchBank.self, from: encoded)
        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(loaded.patches[0].layers[0].filterCutoff, 800, accuracy: 0.5)
        XCTAssertEqual(loaded.patches[0].layers[0].filterResonance, 0.4, accuracy: 1e-5)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var patches = try XCTUnwrap(object["patches"] as? [[String: Any]])
        var patchObject = patches[0]
        var storedLayers = try XCTUnwrap(patchObject["layers"] as? [[String: Any]])
        var layerObject = storedLayers[0]
        layerObject.removeValue(forKey: "filterCutoff")
        layerObject.removeValue(forKey: "filterResonance")
        storedLayers[0] = layerObject
        patchObject["layers"] = storedLayers
        patches[0] = patchObject
        object["patches"] = patches
        object["version"] = 5

        let old = try JSONDecoder().decode(
            PatchBank.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(old.version, 5)
        XCTAssertEqual(
            old.patches[0].layers[0].filterCutoff,
            LayerFilter.defaultCutoff,
            accuracy: 1e-3,
            "a bank written before the field is open, not broken"
        )
        XCTAssertEqual(old.patches[0].layers[0].filterResonance, 0, accuracy: 1e-6)
    }

    func testDecodeClampsAToneOutsideTheLaw() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(PatchBank(patches: [Patch(name: "X", layers: layers())]))
            ) as? [String: Any]
        )
        var patches = try XCTUnwrap(object["patches"] as? [[String: Any]])
        var patchObject = patches[0]
        var storedLayers = try XCTUnwrap(patchObject["layers"] as? [[String: Any]])
        var layerObject = storedLayers[0]
        layerObject["filterCutoff"] = 900_000
        layerObject["filterResonance"] = 12
        storedLayers[0] = layerObject
        patchObject["layers"] = storedLayers
        patches[0] = patchObject
        object["patches"] = patches

        let decoded = try JSONDecoder().decode(
            PatchBank.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(
            decoded.patches[0].layers[0].filterCutoff,
            LayerFilter.maximumCutoff,
            accuracy: 1e-3
        )
        XCTAssertEqual(decoded.patches[0].layers[0].filterResonance, 1, accuracy: 1e-6)
    }
}
