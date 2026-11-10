import Darwin
import XCTest
@testable import SundayKeysCore

/// DSP-level tests: each processor is driven directly with a known signal so the
/// measurement is of the processing itself, not of the synthesiser in front of it.
final class EffectsDSPTests: XCTestCase {
    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        var index = 0
        while index < samples.count {
            value = max(value, abs(samples[index]))
            index += 1
        }
        return value
    }

    private func peak(_ samples: [Float], around center: Int, radius: Int) -> Float {
        var value: Float = 0
        var index = max(0, center - radius)
        let end = min(samples.count - 1, center + radius)
        while index <= end {
            value = max(value, abs(samples[index]))
            index += 1
        }
        return value
    }

    private func energy(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples {
            sum += abs(sample)
        }
        return sum
    }

    private func clear(_ buffer: inout [Float]) {
        var index = 0
        while index < buffer.count {
            buffer[index] = 0
            index += 1
        }
    }

    // MARK: - Reverb

    /// The acceptance test for the reverb: after the input stops, something must
    /// still be sounding, it has to be quieter a second later, and it has to have
    /// died away completely a few seconds after that.
    func testReverbLeavesADecayingTailAfterTheInputStops() {
        let reverb = ReverbProcessor(sampleRate: 48_000)
        var settings = ReverbSettings()
        settings.enabled = true
        settings.mix = 0.6
        settings.decay = 0.7
        settings.damping = 0.3

        var block = [Float](repeating: 0, count: 512)
        var index = 0
        while index < 64 {
            block[index] = Float(sin(Double(index) * 0.37)) * 0.7
            index += 1
        }
        block.withUnsafeMutableBufferPointer { pointer in
            reverb.process(into: pointer, frameCount: pointer.count, settings: settings)
        }

        var early: Float = 0
        var later: Float = 0
        var final: [Float] = []

        var step = 0
        while step < 600 {
            clear(&block)
            block.withUnsafeMutableBufferPointer { pointer in
                reverb.process(into: pointer, frameCount: pointer.count, settings: settings)
            }
            let level = energy(block)
            if step < 10 {
                early = max(early, level)
            }
            if step >= 60 && step < 70 {
                later = max(later, level)
            }
            if step >= 590 {
                final.append(contentsOf: block)
            }
            step += 1
        }

        XCTAssertGreaterThan(early, 1e-4, "a burst has to leave a tail behind it")
        XCTAssertGreaterThan(later, 0, "the tail is still audible a second later")
        XCTAssertLessThan(later, early, "the tail has to decay")
        XCTAssertLessThan(peak(final), 1e-5, "seven seconds of tail has died away")
    }

    func testBypassingReverbDropsItsTail() {
        let reverb = ReverbProcessor(sampleRate: 48_000)
        var settings = ReverbSettings()
        settings.enabled = true
        settings.mix = 0.8
        settings.decay = 0.8

        var block = [Float](repeating: 0, count: 512)
        var index = 0
        while index < 32 {
            block[index] = 0.6
            index += 1
        }
        block.withUnsafeMutableBufferPointer { pointer in
            reverb.process(into: pointer, frameCount: pointer.count, settings: settings)
        }

        var step = 0
        while step < 6 {
            clear(&block)
            block.withUnsafeMutableBufferPointer { pointer in
                reverb.process(into: pointer, frameCount: pointer.count, settings: settings)
            }
            step += 1
        }
        XCTAssertGreaterThan(peak(block), 1e-5, "there is a tail to drop")

        var bypassed = settings
        bypassed.enabled = false
        clear(&block)
        block.withUnsafeMutableBufferPointer { pointer in
            reverb.process(into: pointer, frameCount: pointer.count, settings: bypassed)
        }

        XCTAssertEqual(peak(block), 0, "a bypassed reverb must not leak its tail")
    }

    // MARK: - Delay

    /// A single impulse through a fully wet 100 ms delay has to reappear at exactly
    /// 4800 samples, with nothing in front of it.
    func testDelayRepeatsAtTheConfiguredInterval() {
        let delay = DelayProcessor(sampleRate: 48_000)
        var settings = DelaySettings()
        settings.enabled = true
        settings.mix = 1
        settings.time = 0.1
        settings.feedback = 0

        var collected: [Float] = []
        var block = [Float](repeating: 0, count: 512)
        block[0] = 1

        var step = 0
        while step < 30 {
            if step > 0 {
                clear(&block)
            }
            block.withUnsafeMutableBufferPointer { pointer in
                delay.process(into: pointer, frameCount: pointer.count, settings: settings)
            }
            collected.append(contentsOf: block)
            step += 1
        }

        var loudest = 0
        var loudestValue: Float = 0
        var index = 0
        while index < collected.count {
            let magnitude = abs(collected[index])
            if magnitude > loudestValue {
                loudestValue = magnitude
                loudest = index
            }
            index += 1
        }

        XCTAssertTrue(abs(loudest - 4_800) <= 2, "0.1 s at 48 kHz is 4800 samples, measured \(loudest)")
        XCTAssertGreaterThan(loudestValue, 0.9, "the echo is as loud as the impulse")
        XCTAssertLessThan(abs(collected[4_000]), 1e-4, "nothing arrives before the delay time")
    }

    func testDelayFeedbackProducesRepeatsThatDecay() {
        let delay = DelayProcessor(sampleRate: 48_000)
        var settings = DelaySettings()
        settings.enabled = true
        settings.mix = 1
        settings.time = 0.1
        settings.feedback = 0.5

        var collected: [Float] = []
        var block = [Float](repeating: 0, count: 512)
        block[0] = 1

        var step = 0
        while step < 60 {
            if step > 0 {
                clear(&block)
            }
            block.withUnsafeMutableBufferPointer { pointer in
                delay.process(into: pointer, frameCount: pointer.count, settings: settings)
            }
            collected.append(contentsOf: block)
            step += 1
        }

        let first = peak(collected, around: 4_800, radius: 4)
        let second = peak(collected, around: 9_600, radius: 4)
        let third = peak(collected, around: 14_400, radius: 4)

        XCTAssertGreaterThan(first, 0.9)
        XCTAssertEqual(second, first * 0.5, accuracy: 0.05, "each repeat is scaled by the feedback")
        XCTAssertLessThan(third, second)
        XCTAssertGreaterThan(third, 0.1, "and there is a third repeat")
    }

    // MARK: - Chorus

    /// A steady tone through a swept delay must produce a difference signal whose
    /// level moves: that is what modulation means here.
    func testChorusModulatesTheWetPath() {
        let chorus = ChorusProcessor(sampleRate: 48_000)
        var settings = ChorusSettings()
        settings.enabled = true
        settings.mix = 0.5
        settings.rate = 2
        settings.depth = 1

        var buffer = [Float](repeating: 0, count: 512)
        var dry = [Float](repeating: 0, count: 512)
        var windows: [Float] = []

        var block = 0
        while block < 60 {
            var index = 0
            while index < buffer.count {
                let position = Double(block * buffer.count + index)
                let sample = Float(sin(position * 2.0 * Double.pi * 440.0 / 48_000.0)) * 0.5
                buffer[index] = sample
                dry[index] = sample
                index += 1
            }

            buffer.withUnsafeMutableBufferPointer { pointer in
                chorus.process(into: pointer, frameCount: pointer.count, settings: settings)
            }

            var sum: Float = 0
            index = 0
            while index < buffer.count {
                let difference = buffer[index] - dry[index]
                sum += difference * difference
                index += 1
            }
            if block >= 3 {
                windows.append(sum)
            }
            block += 1
        }

        let largest = windows.max() ?? 0
        let smallest = windows.min() ?? 0

        XCTAssertGreaterThan(largest, 1e-3, "the wet copy is present")
        XCTAssertGreaterThan(largest, smallest * 1.5, "and it moves as the delay sweeps")
    }

    // MARK: - EQ

    func testEQIsBitTransparentAtUnityGain() {
        let eq = EQProcessor(sampleRate: 48_000)
        var settings = EQSettings()
        settings.enabled = true
        settings.lowGain = 0
        settings.highGain = 0

        var buffer = [Float](repeating: 0, count: 256)
        var index = 0
        while index < buffer.count {
            buffer[index] = Float(sin(Double(index) * 0.11)) * 0.6
            index += 1
        }
        let expected = buffer

        buffer.withUnsafeMutableBufferPointer { pointer in
            eq.process(into: pointer, frameCount: pointer.count, settings: settings)
        }

        index = 0
        while index < buffer.count {
            XCTAssertEqual(buffer[index], expected[index], accuracy: 1e-6)
            index += 1
        }
    }

    func testEQBandsLiftAndCutTheirBand() {
        let boosted = ratioThroughFreshEQ(frequency: 60, lowGain: 12, highGain: 0)
        XCTAssertGreaterThan(boosted, 2.5, "60 Hz belongs to the low band")

        let cut = ratioThroughFreshEQ(frequency: 6_000, lowGain: 0, highGain: -12)
        XCTAssertLessThan(cut, 0.5, "6 kHz belongs to the high band")
    }

    private func ratioThroughFreshEQ(frequency: Double, lowGain: Float, highGain: Float) -> Float {
        let eq = EQProcessor(sampleRate: 48_000)
        var settings = EQSettings()
        settings.enabled = true
        settings.lowGain = lowGain
        settings.highGain = highGain

        var buffer = [Float](repeating: 0, count: 512)
        var sum: Float = 0
        var count = 0

        var block = 0
        while block < 30 {
            var index = 0
            while index < buffer.count {
                let position = Double(block * buffer.count + index)
                buffer[index] = Float(sin(position * 2.0 * Double.pi * frequency / 48_000.0)) * 0.5
                index += 1
            }

            buffer.withUnsafeMutableBufferPointer { pointer in
                eq.process(into: pointer, frameCount: pointer.count, settings: settings)
            }

            if block >= 10 {
                for sample in buffer {
                    sum += sample * sample
                    count += 1
                }
            }
            block += 1
        }

        let measured = sqrt(sum / Float(max(1, count)))
        let reference = Float(0.5 / 1.41421356)
        return measured / reference
    }

    // MARK: - Chain

    func testFullyBypassedChainIsBitTransparent() {
        let chain = EffectChain(sampleRate: 48_000)
        var block = [Float](repeating: 0, count: 256)
        var index = 0
        while index < block.count {
            block[index] = Float(index % 17) / 17 - 0.5
            index += 1
        }
        let expected = block

        var step = 0
        while step < 4 {
            block.withUnsafeMutableBufferPointer { pointer in
                chain.process(into: pointer, frameCount: pointer.count)
            }
            step += 1
        }

        XCTAssertEqual(block, expected, "a bypassed chain must not touch a single sample")
    }

    func testTheWholeChainStaysBoundedAndDecays() {
        let chain = EffectChain(sampleRate: 48_000)
        var settings = EffectsSettings()
        settings.eq.enabled = true
        settings.eq.lowGain = 6
        settings.eq.highGain = 6
        settings.chorus.enabled = true
        settings.chorus.mix = 0.5
        settings.chorus.depth = 1
        settings.delay.enabled = true
        settings.delay.mix = 0.5
        settings.delay.feedback = 0.6
        settings.reverb.enabled = true
        settings.reverb.mix = 0.7
        settings.reverb.decay = 0.9
        chain.apply(settings: settings)

        var buffer = [Float](repeating: 0, count: 512)
        var worst: Float = 0
        var duringInput: Float = 0
        var afterInput: Float = 0

        var step = 0
        while step < 220 {
            var index = 0
            while index < buffer.count {
                if step < 100 {
                    let position = Double(step * buffer.count + index)
                    buffer[index] = Float(sin(position * 2.0 * Double.pi * 220.0 / 48_000.0)) * 0.7
                } else {
                    buffer[index] = 0
                }
                index += 1
            }

            buffer.withUnsafeMutableBufferPointer { pointer in
                chain.process(into: pointer, frameCount: pointer.count)
            }

            let level = peak(buffer)
            XCTAssertTrue(level.isFinite, "no sample may become NaN or infinite")
            worst = max(worst, level)
            if step == 99 {
                duringInput = level
            }
            if step >= 215 {
                afterInput = max(afterInput, level)
            }
            step += 1
        }

        XCTAssertLessThan(worst, 6, "the chain must not run away")
        XCTAssertLessThan(afterInput, duringInput, "the chain is quieter two and a half seconds after the input stops")
    }
}

