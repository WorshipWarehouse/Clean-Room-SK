import Foundation

/// A modulated delay line: the classic chorus, with the wet copy of the signal read
/// from a delay that sweeps between 12 ms and 12 ms plus the configured depth.
///
/// The line is fixed at 50 ms, allocated once before audio starts. Unit delay
/// changes are read with linear interpolation, so a sweep is a smooth pitch wobble
/// rather than a sequence of clicks, and the LFO is a plain sine evaluated per
/// sample, which costs a handful of cycles and allocates nothing.
public final class ChorusProcessor {
    public let sampleRate: Double

    private let storage: UnsafeMutablePointer<Float>
    private let length: Int
    private var index = 0
    private var phase: Double = 0
    private var wasEnabled = false

    private let baseSeconds: Double = 0.012
    private let sweepSeconds: Double = 0.008

    public init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        length = max(8, Int(0.05 * rate) + 4)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: length)
        storage.initialize(repeating: 0, count: length)
    }

    deinit {
        storage.deinitialize(count: length)
        storage.deallocate()
    }

    /// Render thread only.
    public func process(
        into buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        settings: ChorusSettings
    ) {
        guard settings.enabled else {
            if wasEnabled {
                clear()
                wasEnabled = false
            }
            return
        }
        wasEnabled = true

        let frames = min(frameCount, buffer.count)
        let rate = min(max(settings.rate, EffectRanges.chorusRate.lowerBound), EffectRanges.chorusRate.upperBound)
        let depth = min(max(settings.depth, EffectRanges.chorusDepth.lowerBound), EffectRanges.chorusDepth.upperBound)
        let mix = min(max(settings.mix, EffectRanges.mix.lowerBound), EffectRanges.mix.upperBound)
        let dry = 1 - mix
        let increment = Double(rate) / sampleRate
        let base = baseSeconds * sampleRate
        let sweep = Double(depth) * sweepSeconds * sampleRate

        var frame = 0
        while frame < frames {
            let input = buffer[frame]

            let lfo = 0.5 + 0.5 * sin(phase * 2.0 * Double.pi)
            let delay = base + sweep * lfo

            var readPosition = Double(index) - delay
            while readPosition < 0 {
                readPosition += Double(length)
            }
            let whole = Int(readPosition)
            let fraction = Float(readPosition - Double(whole))
            let firstIndex = whole % length
            let secondIndex = (firstIndex + 1) % length
            let first = storage[firstIndex]
            let second = storage[secondIndex]
            let delayed = first + (second - first) * fraction

            storage[index] = input
            index += 1
            if index >= length {
                index = 0
            }

            buffer[frame] = input * dry + delayed * mix

            phase += increment
            if phase >= 1 {
                phase -= 1
            }
            frame += 1
        }
    }

    private func clear() {
        var position = 0
        while position < length {
            storage[position] = 0
            position += 1
        }
        index = 0
        phase = 0
    }
}
