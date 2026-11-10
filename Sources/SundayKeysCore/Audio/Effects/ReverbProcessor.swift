import Foundation

/// A Schroeder reverb: four damped comb filters in parallel into two allpass
/// filters in series.
///
/// The delay times are this implementation's own choice, picked for a room-sized
/// spread between roughly 30 ms and 44 ms, and the two allpasses at 5 ms and 1.7 ms
/// smear the comb output into a tail instead of a flam. Damping is a one-pole
/// lowpass inside each comb's feedback path, so a long decay darkens as it dies
/// away, which is what keeps it from sounding like a metal pipe.
///
/// Every buffer is allocated at construction, on the control thread. `process`
/// reads and writes only those buffers and cannot allocate, and feedback is
/// clamped below one, so the tail always decays.
public final class ReverbProcessor {
    public let sampleRate: Double

    private struct DelayLine {
        private let storage: UnsafeMutablePointer<Float>
        private let length: Int
        private var index: Int

        init(samples: Int) {
            let size = max(1, samples)
            length = size
            storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
            storage.initialize(repeating: 0, count: size)
            index = 0
        }

        func read() -> Float {
            storage[index]
        }

        mutating func write(_ value: Float) {
            storage[index] = value
            index += 1
            if index >= length {
                index = 0
            }
        }

        mutating func clear() {
            var position = 0
            while position < length {
                storage[position] = 0
                position += 1
            }
            index = 0
        }

        func release() {
            storage.deinitialize(count: length)
            storage.deallocate()
        }
    }

    private var comb1: DelayLine
    private var comb2: DelayLine
    private var comb3: DelayLine
    private var comb4: DelayLine
    private var allpass1: DelayLine
    private var allpass2: DelayLine

    private var damped1: Float = 0
    private var damped2: Float = 0
    private var damped3: Float = 0
    private var damped4: Float = 0

    private var wasEnabled = false
    private let wetGain: Float = 0.9

    public init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        comb1 = DelayLine(samples: Int(0.0297 * rate))
        comb2 = DelayLine(samples: Int(0.0371 * rate))
        comb3 = DelayLine(samples: Int(0.0413 * rate))
        comb4 = DelayLine(samples: Int(0.0439 * rate))
        allpass1 = DelayLine(samples: Int(0.0050 * rate))
        allpass2 = DelayLine(samples: Int(0.0017 * rate))
    }

    deinit {
        comb1.release()
        comb2.release()
        comb3.release()
        comb4.release()
        allpass1.release()
        allpass2.release()
    }

    /// Render thread only.
    public func process(
        into buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        settings: ReverbSettings
    ) {
        guard settings.enabled else {
            if wasEnabled {
                reset()
                wasEnabled = false
            }
            return
        }
        wasEnabled = true

        let frames = min(frameCount, buffer.count)
        let decay = min(max(settings.decay, EffectRanges.reverbDecay.lowerBound), EffectRanges.reverbDecay.upperBound)
        let damping = min(max(settings.damping, EffectRanges.reverbDamping.lowerBound), EffectRanges.reverbDamping.upperBound)
        let mix = min(max(settings.mix, EffectRanges.mix.lowerBound), EffectRanges.mix.upperBound)
        let dry = 1 - mix
        let feedback = min(max(0.35 + 0.58 * decay, 0.2), 0.93)
        let dampingCoefficient = damping * 0.7

        var frame = 0
        while frame < frames {
            let input = buffer[frame]

            let out1 = comb1.read()
            damped1 = out1 + dampingCoefficient * (damped1 - out1)
            comb1.write(input + damped1 * feedback)

            let out2 = comb2.read()
            damped2 = out2 + dampingCoefficient * (damped2 - out2)
            comb2.write(input + damped2 * feedback)

            let out3 = comb3.read()
            damped3 = out3 + dampingCoefficient * (damped3 - out3)
            comb3.write(input + damped3 * feedback)

            let out4 = comb4.read()
            damped4 = out4 + dampingCoefficient * (damped4 - out4)
            comb4.write(input + damped4 * feedback)

            var wet = (out1 + out2 + out3 + out4) * 0.25

            let buffered1 = allpass1.read()
            let passed1 = buffered1 - wet
            allpass1.write(wet + buffered1 * 0.5)
            wet = passed1

            let buffered2 = allpass2.read()
            let passed2 = buffered2 - wet
            allpass2.write(wet + buffered2 * 0.5)
            wet = passed2

            buffer[frame] = input * dry + wet * mix * wetGain
            frame += 1
        }
    }

    private func reset() {
        comb1.clear()
        comb2.clear()
        comb3.clear()
        comb4.clear()
        allpass1.clear()
        allpass2.clear()
        damped1 = 0
        damped2 = 0
        damped3 = 0
        damped4 = 0
    }
}
