import Foundation

/// One layer's amplitude envelope: three times in seconds and one level.
///
/// The original names these fields - `ADSRModel` carries attack, decay, sustain and
/// release beside a fade - but what it does with them is Unknown: no captured session,
/// no decompiled body and no parameter range were available. The ranges, the defaults
/// and the law below are therefore this repository's own, claimed as such and not as
/// parity.
///
/// The defaults are the instrument's original ramp to the sample: an 8 ms linear attack
/// from zero, no decay, full sustain and a 220 ms linear release. That is what makes a
/// bank written before the field existed sound bit-identically to one this build writes
/// with the defaults stated explicitly.
public struct LayerEnvelope: Equatable, Sendable {
    public static let defaultAttack: Float = 0.008
    public static let defaultDecay: Float = 0
    public static let defaultSustain: Float = 1
    public static let defaultRelease: Float = 0.220

    public static let attackRange: ClosedRange<Float> = 0.001...5
    public static let decayRange: ClosedRange<Float> = 0...5
    public static let sustainRange: ClosedRange<Float> = 0...1
    public static let releaseRange: ClosedRange<Float> = 0.005...10

    /// Seconds from silence to the note's peak.
    public var attack: Float
    /// Seconds from the peak down to the sustain level. Zero means no decay stage.
    public var decay: Float
    /// The level the decay falls to and the note holds at, as a fraction of its peak.
    public var sustain: Float
    /// Seconds from the held level to silence once the key is released.
    public var release: Float

    public init(
        attack: Float = LayerEnvelope.defaultAttack,
        decay: Float = LayerEnvelope.defaultDecay,
        sustain: Float = LayerEnvelope.defaultSustain,
        release: Float = LayerEnvelope.defaultRelease
    ) {
        self.attack = LayerEnvelope.clamp(attack, to: LayerEnvelope.attackRange, fallback: LayerEnvelope.defaultAttack)
        self.decay = LayerEnvelope.clamp(decay, to: LayerEnvelope.decayRange, fallback: LayerEnvelope.defaultDecay)
        self.sustain = LayerEnvelope.clamp(sustain, to: LayerEnvelope.sustainRange, fallback: LayerEnvelope.defaultSustain)
        self.release = LayerEnvelope.clamp(release, to: LayerEnvelope.releaseRange, fallback: LayerEnvelope.defaultRelease)
    }

    /// The envelope a layer written before the field existed sounds with.
    public static let `default` = LayerEnvelope()

    /// Whether the level never falls: no decay, or full sustain. The render path skips
    /// its decay stage on exactly this condition, so an open layer costs one comparison.
    public var holdsLevel: Bool { decay <= 0 || sustain >= 1 }

    /// The one clamp. A value outside its range is pulled to the edge; a value that is
    /// not a number at all takes the documented default, because a NaN reaching the
    /// voice loop would silence the note and never free it.
    public static func clamp(
        _ value: Float,
        to range: ClosedRange<Float>,
        fallback: Float
    ) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// A time in frames at a given rate, never shorter than one frame: a zero-frame ramp
    /// would divide by zero in the voice loop, so one frame is the smallest stage.
    public static func frames(for seconds: Float, sampleRate: Double) -> Float {
        let rate = sampleRate > 0 ? Float(sampleRate) : 48_000
        let time = seconds.isFinite ? max(seconds, 0) : 0
        return max(1, time * rate)
    }
}

// Custom decoding for the same reason the layer's other fields have it: a bank written
// before the field existed must load with the documented default rather than fail, and
// a hand-edited one must not be able to put a stage outside its range.
extension LayerEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case attack
        case decay
        case sustain
        case release
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            attack: try container.decodeIfPresent(Float.self, forKey: .attack)
                ?? LayerEnvelope.defaultAttack,
            decay: try container.decodeIfPresent(Float.self, forKey: .decay)
                ?? LayerEnvelope.defaultDecay,
            sustain: try container.decodeIfPresent(Float.self, forKey: .sustain)
                ?? LayerEnvelope.defaultSustain,
            release: try container.decodeIfPresent(Float.self, forKey: .release)
                ?? LayerEnvelope.defaultRelease
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attack, forKey: .attack)
        try container.encode(decay, forKey: .decay)
        try container.encode(sustain, forKey: .sustain)
        try container.encode(release, forKey: .release)
    }
}
