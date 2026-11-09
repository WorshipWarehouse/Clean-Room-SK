import Foundation
import os

/// Voice allocation and sample generation.
///
/// Render-thread rules that this file must keep:
/// - no allocation, no formatting, no Swift `print`, no throws on the render path
/// - state is shared with the MIDI thread through a single unfair lock that the
///   render path only ever try-locks, so it can never block the audio device
/// - when the try-lock fails the buffer keeps whatever the caller wrote, which is
///   silence, so the failure mode is a dropped buffer rather than a stall
///
/// The oscillator is a deliberately simple sine so the graph can be heard and
/// measured. Sample playback replaces it once the sampler milestone starts.
final class VoiceBank {
    struct Voice {
        var note: UInt8 = 0
        var phase: Double = 0
        var increment: Double = 0
        var gain: Float = 0
        var target: Float = 0
        var active: Bool = false
    }

    private var voices: [Voice]
    private var lock = os_unfair_lock_s()
    private var sampleRate: Double = 48_000

    init(capacity: Int = 16) {
        voices = Array(repeating: Voice(), count: capacity)
    }

    func setSampleRate(_ rate: Double) {
        os_unfair_lock_lock(&lock)
        sampleRate = rate > 0 ? rate : 48_000
        os_unfair_lock_unlock(&lock)
    }

    func noteOn(note: UInt8, velocity: Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let index = voices.firstIndex { !$0.active || $0.note == note } ?? 0
        var voice = Voice()
        voice.note = note
        let frequency = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
        voice.increment = frequency / sampleRate
        voice.gain = velocity
        voice.target = velocity
        voice.active = true
        voices[index] = voice
    }

    func noteOff(note: UInt8) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for index in voices.indices where voices[index].active && voices[index].note == note {
            voices[index].target = 0
        }
    }

    func allNotesOff() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for index in voices.indices {
            voices[index].target = 0
        }
    }

    /// Mixes active voices into the buffer. Returns false when the lock was held.
    @discardableResult
    func render(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) -> Bool {
        guard os_unfair_lock_trylock(&lock) else { return false }
        defer { os_unfair_lock_unlock(&lock) }

        let smoothing: Float = 0.002
        let frames = min(frameCount, buffer.count)

        for frame in 0..<frames {
            var sample: Float = 0
            for index in voices.indices where voices[index].active {
                voices[index].phase += voices[index].increment
                if voices[index].phase >= 1 {
                    voices[index].phase -= 1
                }
                voices[index].gain += (voices[index].target - voices[index].gain) * smoothing
                let amplitude = sinf(Float(voices[index].phase) * 2 * Float.pi)
                sample += amplitude * voices[index].gain * 0.15

                if voices[index].target == 0 && voices[index].gain < 0.0005 {
                    voices[index].active = false
                }
            }
            buffer[frame] += sample
        }
        return true
    }
}
