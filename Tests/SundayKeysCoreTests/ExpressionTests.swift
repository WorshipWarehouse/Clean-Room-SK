import XCTest
@testable import SundayKeysCore

/// The wire-to-engine conversion, asserted at its ends and its centre.
final class ExpressionRangeTests: XCTestCase {
    func testTheBendCentreIsExactlyNeutral() {
        XCTAssertEqual(ExpressionRange.normalisedBend(8_192), 0)
    }

    func testABendReachesBothEndsOfTheRange() {
        XCTAssertEqual(ExpressionRange.normalisedBend(16_383), 1)
        XCTAssertEqual(ExpressionRange.normalisedBend(0), -1)
    }

    func testABendPastTheWireClamps() {
        XCTAssertEqual(ExpressionRange.normalisedBend(40_000), 1)
    }

    func testPressureIsSevenBitAndClamped() {
        XCTAssertEqual(ExpressionRange.normalisedPressure(0), 0)
        XCTAssertEqual(ExpressionRange.normalisedPressure(64), 64.0 / 127.0, accuracy: 0.0001)
        XCTAssertEqual(ExpressionRange.normalisedPressure(127), 1)
        XCTAssertEqual(ExpressionRange.normalisedPressure(200), 1)
    }
}

/// What a bend and a pressure do to the rendered sound, measured from the
/// samples the instrument writes rather than from the commands it received.
final class RenderExpressionTests: XCTestCase {
    private func instrument() -> PolyphonicInstrument {
        PolyphonicInstrument(sampleRate: 48_000, layers: KeyLayer.defaultPatch)
    }

    private func render(_ instrument: PolyphonicInstrument, frames: Int) -> [Float] {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0)
        defer {
            buffer.deinitialize()
            buffer.deallocate()
        }
        instrument.render(into: buffer, frameCount: frames)
        return Array(buffer)
    }

    private func sounding(_ instrument: PolyphonicInstrument) {
        instrument.apply(RenderCommand(kind: .noteOn, layer: 0, note: 69, velocity: 0.9))
    }

    private func crossings(_ samples: [Float]) -> Int {
        var count = 0
        var previous: Float = 0
        for sample in samples {
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
                count += 1
            }
            previous = sample
        }
        return count
    }

    private func peak(_ samples: [Float]) -> Float {
        var highest: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > highest {
                highest = magnitude
            }
        }
        return highest
    }

    func testANeutralBendLeavesTheRenderUntouched() {
        let plain = instrument()
        sounding(plain)
        let neutral = instrument()
        sounding(neutral)
        neutral.apply(RenderCommand(kind: .pitchBend, velocity: 0))
        XCTAssertEqual(render(plain, frames: 4_800), render(neutral, frames: 4_800))
    }

    func testABendUpRaisesTheNumberOfCrossings() {
        let plain = instrument()
        sounding(plain)
        let plainCount = crossings(render(plain, frames: 4_800))

        let bent = instrument()
        sounding(bent)
        bent.apply(RenderCommand(kind: .pitchBend, velocity: 1))
        let bentCount = crossings(render(bent, frames: 4_800))

        XCTAssertGreaterThanOrEqual(bentCount, plainCount + 8)
    }

    func testABendDownLowersTheNumberOfCrossings() {
        let plain = instrument()
        sounding(plain)
        let plainCount = crossings(render(plain, frames: 4_800))

        let bent = instrument()
        sounding(bent)
        bent.apply(RenderCommand(kind: .pitchBend, velocity: -1))
        let bentCount = crossings(render(bent, frames: 4_800))

        XCTAssertLessThanOrEqual(bentCount, plainCount - 8)
    }

    func testABendPastTheRangeClampsToTheFullBend() {
        let full = instrument()
        sounding(full)
        full.apply(RenderCommand(kind: .pitchBend, velocity: 1))
        let fullSamples = render(full, frames: 2_400)

        let past = instrument()
        sounding(past)
        past.apply(RenderCommand(kind: .pitchBend, velocity: 2))
        XCTAssertEqual(render(past, frames: 2_400), fullSamples)
    }

    func testZeroPressureIsExactlyNeutral() {
        let plain = instrument()
        sounding(plain)
        let quiet = instrument()
        sounding(quiet)
        quiet.apply(RenderCommand(kind: .channelPressure, velocity: 0))
        XCTAssertEqual(render(plain, frames: 2_400), render(quiet, frames: 2_400))
    }

    func testFullPressureLiftsThePeakByTheDocumentedFactor() {
        let plain = instrument()
        sounding(plain)
        let plainPeak = peak(render(plain, frames: 4_800))

        let loud = instrument()
        sounding(loud)
        loud.apply(RenderCommand(kind: .channelPressure, velocity: 1))
        let loudPeak = peak(render(loud, frames: 4_800))

        XCTAssertGreaterThan(plainPeak, 0)
        XCTAssertEqual(Double(loudPeak / plainPeak), 1.4, accuracy: 0.01)
    }

    func testPressurePastTheRangeClamps() {
        let full = instrument()
        sounding(full)
        full.apply(RenderCommand(kind: .channelPressure, velocity: 1))
        let fullSamples = render(full, frames: 2_400)

        let past = instrument()
        sounding(past)
        past.apply(RenderCommand(kind: .channelPressure, velocity: 3))
        XCTAssertEqual(render(past, frames: 2_400), fullSamples)
    }
}
