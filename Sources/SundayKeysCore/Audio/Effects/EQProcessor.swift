import Foundation

/// A three-band voicing stage built from two one-pole splits.
///
/// The low band is a one-pole lowpass at 250 Hz, the high band is the residue of a
/// one-pole lowpass at 3 kHz, and the middle band is whatever is left. Because
/// `low + mid + high` is exactly the input, the stage is transparent at unity gain
/// rather than approximately transparent, which is what lets the test assert an
/// exact dry match and what lets the chain leave the EQ engaged without cost.
public final class EQProcessor {
    public let sampleRate: Double

    private let lowCutoff: Double = 250
    private let highCutoff: Double = 3_000

    private var lowState: Float = 0
    private var highState: Float = 0
    private var wasEnabled = false

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
    }

    /// Render thread only.
    public func process(
        into buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        settings: EQSettings
    ) {
        guard settings.enabled else {
            if wasEnabled {
                lowState = 0
                highState = 0
                wasEnabled = false
            }
            return
        }
        wasEnabled = true

        let frames = min(frameCount, buffer.count)
        let lowGain = Float(pow(10.0, Double(min(max(settings.lowGain, EffectRanges.eqGainDB.lowerBound), EffectRanges.eqGainDB.upperBound)) / 20.0))
        let highGain = Float(pow(10.0, Double(min(max(settings.highGain, EffectRanges.eqGainDB.lowerBound), EffectRanges.eqGainDB.upperBound)) / 20.0))
        let lowCoefficient = Float(1 - exp(-2.0 * Double.pi * lowCutoff / sampleRate))
        let highCoefficient = Float(1 - exp(-2.0 * Double.pi * highCutoff / sampleRate))

        var frame = 0
        while frame < frames {
            let input = buffer[frame]

            lowState += lowCoefficient * (input - lowState)
            highState += highCoefficient * (input - highState)

            let low = lowState
            let high = input - highState
            let mid = input - low - high

            buffer[frame] = low * lowGain + mid + high * highGain
            frame += 1
        }
    }
}