/// Engine-level tests: the effects have to be in the real per-patch path, and a
/// settings change must behave like an edit rather than like a patch switch.
final class EffectsIntegrationTests: XCTestCase {
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

    func testEngineRendersTheReverbTailAfterTheVoicesAreFreed() {
        var patch = Patch(name: "Verb", layers: KeyLayer.defaultPatch)
        patch.effects.reverb.enabled = true
        patch.effects.reverb.mix = 0.6
        patch.effects.reverb.decay = 0.6

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 6)

        engine.noteOff(note: 60)
        let tail = render(engine, blocks: 40)

        XCTAssertEqual(engine.voiceCount, 0, "every voice is free again")
        XCTAssertGreaterThan(
            peak(Array(tail.suffix(frameCount))),
            1e-5,
            "but the patch's reverb is still ringing, which only happens inside the render path"
        )
    }

    func testDryEngineFallsSilentAfterTheRelease() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 6)

        engine.noteOff(note: 60)
        let tail = render(engine, blocks: 40)

        XCTAssertEqual(engine.voiceCount, 0)
        XCTAssertEqual(peak(Array(tail.suffix(frameCount))), 0, "with the chain bypassed there is nothing left to hear")
    }

    func testChangingAnEffectOnAHeldNoteKeepsItSounding() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 2)
        XCTAssertEqual(engine.voiceCount, 1)

        var patch = engine.patch
        patch.effects.reverb.enabled = true
        patch.effects.reverb.mix = 0.5
        patch.effects.delay.enabled = true
        patch.effects.delay.mix = 0.4
        patch.effects.delay.time = 0.25
        engine.setPatch(patch, releasingVoices: false)

        var quietBlocks = 0
        var step = 0
        while step < 12 {
            let samples = render(engine, blocks: 1)
            if peak(samples) < 1e-4 {
                quietBlocks += 1
            }
            step += 1
        }

        XCTAssertEqual(engine.voiceCount, 1, "the note under the player's hands must survive the edit")
        XCTAssertEqual(quietBlocks, 0, "and must not fall silent while the effect changes")
    }

    func testSwitchingPatchesReplacesTheEffectSettings() {
        var wet = Patch(name: "Wet", layers: KeyLayer.defaultPatch)
        wet.effects.reverb.enabled = true
        wet.effects.reverb.mix = 0.7
        wet.effects.reverb.decay = 0.7

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: wet.layers)
        engine.setPatch(wet)
        engine.noteOn(note: 60, velocity: 110)
        _ = render(engine, blocks: 6)
        engine.noteOff(note: 60)
        let wetTail = render(engine, blocks: 24)
        XCTAssertGreaterThan(peak(Array(wetTail.suffix(frameCount))), 1e-5)

        let dry = Patch(name: "Dry", layers: KeyLayer.defaultPatch)
        engine.setPatch(dry)
        _ = render(engine, blocks: 24)

        XCTAssertEqual(peak(render(engine, blocks: 2)), 0, "the next patch must not inherit the previous tail")
        XCTAssertTrue(engine.patch.effects.isDry)
    }

    func testEffectUpdatesWhileAnotherThreadRendersStayConsistent() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, queueCapacity: 4096)
        engine.noteOn(note: 60, velocity: 110)

        let rendered = expectation(description: "render loop finished")
        DispatchQueue(label: "sundaykeys.effects.render").async {
            var buffer = [Float](repeating: 0, count: 256)
            var step = 0
            while step < 400 {
                buffer.withUnsafeMutableBufferPointer { pointer in
                    var index = 0
                    while index < pointer.count {
                        pointer[index] = 0
                        index += 1
                    }
                    engine.render(into: pointer, frameCount: pointer.count)
                }
                step += 1
            }
            rendered.fulfill()
        }

        var step = 0
        while step < 300 {
            var settings = EffectsSettings()
            settings.reverb.enabled = step % 2 == 0
            settings.reverb.mix = 0.5
            settings.delay.enabled = step % 3 == 0
            settings.chorus.enabled = step % 5 == 0
            settings.eq.enabled = true
            settings.eq.lowGain = Float(step % 7) - 3
            engine.setEffects(settings)
            step += 1
        }

        wait(for: [rendered], timeout: 60)

        engine.allNotesOff()
        _ = render(engine, blocks: 48)
        XCTAssertEqual(engine.voiceCount, 0)
    }
}

