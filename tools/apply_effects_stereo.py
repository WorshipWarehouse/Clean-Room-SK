import pathlib
import sys


def write(path, text):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print("wrote", path, len(text))


def patch(path, old, new, note):
    target = pathlib.Path(path)
    text = target.read_text(encoding="utf-8")
    found = text.count(old)
    if found != 1:
        sys.exit("anchor %r for %s appears %d times" % (old[:60], note, found))
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("patched", note)


SETTINGS = '''import Foundation

/// Where each effect parameter lives, in the ranges this implementation chose.
///
/// These are original design choices, not measurements of the original app: the
/// analysis records its effect parameter ranges as Unknown, and nothing here
/// guesses at them. A range is what the controls clamp to, and every processor
/// clamps again on the render thread so an out-of-range value cannot destabilise
/// a filter.
public enum EffectRanges {
    public static let mix: ClosedRange<Float> = 0...1
    public static let reverbDecay: ClosedRange<Float> = 0...1
    public static let reverbDamping: ClosedRange<Float> = 0...1
    public static let chorusRate: ClosedRange<Float> = 0.05...6
    public static let chorusDepth: ClosedRange<Float> = 0...1
    public static let delayTime: ClosedRange<Float> = 0.02...1.2
    public static let delayFeedback: ClosedRange<Float> = 0...0.9
    public static let eqGainDB: ClosedRange<Float> = -18...18
}

/// Reverb settings.
///
/// `mix` is the wet share of the output, `decay` moves comb feedback from 0.35 to
/// 0.93, and `damping` moves the one-pole lowpass inside each comb from none to a
/// coefficient of 0.7. Disabled means the processor returns immediately and the
/// buffer is bit-for-bit dry.
public struct ReverbSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mix: Float
    public var decay: Float
    public var damping: Float

    public init(enabled: Bool = false, mix: Float = 0.25, decay: Float = 0.55, damping: Float = 0.35) {
        self.enabled = enabled
        self.mix = mix
        self.decay = decay
        self.damping = damping
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mix
        case decay
        case damping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReverbSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        mix = try container.decodeIfPresent(Float.self, forKey: .mix) ?? defaults.mix
        decay = try container.decodeIfPresent(Float.self, forKey: .decay) ?? defaults.decay
        damping = try container.decodeIfPresent(Float.self, forKey: .damping) ?? defaults.damping
    }
}

/// Chorus settings: how fast the delay sweeps and how far, plus the wet share.
///
/// `rate` is the LFO in Hz, `depth` scales a sweep of up to 8 ms around a 12 ms
/// base delay, and `mix` is the wet share of the output.
public struct ChorusSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mix: Float
    public var rate: Float
    public var depth: Float

    public init(enabled: Bool = false, mix: Float = 0.3, rate: Float = 0.6, depth: Float = 0.5) {
        self.enabled = enabled
        self.mix = mix
        self.rate = rate
        self.depth = depth
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mix
        case rate
        case depth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChorusSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        mix = try container.decodeIfPresent(Float.self, forKey: .mix) ?? defaults.mix
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? defaults.rate
        depth = try container.decodeIfPresent(Float.self, forKey: .depth) ?? defaults.depth
    }
}

/// Delay settings: two independent echo intervals, how much of each repeat feeds
/// the next, and the wet share.
///
/// A stereo delay is two taps, so it has two times: `leftTime` is what the left
/// channel hears and `rightTime` what the right channel hears. Both are clamped to
/// 20 ms to 1.2 s, which is the length of each line, and `feedback` to 0.9 so the
/// repeats always decay. The taps share one feedback control rather than
/// cross-feeding, which is what keeps a wide setting stable instead of building a
/// ping-pong that can run away.
///
/// `time` is the both-sides shorthand: reading it gives the left tap and writing it
/// moves both, so a control that has one knob still works and a document written
/// before the two taps existed still loads.
public struct DelaySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mix: Float
    public var leftTime: Float
    public var rightTime: Float
    public var feedback: Float

    public init(
        enabled: Bool = false,
        mix: Float = 0.25,
        leftTime: Float = 0.32,
        rightTime: Float = 0.32,
        feedback: Float = 0.3
    ) {
        self.enabled = enabled
        self.mix = mix
        self.leftTime = leftTime
        self.rightTime = rightTime
        self.feedback = feedback
    }

    /// Both taps at once.
    public var time: Float {
        get { leftTime }
        set {
            leftTime = newValue
            rightTime = newValue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mix
        case time
        case leftTime
        case rightTime
        case feedback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DelaySettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        mix = try container.decodeIfPresent(Float.self, forKey: .mix) ?? defaults.mix
        let single = try container.decodeIfPresent(Float.self, forKey: .time)
        leftTime = try container.decodeIfPresent(Float.self, forKey: .leftTime) ?? single ?? defaults.leftTime
        rightTime = try container.decodeIfPresent(Float.self, forKey: .rightTime) ?? single ?? defaults.rightTime
        feedback = try container.decodeIfPresent(Float.self, forKey: .feedback) ?? defaults.feedback
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mix, forKey: .mix)
        try container.encode(leftTime, forKey: .leftTime)
        try container.encode(rightTime, forKey: .rightTime)
        try container.encode(feedback, forKey: .feedback)
    }
}

/// A three-section voicing stage: a low shelf at 250 Hz, a peaking band at 1 kHz
/// and a high shelf at 3 kHz.
///
/// The sections are the standard shelving and peaking forms every audio text
/// derives; the corners and the peaking width are this repository's own choice,
/// because the analysis records the original's curve as Unknown. A section whose
/// gain is exactly 0 dB is not run at all, so a flat EQ is bit-transparent rather
/// than approximately transparent and can be left engaged without colouring the
/// instrument.
public struct EQSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lowGain: Float
    public var midGain: Float
    public var highGain: Float

    public init(enabled: Bool = false, lowGain: Float = 0, midGain: Float = 0, highGain: Float = 0) {
        self.enabled = enabled
        self.lowGain = lowGain
        self.midGain = midGain
        self.highGain = highGain
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case lowGain
        case midGain
        case highGain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EQSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        lowGain = try container.decodeIfPresent(Float.self, forKey: .lowGain) ?? defaults.lowGain
        midGain = try container.decodeIfPresent(Float.self, forKey: .midGain) ?? defaults.midGain
        highGain = try container.decodeIfPresent(Float.self, forKey: .highGain) ?? defaults.highGain
    }
}

/// The whole chain, stored with every patch.
///
/// Every effect defaults to bypassed, so a patch saved before effects existed,
/// and an engine built without touching the effects, both sound exactly as dry
/// as they did before the chain existed. Nothing here is audio-thread state: a
/// value of this type is published to the render thread whole.
public struct EffectsSettings: Codable, Equatable, Sendable {
    public var eq: EQSettings
    public var chorus: ChorusSettings
    public var delay: DelaySettings
    public var reverb: ReverbSettings

    public init(
        eq: EQSettings = EQSettings(),
        chorus: ChorusSettings = ChorusSettings(),
        delay: DelaySettings = DelaySettings(),
        reverb: ReverbSettings = ReverbSettings()
    ) {
        self.eq = eq
        self.chorus = chorus
        self.delay = delay
        self.reverb = reverb
    }

    /// True when the whole chain would pass audio through untouched.
    public var isDry: Bool {
        !eq.enabled && !chorus.enabled && !delay.enabled && !reverb.enabled
    }

    private enum CodingKeys: String, CodingKey {
        case eq
        case chorus
        case delay
        case reverb
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EffectsSettings()
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? defaults.eq
        chorus = try container.decodeIfPresent(ChorusSettings.self, forKey: .chorus) ?? defaults.chorus
        delay = try container.decodeIfPresent(DelaySettings.self, forKey: .delay) ?? defaults.delay
        reverb = try container.decodeIfPresent(ReverbSettings.self, forKey: .reverb) ?? defaults.reverb
    }
}
'''

