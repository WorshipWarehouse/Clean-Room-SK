import XCTest
@testable import SundayKeysCore

/// The click is measured, not described: every case here renders frames and looks at
/// where the sound actually is.
final class MetronomeTests: XCTestCase {
    private let rate: Double = 48_000

    /// Renders `frames` frames in blocks, the way the audio callback does, and returns
    /// the buffer it filled. `atEachBlock` runs before a block is rendered, which is
    /// where a block boundary can change the settings.
    private func render(
        _ metronome: Metronome,
        frames: Int,
        blockSize: Int = 512,
        atEachBlock: ((Int) -> Void)? = nil
    ) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < frames {
                let count = min(blockSize, frames - offset)
                let slice = UnsafeMutableBufferPointer(start: base + offset, count: count)
                for index in 0..<count {
                    slice[index] = 0
                }
                atEachBlock?(offset)
                metronome.render(into: slice, frameCount: count)
                offset += count
            }
        }
        return output
    }

    private func render(_ engine: RealtimeKeysoundEngine, frames: Int, blockSize: Int = 512) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < frames {
                let count = min(blockSize, frames - offset)
                let slice = UnsafeMutableBufferPointer(start: base + offset, count: count)
                for index in 0..<count {
                    slice[index] = 0
                }
                engine.render(into: slice, frameCount: count)
                offset += count
            }
        }
        return output
    }

    /// The first frame of each run of sound, separated by at least `quiet` silent
    /// frames, so one click's decay cannot be read as the next beat.
    private func onsets(in samples: [Float], threshold: Float = 0.01, quiet: Int = 480) -> [Int] {
        var result: [Int] = []
        var lastLoud = -quiet - 1
        for index in samples.indices where abs(samples[index]) > threshold {
            if index - lastLoud > quiet {
                result.append(index)
            }
            lastLoud = index
        }
        return result
    }

    private func peak(_ samples: [Float], at index: Int) -> Float {
        abs(samples[index])
    }

    func testTheClickLandsOnEveryBeat() {
        let metronome = Metronome(sampleRate: rate)
        metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        let samples = render(metronome, frames: 97_000)

        XCTAssertEqual(onsets(in: samples), [0, 24_000, 48_000, 72_000, 96_000])
    }

    func testTheDownbeatIsLouderAndComesRoundAgain() {
        let metronome = Metronome(sampleRate: rate)
        metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        let samples = render(metronome, frames: 97_000)
        let peaks = [0, 24_000, 48_000, 72_000, 96_000].map { peak(samples, at: $0) }

        XCTAssertGreaterThan(peaks[0], peaks[1] * 1.2, "the first beat of the bar is the accent")
        XCTAssertEqual(peaks[1], peaks[2], accuracy: 1e-5, "the beats inside the bar sound alike")
        XCTAssertEqual(peaks[2], peaks[3], accuracy: 1e-5)
        XCTAssertEqual(peaks[0], peaks[4], accuracy: 1e-5, "the accent returns at the next downbeat")
    }

    func testABarOfThreeAccentsEveryThirdBeat() {
        let metronome = Metronome(sampleRate: rate)
        metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 3))

        let samples = render(metronome, frames: 97_000)
        let peaks = [0, 24_000, 48_000, 72_000, 96_000].map { peak(samples, at: $0) }

        XCTAssertGreaterThan(peaks[0], peaks[1])
        XCTAssertGreaterThan(peaks[1], 0)
        XCTAssertEqual(peaks[0], peaks[3], accuracy: 1e-5, "the fourth beat starts the next bar")
        XCTAssertGreaterThan(peaks[3], peaks[4])
    }

    func testAStoppedClickIsSilent() {
        let metronome = Metronome(sampleRate: rate)

        let samples = render(metronome, frames: 48_000)

        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "a click that was never switched on must not write a sample")
        XCTAssertEqual(metronome.clickCount, 0)
    }

    func testATempoChangeTakesEffectAfterTheBeatAlreadyOnItsWay() {
        let metronome = Metronome(sampleRate: rate)
        metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        // The tempo changes on the block that starts exactly on the second beat, so the
        // beat that was already due still lands and the interval after it is the 60 bpm
        // one: 48,000 frames, not 24,000.
        let samples = render(metronome, frames: 73_000, blockSize: 1_000) { offset in
            if offset == 24_000 {
                metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 60, beatsPerBar: 4))
            }
        }

        XCTAssertEqual(onsets(in: samples), [0, 24_000, 72_000])
    }

    func testStoppingLetsTheClickFinishAndStopsScheduling() {
        let metronome = Metronome(sampleRate: rate)
        metronome.publish(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        let samples = render(metronome, frames: 30_000, blockSize: 100) { offset in
            if offset == 1_000 {
                metronome.publish(MetronomeSettings(enabled: false, beatsPerMinute: 120, beatsPerBar: 4))
            }
        }

        XCTAssertEqual(onsets(in: samples), [0], "one click started before the stop and none after it")
        let tail = samples[1_000...2_000].reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(tail, 0, "the click that had already started is allowed to ring out")
        XCTAssertTrue(
            samples[3_000...5_000].allSatisfy { $0 == 0 },
            "and it ends on its own envelope rather than being cut"
        )
    }

    func testOutOfRangeSettingsClamp() {
        XCTAssertEqual(MetronomeSettings(beatsPerMinute: 10).beatsPerMinute, 20)
        XCTAssertEqual(MetronomeSettings(beatsPerMinute: 999).beatsPerMinute, 300)
        XCTAssertEqual(MetronomeSettings(beatsPerMinute: Double.nan).beatsPerMinute, 120)
        XCTAssertEqual(MetronomeSettings(beatsPerBar: 0).beatsPerBar, 1)
        XCTAssertEqual(MetronomeSettings(beatsPerBar: 99).beatsPerBar, 16)
    }

    func testTheClickBypassesTheEffectChain() {
        let engine = RealtimeKeysoundEngine(sampleRate: rate)
        var patch = Patch.starter
        patch.effects.delay = DelaySettings(enabled: true, mix: 1, time: 0.1, feedback: 0.8)
        engine.setPatch(patch)
        engine.setMetronome(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        let samples = render(engine, frames: 30_000)

        // A 100 ms delay at 48 kHz repeats every 4,800 frames. If the click went through
        // the chain those repeats would be onsets; a cue is not part of the patch.
        XCTAssertEqual(onsets(in: samples), [0, 24_000])
    }

    func testTheClickLeavesTheVoicesAlone() {
        let engine = RealtimeKeysoundEngine(sampleRate: rate)
        engine.setMetronome(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))
        engine.noteOn(note: 60, velocity: 100)

        _ = render(engine, frames: 12_000)
        XCTAssertEqual(engine.voiceCount, 1, "the click is added beside the voices, not through them")

        _ = render(engine, frames: 12_000)
        XCTAssertEqual(engine.voiceCount, 1, "and it never borrows a voice to sound")

        engine.setMetronome(MetronomeSettings(enabled: false))
        _ = render(engine, frames: 6_000)
        XCTAssertEqual(engine.voiceCount, 1, "stopping the click does not release the note")
    }

    func testTheClickCountFollowsTheBeats() {
        let engine = RealtimeKeysoundEngine(sampleRate: rate)
        engine.setMetronome(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))

        _ = render(engine, frames: 97_000)

        XCTAssertEqual(engine.clickCount, 5, "five beats in one second at 120 bpm, counted on the render thread")
    }
}
