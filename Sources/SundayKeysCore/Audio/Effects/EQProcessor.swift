import Foundation

/// A three-section equaliser: a low shelf, a peaking band and a high shelf.
///
/// The coefficients are the standard shelving and peaking forms, written out here
/// rather than linked: this is original code computing textbook coefficients, not
/// code taken from anywhere. The corners and the peaking width are this
/// repository's own choice, because the analysis records the original's EQ curve
/// as Unknown.
///
/// A section whose gain is exactly 0 dB is set to pass-through coefficients, so a
/// flat EQ is bit-transparent rather than approximately transparent. Every gain is
/// clamped to plus or minus 18 dB here as well as by the control, because a
/// document read from disk must not be able to drive a section into a numerical
/// corner.
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
        let low = Self.lowShelf(gainDB: settings.lowGain, cutoff: lowHz, sampleRate: sampleRate)
        let mid = Self.peak(gainDB: settings.midGain, cutoff: midHz, q: midQ, sampleRate: sampleRate)
        let high = Self.highShelf(gainDB: settings.highGain, cutoff: highHz, sampleRate: sampleRate)
        Self.set(low, on: &lowLeft)
        Self.set(low, on: &lowRight)
        Self.set(mid, on: &midLeft)
        Self.set(mid, on: &midRight)
        Self.set(high, on: &highLeft)
        Self.set(high, on: &highRight)
    }

    private static func set(_ coefficients: Coefficients?, on section: inout Biquad) {
        guard let coefficients else {
            section.passThrough()
            return
        }
        section.apply(coefficients)
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
        let alpha = sin(omega) / 2.0 * Double(2).squareRoot()
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
        let alpha = sin(omega) / 2.0 * Double(2).squareRoot()
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
