import Darwin
import XCTest
@testable import SundayKeysCore

/// The stereo half of the chain: an EQ whose three sections can be measured one at
/// a time, two delay taps with their own times, and a device path that carries both
/// channels through the effects.
final class EffectsStereoTests: XCTestCase {
    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        for sample in samples {
            value = max(value, abs(sample))
        }
        return value
    }

    private func loudestIndex(_ samples: [Float]) -> Int {
        var best = 0
        var bestValue: Float = 0
        for index in samples.indices {
            let magnitude = abs(samples[index])
            if magnitude > bestValue {
                bestValue = magnitude
                best = index
            }
        }
        return best
    }

    private func around(_ samples: [Float], _ center: Int) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        var index = max(0, center - 4)
        let end = min(samples.count - 1, center + 4)
        while index <= end {
            value = max(value, abs(samples[index]))
            index += 1
        }
        return value
    }

    /// Runs a sine through a fresh EQ and returns its level relative to unity.
    private func ratio(frequency: Double, configure: (inout EQSettings) -> Void) -> Float {
        let eq = EQProcessor(sampleRate: 48_000)
        var settings = EQSettings()
        settings.enabled = true
        configure(&settings)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        var sum: Float = 0
        var count = 0

        for block in 0..<30 {
            for index in 0..<left.count {
                let position = Double(block * left.count + index)
                let sample = Float(sin(position * 2.0 * Double.pi * frequency / 48_000.0)) * 0.5
                left[index] = sample
                right[index] = sample
            }

            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    eq.process(
                        into: leftPointer,
                        and: rightPointer,
                        frameCount: leftPointer.count,
                        settings: settings
                    )
                }
            }

            if block >= 10 {
                for sample in left {
                    sum += sample * sample
                    count += 1
                }
            }
        }

        let measured = sqrt(sum / Float(max(1, count)))
        let reference = Float(0.5 / 1.41421356)
        return measured / reference
    }

    func testFlatEQIsBitTransparentInBothChannels() {
        let eq = EQProcessor(sampleRate: 48_000)
        var settings = EQSettings()
        settings.enabled = true

        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        for index in 0..<left.count {
            left[index] = Float(index % 13) / 13 - 0.5
            right[index] = Float(index % 7) / 7 - 0.5
        }
        let expectedLeft = left
        let expectedRight = right

        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                eq.process(into: leftPointer, and: rightPointer, frameCount: leftPointer.count, settings: settings)
            }
        }

        XCTAssertEqual(left, expectedLeft)
        XCTAssertEqual(right, expectedRight)
    }

    func testEachEQSectionMovesOnlyItsOwnRange() {
        XCTAssertGreaterThan(ratio(frequency: 60) { $0.lowGain = 12 }, 2.5)
        XCTAssertGreaterThan(ratio(frequency: 1_000) { $0.midGain = 12 }, 2.5)
        XCTAssertGreaterThan(ratio(frequency: 6_000) { $0.highGain = 12 }, 1.4)
        XCTAssertLessThan(ratio(frequency: 1_000) { $0.midGain = -12 }, 0.5)

        XCTAssertEqual(ratio(frequency: 8_000) { $0.lowGain = 12 }, 1, accuracy: 0.1)
        XCTAssertEqual(ratio(frequency: 60) { $0.highGain = 12 }, 1, accuracy: 0.1)
        XCTAssertEqual(ratio(frequency: 60) { $0.midGain = 12 }, 1, accuracy: 0.1)
    }

    private func delayRun(
        channel: EffectChannel,
        leftTime: Float,
        rightTime: Float,
        feedback: Float,
        blocks: Int
    ) -> [Float] {
        let chain = EffectChain(sampleRate: 48_000, channel: channel)
        var settings = EffectsSettings()
        settings.delay.enabled = true
        settings.delay.mix = 1
        settings.delay.feedback = feedback
        settings.delay.leftTime = leftTime
        settings.delay.rightTime = rightTime
        chain.apply(settings: settings)

        var collected: [Float] = []
        var block = [Float](repeating: 0, count: 512)
        block[0] = 1

        for step in 0..<blocks {
            if step > 0 {
                for index in 0..<block.count {
                    block[index] = 0
                }
            }
            block.withUnsafeMutableBufferPointer { pointer in
                chain.process(into: pointer, frameCount: pointer.count)
            }
            collected.append(contentsOf: block)
        }
        return collected
    }

    func testDelayTapsAreIndependentPerSide() {
        let left = delayRun(channel: .left, leftTime: 0.05, rightTime: 0.25, feedback: 0, blocks: 40)
        let right = delayRun(channel: .right, leftTime: 0.05, rightTime: 0.25, feedback: 0, blocks: 40)

        let leftPeak = loudestIndex(left)
        let rightPeak = loudestIndex(right)

        XCTAssertTrue(abs(leftPeak - 2_400) <= 4, "left tap at 50 ms, measured \(leftPeak)")
        XCTAssertTrue(abs(rightPeak - 12_000) <= 4, "right tap at 250 ms, measured \(rightPeak)")
    }

    func testDelayRepeatsDecayOnBothSides() {
        let left = delayRun(channel: .left, leftTime: 0.1, rightTime: 0.2, feedback: 0.5, blocks: 130)
        let right = delayRun(channel: .right, leftTime: 0.1, rightTime: 0.2, feedback: 0.5, blocks: 130)

        XCTAssertGreaterThan(around(left, 4_800), 0.9)
        XCTAssertGreaterThan(around(right, 9_600), 0.9)
        XCTAssertEqual(around(left, 9_600), around(left, 4_800) * 0.5, accuracy: 0.06)
        XCTAssertEqual(around(right, 19_200), around(right, 9_600) * 0.5, accuracy: 0.06)
    }

    func testDelayStaysBoundedAtMaximumFeedback() {
        let chain = EffectChain(sampleRate: 48_000, channel: .left)
        var settings = EffectsSettings()
        settings.delay.enabled = true
        settings.delay.mix = 0.5
        settings.delay.feedback = 0.9
        settings.delay.leftTime = 0.03
        settings.delay.rightTime = 0.037
        chain.apply(settings: settings)

        var block = [Float](repeating: 0, count: 512)
        var worst: Float = 0

        for step in 0..<900 {
            for index in 0..<block.count {
                if step < 300 {
                    let position = Double(step * block.count + index)
                    block[index] = Float(sin(position * 2.0 * Double.pi * 330.0 / 48_000.0)) * 0.7
                } else {
                    block[index] = 0
                }
            }
            block.withUnsafeMutableBufferPointer { pointer in
                chain.process(into: pointer, frameCount: pointer.count)
            }
            XCTAssertTrue(peak(block).isFinite)
            worst = max(worst, peak(block))
        }

        XCTAssertLessThan(worst, 12, "0.9 feedback must still decay")
    }

    func testFullyBypassedChainsAreBitTransparent() {
        let leftChain = EffectChain(sampleRate: 48_000, channel: .left)
        let rightChain = EffectChain(sampleRate: 48_000, channel: .right)

        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        for index in 0..<left.count {
            left[index] = Float(index % 19) / 19 - 0.5
            right[index] = Float(index % 23) / 23 - 0.5
        }
        let expectedLeft = left
        let expectedRight = right

        for _ in 0..<4 {
            left.withUnsafeMutableBufferPointer { pointer in
                leftChain.process(into: pointer, frameCount: pointer.count)
            }
            right.withUnsafeMutableBufferPointer { pointer in
                rightChain.process(into: pointer, frameCount: pointer.count)
            }
        }

        XCTAssertEqual(left, expectedLeft)
        XCTAssertEqual(right, expectedRight)
    }

    func testChainStaysBoundedAcrossALongRun() {
        let leftChain = EffectChain(sampleRate: 48_000, channel: .left)
        let rightChain = EffectChain(sampleRate: 48_000, channel: .right)
        var settings = EffectsSettings()
        settings.eq.enabled = true
        settings.eq.lowGain = 6
        settings.eq.midGain = -4
        settings.eq.highGain = 6
        settings.chorus.enabled = true
        settings.chorus.mix = 0.5
        settings.chorus.depth = 1
        settings.delay.enabled = true
        settings.delay.mix = 0.5
        settings.delay.feedback = 0.7
        settings.delay.leftTime = 0.11
        settings.delay.rightTime = 0.17
        settings.reverb.enabled = true
        settings.reverb.mix = 0.6
        settings.reverb.decay = 0.85
        leftChain.apply(settings: settings)
        rightChain.apply(settings: settings)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        var worst: Float = 0

        for step in 0..<260 {
            for index in 0..<left.count {
                if step < 120 {
                    let position = Double(step * left.count + index)
                    let sample = Float(sin(position * 2.0 * Double.pi * 220.0 / 48_000.0)) * 0.7
                    left[index] = sample
                    right[index] = sample
                } else {
                    left[index] = 0
                    right[index] = 0
                }
            }

            left.withUnsafeMutableBufferPointer { pointer in
                leftChain.process(into: pointer, frameCount: pointer.count)
            }
            right.withUnsafeMutableBufferPointer { pointer in
                rightChain.process(into: pointer, frameCount: pointer.count)
            }

            XCTAssertTrue(peak(left).isFinite)
            XCTAssertTrue(peak(right).isFinite)
            worst = max(worst, max(peak(left), peak(right)))
        }

        XCTAssertLessThan(worst, 6)
    }

    private let frameCount = 512

    private func renderStereo(_ engine: RealtimeKeysoundEngine, blocks: Int) -> (left: [Float], right: [Float]) {
        var leftAll: [Float] = []
        var rightAll: [Float] = []
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)

        for _ in 0..<blocks {
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    for index in 0..<leftPointer.count {
                        leftPointer[index] = 0
                        rightPointer[index] = 0
                    }
                    engine.renderStereo(intoLeft: leftPointer, intoRight: rightPointer, frameCount: leftPointer.count)
                }
            }
            leftAll.append(contentsOf: left)
            rightAll.append(contentsOf: right)
        }

        return (leftAll, rightAll)
    }

    func testStereoEngineCarriesTheReverbTailInBothChannels() {
        var patch = Patch(name: "Verb", layers: KeyLayer.defaultPatch)
        patch.effects.reverb.enabled = true
        patch.effects.reverb.mix = 0.6
        patch.effects.reverb.decay = 0.6

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: 60, velocity: 110)
        _ = renderStereo(engine, blocks: 6)

        engine.noteOff(note: 60)
        let tail = renderStereo(engine, blocks: 40)

        XCTAssertEqual(engine.voiceCount, 0)
        XCTAssertGreaterThan(peak(Array(tail.left.suffix(frameCount))), 1e-5)
        XCTAssertGreaterThan(peak(Array(tail.right.suffix(frameCount))), 1e-5)
    }

    func testStereoEngineIsSilentBothSidesWhenTheChainIsDry() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)
        _ = renderStereo(engine, blocks: 6)

        engine.noteOff(note: 60)
        let tail = renderStereo(engine, blocks: 40)

        XCTAssertEqual(engine.voiceCount, 0)
        XCTAssertEqual(peak(Array(tail.left.suffix(frameCount))), 0)
        XCTAssertEqual(peak(Array(tail.right.suffix(frameCount))), 0)
    }

    func testBothDelayTapsSurviveTheBank() throws {
        var effects = EffectsSettings()
        effects.delay.enabled = true
        effects.delay.leftTime = 0.18
        effects.delay.rightTime = 0.27
        effects.delay.feedback = 0.42
        effects.eq.enabled = true
        effects.eq.midGain = 3.5

        let bank = PatchBank(patches: [Patch(name: "Wide", layers: KeyLayer.defaultPatch, effects: effects)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysStereoTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PatchStore(url: directory.appendingPathComponent("patches.json"))
        try store.save(bank)

        let loaded = try store.load()
        XCTAssertEqual(loaded.patches[0].effects.delay.leftTime, 0.18, accuracy: 1e-6)
        XCTAssertEqual(loaded.patches[0].effects.delay.rightTime, 0.27, accuracy: 1e-6)
        XCTAssertEqual(loaded.patches[0].effects.delay.feedback, 0.42, accuracy: 1e-6)
        XCTAssertEqual(loaded.patches[0].effects.eq.midGain, 3.5, accuracy: 1e-6)
    }

    func testRestoredSessionOpensThePatchWithItsEffects() {
        var wet = EffectsSettings()
        wet.reverb.enabled = true
        wet.reverb.mix = 0.4
        let sounding = Patch(name: "Wet", layers: KeyLayer.defaultPatch, effects: wet)
        let bypassed = Patch(name: "Dry", layers: KeyLayer.defaultPatch)
        let bank = PatchBank(patches: [bypassed, sounding])

        let restore = SessionScope.restore(
            memory: SessionMemory(lastPatchID: sounding.id),
            patches: bank.patches
        )

        XCTAssertTrue(restore.isRemembered)
        guard let id = restore.patchID, let index = bank.index(of: id) else {
            return XCTFail("the remembered patch has to resolve")
        }
        XCTAssertEqual(bank.patches[index].effects, wet)
        XCTAssertTrue(bank.patches[index].effects.reverb.enabled)
        XCTAssertTrue(bank.patches[0].effects.isDry)
    }

    func testDocumentWithOneDelayTimeFillsBothTaps() throws {
        let json = "{ \"enabled\": true, \"mix\": 0.4, \"time\": 0.5, \"feedback\": 0.2 }"
        let settings = try JSONDecoder().decode(DelaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.leftTime, 0.5, accuracy: 1e-6)
        XCTAssertEqual(settings.rightTime, 0.5, accuracy: 1e-6)
    }
}
