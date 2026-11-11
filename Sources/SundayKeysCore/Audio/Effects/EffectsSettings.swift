import Foundation

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

/// Delay settings: two independent echo times, one feedback control, one wet share.
///
/// `leftTime` is what the left channel hears and `rightTime` what the right hears;
/// both are clamped to 20 ms to 1.2 s, which is the length of each tap. The taps
/// share `feedback`, clamped to 0.9 so the repeats always decay, and there is no
/// cross-feed: independent taps with a shared tail are what keep a wide setting
/// stable instead of building a ping-pong that can run away.
///
/// `time` is the both-sides shorthand. Reading it gives the left tap and writing it
/// moves both, so a control with one knob still works and a document written before
/// the two taps existed still loads.
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

    /// The same shorthand as a call, so a caller that asked for one time still
    /// compiles and still means both taps.
    public init(enabled: Bool = false, mix: Float = 0.25, time: Float, feedback: Float = 0.3) {
        self.enabled = enabled
        self.mix = mix
        self.leftTime = time
        self.rightTime = time
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
/// peaking width are this repository's own choice. A section whose gain is exactly
/// 0 dB is not run at all, which makes a flat EQ bit-transparent rather than
/// approximately transparent and lets the chain keep it engaged.
public struct EQSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lowGain: Float
    public var highGain: Float
    /// The peaking band's gain, which is the band the first version had no control
    /// for: low and high were shelves and everything between them was fixed.
    public var midGain: Float

    public init(
        enabled: Bool = false,
        lowGain: Float = 0,
        highGain: Float = 0,
        midGain: Float = 0
    ) {
        self.enabled = enabled
        self.lowGain = lowGain
        self.highGain = highGain
        self.midGain = midGain
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
        highGain = try container.decodeIfPresent(Float.self, forKey: .highGain) ?? defaults.highGain
        midGain = try container.decodeIfPresent(Float.self, forKey: .midGain) ?? defaults.midGain
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
