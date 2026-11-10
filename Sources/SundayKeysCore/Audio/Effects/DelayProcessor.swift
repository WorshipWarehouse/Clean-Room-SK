import Foundation

/// A feedback delay with a fixed 1.2 s line and a fractional read.
///
/// The read position is smoothed towards the configured time over about 30 ms, so
/// dragging the time control bends the tail instead of cutting it, and the line is
/// long enough for the whole documented range. Feedback is clamped below one, which
/// is what guarantees the repeats decay.
public final class DelayProcessor {
    public let sampleRate: Double

    private let storage: UnsafeMutablePointer<Float>
    private let length: Int
    private var index = 0
    private var smoothedDelay: Double = 0
    private var primed = false
    private var wasEnabled = false

    private let glideSeconds: Double = 0.03

    public init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        length = max(16, Int(Double(EffectRanges.delayTime.upperBound) * rate) + 4)
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
        settings: DelaySettings
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
        let seconds = min(max(settings.time, EffectRanges.delayTime.lowerBound), EffectRanges.delayTime.upperBound)
        let target = Double(seconds) * sampleRate
        if !primed {
            smoothedDelay = target
            primed = true
        }

        let glide = 1 - exp(-1.0 / (glideSeconds * sampleRate))
        let mix = min(max(settings.mix, EffectRanges.mix.lowerBound), EffectRanges.mix.upperBound)
        let dry = 1 - mix
        let feedback = min(max(settings.feedback, EffectRanges.delayFeedback.lowerBound), EffectRanges.delayFeedback.upperBound)

        var frame = 0
        while frame < frames {
            smoothedDelay += (target - smoothedDelay) * glide

            let input = buffer[frame]

            var readPosition = Double(index) - smoothedDelay
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

            storage[index] = input + delayed * feedback
            index += 1
            if index >= length {
                index = 0
            }

            buffer[frame] = input * dry + delayed * mix
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
        smoothedDelay = 0
        primed = false
    }
}
