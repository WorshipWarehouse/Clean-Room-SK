import Foundation

/// A layer's low-pass corner and resonance, and the one place the law that turns
/// them into coefficients lives.
///
/// The original app exposes a `ModulationFilterApi` with a filter range and a
/// resonance field; what it does with them is **Unknown**, so the topology and the
/// mapping here are this repository's own, stated once so the engine, the window
/// and the tests cannot disagree.
///
/// A patch written before the field existed decodes to a wide-open filter, and
/// `isOpen` lets the render path skip the filter entirely in that case, so such a
/// patch renders bit-identically to one this build wrote.
public enum LayerFilter {
    /// The corner's range. 20 kHz is the top of the band a 48 kHz path carries,
    /// so a layer at the top is open rather than merely high.
    public static let minimumCutoff: Float = 20
    public static let maximumCutoff: Float = 20_000
    public static let defaultCutoff: Float = maximumCutoff
    public static let defaultResonance: Float = 0
    public static let maximumResonance: Float = 1

    /// The control's scale in octaves above 20 Hz: 0 is 20 Hz and 10 is 20 kHz.
    /// A player hears tone in octaves, so a slider is a position on that scale
    /// rather than a frequency, and 20 Hz to 20 kHz spreads evenly across it.
    public static let octaveSpan: Float = 10

    public static func clampCutoff(_ hz: Float) -> Float {
        guard hz.isFinite else { return defaultCutoff }
        return min(max(hz, minimumCutoff), maximumCutoff)
    }

    public static func clampResonance(_ value: Float) -> Float {
        guard value.isFinite else { return defaultResonance }
        return min(max(value, 0), maximumResonance)
    }

    /// True when a layer's filter does nothing at all.
    public static func isOpen(cutoff: Float, resonance: Float) -> Bool {
        clampCutoff(cutoff) >= maximumCutoff && clampResonance(resonance) <= 0.0001
    }

    public static func octaves(fromCutoff hz: Float) -> Float {
        let clamped = clampCutoff(hz)
        return min(max(log2(clamped / minimumCutoff), 0), octaveSpan)
    }

    public static func cutoff(fromOctaves octaves: Float) -> Float {
        let clamped = min(max(octaves, 0), octaveSpan)
        return clampCutoff(minimumCutoff * pow(2, clamped))
    }

    /// The three coefficients the render loop applies, or a bypass flag.
    public struct Coefficients: Equatable, Sendable {
        public var a1: Float
        public var a2: Float
        public var a3: Float
        public var bypass: Bool
    }

    /// A topology-preserving state-variable low pass, pre-reduced to three
    /// coefficients so the voice loop never divides per sample.
    ///
    /// `g` is the corner pre-warped to the sample rate and `k` is the damping:
    /// 1.414 with no resonance, falling to 0.1 at full resonance, which lifts the
    /// corner instead of letting it run away.
    public static func coefficients(
        cutoff: Float,
        resonance: Float,
        sampleRate: Double
    ) -> Coefficients {
        let hz = clampCutoff(cutoff)
        let damping = clampResonance(resonance)
        if isOpen(cutoff: hz, resonance: damping) {
            return Coefficients(a1: 0, a2: 0, a3: 0, bypass: true)
        }
        let rate = sampleRate > 0 ? Float(sampleRate) : 48_000
        // A corner above Nyquist would wrap, so hold it just below even when a
        // 20 kHz request meets a lower device rate.
        let corner = min(hz, rate * 0.49)
        let g = tan(Float.pi * corner / rate)
        let k = 1.41421356 - 1.31421356 * damping
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        return Coefficients(a1: a1, a2: a2, a3: a3, bypass: false)
    }

    /// One voice's filter memory: two integrators, which is what the topology
    /// above needs and all it needs.
    public struct State: Sendable {
        private var ic1: Float = 0
        private var ic2: Float = 0

        public init() {}

        public mutating func process(
            _ input: Float,
            a1: Float,
            a2: Float,
            a3: Float
        ) -> Float {
            let v3 = input - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return v2
        }
    }
}
