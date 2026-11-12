import XCTest
@testable import SundayKeysCore

/// The layer's stereo position, measured on the stereo render path.
final class LayerPanTests: XCTestCase {
    private let frames = 512

    private func layers(pan: Float) -> [KeyLayer] {
        [KeyLayer(
            id: 0,
            name: "Lead",
            range: NoteRange(0, 127),
            gain: 1,
            pan: pan
        )]
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

    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        for sample in samples { value = max(value, abs(sample)) }
        return value
    }

    func testPanLawIsUnityAtCentre() {
        let centre = KeyLayer.panGains(for: 0)
        XCTAssertEqual(centre.left, 1.0, accuracy: 1e-6, "centre left")
        XCTAssertEqual(centre.right, 1.0, accuracy: 1e-6, "centre right")

        let hardLeft = KeyLayer.panGains(for: -1)
        XCTAssertEqual(hardLeft.left, 1.0, accuracy: 1e-6, "hard left, left side")
        XCTAssertEqual(hardLeft.right, 0.0, accuracy: 1e-6, "hard left, right side")

        let hardRight = KeyLayer.panGains(for: 1)
        XCTAssertEqual(hardRight.left, 0.0, accuracy: 1e-6, "hard right, left side")
        XCTAssertEqual(hardRight.right, 1.0, accuracy: 1e-6, "hard right, right side")
    }

    func testLayerClampsThePositionItStores() {
        let over = KeyLayer(
            id: 2,
            name: "Pad",
            range: NoteRange(0, 127),
            pan: 9
        )
        XCTAssertEqual(over.pan, 1, accuracy: 1e-6)
        let under = KeyLayer(
            id: 3,
            name: "Pad",
            range: NoteRange(0, 127),
            pan: -9
        )
        XCTAssertEqual(under.pan, -1, accuracy: 1e-6)
    }

    func testLayerPannedHardLeftIsSilentOnTheRight() {
        let engine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(pan: -1)
        )
        engine.noteOn(note: 60, velocity: 110)
        let audio = render(engine, blocks: 4)
        XCTAssertGreaterThan(rms(audio.left), 0.01)
        XCTAssertEqual(peak(audio.right), 0)
    }

    func testLayerPannedHardRightIsSilentOnTheLeft() {
        let engine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(pan: 1)
        )
        engine.noteOn(note: 60, velocity: 110)
        let audio = render(engine, blocks: 4)
        XCTAssertGreaterThan(rms(audio.right), 0.01)
        XCTAssertEqual(peak(audio.left), 0)
    }

    func testCentreIsBitIdenticalToTheMonoPath() {
        var buffer = [Float](repeating: 0, count: frames)
        var mono: [Float] = []
        let monoEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(pan: 0)
        )
        monoEngine.noteOn(note: 60, velocity: 110)
        for _ in 0..<4 {
            var index = 0
            while index < frames {
                buffer[index] = 0
                index += 1
            }
            buffer.withUnsafeMutableBufferPointer { pointer in
                monoEngine.render(
                    into: pointer,
                    frameCount: frames
                )
            }
            mono.append(contentsOf: buffer)
        }

        let stereoEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(pan: 0)
        )
        stereoEngine.noteOn(note: 60, velocity: 110)
        let audio = render(stereoEngine, blocks: 4)
        XCTAssertEqual(audio.left, mono)
        XCTAssertEqual(audio.right, mono)
    }

    func testBankKeepsThePositionAndDefaultsOldPatches() throws {
        let patch = Patch(name: "Left", layers: layers(pan: -1))
        let encoded = try JSONEncoder().encode(
            PatchBank(patches: [patch])
        )
        let loaded = try JSONDecoder().decode(
            PatchBank.self,
            from: encoded
        )
        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(
            loaded.patches[0].layers[0].pan,
            -1,
            accuracy: 1e-6
        )

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var patches = try XCTUnwrap(
            object["patches"] as? [[String: Any]]
        )
        var patchObject = patches[0]
        var storedLayers = try XCTUnwrap(
            patchObject["layers"] as? [[String: Any]]
        )
        var layerObject = storedLayers[0]
        layerObject.removeValue(forKey: "pan")
        storedLayers[0] = layerObject
        patchObject["layers"] = storedLayers
        patches[0] = patchObject
        object["patches"] = patches
        object["version"] = 4
        let old = try JSONDecoder().decode(
            PatchBank.self,
            from: try JSONSerialization.data(
                withJSONObject: object
            )
        )
        XCTAssertEqual(old.version, 4)
        XCTAssertEqual(
            old.patches[0].layers[0].pan,
            0,
            accuracy: 1e-6
        )
    }

    func testPanMovedUnderAHeldNoteKeepsTheVoice() {
        var patch = Patch(name: "Hold", layers: layers(pan: 0))
        let engine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: patch.layers
        )
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 2)
        let voices = engine.voiceCount
        XCTAssertGreaterThan(voices, 0)

        patch.layers[0].pan = -1
        engine.setPatch(patch, releasingVoices: false)
        XCTAssertEqual(engine.voiceCount, voices)

        let moved = render(engine, blocks: 2)
        XCTAssertGreaterThan(rms(moved.left), 0.01)
        XCTAssertEqual(peak(moved.right), 0)
    }
}
