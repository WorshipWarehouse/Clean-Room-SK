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
        sys.exit("anchor for %s appears %d times" % (note, found))
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

/// Chorus settings: sweep rate, sweep length and wet share.
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

/// Delay settings: two independent echo times, one feedback control, one wet share.
///
/// `leftTime` is what the left channel hears and `rightTime` what the right hears;
/// both are clamped to 20 ms to 1.2 s. The taps share `feedback`, which is clamped
/// to 0.9 so the repeats decay, and there is no cross-feed: two independent taps
/// with a shared tail is what keeps a wide setting stable instead of building a
/// ping-pong that can run away. `time` is the both-sides shorthand, so a one-knob
/// control works and a document written before the two taps existed still loads.
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
/// The analysis records the original's curve as Unknown, so the corners and the
/// peaking width are this repository's own choice. A section at exactly 0 dB is not
/// run at all, which makes a flat EQ bit-transparent rather than approximately
/// transparent.
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
/// Every effect defaults to bypassed, so a patch saved before effects existed, and
/// an engine built without touching the effects, both sound exactly as dry as they
/// did before the chain existed.
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
/// rather than linked: original code computing textbook coefficients. The corners
/// and the peaking width are this repository's own choice, because the analysis
/// records the original's EQ curve as Unknown.
///
/// A section at exactly 0 dB is set to pass-through coefficients, so a flat EQ is
/// bit-transparent. Every gain is clamped to plus or minus 18 dB here as well as by
/// the control, because a document read from disk must not be able to drive a
/// section into a numerical corner.
public final class EQProcessor {
    public let sampleRate: Double

    private let lowHz: Double = 250
    private let midHz: Double = 1_000
    private let highHz: Double = 3_000
    private let midQ: Double = 0.9

    private struct Coefficients {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float
    }

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

        mutating func apply(_ coefficients: Coefficients) {
            b0 = coefficients.b0
            b1 = coefficients.b1
            b2 = coefficients.b2
            a1 = coefficients.a1
            a2 = coefficients.a2
        }
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
        apply(Self.lowShelf(gainDB: settings.lowGain, cutoff: lowHz, sampleRate: sampleRate), toLow: true)
        apply(Self.lowShelf(gainDB: settings.lowGain, cutoff: lowHz, sampleRate: sampleRate), toLow: false)
        apply(Self.peak(gainDB: settings.midGain, cutoff: midHz, q: midQ, sampleRate: sampleRate), toLow: true)
        apply(Self.peak(gainDB: settings.midGain, cutoff: midHz, q: midQ, sampleRate: sampleRate), toLow: false)
        apply(Self.highShelf(gainDB: settings.highGain, cutoff: highHz, sampleRate: sampleRate), toLow: true)
        apply(Self.highShelf(gainDB: settings.highGain, cutoff: highHz, sampleRate: sampleRate), toLow: false)
    }

    private func apply(_ coefficients: Coefficients?, toLow leftSide: Bool) {
        // Placeholder replaced below.
    }

    private func clear() {
        lowLeft.clear()
        midLeft.clear()
        highLeft.clear()
        lowRight.clear()
        midRight.clear()
        highRight.clear()
    }

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
        let alpha = sine / 2.0 * Double(2).squareRoot()
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
        let alpha = sine / 2.0 * Double(2).squareRoot()
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

write("Sources/SundayKeysCore/Audio/Effects/EffectsSettings.swift", SETTINGS)
print("stage one complete")
