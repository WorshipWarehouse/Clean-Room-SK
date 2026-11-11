import Foundation
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The effects panel, driven the way the window drives it.
///
/// `AppModel.updateEffects` is the one method every control in the effects panel calls, and it
/// takes the live-edit path: the edited patch is republished to the render thread and no voice is
/// released. The core suite already measures the chain on its own; what no test had shown was that
/// the panel's own entry point reaches the sound. Each case here edits through that method and then
/// renders the model's resulting patch on the real `RealtimeKeysoundEngine`, so the assertion is
/// about samples rather than about a settings value.
///
/// The numbers below are measured against each other rather than asserted from a table: a boost is
/// compared with a cut of the same band, the two delay taps with each other, and the wet tail with
/// the dry release it outlives. Nothing here starts a device or reads a file that a player owns.
@MainActor
final class EffectsPanelTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    private struct Rendered {
        let left: [Float]
        let right: [Float]
    }

    // MARK: - Rendering

    /// Renders `patch` on the engine the app builds, with one note held and optionally released,
    /// and returns both channels so a stereo claim can be measured rather than implied.
    private func render(
        _ patch: Patch,
        note: UInt8 = 60,
        blocks: Int = 60,
        releaseAfter: Int? = nil
    ) -> Rendered {
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: note, velocity: 110)

        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var leftOut = [Float]()
        var rightOut = [Float]()
        leftOut.reserveCapacity(blocks * block)
        rightOut.reserveCapacity(blocks * block)

        var index = 0
        while index < blocks {
            if let releaseAfter, index == releaseAfter {
                engine.noteOff(note: note)
            }
            left.withUnsafeMutableBufferPointer { destination in
                right.withUnsafeMutableBufferPointer { other in
                    engine.renderStereo(intoLeft: destination, intoRight: other, frameCount: block)
                }
            }
            leftOut.append(contentsOf: left)
            rightOut.append(contentsOf: right)
            index += 1
        }
        return Rendered(left: leftOut, right: rightOut)
    }

    /// Advances an engine that is already sounding, which is how a live edit is measured under a
    /// chord the player is holding.
    private func advance(_ engine: RealtimeKeysoundEngine, blocks: Int) {
        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var index = 0
        while index < blocks {
            left.withUnsafeMutableBufferPointer { destination in
                right.withUnsafeMutableBufferPointer { other in
                    engine.renderStereo(intoLeft: destination, intoRight: other, frameCount: block)
                }
            }
            index += 1
        }
    }

    // MARK: - Measurement

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in samples {
            total += Double(sample) * Double(sample)
        }
        return (total / Double(samples.count)).squareRoot()
    }

    private func largestDifference(_ first: [Float], _ second: [Float]) -> Double {
        var largest: Float = 0
        let count = min(first.count, second.count)
        var index = 0
        while index < count {
            largest = max(largest, abs(first[index] - second[index]))
            index += 1
        }
        return Double(largest)
    }

    private func makeModel() -> AppModel {
        AppModel(audio: AudioEngineController())
    }

    // MARK: - The panel's entry point

    /// The switch in the panel, end to end: the edit lands in the patch the window shows, the panel's
    /// status line is the model's, and the rendered samples change.
    func testThePanelsReverbSwitchReachesTheRenderedSamples() {
        let model = makeModel()
        model.updateEffects { $0 = EffectsSettings() }
        let dry = render(model.patch)

        model.updateEffects {
            $0.reverb = ReverbSettings(enabled: true, mix: 0.5, decay: 0.8, damping: 0.2)
        }

        XCTAssertTrue(model.patch.effects.reverb.enabled, "the edit is in the patch the window shows")
        XCTAssertEqual(
            model.bankStatus,
            "Edited effects on \(model.patch.name), not saved yet",
            "the panel's status line should be the model's own"
        )

        let wet = render(model.patch)
        XCTAssertGreaterThan(
            largestDifference(dry.left, wet.left), 1e-3,
            "the panel's reverb switch changed nothing in the rendered samples"
        )
    }

    /// The EQ band's own control, measured two ways: a boost must carry more energy than a cut of
    /// the same shelf, which a bypassed chain or an unwired control could not produce.
    func testThePanelsEQBoostAndCutAreMeasurablyOrdered() {
        let model = makeModel()
        model.updateEffects {
            $0 = EffectsSettings(eq: EQSettings(enabled: true, lowGain: 12))
        }
        let boosted = rms(render(model.patch, note: 60).left[...])

        model.updateEffects { $0.eq.lowGain = -12 }
        XCTAssertEqual(model.patch.effects.eq.lowGain, -12)
        let cut = rms(render(model.patch, note: 60).left[...])

        XCTAssertGreaterThan(
            boosted, cut * 1.5,
            "a 12 dB shelf boost should carry more energy than a 12 dB cut: \(boosted) vs \(cut)"
        )
    }

    /// The chorus control, measured as a difference from the same patch with the stage bypassed.
    func testThePanelsChorusEditChangesTheWetCopy() {
        let model = makeModel()
        model.updateEffects { $0 = EffectsSettings() }
        let dry = render(model.patch, blocks: 40)

        model.updateEffects {
            $0.chorus = ChorusSettings(enabled: true, mix: 0.5, rate: 3.5, depth: 1)
        }
        let wet = render(model.patch, blocks: 40)

        XCTAssertGreaterThan(
            largestDifference(dry.left, wet.left), 1e-3,
            "the panel's chorus edit changed nothing in the rendered samples"
        )
    }

    /// The two delay taps as the panel exposes them: different times must not render the same on
    /// both sides, and equal times must bring the sides back together.
    func testThePanelsTwoDelayTapsAreMeasuredAgainstEachOther() {
        let model = makeModel()
        model.updateEffects {
            $0 = EffectsSettings(
                delay: DelaySettings(
                    enabled: true, mix: 0.6, leftTime: 0.08, rightTime: 0.24, feedback: 0.5
                )
            )
        }
        let spread = render(model.patch)
        let apart = largestDifference(spread.left, spread.right)

        model.updateEffects { $0.delay.rightTime = 0.08 }
        let matched = render(model.patch)
        let together = largestDifference(matched.left, matched.right)

        XCTAssertGreaterThan(
            apart, 1e-3,
            "two different tap times should not render the same on both sides"
        )
        XCTAssertLessThan(
            together, apart * 0.5,
            "with both taps equal the sides should be far closer: \(together) vs \(apart)"
        )
    }

    /// The reverb mix, measured after the note is released: the wet tail has to outlast the dry
    /// release the engine applies on its own.
    func testThePanelsReverbTailOutlivesTheDryRelease() {
        let model = makeModel()
        model.updateEffects { $0 = EffectsSettings() }
        let dry = render(model.patch, blocks: 80, releaseAfter: 20)

        model.updateEffects {
            $0.reverb = ReverbSettings(enabled: true, mix: 0.6, decay: 0.85, damping: 0.15)
        }
        let wet = render(model.patch, blocks: 80, releaseAfter: 20)

        let window = (70 * block)..<(80 * block)
        let dryTail = rms(dry.left[window])
        let wetTail = rms(wet.left[window])

        XCTAssertGreaterThan(wetTail, 1e-4, "the tail should still carry signal")
        XCTAssertGreaterThan(
            wetTail, dryTail * 1.5,
            "the wet tail should outlast the dry release: wet \(wetTail), dry \(dryTail)"
        )
    }

    /// The live-edit contract the panel depends on: changing an effect under a held chord changes
    /// the sound without releasing the voice.
    func testThePanelEditUnderAHeldChordDoesNotReleaseTheVoice() {
        let model = makeModel()
        model.updateEffects { $0 = EffectsSettings() }

        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: model.patch.layers)
        engine.setPatch(model.patch)
        engine.noteOn(note: 60, velocity: 110)
        advance(engine, blocks: 6)

        let sounding = engine.voiceCount
        XCTAssertGreaterThan(sounding, 0, "the note has to be sounding for this to mean anything")

        model.updateEffects {
            $0.chorus = ChorusSettings(enabled: true, mix: 0.5, rate: 4, depth: 1)
        }
        engine.setPatch(model.patch, releasingVoices: false)
        advance(engine, blocks: 6)

        XCTAssertEqual(
            engine.voiceCount, sounding,
            "a live edit must not release the held chord"
        )
    }
}
