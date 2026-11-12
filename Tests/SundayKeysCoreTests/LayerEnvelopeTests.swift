import XCTest
@testable import SundayKeysCore

/// The per-layer envelope, measured on the real render path at 48 kHz and 512 frames per
/// block: the times are checked as positions in the rendered samples, the level as a ratio
/// of RMS, the law as clamps on read, write and decode, and the live-edit path as a held
/// voice that survives the edit and then obeys it.
final class LayerEnvelopeTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    // MARK: - Helpers

    private func layer(envelope: LayerEnvelope) -> KeyLayer {
        KeyLayer(id: 0, name: "Pad", range: NoteRange(0, 127), gain: 1, envelope: envelope)
    }

    private func render(
        _ patch: Patch,
        note: UInt8 = 60,
        blocks: Int = 60,
        releaseAfter: Int? = nil
    ) -> [Float] {
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: note, velocity: 110)

        var scratch = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var out = [Float]()
        out.reserveCapacity(blocks * block)

        var index = 0
        while index < blocks {
            if let releaseAfter, index == releaseAfter {
                engine.noteOff(note: note)
            }
            scratch.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    engine.renderStereo(
                        intoLeft: leftBuffer,
                        intoRight: rightBuffer,
                        frameCount: block
                    )
                }
            }
            out.append(contentsOf: scratch)
            index += 1
        }
        return out
    }

    private func blockPeak(_ samples: [Float], _ index: Int) -> Double {
        let start = index * block
        let end = min(samples.count, start + block)
        guard start < end else { return 0 }
        var peak = 0.0
        var cursor = start
        while cursor < end {
            peak = max(peak, abs(Double(samples[cursor])))
            cursor += 1
        }
        return peak
    }

    private func rms(_ samples: [Float], from: Int, to: Int) -> Double {
        let start = from * block
        let end = min(samples.count, to * block)
        guard start < end else { return 0 }
        var total = 0.0
        var cursor = start
        while cursor < end {
            total += Double(samples[cursor]) * Double(samples[cursor])
            cursor += 1
        }
        return (total / Double(end - start)).squareRoot()
    }

    // MARK: - The law

    func testTheLawClampsEveryStageAndDefaultsANonNumber() {
        XCTAssertEqual(LayerEnvelope(attack: -1).attack, 0.001)
        XCTAssertEqual(LayerEnvelope(attack: 99).attack, 5)
        XCTAssertEqual(LayerEnvelope(attack: .nan).attack, LayerEnvelope.defaultAttack)
        XCTAssertEqual(LayerEnvelope(decay: -3).decay, 0)
        XCTAssertEqual(LayerEnvelope(decay: 42).decay, 5)
        XCTAssertEqual(LayerEnvelope(sustain: 2).sustain, 1)
        XCTAssertEqual(LayerEnvelope(sustain: -2).sustain, 0)
        XCTAssertEqual(LayerEnvelope(release: 0).release, 0.005)
        XCTAssertEqual(LayerEnvelope(release: 1e9).release, 10)

        XCTAssertTrue(LayerEnvelope.default.holdsLevel)
        XCTAssertTrue(LayerEnvelope(sustain: 1, decay: 2).holdsLevel)
        XCTAssertFalse(LayerEnvelope(decay: 0.2, sustain: 0.5).holdsLevel)

        XCTAssertEqual(LayerEnvelope.frames(for: 0, sampleRate: sampleRate), 1)
        XCTAssertEqual(LayerEnvelope.frames(for: 0.5, sampleRate: sampleRate), 24_000, accuracy: 1)
    }

    func testADecodedEnvelopeIsClampedAndALayerWrittenBeforeItLoadsTheDefaults() throws {
        let json = "{\"attack\": 9000, \"decay\": -4, \"sustain\": 9, \"release\": 0.5}"
        let decoded = try JSONDecoder().decode(
            LayerEnvelope.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.attack, 5)
        XCTAssertEqual(decoded.decay, 0)
        XCTAssertEqual(decoded.sustain, 1)
        XCTAssertEqual(decoded.release, 0.5)

        let layer = self.layer(envelope: LayerEnvelope(attack: 0.5, decay: 0.2, sustain: 0.6, release: 1.5))
        let data = try JSONEncoder().encode(layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "envelope")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let older = try JSONDecoder().decode(KeyLayer.self, from: stripped)
        XCTAssertEqual(older.envelope, .default, "a version 6 layer should load with the default envelope")
    }

    func testALayerRoundTripsItsEnvelope() throws {
        let envelope = LayerEnvelope(attack: 0.05, decay: 0.2, sustain: 0.6, release: 1.5)
        let data = try JSONEncoder().encode(layer(envelope: envelope))
        let decoded = try JSONDecoder().decode(KeyLayer.self, from: data)
        XCTAssertEqual(decoded.envelope.attack, 0.05, accuracy: 1e-6)
        XCTAssertEqual(decoded.envelope.decay, 0.2, accuracy: 1e-6)
        XCTAssertEqual(decoded.envelope.sustain, 0.6, accuracy: 1e-6)
        XCTAssertEqual(decoded.envelope.release, 1.5, accuracy: 1e-6)
    }

    // MARK: - The rendered behaviour

    func testADefaultEnvelopeRendersIdenticallyToTheDefaultsStatedExplicitly() {
        let implicit = render(Patch(name: "Implicit", layers: [layer(envelope: .default)]), blocks: 20)
        let explicit = render(
            Patch(
                name: "Explicit",
                layers: [layer(envelope: LayerEnvelope(attack: 0.008, decay: 0, sustain: 1, release: 0.220))]
            ),
            blocks: 20
        )

        var index = 0
        var largest = 0.0
        while index < min(implicit.count, explicit.count) {
            largest = max(largest, abs(Double(implicit[index] - explicit[index])))
            index += 1
        }
        XCTAssertLessThan(largest, 1e-6, "an unset envelope should render bit-identically")
    }

    func testASlowAttackDelaysThePeakByItsOwnTime() {
        // 0.25 s at 48 kHz is 12,000 frames, which is 23.4 blocks of 512.
        let samples = render(
            Patch(name: "Swell", layers: [layer(envelope: LayerEnvelope(attack: 0.25))]),
            blocks: 50
        )
        let steady = blockPeak(samples, 40)
        XCTAssertGreaterThan(steady, 0.01, "the note never sounded")

        let early = blockPeak(samples, 3)
        XCTAssertLessThan(early, steady * 0.30, "the third block should still be inside a 0.25 s attack")

        let after = blockPeak(samples, 25)
        XCTAssertGreaterThan(after, steady * 0.95, "the attack should have completed by 0.27 s")
    }

    func testDecayFallsToTheSustainLevelAndHoldsThere() {
        let sustained = render(
            Patch(
                name: "Full",
                layers: [layer(envelope: LayerEnvelope(attack: 0.002, decay: 0, sustain: 1))]
            ),
            blocks: 50
        )
        let decayed = render(
            Patch(
                name: "Half",
                layers: [layer(envelope: LayerEnvelope(attack: 0.002, decay: 0.05, sustain: 0.4))]
            ),
            blocks: 50
        )

        let full = rms(sustained, from: 30, to: 50)
        let quiet = rms(decayed, from: 30, to: 50)
        XCTAssertGreaterThan(full, 0.01, "the reference note never sounded")
        XCTAssertEqual(quiet / full, 0.4, accuracy: 0.06, "the sustain level should be 0.4 of the peak")
    }

    func testTheReleaseTailFollowsTheEnvelopesOwnTime() {
        let long = render(
            Patch(name: "Long", layers: [layer(envelope: LayerEnvelope(release: 1.0))]),
            blocks: 50,
            releaseAfter: 10
        )
        // 0.3 s after the key came up a one second release is still sounding.
        let tail = rms(long, from: 24, to: 40)
        XCTAssertGreaterThan(tail, 0.005, "a one second release should still be audible at 0.3 s")

        let short = render(
            Patch(name: "Short", layers: [layer(envelope: LayerEnvelope(release: 0.05))]),
            blocks: 50,
            releaseAfter: 10
        )
        let gone = rms(short, from: 20, to: 50)
        XCTAssertLessThan(gone, tail * 0.05, "a 0.05 s release should be silent by 0.11 s")
    }

    func testALiveEnvelopeEditKeepsTheHeldVoiceAndThenObeysIt() {
        let engine = RealtimeKeysoundEngine(
            sampleRate: sampleRate,
            layers: [layer(envelope: .default)]
        )
        engine.noteOn(note: 60, velocity: 110)

        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        func renderBlocks(_ count: Int) {
            var index = 0
            while index < count {
                left.withUnsafeMutableBufferPointer { leftBuffer in
                    right.withUnsafeMutableBufferPointer { rightBuffer in
                        engine.renderStereo(
                            intoLeft: leftBuffer,
                            intoRight: rightBuffer,
                            frameCount: block
                        )
                    }
                }
                index += 1
            }
        }

        renderBlocks(4)
        XCTAssertEqual(engine.voiceCount, 1)

        // The edit lands on the ring the render thread drains; nothing releases the voice.
        engine.setLayerEnvelope(
            layer: 0,
            envelope: LayerEnvelope(attack: 0.008, decay: 0, sustain: 1, release: 3.0)
        )
        renderBlocks(2)
        XCTAssertEqual(engine.voiceCount, 1, "a live envelope edit must not cut the held note")

        engine.noteOff(note: 60)
        // 0.43 s later the three second release is still inside its tail, where the
        // instrument's own 220 ms release would have freed the voice.
        renderBlocks(40)
        XCTAssertEqual(engine.voiceCount, 1, "the edited release time did not reach the render thread")

        renderBlocks(20)
        XCTAssertEqual(engine.voiceCount, 1, "an unchanged release should still be sounding at 0.64 s")

        engine.setLayerEnvelope(
            layer: 0,
            envelope: LayerEnvelope(attack: 0.008, decay: 0, sustain: 1, release: 0.05)
        )
        engine.noteOn(note: 64, velocity: 110)
        renderBlocks(2)
        engine.noteOff(note: 64)
        renderBlocks(20)
        XCTAssertEqual(engine.voiceCount, 1, "the first note keeps its own longer release")
    }
}