EQ = '''import Foundation

/// A three-section equaliser: a low shelf, a peaking band and a high shelf.
///
/// The coefficients are the standard shelving and peaking forms, written out here
/// rather than linked: this is original code computing textbook coefficients, not
/// code taken from anywhere. The corners and the peaking width are this
/// repository's own choice; the analysis records the original's EQ curve as
/// Unknown, so nothing here claims to reproduce it.
///
/// A section with exactly 0 dB of gain is set to pass-through coefficients, which
/// makes a flat EQ bit-transparent rather than approximately transparent. Every
/// gain is clamped to plus or minus 18 dB on the render thread as well as by the
/// control, because a document read from disk must not be able to drive a section
/// into a numerical corner.
public final class EQProcessor {
    public let sampleRate: Double

    private let lowHz: Double = 250
    private let midHz: Double = 1_000
    private let highHz: Double = 3_000
    private let midQ: Double = 0.9

    private struct Biquad {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0
        var x1: Float = 0
        var x2: Float = 0
        var y1: Float = 0
        var y2: Float = 0

        mutating func process(_ input: Float) -> Float {
            let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = input
            y2 = y1
            y1 = output
            return output
        }

        mutating func clear() {
            x1 = 0
            x2 = 0
            y1 = 0
            y2 = 0
        }

        mutating func passThrough() {
            b0 = 1
            b1 = 0
            b2 = 0
            a1 = 0
            a2 = 0
        }

        mutating func set(_ coefficients: Coefficients) {
            b0 = coefficients.b0
            b1 = coefficients.b1
            b2 = coefficients.b2
            a1 = coefficients.a1
            a2 = coefficients.a2
        }
    }

    private struct Coefficients {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float
    }

    private var lowLeft = Biquad()
    private var midLeft = Biquad()
    private var highLeft = Biquad()
    private var lowRight = Biquad()
    private var midRight = Biquad()
    private var highRight = Biquad()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
    }

    /// Render thread only. Mono, in place.
    public func process(
        into buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        settings: EQSettings
    ) {
        guard settings.enabled else {
            clear()
            return
        }
        configure(settings)

        let frames = min(frameCount, buffer.count)
        var frame = 0
        while frame < frames {
            buffer[frame] = processLeft(buffer[frame])
            frame += 1
        }
    }

    /// Render thread only. One pass over both channels, each with its own state.
    public func process(
        into left: UnsafeMutableBufferPointer<Float>,
        and right: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        settings: EQSettings
    ) {
        guard settings.enabled else {
            clear()
            return
        }
        configure(settings)

        let frames = min(frameCount, min(left.count, right.count))
        var frame = 0
        while frame < frames {
            left[frame] = processLeft(left[frame])
            right[frame] = processRight(right[frame])
            frame += 1
        }
    }

    private func processLeft(_ input: Float) -> Float {
        var value = lowLeft.process(input)
        value = midLeft.process(value)
        return highLeft.process(value)
    }

    private func processRight(_ input: Float) -> Float {
        var value = lowRight.process(input)
        value = midRight.process(value)
        return highRight.process(value)
    }

    private func configure(_ settings: EQSettings) {
        apply(Self.lowShelf(gainDB: settings.lowGain, cutoff: lowHz, sampleRate: sampleRate), to: &lowLeft)
        apply(Self.lowShelf(gainDB: settings.lowGain, cutoff: lowHz, sampleRate: sampleRate), to: &lowRight)
        apply(Self.peak(gainDB: settings.midGain, cutoff: midHz, q: midQ, sampleRate: sampleRate), to: &midLeft)
        apply(Self.peak(gainDB: settings.midGain, cutoff: midHz, q: midQ, sampleRate: sampleRate), to: &midRight)
        apply(Self.highShelf(gainDB: settings.highGain, cutoff: highHz, sampleRate: sampleRate), to: &highLeft)
        apply(Self.highShelf(gainDB: settings.highGain, cutoff: highHz, sampleRate: sampleRate), to: &highRight)
    }

    private func apply(_ coefficients: Coefficients?, to section: inout Biquad) {
        guard let coefficients else {
            section.passThrough()
            return
        }
        section.set(coefficients)
    }

    private func clear() {
        lowLeft.clear()
        midLeft.clear()
        highLeft.clear()
        lowRight.clear()
        midRight.clear()
        highRight.clear()
    }

    /// Nil at exactly 0 dB, which is what makes a flat section a no-op.
    private static func gain(_ gainDB: Float) -> Double? {
        let clamped = Double(min(max(gainDB, EffectRanges.eqGainDB.lowerBound), EffectRanges.eqGainDB.upperBound))
        if clamped == 0 {
            return nil
        }
        return pow(10.0, clamped / 40.0)
    }

    private static func lowShelf(gainDB: Float, cutoff: Double, sampleRate: Double) -> Coefficients? {
        guard let amplitude = gain(gainDB) else { return nil }
        let omega = 2.0 * Double.pi * cutoff / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / 2.0 * 2.0.squareRoot()
        let rootA = amplitude.squareRoot()
        let a0 = (amplitude + 1) + (amplitude - 1) * cosine + 2 * rootA * alpha
        let b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + 2 * rootA * alpha)
        let b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine)
        let b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - 2 * rootA * alpha)
        let a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine)
        let a2 = (amplitude + 1) + (amplitude - 1) * cosine - 2 * rootA * alpha
        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private static func highShelf(gainDB: Float, cutoff: Double, sampleRate: Double) -> Coefficients? {
        guard let amplitude = gain(gainDB) else { return nil }
        let omega = 2.0 * Double.pi * cutoff / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / 2.0 * 2.0.squareRoot()
        let rootA = amplitude.squareRoot()
        let a0 = (amplitude + 1) - (amplitude - 1) * cosine + 2 * rootA * alpha
        let b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + 2 * rootA * alpha)
        let b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine)
        let b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - 2 * rootA * alpha)
        let a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine)
        let a2 = (amplitude + 1) - (amplitude - 1) * cosine - 2 * rootA * alpha
        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private static func peak(gainDB: Float, cutoff: Double, q: Double, sampleRate: Double) -> Coefficients? {
        guard let amplitude = gain(gainDB) else { return nil }
        let omega = 2.0 * Double.pi * cutoff / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * q)
        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cosine
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cosine
        let a2 = 1 - alpha / amplitude
        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private static func normalised(
        b0: Double,
        b1: Double,
        b2: Double,
        a0: Double,
        a1: Double,
        a2: Double
    ) -> Coefficients {
        guard a0 != 0, a0.isFinite else {
            return Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        }
        return Coefficients(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
}
'''