/// Persistence: effect settings are part of the patch, so they have to survive the
/// bank exactly like layers do, and a bank written before they existed must load.
final class EffectsPersistenceTests: XCTestCase {
    private func temporaryStore() -> PatchStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysEffectTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PatchStore(url: directory.appendingPathComponent("patches.json"))
    }

    private func sampleEffects() -> EffectsSettings {
        var effects = EffectsSettings()
        effects.eq.enabled = true
        effects.eq.lowGain = -3.5
        effects.eq.highGain = 2.25
        effects.chorus.enabled = true
        effects.chorus.mix = 0.42
        effects.chorus.rate = 1.7
        effects.chorus.depth = 0.8
        effects.delay.enabled = true
        effects.delay.time = 0.22
        effects.delay.feedback = 0.4
        effects.reverb.enabled = true
        effects.reverb.mix = 0.31
        effects.reverb.decay = 0.66
        effects.reverb.damping = 0.2
        return effects
    }

    func testEffectSettingsRoundTripThroughTheBank() throws {
        let effects = sampleEffects()
        let bank = PatchBank(patches: [
            Patch(name: "Wet", layers: KeyLayer.defaultPatch, effects: effects),
            Patch(name: "Dry", layers: KeyLayer.defaultPatch),
        ])

        let store = temporaryStore()
        try store.save(bank)
        let loaded = try store.load()

        XCTAssertEqual(loaded, bank)
        XCTAssertEqual(loaded.patches[0].effects, effects)
        XCTAssertEqual(loaded.patches[0].effects.delay.time, 0.22, accuracy: 1e-6)
        XCTAssertEqual(loaded.patches[0].effects.reverb.decay, 0.66, accuracy: 1e-6)
        XCTAssertTrue(loaded.patches[0].effects.reverb.enabled)
        XCTAssertTrue(loaded.patches[1].effects.isDry)
    }

    func testBankWrittenBeforeEffectsExistedLoadsDry() throws {
        let json = """
        {
          "version": 1,
          "patches": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Legacy",
              "layers": [
                { "id": 0, "name": "Keys", "range": { "lower": 36, "upper": 96 }, "transpose": 0, "gain": 0.8, "timbre": "keys", "enabled": true }
              ]
            }
          ]
        }
        """

        let bank = try JSONDecoder().decode(PatchBank.self, from: Data(json.utf8))

        XCTAssertEqual(bank.patches.count, 1)
        XCTAssertEqual(bank.patches[0].layers.count, 1)
        XCTAssertTrue(bank.patches[0].effects.isDry, "an old bank must not invent reverb")
        XCTAssertEqual(bank.patches[0].effects, EffectsSettings())
    }

    func testStarterPatchShipsWithReverbEngaged() {
        XCTAssertTrue(Patch.starter.effects.reverb.enabled)
        XCTAssertFalse(Patch.starter.effects.reverb.mix == 0)
        XCTAssertFalse(Patch.starter.effects.chorus.enabled)
        XCTAssertFalse(Patch.starter.effects.delay.enabled)
    }
}
