import AVFoundation
import Foundation
import SundayKeysCore

/// Owns the audio graph.
///
/// Graph: `AVAudioSourceNode` -> `mainMixerNode` -> `outputNode`.
///
/// Render-thread design for this milestone:
/// - the render block allocates nothing, formats nothing, and performs no locking
///   that can block; it hands the buffer to `VoiceBank`, which try-locks and
///   returns silence rather than waiting when a MIDI update is in flight
/// - parameters that the render thread reads are only mutated behind that same
///   lock, so no torn reads are possible
/// - the engine and node are created, attached and detached only on the main
///   actor, never while the render thread is running
///
/// Known limitation, tracked for the next audio milestone: the try-lock drops
/// audio the moment two events collide. It is replaced by a lock-free single
/// producer queue before this is used live.
final class AudioEngineController {
    private let engine = AVAudioEngine()
    private let voices = VoiceBank()
    private let curve = VelocityCurve()
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0

    func start() throws {
        guard !isRunning else { return }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NSError(
                domain: "SundayKeysAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create a stereo render format"]
            )
        }

        sampleRate = rate
        voices.setSampleRate(rate)

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            for index in 0..<buffers.count {
                guard let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let pointer = UnsafeMutableBufferPointer(start: data, count: frames)
                for frame in pointer.indices {
                    pointer[frame] = 0
                }
                self.voices.render(into: pointer, frameCount: frames)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw error
        }

        sourceNode = node
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        voices.allNotesOff()
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        isRunning = false
    }

    func noteOn(note: UInt8, velocity: UInt8) {
        voices.noteOn(note: note, velocity: curve.gain(forVelocity: velocity))
    }

    func noteOff(note: UInt8) {
        voices.noteOff(note: note)
    }
}