TESTS = '''import Darwin
import XCTest
@testable import SundayKeysCore

/// The stereo half of the chain: two delay taps with their own times, an EQ whose
/// three sections can be measured one at a time, and a device path that carries
/// both channels through the effects.
final class EffectsStereoTests: XCTestCase {
    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        for sample in samples {
            value = max(value, abs(sample))
        }
        return value
    }

    private func loudestIndex(_ samples: [Float]) -> Int {
        var index = 0
        var best = 0
        var bestValue: Float = 0
        while index < samples.count {
            let magnitude = abs(samples[index])
            if magnitude > bestValue {
                bestValue = magnitude
                best = index
            }
            index += 1
        }
        return best
    }

    private func ratio(
        frequency: Double,
        configure: (inout EQSettings) -> Void
    ) -> Float {
        let eq = EQProcessor(sampleRate: 48_000)
        var settings = EQSettings()
        settings.enabled = true
        configure(&settings)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        var sum: Float = 0
        var count = 0

        var block = 0
        while block < 30 {
            var index = 0
            while index < left.count {
                let position = Double(block * left.count + index)
                let sample = Float(sin(position * 2.0 * Double.pi * frequency / 48_000.0)) * 0.5
                left[index] = sample
                right[index] = sample
                index += 1
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
            block += 1
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
        var index = 0
        while index < left.count {
            left[index] = Float(index % 13) / 13 - 0.5
            right[index] = Float(index % 7) / 7 - 0.5
            index += 1
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

    func testEachEQBandMovesItsOwnRange() {
        let liftedLow = ratio(frequency: 60) { $0.lowGain = 12 }
        XCTAssertGreaterThan(liftedLow, 2.5)

        let liftedMid = ratio(frequency: 1_000) { $0.midGain = 12 }
        XCTAssertGreaterThan(liftedMid, 2.5)

        let liftedHigh = ratio(frequency: 6_000) { $0.highGain = 12 }
        XCTAssertGreaterThan(liftedHigh, 1.4)

        let cutMid = ratio(frequency: 1_000) { $0.midGain = -12 }
        XCTAssertLessThan(cutMid, 0.5)

        let lowBandLeavesTreble = ratio(frequency: 8_000) { $0.lowGain = 12 }
        XCTAssertEqual(lowBandLeavesTreble, 1, accuracy: 0.1)

        let highBandLeavesBass = ratio(frequency: 60) { $0.highGain = 12 }
        XCTAssertEqual(highBandLeavesBass, 1, accuracy: 0.1)

        let midBandLeavesBass = ratio(frequency: 60) { $0.midGain = 12 }
        XCTAssertEqual(midBandLeavesBass, 1, accuracy: 0.1)
    }

    func testStereoDelayKeepsIndependentLeftAndRightTimes() {
        let delay = DelayProcessor(sampleRate: 48_000)
        var settings = DelaySettings()
        settings.enabled = true
        settings.mix = 1
        settings.feedback = 0
        settings.leftTime = 0.05
        settings.rightTime = 0.15

        var leftCollected: [Float] = []
        var rightCollected: [Float] = []
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        left[0] = 1
        right[0] = 1

        var step = 0
        while step < 40 {
            if step > 0 {
                for index in 0..<left.count {
                    left[index] = 0
                    right[index] = 0
                }
            }
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    delay.process(
                        into: leftPointer,
                        and: rightPointer,
                        frameCount: leftPointer.count,
                        settings: settings
                    )
                }
            }
            leftCollected.append(contentsOf: left)
            rightCollected.append(contentsOf: right)
            step += 1
        }

        let leftPeak = loudestIndex(leftCollected)
        let rightPeak = loudestIndex(rightCollected)

        XCTAssertTrue(abs(leftPeak - 2_400) <= 4, "left tap at 50 ms, measured \\(leftPeak)")
        XCTAssertTrue(abs(rightPeak - 7_200) <= 4, "right tap at 150 ms, measured \\(rightPeak)")
    }

    func testStereoDelayRepeatsDecayOnBothSides() {
        let delay = DelayProcessor(sampleRate: 48_000)
        var settings = DelaySettings()
        settings.enabled = true
        settings.mix = 1
        settings.feedback = 0.5
        settings.leftTime = 0.1
        settings.rightTime = 0.2

        var leftCollected: [Float] = []
        var rightCollected: [Float] = []
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        left[0] = 1
        right[0] = 1

        var step = 0
        while step < 130 {
            if step > 0 {
                for index in 0..<left.count {
                    left[index] = 0
                    right[index] = 0
                }
            }
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    delay.process(into: leftPointer, and: rightPointer, frameCount: leftPointer.count, settings: settings)
                }
            }
            leftCollected.append(contentsOf: left)
            rightCollected.append(contentsOf: right)
            step += 1
        }

        func around(_ samples: [Float], _ center: Int) -> Float {
            var value: Float = 0
            var index = max(0, center - 4)
            let end = min(samples.count - 1, center + 4)
            while index <= end {
                value = max(value, abs(samples[index]))
                index += 1
            }
            return value
        }

        let leftFirst = around(leftCollected, 4_800)
        let leftSecond = around(leftCollected, 9_600)
        let rightFirst = around(rightCollected, 9_600)
        let rightSecond = around(rightCollected, 19_200)

        XCTAssertGreaterThan(leftFirst, 0.9)
        XCTAssertGreaterThan(rightFirst, 0.9)
        XCTAssertEqual(leftSecond, leftFirst * 0.5, accuracy: 0.06)
        XCTAssertEqual(rightSecond, rightFirst * 0.5, accuracy: 0.06)
    }

    func testStereoDelayStaysBoundedAtMaximumFeedback() {
        let delay = DelayProcessor(sampleRate: 48_000)
        var settings = DelaySettings()
        settings.enabled = true
        settings.mix = 0.5
        settings.feedback = 0.9
        settings.leftTime = 0.03
        settings.rightTime = 0.037

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        var worst: Float = 0

        var step = 0
        while step < 900 {
            var index = 0
            while index < left.count {
                if step < 300 {
                    let position = Double(step * left.count + index)
                    let sample = Float(sin(position * 2.0 * Double.pi * 330.0 / 48_000.0)) * 0.7
                    left[index] = sample
                    right[index] = sample
                } else {
                    left[index] = 0
                    right[index] = 0
                }
                index += 1
            }

            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    delay.process(into: leftPointer, and: rightPointer, frameCount: leftPointer.count, settings: settings)
                }
            }

            XCTAssertTrue(peak(left).isFinite)
            XCTAssertTrue(peak(right).isFinite)
            worst = max(worst, max(peak(left), peak(right)))
            step += 1
        }

        XCTAssertLessThan(worst, 12, "0.9 feedback with two taps must still decay")
    }

    func testFullyBypassedStereoChainIsBitTransparent() {
        let chain = EffectChain(sampleRate: 48_000, channel: .left)
        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        var index = 0
        while index < left.count {
            left[index] = Float(index % 19) / 19 - 0.5
            right[index] = Float(index % 23) / 23 - 0.5
            index += 1
        }
        let expectedLeft = left
        let expectedRight = right

        var step = 0
        while step < 4 {
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    chain.process(into: leftPointer, and: rightPointer, frameCount: leftPointer.count)
                }
            }
            step += 1
        }

        XCTAssertEqual(left, expectedLeft)
        XCTAssertEqual(right, expectedRight)
    }

    func testStereoChainStaysBoundedAcrossALongRun() {
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

        var step = 0
        while step < 260 {
            var index = 0
            while index < left.count {
                if step < 120 {
                    let position = Double(step * left.count + index)
                    let sample = Float(sin(position * 2.0 * Double.pi * 220.0 / 48_000.0)) * 0.7
                    left[index] = sample
                    right[index] = sample
                } else {
                    left[index] = 0
                    right[index] = 0
                }
                index += 1
            }

            left.withUnsafeMutableBufferPointer { leftPointer in
                leftChain.process(into: leftPointer, frameCount: leftPointer.count)
            }
            right.withUnsafeMutableBufferPointer { rightPointer in
                rightChain.process(into: rightPointer, frameCount: rightPointer.count)
            }

            XCTAssertTrue(peak(left).isFinite)
            XCTAssertTrue(peak(right).isFinite)
            worst = max(worst, max(peak(left), peak(right)))
            step += 1
        }

        XCTAssertLessThan(worst, 6, "the stereo chain must not run away")
    }

    private let frameCount = 512

    private func renderStereo(
        _ engine: RealtimeKeysoundEngine,
        blocks: Int
    ) -> (left: [Float], right: [Float]) {
        var leftAll: [Float] = []
        var rightAll: [Float] = []
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)

        var block = 0
        while block < blocks {
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    var index = 0
                    while index < leftPointer.count {
                        leftPointer[index] = 0
                        rightPointer[index] = 0
                        index += 1
                    }
                    engine.renderStereo(
                        intoLeft: leftPointer,
                        intoRight: rightPointer,
                        frameCount: leftPointer.count
                    )
                }
            }
            leftAll.append(contentsOf: left)
            rightAll.append(contentsOf: right)
            block += 1
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

    func testStereoEngineUsesBothDelayTapsWhileANoteSounds() {
        var patch = Patch(name: "Wide", layers: KeyLayer.defaultPatch)
        patch.effects.delay.enabled = true
        patch.effects.delay.mix = 1
        patch.effects.delay.feedback = 0
        patch.effects.delay.leftTime = 0.05
        patch.effects.delay.rightTime = 0.25

        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: 72, velocity: 110)
        _ = renderStereo(engine, blocks: 2)
        engine.noteOff(note: 72)

        let tail = renderStereo(engine, blocks: 60)
        let leftWindow = Array(tail.left[4_096..<(4_096 + frameCount)])
        let rightWindow = Array(tail.right[12_288..<(12_288 + frameCount)])

        XCTAssertGreaterThan(peak(leftWindow), 1e-4, "the short tap is heard on the left")
        XCTAssertGreaterThan(peak(rightWindow), 1e-4, "and the long tap on the right")
    }

    func testDelaySettingsRoundTripKeepsBothTaps() throws {
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
        wet.delay.enabled = false

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
        XCTAssertFalse(bank.patches[index].effects.delay.enabled)
        XCTAssertTrue(bank.patches[0].effects.isDry)
    }

    func testDocumentWrittenWithOneDelayTimeFillsBothTaps() throws {
        let json = """
        { "enabled": true, "mix": 0.4, "time": 0.5, "feedback": 0.2 }
        """
        let settings = try JSONDecoder().decode(DelaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.leftTime, 0.5, accuracy: 1e-6)
        XCTAssertEqual(settings.rightTime, 0.5, accuracy: 1e-6)
    }
}
'''

DOC = '''# The effects chain

What the signal path does between the voices and the device, what is this
repository's own choice, and what is still Unknown about the original.

## The path

`PolyphonicInstrument` sums its voices into one buffer. `RealtimeKeysoundEngine`
then runs the patch's `EffectChain` over that block and finally adds the click, so
no cue is reverberated, delayed or equalised. The chain is per patch: `Patch` owns
an `EffectsSettings`, `setPatch` publishes it, and `setEffects` publishes an edit
without touching a sounding voice.

Order is deliberate and documented in the code: **EQ, chorus, delay, reverb**.
The EQ shapes what the chorus and delay repeat, the delay feeds the reverb so the
tail belongs to the space rather than to the instrument, and the reverb is last so
nothing smears its tail afterwards. Each stage has its own wet share (`mix`) and
its own `enabled` switch; a disabled stage returns before touching a sample, which
is what makes bypass exactly neutral rather than nearly neutral.

## Stereo

The voices are mono and are rendered once. The engine copies that mix to the right
channel, runs the chain once over both channels, and the device block writes the
left channel to even output channels and the right to odd ones. So the chain is
where stereo is created, and the two delay taps are what make it audible.

Each side owns its own processor instance, which is why the EQ, chorus and reverb
keep per-channel filter and buffer state without sharing a line. The delay is one
processor with two taps: `leftTime` and `rightTime` are independent, and feedback
is shared and clamped to 0.9 so a wide setting decays instead of building.

## What each stage is

- **EQ** — a low shelf at 250 Hz, a peaking band at 1 kHz (Q 0.9) and a high shelf
  at 3 kHz. The section shapes are the standard shelving and peaking forms; the
  corners and the width are this repository's own choice. A section at exactly 0 dB
  is set to pass-through coefficients, so a flat EQ is bit-transparent.
- **Chorus** — a modulated delay line: a 12 ms base swept by up to 8 ms at the
  configured rate, read with linear interpolation, with the LFO run once per side.
- **Delay** — two lines of 1.2 s each, fractional read, the time glided over 30 ms
  so a move bends the tail instead of cutting it.
- **Reverb** — four damped comb filters in parallel into two allpasses in series.
  Comb times are this implementation's own, chosen for a room-sized spread of about
  30 ms to 44 ms; damping is a one-pole lowpass in each comb's feedback path.

## What is Unknown

- The original's EQ curve, crossover points, shelf slopes and peaking width.
- Its delay topology: whether the two taps are independent, and whether feedback
  crosses between sides.
- Its reverb algorithm and tail length, and its chorus modulation depth and rate.
- Whether any of it runs per layer or only on the whole patch.

Every number in `EffectRanges` and every corner frequency above is therefore a
replaceable decision, not a measurement.

## What the tests assert

Measured on samples, not on command plumbing. The existing suite proves a decaying
diffuse reverb tail after the input stops and byte-identical output when bypassed,
delay repeats at the configured interval with the feedback ratio correct, chorus
modulation moving the wet copy, EQ bands lifting and cutting their own range, the
chain staying finite over a long run, and effect settings surviving the patch bank
including a bank written before effects existed. The stereo suite added beside it
proves the two delay taps land at their own times, each tap's repeats decay, the
maximum feedback stays bounded, a flat EQ and a fully bypassed stereo chain are
bit-identical, each EQ section moves only its own range, the stereo chain stays
bounded over 260 blocks, the stereo engine carries a reverb tail in both channels
and is exactly silent when dry, both taps are audible through the engine, both
taps survive the bank, a restored session opens the patch with its effects, and a
one-time document fills both taps.

## What is not established

Nothing here was heard: no output device, no microphone, no ear and no window were
involved, and no controller was attached. The device path is exercised only by the
runner's launch and audio probe, which uses a virtual device.
'''

write("Sources/SundayKeysCore/Audio/Effects/EffectsSettings.swift", SETTINGS)
write("Sources/SundayKeysCore/Audio/Effects/EQProcessor.swift", EQ)
write("Tests/SundayKeysCoreTests/EffectsStereoTests.swift", TESTS)
write("docs/re/effects-chain.md", DOC)

patch(
    "Sources/SundayKeysCore/Audio/Effects/EffectChain.swift",
    "public final class EffectChain {",
    "/// Which side of the stereo pair a chain instance feeds.\n///\n/// The voices are mono, so stereo exists only inside the chain: one instance per\n/// side, each with its own filter and buffer state, and the delay reading the tap\n/// that belongs to its side.\npublice numEffectChanneloops",
    "chain-channel-enum",
)
print("staged")
